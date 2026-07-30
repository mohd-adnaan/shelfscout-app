import Foundation
import simd
import Combine

/// Shared handle on a live ARKit navigation screen.
///
/// Cold-starting a leg costs a full relocalization, which is exactly the
/// step that fails when the user stands at a destination facing opposite to
/// the capture direction. Destination-to-destination hops therefore keep the
/// AR session presented and relocalized, and retarget it in place: the pose
/// is already known, so the next leg starts instantly and correctly.
final class ARKitNavigationSession: ObservableObject {
    static let shared = ARKitNavigationSession()

    /// Target for the leg currently being guided. Nil when no automated
    /// navigation screen is mounted.
    @Published private(set) var activeTarget: String?
    /// Bumped on every retarget so the mounted view can restart its
    /// automation state machine for the new leg.
    @Published private(set) var retargetRevision = 0
    /// True while an automated navigation screen is mounted AND its AR
    /// session is relocalized, i.e. a retarget can skip relocalization.
    @Published var isWarm = false
    /// True while a mounted screen is still working on relocalization and has
    /// not given up on the ARKit session.
    ///
    /// Relocalization against a saved map is cumulative: ARKit keeps matching
    /// incoming frames until it finds the map. Tearing the screen down on a
    /// timeout and relaunching runs `.resetTracking`, which throws that
    /// accumulated work away — so N retries are N independent cold attempts
    /// rather than one long one. Retargeting a searching session instead lets
    /// attempt N+1 continue attempt N.
    @Published var isSearching = false

    private init() {}

    func begin(target: String?) {
        activeTarget = target
        isWarm = false
        isSearching = false
    }

    func retarget(to target: String) {
        activeTarget = target
        retargetRevision += 1
    }

    func end() {
        activeTarget = nil
        isWarm = false
        isSearching = false
    }
}

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
    /// Gravity-referenced device yaw straight from `CMDeviceMotion.attitude`
    /// under `.xArbitraryZVertical`, in degrees.
    ///
    /// NOT a compass bearing — its origin is arbitrary and fixed for the life
    /// of the motion session. That is exactly what makes it useful: it measures
    /// how much the DEVICE turned, independently of ARKit. Differencing it
    /// against the ARKit world yaw isolates rotation of the world FRAME, which
    /// is the signature of a relocalization realignment and is invisible to
    /// every position-based check. Unlike `bearing` it is not seeded from the
    /// AR heading, is drift-corrected by the accelerometer, and — because Z is
    /// pinned to gravity — stays valid when the phone pitches, where
    /// integrating raw `rotationRate.z` does not.
    var deviceYawDegrees: Double?

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
        pdrUncertaintyMeters: Double = 0.85,
        deviceYawDegrees: Double? = nil
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
        self.deviceYawDegrees = deviceYawDegrees
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
    /// True when the AR session stayed alive and relocalized after this
    /// result, so the next leg can be started with `continueNavigation`
    /// and skip relocalization entirely.
    var sessionAlive: Bool = false
    let message: String?

    func dictionary() -> [String: Any] {
        var output: [String: Any] = [
            "success": success,
            "reason": reason,
            "sessionAlive": sessionAlive
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
