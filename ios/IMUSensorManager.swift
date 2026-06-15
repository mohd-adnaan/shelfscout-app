//
//  IMUSensorManager.swift
//  IndoorNavigationTACME
//
//

import Foundation
import CoreMotion
import Combine

class IMUSensorManager: ObservableObject {
    
    // MARK: - Published Properties
    @Published var imuState = IMUState()
    
    // MARK: - Private Properties
    private let motionManager = CMMotionManager()
    private var calibrationManager: IMUCalibrationManager?
    private let stepFactorCalibration = UserStepFactorCalibration()
    
    // Sensor update interval
    private let sensorUpdateInterval: TimeInterval = 0.02 // 50Hz
    
    // Dedicated serial queue for all sensor processing (keeps main thread free)
    private let sensorQueue = DispatchQueue(label: "com.tacme.imu.sensor", qos: .userInteractive)
    
    // Position tracking
    private var currentX: Double = 0
    private var currentY: Double = 0
    private var currentBearing: Double = 0
    private var stepCount: Int = 0
    private var currentStepLength: Double = 0.65
    
    // Gyroscope integration
    private var gyroIntegrationBearing: Double = 0
    private var initialBearingSet: Bool = false
    private var lastTimestamp: TimeInterval = 0
    
    // Step detection - MATCHING ANDROID
    private var filteredAcceleration: [Double] = []
    private var accelerationTimestamps: [TimeInterval] = []
    private var accelerationVariances: [Double] = []
    private var detectedPeaks: [Double] = []
    private var recentStepPeriods: [TimeInterval] = []
    private var lastStepTime: Date?
    private var pendingStepCandidateTime: Date?
    
    // Peak-valley detection
    // Uses SIGNED vertical projection (dot product with gravity vector) which gives
    // a clean oscillation of ~±0.1-0.3 during walking.
    private var lastPeak: Double = 0
    private var lastValley: Double = 0
    private var lastPeakTime: TimeInterval = 0
    // FIX: Raised from 0.025 → 0.12. The old threshold was far too low —
    // light phone shaking produces pvDiffs of 0.09-0.18 which all passed through.
    // Real walking pvDiffs are consistently 0.25-0.73. Setting to 0.12 provides
    // margin for gentle walking while rejecting shaking/tremor.
    private let stepPeakThreshold: Double = 0.12
    
    // FIX: Raised absolute amplitude floors.
    // Old values (peak=0.06, valley=-0.03) allowed hand tremor (±0.05-0.10) through.
    // Walking peaks are consistently >0.10, valleys consistently < -0.06.
    private let absoluteMinPeakAmplitude: Double = 0.08
    private let absoluteMinValleyAmplitude: Double = -0.05
    // Maximum age (seconds) for a peak to be used in pvDiff calculation.
    // Prevents stale peaks from walking contaminating standstill detection.
    private let maxPeakAge: TimeInterval = 2.0
    
    // FIX: Ported from Android — Similarity constraint.
    // After 6+ confirmed steps, rejects new peaks whose magnitude deviates
    // more than 3σ from the running average of confirmed step peaks.
    // This makes step detection adaptive to the user's walking intensity.
    private var confirmedStepPeakMagnitudes: [Double] = []
    private let similarityMinSteps = 6
    private let similarityMaxDeviations: Double = 3.0
    private let similarityMaxHistory = 20
    
    // FIX: Ported from Android — Continuity constraint.
    // Requires 4 out of the last 7 variance windows to be "active" (above threshold),
    // ensuring continuous walking motion rather than a one-off shake.
    private let continuityWindowSize = 7
    private let continuityThreshold = 4
    
    // Real Butterworth bandpass filter (SAME COEFFICIENTS AS ANDROID)
    private let butterworthFilter = ButterworthBandpassFilter()
    
    // Filter parameters
    private let dynamicWindowSize = 50
    // Raised from 0.0003 to 0.0005: the old value was too low to detect
    // the phone settling/weight-shifting at standstill. pvDiffs of 0.03-0.06
    // were passing through and registering as ghost steps.
    private let varianceThreshold: Double = 0.0005
    
    // Bearing correction
    private var pathBearings: [Double] = []
    private var currentSegmentId: Int = -1
    private var bearingCorrectionCount: Int = 0
    private let bearingCorrectionThreshold: Double = 25.0
    
    // Constants
    private let gyroNoiseThreshold: Double = 0.01
    private let maxGyroRate: Double = 5.0
    
    // FIX: Default beta raised from 0.6 to 0.8 for iOS.
    // Android uses raw accelerometer magnitude (pvDiff ~1.0-5.0, pvDiff^0.25 ~1.0-1.5).
    // iOS uses filtered vertical acceleration (pvDiff ~0.3-0.7, pvDiff^0.25 ~0.74-0.92).
    // With Android beta=0.6: step = 0.6 * 1.2 = 0.72m
    // With iOS beta=0.6:     step = 0.6 * 0.84 = 0.50m (too short!)
    // With iOS beta=0.8:     step = 0.8 * 0.84 = 0.67m (correct)
    private let defaultBeta: Double = 0.8
    
    // Step timing constraints
    private let minStepPeriod: TimeInterval = 0.3
    private let maxStepPeriod: TimeInterval = 1.2
    // Stationary variance gate: when recent variance indicates standstill,
    // require pvDiff to exceed stepPeakThreshold * 2.0 (i.e. 0.24).
    // This is a secondary soft gate; the primary hard gate is the continuity constraint.
    private let stationaryVarianceGateMultiplier: Double = 0.6
    
    // Acceleration logging
    private var accelerationLogger = AccelerationLogger()
    
    // Debug
    private var totalSamples: Int = 0
    private var lastDebugLog: Date = Date.distantPast
    
    // MARK: - Initialization
    init() {
        setupMotionManager()
        imuState.beta = stepFactorCalibration.getUserBeta()
        imuState.isStepCalibrationValid = stepFactorCalibration.isCalibrationValid()
        print("IMUSensorManager: Initialized")
    }
    
    deinit {
        stopSensors()
    }
    
    // MARK: - Public Methods
    
    func setCalibrationManager(_ manager: IMUCalibrationManager) {
        self.calibrationManager = manager
    }
    
    func startSensors() {
        guard motionManager.isDeviceMotionAvailable else {
            print("IMUSensorManager: Device motion not available")
            return
        }

        guard !motionManager.isDeviceMotionActive else {
            return
        }
        
        motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: OperationQueue()) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    print("IMUSensorManager: Motion error: \(error)")
                }
                return
            }
            // Process sensor data on dedicated background queue (not main thread)
            self.sensorQueue.async {
                self.processMotionUpdate(motion)
            }
        }
        
        print("IMUSensorManager: Started updates at \(1.0/sensorUpdateInterval)Hz")
    }
    
    func stopSensors() {
        motionManager.stopDeviceMotionUpdates()
        print("IMUSensorManager: Sensors stopped")
    }
    
    func resetPosition() {
        // FIX B: Route through sensorQueue to avoid data races with processMotionUpdate.
        sensorQueue.sync {
            currentX = 0
            currentY = 0
            stepCount = 0
            filteredAcceleration.removeAll()
            accelerationTimestamps.removeAll()
            accelerationVariances.removeAll()
            detectedPeaks.removeAll()
            confirmedStepPeakMagnitudes.removeAll()
            recentStepPeriods.removeAll()
            lastStepTime = nil
            pendingStepCandidateTime = nil
            lastPeak = 0
            lastValley = 0
            lastPeakTime = 0
            butterworthFilter.reset()
            accelerationLogger.clear()
            totalSamples = 0
            updateIMUState()
        }
        print("IMUSensorManager: Position reset (thread-safe)")
    }
    
    /// FIX: Position-only reset that preserves filter and step detection momentum.
    /// Used for segment_change recalibration instead of full resetPosition().
    ///
    /// Full resetPosition() kills the Butterworth filter state, which means the
    /// first 1-2 steps after recalibration have distorted pvDiff values (~20% lower),
    /// producing shorter step lengths. Over a 5m segment, this accumulates to ~0.5m
    /// of position lag — enough to cause announcements to arrive after the user
    /// has already passed the landmark.
    ///
    /// This method resets ONLY position/stepCount while preserving:
    /// - Butterworth filter coefficients → no warmup delay
    /// - Peak/valley detection state → continuous step detection
    /// - Step timing and periods → no "first step" penalty
    /// - Acceleration variances → continuity constraint stays warm
    func resetPositionOnly() {
        sensorQueue.sync {
            currentX = 0
            currentY = 0
            stepCount = 0
            // Preserve: filteredAcceleration, accelerationTimestamps, accelerationVariances
            // Preserve: lastPeak, lastValley, lastPeakTime
            // Preserve: butterworthFilter state
            // Preserve: recentStepPeriods, lastStepTime, pendingStepCandidateTime
            // Preserve: confirmedStepPeakMagnitudes (similarity constraint stays warm)
            
            // Only clear the logger and detected peaks display list
            detectedPeaks.removeAll()
            accelerationLogger.clear()
            totalSamples = 0
            updateIMUState()
        }
        print("IMUSensorManager: Position-only reset (filter preserved)")
    }
    
    func setInitialBearing(_ bearing: Double) {
        sensorQueue.sync {
            gyroIntegrationBearing = bearing
            currentBearing = bearing
            initialBearingSet = true
            updateIMUState()
        }
        print("IMUSensorManager: Initial bearing set to \(bearing)°")
    }
    
    func getCurrentPosition() -> Position {
        return sensorQueue.sync {
            Position(x: currentX, y: currentY, bearing: currentBearing)
        }
    }
    
    /// Internal-only: returns position WITHOUT sensorQueue.sync.
    /// MUST only be called from code already executing on sensorQueue
    /// (processMotionUpdate → confirmStep, updateIMUState, etc.)
    private func _unsafeGetCurrentPosition() -> Position {
        return Position(x: currentX, y: currentY, bearing: currentBearing)
    }
    
    func getCurrentMapPosition() -> Position? {
        return calibrationManager?.transformToMapPosition(getCurrentPosition())
    }
    
    func setBearingCorrectionData(_ bearings: [Double], _ segmentId: Int) {
        sensorQueue.sync {
            pathBearings = bearings
            currentSegmentId = segmentId
        }
        print("IMUSensorManager: Bearing correction data set - \(bearings.count) bearings, segment \(segmentId)")
    }
    
    func startStepCalibration() {
        stepFactorCalibration.startCalibration()
        imuState.isCalibrating = true
    }
    
    func completeStepCalibration() {
        stepFactorCalibration.completeCalibration()
        imuState.beta = stepFactorCalibration.getUserBeta()
        imuState.isStepCalibrationValid = stepFactorCalibration.isCalibrationValid()
        imuState.isCalibrating = false
    }
    
    func stopStepCalibration() {
        let _ = stepFactorCalibration.stopCalibration()
        imuState.beta = stepFactorCalibration.getUserBeta()
        imuState.isStepCalibrationValid = stepFactorCalibration.isCalibrationValid()
        imuState.isCalibrating = false
    }

    /// Wipe the persisted step-factor calibration. Call before handing the device
    /// to a new user so they can recalibrate for their own gait. Resets `imuState`
    /// to reflect the cleared values immediately.
    func clearStepCalibration() {
        stepFactorCalibration.clearPersisted()
        imuState.beta = stepFactorCalibration.getUserBeta()
        imuState.isStepCalibrationValid = stepFactorCalibration.isCalibrationValid()
        imuState.isCalibrating = false
        imuState.calibrationStepCount = 0
        print("IMUSensorManager: Step calibration cleared — beta reset to \(imuState.beta)")
    }

    func getStepDetectionMetrics() -> [String: Any] {
        return [
            "totalSteps": stepCount,
            "averageStepLength": String(format: "%.2f", currentStepLength),
            "recentStepPeriods": recentStepPeriods.suffix(5),
            "dynamicWindowSize": dynamicWindowSize,
            "filterStatus": "Butterworth 0.8-4Hz",
            "totalSamples": totalSamples,
            "lastPeak": String(format: "%.4f", lastPeak),
            "lastValley": String(format: "%.4f", lastValley)
        ]
    }
    
    func getBearingCorrectionStats() -> [String: Any] {
        return [
            "pathBearingsCount": pathBearings.count,
            "currentSegmentId": currentSegmentId,
            "bearingCorrectionCount": bearingCorrectionCount,
            "bearingThreshold": bearingCorrectionThreshold,
            "currentBearing": String(format: "%.1f°", currentBearing)
        ]
    }
    
    func getAccelerationSamples() -> [AccelerationSample] {
        return sensorQueue.sync { accelerationLogger.getSamples() }
    }
    
    func getAccelerationLoggerStatistics() -> (totalSamples: Int, peakCount: Int, valleyCount: Int, confirmedStepCount: Int, timeSpanMs: Int64) {
        return sensorQueue.sync { accelerationLogger.getStatistics() }
    }
    
    func getSensorStatus() -> [String: Any] {
        return [
            "isInitialized": motionManager.isDeviceMotionActive,
            "stepCount": stepCount,
            "position": "(\(String(format: "%.2f", currentX)), \(String(format: "%.2f", currentY)))",
            "bearing": "\(String(format: "%.1f", currentBearing))°",
            "currentStepLength": "\(String(format: "%.2f", currentStepLength))m",
            "dynamicWindowSize": dynamicWindowSize,
            "filterQuality": imuState.filterQuality,
            "stepStability": String(format: "%.2f", imuState.stepStability),
            "headingReliability": String(format: "%.2f", imuState.headingReliability),
            "pdrUncertaintyMeters": String(format: "%.2f", imuState.pdrUncertaintyMeters),
            "detectedPeaks": detectedPeaks.count,
            "totalSamples": totalSamples
        ]
    }
    
    // MARK: - Private Methods
    
    private func setupMotionManager() {
        motionManager.deviceMotionUpdateInterval = sensorUpdateInterval
    }
    
    private func processMotionUpdate(_ motion: CMDeviceMotion) {
        let timestamp = motion.timestamp
        processAccelerometer(motion, timestamp: timestamp)
        processGyroscope(motion.rotationRate, timestamp: timestamp)
        updateIMUState()
    }
    
    private func processAccelerometer(_ motion: CMDeviceMotion, timestamp: TimeInterval) {
        let acceleration = motion.userAcceleration
        let gravity = motion.gravity
        
        // FIX: Use SIGNED vertical projection instead of unsigned magnitude.
        // The dot product of userAcceleration with the gravity unit vector gives
        // the acceleration component along the vertical axis. During walking this
        // oscillates cleanly (positive on heel strike push-up, negative during fall).
        // The unsigned magnitude (sqrt(x²+y²+z²)) collapses positive and negative
        // phases together, halving the effective amplitude and making the bandpass
        // filter output ~34x weaker than what Android sees.
        let gravityMagnitude = sqrt(gravity.x * gravity.x +
                                    gravity.y * gravity.y +
                                    gravity.z * gravity.z)
        let verticalAccel: Double
        if gravityMagnitude > 0.01 {
            // Project userAcceleration onto gravity direction (signed)
            verticalAccel = (acceleration.x * gravity.x +
                             acceleration.y * gravity.y +
                             acceleration.z * gravity.z) / gravityMagnitude
        } else {
            // Fallback if gravity not available (shouldn't happen in practice)
            verticalAccel = acceleration.z
        }
        
        // Also compute magnitude for logging
        let magnitude = sqrt(acceleration.x * acceleration.x +
                             acceleration.y * acceleration.y +
                             acceleration.z * acceleration.z)
        
        totalSamples += 1
        
        // Apply Butterworth bandpass filter to the SIGNED vertical signal
        let filtered = butterworthFilter.filter(verticalAccel)
        
        // Log sample
        accelerationLogger.addSample(AccelerationSample(
            sampleIndex: 0, // overridden by logger
            timestamp: Date(),
            x: acceleration.x,
            y: acceleration.y,
            z: acceleration.z,
            magnitude: magnitude,
            filtered: filtered
        ))
        
        accelerationTimestamps.append(timestamp)
        filteredAcceleration.append(filtered)
        
        // Maintain window
        if filteredAcceleration.count > dynamicWindowSize {
            filteredAcceleration.removeFirst()
            accelerationTimestamps.removeFirst()
        }
        
        // Calculate variance
        if filteredAcceleration.count >= dynamicWindowSize {
            let variance = calculateVariance(Array(filteredAcceleration))
            accelerationVariances.append(variance)
            if accelerationVariances.count > dynamicWindowSize {
                accelerationVariances.removeFirst()
            }
        }
        
        // Peak-valley step detection
        if filteredAcceleration.count >= 3 {
            detectPeaksAndValidateSteps(timestamp: timestamp)
        }
        
        // Periodic debug logging (every 5 seconds)
        if Date().timeIntervalSince(lastDebugLog) > 5.0 && totalSamples > 0 {
            lastDebugLog = Date()
            let recentMax = filteredAcceleration.max() ?? 0
            let recentMin = filteredAcceleration.min() ?? 0
            print("IMUSensorManager: [DEBUG] samples=\(totalSamples), steps=\(stepCount), range=[\(String(format: "%.4f", recentMin))...\(String(format: "%.4f", recentMax))], peak=\(String(format: "%.4f", lastPeak)), valley=\(String(format: "%.4f", lastValley))")
        }
    }
    
    // MARK: - Peak-Valley Step Detection
    
    private func detectPeaksAndValidateSteps(timestamp: TimeInterval) {
        guard filteredAcceleration.count >= 3 else { return }
        
        let mean = filteredAcceleration.reduce(0, +) / Double(filteredAcceleration.count)
        let std = calculateStd(filteredAcceleration, mean: mean)
        
        let upperThreshold = mean + std * 1.0
        let lowerThreshold = mean - std * 0.5
        
        let n = filteredAcceleration.count
        let current = filteredAcceleration[n - 1]
        let previous = filteredAcceleration[n - 2]
        let beforePrevious = filteredAcceleration[n - 3]
        
        // Peak detection: local maximum above BOTH the dynamic upper threshold
        // AND the absolute minimum amplitude (rejects hand tremor at standstill).
        if previous > beforePrevious &&
            previous > current &&
            previous > upperThreshold &&
            previous > absoluteMinPeakAmplitude {
            lastPeak = previous
            lastPeakTime = accelerationTimestamps.count >= 2 ?
            accelerationTimestamps[accelerationTimestamps.count - 2] : timestamp
            accelerationLogger.markLastSampleAsPeak()
        }
        
        // Valley detection: local minimum below BOTH thresholds (after a peak)
        if previous < beforePrevious &&
            previous < current &&
            previous < lowerThreshold &&
            previous < absoluteMinValleyAmplitude &&
            lastPeakTime > 0 {
            
            // Reject stale peaks from a previous walking burst
            let peakAge = timestamp - lastPeakTime
            guard peakAge <= maxPeakAge else {
                lastPeakTime = 0
                return
            }
            
            lastValley = previous
            let peakValleyDiff = lastPeak - lastValley
            accelerationLogger.markLastSampleAsValley()
            
            // FIX: Use the HIGHER of the base threshold and the adaptive calibrated threshold.
            // After calibration, the system learns the user's typical pvDiff and uses 25% of
            // the average as a floor — this makes step detection adapt to the user's walking
            // pattern and rejects movements that are too weak relative to their normal gait.
            let adaptiveThreshold = stepFactorCalibration.getAdaptivePvDiffThreshold()
            let effectiveThreshold = max(stepPeakThreshold, adaptiveThreshold)
            
            if peakValleyDiff > effectiveThreshold {
                let currentDate = Date()
                
                // Soft gate: raise threshold further when stationary
                let recentVariance = accelerationVariances.suffix(5).reduce(0, +) /
                Double(max(accelerationVariances.suffix(5).count, 1))
                let isStationary = recentVariance < (varianceThreshold * stationaryVarianceGateMultiplier)
                if isStationary && peakValleyDiff < (effectiveThreshold * 2.0) {
                    pendingStepCandidateTime = nil
                    return
                }
                
                // FIX: Ported from Android — Continuity constraint (hard gate).
                // Requires sustained motion across multiple variance windows.
                // Rejects one-off shakes that produce a single large pvDiff.
                if !checkContinuityConstraint() {
                    return
                }
                
                // FIX: Ported from Android — Similarity constraint (adaptive gate).
                // After 6+ confirmed steps, rejects peaks whose magnitude deviates
                // more than 3σ from the running average. This learns the user's
                // walking intensity and rejects outliers (e.g., phone bumps).
                if !checkSimilarityConstraint(peakMagnitude: lastPeak) {
                    return
                }
                
                if let lastStep = lastStepTime {
                    let timeSinceLastStep = currentDate.timeIntervalSince(lastStep)
                    
                    if timeSinceLastStep >= minStepPeriod && timeSinceLastStep <= maxStepPeriod {
                        confirmStep(peakValleyDiff: peakValleyDiff, period: timeSinceLastStep, date: currentDate)
                    } else if timeSinceLastStep > maxStepPeriod {
                        // Require two close candidates to resume counting after long idle
                        if let candidateTime = pendingStepCandidateTime {
                            let candidateGap = currentDate.timeIntervalSince(candidateTime)
                            if candidateGap >= minStepPeriod && candidateGap <= maxStepPeriod {
                                confirmStep(peakValleyDiff: peakValleyDiff, period: candidateGap, date: currentDate)
                                pendingStepCandidateTime = nil
                            } else {
                                pendingStepCandidateTime = currentDate
                            }
                        } else {
                            pendingStepCandidateTime = currentDate
                        }
                    }
                } else {
                    if let candidateTime = pendingStepCandidateTime {
                        let candidateGap = currentDate.timeIntervalSince(candidateTime)
                        if candidateGap >= minStepPeriod && candidateGap <= maxStepPeriod {
                            confirmStep(peakValleyDiff: peakValleyDiff, period: candidateGap, date: currentDate)
                            pendingStepCandidateTime = nil
                        } else {
                            pendingStepCandidateTime = currentDate
                        }
                    } else {
                        pendingStepCandidateTime = currentDate
                    }
                }
            }
        }
    }
    
    // MARK: - Step Validation Constraints (Ported from Android)
    
    /// Similarity constraint: after enough confirmed steps, reject peaks whose magnitude
    /// deviates more than 3σ from the running average. This adapts to the user's walking
    /// pattern — gentle walkers will have lower average peaks, vigorous walkers higher.
    private func checkSimilarityConstraint(peakMagnitude: Double) -> Bool {
        // Need sufficient history for meaningful comparison; allow all steps until then
        guard confirmedStepPeakMagnitudes.count >= similarityMinSteps else { return true }
        
        let avgMagnitude = confirmedStepPeakMagnitudes.reduce(0, +) /
        Double(confirmedStepPeakMagnitudes.count)
        let stdDev = calculateStd(confirmedStepPeakMagnitudes, mean: avgMagnitude)
        
        // If standard deviation is near-zero (very consistent walker), allow the step
        guard stdDev > 0.001 else { return true }
        
        let deviationFromMean = abs(peakMagnitude - avgMagnitude)
        let normalizedDeviation = deviationFromMean / stdDev
        
        return normalizedDeviation <= similarityMaxDeviations
    }
    
    /// Continuity constraint: requires sustained motion (4 out of 7 variance windows active).
    /// Prevents a single shake or bump from being counted as a step — real walking produces
    /// continuous elevated variance across multiple windows.
    private func checkContinuityConstraint() -> Bool {
        // Need sufficient variance history; allow steps during warmup
        guard accelerationVariances.count >= continuityWindowSize else { return true }
        
        let recentWindows = accelerationVariances.suffix(continuityWindowSize)
        let activeWindows = recentWindows.filter { $0 > varianceThreshold }.count
        
        return activeWindows >= continuityThreshold
    }
    
    private func confirmStep(peakValleyDiff: Double, period: TimeInterval, date: Date) {
        stepCount += 1
        lastStepTime = date
        pendingStepCandidateTime = nil
        
        recentStepPeriods.append(period)
        if recentStepPeriods.count > 10 { recentStepPeriods.removeFirst() }
        
        // FIX: Use calibrated beta for step length (same formula as Android).
        // The calibrated beta adapts the step length to the user's stride.
        let beta = stepFactorCalibration.isCalibrationValid() ?
        stepFactorCalibration.getUserBeta() : defaultBeta
        currentStepLength = beta * pow(peakValleyDiff, 0.25)
        // FIX: Removed the 0.3–1.2 clamp to match Android, which does NOT clamp.
        // The calibrated beta already accounts for the user's stride characteristics.
        
        // Mark sample as confirmed step (Android parity)
        accelerationLogger.markSampleAsConfirmedStep(
            timestamp: date,
            stepLength: currentStepLength,
            stepNumber: stepCount,
            peakValleyDiff: peakValleyDiff
        )
        
        if stepFactorCalibration.isCalibrating {
            stepFactorCalibration.addStepData(peakValleyDifference: peakValleyDiff)
        }
        
        detectedPeaks.append(lastPeak)
        if detectedPeaks.count > 20 { detectedPeaks.removeFirst() }
        
        // FIX: Track confirmed step peak magnitudes for the similarity constraint.
        // This enables adaptive step detection — after 6+ steps the system knows
        // the user's typical peak magnitude and rejects outliers.
        confirmedStepPeakMagnitudes.append(lastPeak)
        if confirmedStepPeakMagnitudes.count > similarityMaxHistory {
            confirmedStepPeakMagnitudes.removeFirst()
        }
        
        updatePosition()
        calibrationManager?.updateCalibration(currentImuPosition: _unsafeGetCurrentPosition(), stepCount: stepCount)
        
        print("IMUSensorManager: Step #\(stepCount) pvDiff=\(String(format: "%.3f", peakValleyDiff)), len=\(String(format: "%.2f", currentStepLength))m, bearing=\(String(format: "%.1f", currentBearing))°")
    }
    
    private func processGyroscope(_ rotationRate: CMRotationRate, timestamp: TimeInterval) {
        guard initialBearingSet else { return }
        
        if lastTimestamp != 0 {
            let dt = timestamp - lastTimestamp
            let gyroZ = rotationRate.z
            
            if abs(gyroZ) >= gyroNoiseThreshold && abs(gyroZ) <= maxGyroRate {
                let deltaBearing = gyroZ * dt * (-180.0 / .pi)
                gyroIntegrationBearing = (gyroIntegrationBearing + deltaBearing)
                    .truncatingRemainder(dividingBy: 360)
                if gyroIntegrationBearing < 0 { gyroIntegrationBearing += 360 }
                
                let result = applyBearingCorrection(gyroIntegrationBearing)
                currentBearing = result.bearing
            }
        }
        
        lastTimestamp = timestamp
    }
    
    private func updatePosition() {
        let bearingRad = currentBearing * .pi / 180.0
        currentX += currentStepLength * sin(bearingRad)
        currentY += currentStepLength * cos(bearingRad)
    }
    
    private func applyBearingCorrection(_ rawBearing: Double) -> BearingResult {
        guard currentSegmentId >= 0 && currentSegmentId < pathBearings.count else {
            return BearingResult(rawBearing, false)
        }
        let trueBearing = pathBearings[currentSegmentId]
        let diff = calculateBearingDifference(rawBearing, trueBearing)
        if abs(diff) <= bearingCorrectionThreshold {
            bearingCorrectionCount += 1
            return BearingResult(trueBearing, true)
        }
        return BearingResult(rawBearing, false)
    }
    
    private func calculateBearingDifference(_ bearing1: Double, _ bearing2: Double) -> Double {
        var diff = bearing1 - bearing2
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }
    
    private func calculateVariance(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        return values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    }
    
    private func calculateStd(_ values: [Double], mean: Double) -> Double {
        guard values.count > 1 else { return 0 }
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        return sqrt(variance)
    }
    
    private func updateIMUState() {
        let isMoving = !accelerationVariances.isEmpty &&
        accelerationVariances.suffix(3).contains { $0 > varianceThreshold }
        
        let filterQuality: String
        if detectedPeaks.count >= 3 && !recentStepPeriods.isEmpty {
            filterQuality = "Excellent"
        } else if filteredAcceleration.count >= dynamicWindowSize {
            filterQuality = "Good"
        } else {
            filterQuality = "Initializing"
        }

        let stepStability: Double
        if recentStepPeriods.count >= 3 {
            let avgPeriod = recentStepPeriods.reduce(0, +) / Double(recentStepPeriods.count)
            let stdPeriod = calculateStd(recentStepPeriods, mean: avgPeriod)
            stepStability = max(0.10, min(1.0, 1.0 - stdPeriod / 0.35))
        } else if stepCount > 0 {
            stepStability = 0.55
        } else {
            stepStability = isMoving ? 0.35 : 0.45
        }

        let headingReliability: Double
        if !initialBearingSet {
            headingReliability = 0.20
        } else if currentSegmentId >= 0 && currentSegmentId < pathBearings.count {
            headingReliability = min(0.95, 0.68 + Double(min(bearingCorrectionCount, 8)) * 0.03)
        } else {
            headingReliability = 0.58
        }

        let calibrationPenalty = stepFactorCalibration.isCalibrationValid() ? 0.0 : 0.30
        let motionPenalty = isMoving ? 0.0 : 0.20
        let pdrUncertaintyMeters = max(
            0.35,
            0.45 + (1.0 - stepStability) * 0.75 + (1.0 - headingReliability) * 0.35 + calibrationPenalty + motionPenalty
        )
        
        // Capture all values locally (safe from any thread since these are private vars)
        let newState = IMUState(
            position: _unsafeGetCurrentPosition(),
            stepCount: stepCount,
            isCalibrated: calibrationManager?.isCalibrationValid() ?? false,
            accelerationMagnitude: Float(filteredAcceleration.last ?? 0),
            isMoving: isMoving,
            currentStepLength: currentStepLength,
            filterQuality: filterQuality,
            beta: stepFactorCalibration.getUserBeta(),
            isStepCalibrationValid: stepFactorCalibration.isCalibrationValid(),
            isCalibrating: stepFactorCalibration.isCalibrating,
            calibrationStepCount: stepFactorCalibration.getCalibrationStepCount(),
            bearing: currentBearing,
            stepStability: stepStability,
            headingReliability: headingReliability,
            pdrUncertaintyMeters: pdrUncertaintyMeters
        )
        
        // FIX: Always dispatch @Published write to main thread.
        // Motion callbacks already come on .main (safe, just defers 1 runloop).
        // Background calls from resetPosition/resetPositionOnly are the crash source.
        if Thread.isMainThread {
            imuState = newState
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.imuState = newState
            }
        }
    }
}

// MARK: - Real Butterworth Bandpass Filter (SAME AS ANDROID)

class ButterworthBandpassFilter {
    private let a0: Double = 1.0
    private let a1: Double = -1.6255829582907484
    private let a2: Double = 0.6675381679326730
    private let b0: Double = 0.16623091603366352
    private let b1: Double = 0.0
    private let b2: Double = -0.16623091603366352
    
    private var x1: Double = 0
    private var x2: Double = 0
    private var y1: Double = 0
    private var y2: Double = 0
    
    func filter(_ input: Double) -> Double {
        let output = (b0 * input + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2 = x1; x1 = input
        y2 = y1; y1 = output
        return output
    }
    
    func reset() {
        x1 = 0; x2 = 0
        y1 = 0; y2 = 0
    }
}

// MARK: - User Step Factor Calibration

class UserStepFactorCalibration {
    
    private(set) var isCalibrating: Bool = false
    private var userStepCount: Int = 0
    private var accumulatedAccelerationDiff: Double = 0
    private var userBeta: Double = 0.6
    private var calibratedBeta: Double = 0.6
    private var isValid: Bool = false
    
    // FIX: Track pvDiff values during calibration to compute an adaptive threshold.
    // After calibration, the average pvDiff represents the user's typical walking
    // intensity. 25% of this average is used as a minimum detection threshold,
    // making step detection adapt to the individual's gait pattern.
    private var calibrationPvDiffs: [Double] = []
    private var calibratedAvgPvDiff: Double = 0.0
    
    private let calibrationDistance: Double = 20.0
    // FIX: Default beta raised from 0.6 to 0.8 for iOS signal scale.
    // See IMUSensorManager.defaultBeta comment for full explanation.
    private let defaultBeta: Double = 0.8
    private let calibrationBetaKey = "imu.stepCalibration.beta"
    private let calibrationValidKey = "imu.stepCalibration.isValid"
    private let calibrationAvgPvDiffKey = "imu.stepCalibration.avgPvDiff"
    // Fraction of average pvDiff to use as minimum threshold.
    // 0.25 means the threshold is 25% of the user's typical walking pvDiff.
    // This rejects movements that are too weak relative to normal gait.
    private let adaptiveThresholdFraction: Double = 0.25

    init() {
        loadPersistedCalibration()
    }
    
    func startCalibration() {
        isCalibrating = true
        userStepCount = 0
        accumulatedAccelerationDiff = 0
        calibrationPvDiffs.removeAll()
    }
    
    func addStepData(peakValleyDifference: Double) {
        guard isCalibrating && peakValleyDifference > 0 else { return }
        let accDiff = pow(peakValleyDifference, 0.25)
        accumulatedAccelerationDiff += accDiff
        userStepCount += 1
        // Track raw pvDiff for adaptive threshold computation
        calibrationPvDiffs.append(peakValleyDifference)
    }
    
    func completeCalibration() {
        guard isCalibrating else { return }
        if accumulatedAccelerationDiff > 0 {
            userBeta = calibrationDistance / accumulatedAccelerationDiff
            isValid = userBeta > 0.1 && userBeta < 2.0
            if isValid {
                calibratedBeta = userBeta
                // Compute average pvDiff from calibration walk
                if !calibrationPvDiffs.isEmpty {
                    calibratedAvgPvDiff = calibrationPvDiffs.reduce(0, +) /
                        Double(calibrationPvDiffs.count)
                }
                persistCalibration()
            }
        }
        isCalibrating = false
    }
    
    func stopCalibration() -> Bool {
        guard isCalibrating else { return false }
        if accumulatedAccelerationDiff > 0 && userStepCount > 0 {
            let estimatedDistance = Double(userStepCount) * 0.65
            userBeta = estimatedDistance / accumulatedAccelerationDiff
            isValid = userBeta > 0.1 && userBeta < 2.0
            if isValid {
                calibratedBeta = userBeta
                if !calibrationPvDiffs.isEmpty {
                    calibratedAvgPvDiff = calibrationPvDiffs.reduce(0, +) /
                        Double(calibrationPvDiffs.count)
                }
                persistCalibration()
            }
        }
        isCalibrating = false
        return isValid
    }
    
    func cancel() {
        isCalibrating = false
        userStepCount = 0
        accumulatedAccelerationDiff = 0
        calibrationPvDiffs.removeAll()
    }
    
    func getCalibrationStepCount() -> Int {
        return userStepCount
    }
    
    func getUserBeta() -> Double {
        return isValid ? calibratedBeta : defaultBeta
    }
    
    func isCalibrationValid() -> Bool {
        return isValid
    }
    
    /// Returns an adaptive minimum pvDiff threshold based on calibration data.
    /// If not calibrated, returns 0 (no adaptive floor — only the base threshold applies).
    /// If calibrated, returns 25% of the user's average calibration pvDiff.
    /// Example: user's avg pvDiff during calibration was 0.55 → threshold = 0.14
    /// This means movements weaker than 14% of their typical stride are rejected.
    func getAdaptivePvDiffThreshold() -> Double {
        guard isValid && calibratedAvgPvDiff > 0 else { return 0 }
        return calibratedAvgPvDiff * adaptiveThresholdFraction
    }

    private func persistCalibration() {
        UserDefaults.standard.set(calibratedBeta, forKey: calibrationBetaKey)
        UserDefaults.standard.set(isValid, forKey: calibrationValidKey)
        UserDefaults.standard.set(calibratedAvgPvDiff, forKey: calibrationAvgPvDiffKey)
    }

    /// Wipe persisted calibration so the device can be handed to a new user.
    /// Returns the calibration to "first-time use" state — beta falls back to
    /// `defaultBeta`, isValid becomes false, and the adaptive pvDiff floor is cleared.
    /// Any in-progress calibration walk is also cancelled.
    func clearPersisted() {
        // Cancel any in-progress calibration walk
        isCalibrating = false
        userStepCount = 0
        accumulatedAccelerationDiff = 0
        calibrationPvDiffs.removeAll()

        // Reset in-memory state to defaults
        userBeta = defaultBeta
        calibratedBeta = defaultBeta
        calibratedAvgPvDiff = 0.0
        isValid = false

        // Remove from UserDefaults so a fresh launch sees no persisted calibration
        UserDefaults.standard.removeObject(forKey: calibrationBetaKey)
        UserDefaults.standard.removeObject(forKey: calibrationValidKey)
        UserDefaults.standard.removeObject(forKey: calibrationAvgPvDiffKey)
    }

    private func loadPersistedCalibration() {
        let wasValid = UserDefaults.standard.bool(forKey: calibrationValidKey)
        guard wasValid else { return }

        let storedBeta = UserDefaults.standard.double(forKey: calibrationBetaKey)
        guard storedBeta > 0.1 && storedBeta < 2.0 else { return }

        calibratedBeta = storedBeta
        userBeta = storedBeta
        isValid = true
        
        // Load persisted average pvDiff for adaptive threshold
        let storedAvgPvDiff = UserDefaults.standard.double(forKey: calibrationAvgPvDiffKey)
        if storedAvgPvDiff > 0 {
            calibratedAvgPvDiff = storedAvgPvDiff
        }
    }
}

// MARK: - Acceleration Logger

/// Logger matching Android's AccelerationDataLogger.
/// Stores samples and allows retroactive marking of peaks, valleys, and confirmed steps.
class AccelerationLogger {
    private var samples: [AccelerationSample] = []
    private let maxSamples = 100000
    private var sampleCounter: Int = 0
    
    func addSample(_ sample: AccelerationSample) {
        var s = sample
        s = AccelerationSample(
            sampleIndex: sampleCounter,
            timestamp: s.timestamp,
            x: s.x, y: s.y, z: s.z,
            magnitude: s.magnitude,
            filtered: s.filtered,
            isPeak: s.isPeak,
            isValley: s.isValley,
            isConfirmedStep: s.isConfirmedStep,
            stepLength: s.stepLength,
            stepNumber: s.stepNumber,
            peakValleyDiff: s.peakValleyDiff
        )
        samples.append(s)
        sampleCounter += 1
        if samples.count > maxSamples { samples.removeFirst() }
    }
    
    /// Mark the second-to-last sample as a detected peak (matching Android)
    func markLastSampleAsPeak() {
        guard samples.count >= 2 else { return }
        let idx = samples.count - 2
        samples[idx].isPeak = true
    }
    
    /// Mark the second-to-last sample as a detected valley (matching Android)
    func markLastSampleAsValley() {
        guard samples.count >= 2 else { return }
        let idx = samples.count - 2
        samples[idx].isValley = true
    }
    
    /// Mark a sample (by closest timestamp) as a confirmed step
    func markSampleAsConfirmedStep(timestamp: Date, stepLength: Double, stepNumber: Int, peakValleyDiff: Double) {
        // Find the sample closest to the given timestamp
        guard let idx = samples.lastIndex(where: { abs($0.timestamp.timeIntervalSince(timestamp)) < 0.5 }) else { return }
        samples[idx].isConfirmedStep = true
        samples[idx].stepLength = stepLength
        samples[idx].stepNumber = stepNumber
        samples[idx].peakValleyDiff = peakValleyDiff
    }
    
    func getSamples() -> [AccelerationSample] { return samples }
    
    func getStatistics() -> (totalSamples: Int, peakCount: Int, valleyCount: Int, confirmedStepCount: Int, timeSpanMs: Int64) {
        let peaks = samples.filter { $0.isPeak }.count
        let valleys = samples.filter { $0.isValley }.count
        let steps = samples.filter { $0.isConfirmedStep }.count
        let span: Int64 = samples.count >= 2
            ? Int64(samples.last!.timestamp.timeIntervalSince(samples.first!.timestamp) * 1000)
            : 0
        return (samples.count, peaks, valleys, steps, span)
    }
    
    func clear() {
        samples.removeAll()
        sampleCounter = 0
    }
}
