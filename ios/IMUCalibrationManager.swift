//
//  IMUCalibrationManager.swift
//  IndoorNavigationTACME
//
//  Manages IMU calibration and coordinate system transformations
//

import Foundation
import Combine

// MARK: - Calibration State

/// State tracking for IMU calibration
struct CalibrationState {
    var isPositionCalibrated: Bool = false
    var isBearingCalibrated: Bool = false
    var positionOffsetX: Double = 0.0
    var positionOffsetY: Double = 0.0
    var bearingOffset: Double = 0.0
    var calibrationConfidence: Double = 0.0
    var calibrationTimestamp: Date? = nil
    var permanentBearingOffset: Double? = nil
    var initialBearing: Double? = nil
}

// MARK: - IMU Calibration Manager

/// Manages IMU calibration and coordinate transformations
class IMUCalibrationManager: ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var calibrationState = CalibrationState()
    
    // MARK: - Private Properties
    
    private var lastKnownImuPosition = Position()
    private weak var sensorManager: IMUSensorManager?
    
    // Constants
    private let minConfidenceThreshold: Double = 0.5
    private let bearingWrapThreshold: Double = 180.0
    private let maxCalibrationAgeMs: TimeInterval = 300 // 5 minutes
    
    // MARK: - Public Methods
    
    /// Set reference to sensor manager for initial bearing setup
    func setSensorManager(_ manager: IMUSensorManager) {
        self.sensorManager = manager
        print("IMUCalibrationManager: Sensor manager reference set")
    }
    
    /// Perform calibration with map coordinates
    func calibrateWithMapPosition(
        currentImuPosition: Position,
        mapX: Double,
        mapY: Double,
        mapBearing: Double?,
        stepCount: Int = 0
    ) -> Bool {
        let currentTime = Date()
        
        // Calculate position offset
        let offsetX = mapX - currentImuPosition.x
        let offsetY = mapY - currentImuPosition.y
        
        // Calculate bearing offset if provided
        var bearingOffset: Double = 0
        var isBearingCalibrated = false
        
        if let bearing = mapBearing {
            if !calibrationState.isBearingCalibrated {
                // First time calibration - set initial bearing
                sensorManager?.setInitialBearing(bearing)
                calibrationState.initialBearing = bearing
                bearingOffset = 0
                isBearingCalibrated = true
                print("IMUCalibrationManager: Initial bearing set: \(bearing)°")
            } else {
                // FIX 2: On recalibration, ALSO update the bearing.
                // Previously this branch just printed "preserving existing bearing"
                // and did nothing — meaning the server's corrected bearing was ignored
                // on all segment recalibrations after the initial one.
                // This caused bearing to drift (gyro integration error accumulates)
                // and never get corrected, leading to position spiral and crashes.
                sensorManager?.setInitialBearing(bearing)
                calibrationState.initialBearing = bearing
                isBearingCalibrated = true
                print("IMUCalibrationManager: Recalibration - bearing UPDATED to \(String(format: "%.1f", bearing))°")
            }
        }
        
        // Calculate confidence
        let confidence = calculateConfidence(stepCount: stepCount, timeElapsed: 0)
        
        let newState = CalibrationState(
            isPositionCalibrated: true,
            isBearingCalibrated: isBearingCalibrated || calibrationState.isBearingCalibrated,
            positionOffsetX: offsetX,
            positionOffsetY: offsetY,
            bearingOffset: bearingOffset,
            calibrationConfidence: confidence,
            calibrationTimestamp: currentTime,
            permanentBearingOffset: calibrationState.permanentBearingOffset,
            initialBearing: calibrationState.initialBearing ?? mapBearing
        )
        DispatchQueue.main.async { [weak self] in
            self?.calibrationState = newState
        }
        
        lastKnownImuPosition = currentImuPosition
        
        print("IMUCalibrationManager: Calibration complete")
        print("  Position offset: (\(offsetX), \(offsetY))")
        print("  Bearing offset: \(bearingOffset)°")
        print("  Confidence: \(confidence)")
        
        return true
    }
    
    /// Transform IMU position to map coordinates
    func transformToMapPosition(_ imuPosition: Position) -> Position? {
        guard calibrationState.isPositionCalibrated else {
            print("IMUCalibrationManager: Position not calibrated")
            return nil
        }
        
        let mapX = imuPosition.x + calibrationState.positionOffsetX
        let mapY = imuPosition.y + calibrationState.positionOffsetY
        
        let mapBearing: Double
        if calibrationState.isBearingCalibrated {
            let offset = calibrationState.permanentBearingOffset ?? calibrationState.bearingOffset
            mapBearing = normalizeBearing(imuPosition.bearing + offset)
        } else {
            mapBearing = imuPosition.bearing
        }
        
        return Position(x: mapX, y: mapY, bearing: mapBearing)
    }
    
    /// Update calibration confidence based on movement
    func updateCalibration(currentImuPosition: Position, stepCount: Int) {
        guard calibrationState.isPositionCalibrated else { return }
        guard let timestamp = calibrationState.calibrationTimestamp else { return }
        
        let timeElapsed = Date().timeIntervalSince(timestamp)
        let newConfidence = calculateConfidence(stepCount: stepCount, timeElapsed: timeElapsed)
        
        // Time decay factor
        let timeDecayFactor: Double
        if timeElapsed > maxCalibrationAgeMs {
            timeDecayFactor = 0.3
        } else if timeElapsed > maxCalibrationAgeMs / 2 {
            timeDecayFactor = 0.7
        } else {
            timeDecayFactor = 1.0
        }
        
        let adjustedConfidence = newConfidence * timeDecayFactor
        
        calibrationState.calibrationConfidence = adjustedConfidence
        lastKnownImuPosition = currentImuPosition
    }
    
    /// Check if calibration is valid and reliable
    func isCalibrationValid() -> Bool {
        return calibrationState.isPositionCalibrated &&
               calibrationState.calibrationConfidence >= minConfidenceThreshold
    }
    
    /// Check if bearing calibration is available
    func isBearingCalibrated() -> Bool {
        return calibrationState.isBearingCalibrated && isCalibrationValid()
    }
    
    /// Get calibration status as human-readable string
    func getCalibrationStatus() -> String {
        if !calibrationState.isPositionCalibrated {
            return "Position not calibrated"
        }
        if !calibrationState.isBearingCalibrated {
            return "Bearing not calibrated"
        }
        if calibrationState.calibrationConfidence < minConfidenceThreshold {
            return "Low calibration confidence (\(Int(calibrationState.calibrationConfidence * 100))%)"
        }
        return "Fully calibrated (\(Int(calibrationState.calibrationConfidence * 100))%)"
    }
    
    /// Get calibration confidence as percentage
    func getCalibrationConfidence() -> Double {
        return calibrationState.calibrationConfidence
    }
    
    /// Check if recalibration is recommended
    func isRecalibrationRecommended() -> Bool {
        guard let timestamp = calibrationState.calibrationTimestamp else {
            return true
        }
        let timeElapsed = Date().timeIntervalSince(timestamp)
        return calibrationState.calibrationConfidence < 0.3 ||
               timeElapsed > maxCalibrationAgeMs
    }
    
    /// Reset calibration state
    func resetCalibration() {
        let reset = CalibrationState()
        DispatchQueue.main.async { [weak self] in
            self?.calibrationState = reset
        }
        lastKnownImuPosition = Position()
        print("IMUCalibrationManager: Calibration reset")
    }
    
    /// Get detailed calibration information
    func getCalibrationDetails() -> [String: Any] {
        var ageMs: TimeInterval = 0
        if let timestamp = calibrationState.calibrationTimestamp {
            ageMs = Date().timeIntervalSince(timestamp) * 1000
        }
        
        return [
            "isPositionCalibrated": calibrationState.isPositionCalibrated,
            "isBearingCalibrated": calibrationState.isBearingCalibrated,
            "positionOffset": "(\(calibrationState.positionOffsetX), \(calibrationState.positionOffsetY))",
            "bearingOffset": "\(calibrationState.bearingOffset)°",
            "confidence": "\(Int(calibrationState.calibrationConfidence * 100))%",
            "ageMs": ageMs,
            "isValid": isCalibrationValid()
        ]
    }
    
    // MARK: - Private Methods
    
    private func calculateConfidence(stepCount: Int, timeElapsed: TimeInterval) -> Double {
        let stepConfidence: Double
        switch stepCount {
        case ..<5: stepConfidence = 0.7
        case 5..<15: stepConfidence = 0.8
        case 15..<30: stepConfidence = 0.85
        default: stepConfidence = 0.9
        }
        
        let timeConfidence: Double
        switch timeElapsed {
        case ..<10: timeConfidence = 0.7
        case 10..<30: timeConfidence = 0.8
        case 30..<60: timeConfidence = 0.9
        default: timeConfidence = 0.6
        }
        
        return (stepConfidence + timeConfidence) / 2.0
    }
    
    private func normalizeBearing(_ bearing: Double) -> Double {
        var normalized = bearing.truncatingRemainder(dividingBy: 360)
        if normalized < 0 {
            normalized += 360
        }
        return normalized
    }
}
