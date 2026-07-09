import Foundation
import simd

struct Position: Equatable {
    var x: Double
    var y: Double
    var bearing: Double

    init(x: Double = 0, y: Double = 0, bearing: Double = 0) {
        self.x = x
        self.y = y
        self.bearing = bearing
    }
}

struct IMUState {
    var position: Position
    var stepCount: Int
    var isCalibrated: Bool
    var accelerationMagnitude: Float
    var isMoving: Bool
    var currentStepLength: Double
    var filterQuality: String
    var beta: Double
    var isStepCalibrationValid: Bool
    var isCalibrating: Bool
    var calibrationStepCount: Int
    var bearing: Double
    var stepStability: Double
    var headingReliability: Double
    var pdrUncertaintyMeters: Double

    init(
        position: Position = Position(),
        stepCount: Int = 0,
        isCalibrated: Bool = false,
        accelerationMagnitude: Float = 0,
        isMoving: Bool = false,
        currentStepLength: Double = 0.65,
        filterQuality: String = "Initializing",
        beta: Double = 0.6,
        isStepCalibrationValid: Bool = false,
        isCalibrating: Bool = false,
        calibrationStepCount: Int = 0,
        bearing: Double = 0,
        stepStability: Double = 0.35,
        headingReliability: Double = 0.35,
        pdrUncertaintyMeters: Double = 0.85
    ) {
        self.position = position
        self.stepCount = stepCount
        self.isCalibrated = isCalibrated
        self.accelerationMagnitude = accelerationMagnitude
        self.isMoving = isMoving
        self.currentStepLength = currentStepLength
        self.filterQuality = filterQuality
        self.beta = beta
        self.isStepCalibrationValid = isStepCalibrationValid
        self.isCalibrating = isCalibrating
        self.calibrationStepCount = calibrationStepCount
        self.bearing = bearing
        self.stepStability = stepStability
        self.headingReliability = headingReliability
        self.pdrUncertaintyMeters = pdrUncertaintyMeters
    }
}

struct AccelerationSample {
    let sampleIndex: Int
    let timestamp: Date
    let x: Double
    let y: Double
    let z: Double
    let magnitude: Double
    let filtered: Double
    var isPeak: Bool = false
    var isValley: Bool = false
    var isConfirmedStep: Bool = false
    var stepLength: Double? = nil
    var stepNumber: Int? = nil
    var peakValleyDiff: Double? = nil
}

struct BearingResult {
    let bearing: Double
    let wasCorrected: Bool

    init(_ bearing: Double, _ wasCorrected: Bool) {
        self.bearing = bearing
        self.wasCorrected = wasCorrected
    }
}

struct TTSState {
    var isReady: Bool
    var isEnabled: Bool
    var voiceOverCompatibilityEnabled: Bool
    var isSpeaking: Bool
    var lastSpokenText: String
    var lastSpeechTime: Date?

    init(
        isReady: Bool = true,
        isEnabled: Bool = true,
        voiceOverCompatibilityEnabled: Bool = false,
        isSpeaking: Bool = false,
        lastSpokenText: String = "",
        lastSpeechTime: Date? = nil
    ) {
        self.isReady = isReady
        self.isEnabled = isEnabled
        self.voiceOverCompatibilityEnabled = voiceOverCompatibilityEnabled
        self.isSpeaking = isSpeaking
        self.lastSpokenText = lastSpokenText
        self.lastSpeechTime = lastSpeechTime
    }
}

struct ARKitNavigationNativeResult {
    let success: Bool
    let reason: String
    let targetName: String?
    let routeMapId: String?
    let routeName: String?
    let targetWorldPosition: simd_float3?
    /// Graspable object marked on the arrived destination during mapping.
    /// Present only on `arrived`; JS switches into spatial-target reaching
    /// for this object instead of the destination itself.
    var reachingObjectName: String? = nil
    var reachingObjectWorldPosition: simd_float3? = nil
    let message: String?

    func dictionary() -> [String: Any] {
        var output: [String: Any] = [
            "success": success,
            "reason": reason
        ]
        if let targetName { output["targetName"] = targetName }
        if let routeMapId { output["routeMapId"] = routeMapId }
        if let routeName { output["routeName"] = routeName }
        if let targetWorldPosition {
            output["targetWorldPosition"] = [
                "x": targetWorldPosition.x,
                "y": targetWorldPosition.y,
                "z": targetWorldPosition.z
            ]
        }
        if let reachingObjectName { output["reachingObjectName"] = reachingObjectName }
        if let reachingObjectWorldPosition {
            output["reachingObjectWorldPosition"] = [
                "x": reachingObjectWorldPosition.x,
                "y": reachingObjectWorldPosition.y,
                "z": reachingObjectWorldPosition.z
            ]
        }
        if let message { output["message"] = message }
        return output
    }
}
