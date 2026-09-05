import Foundation
import CoreImage
import CoreVideo
import ImageIO
import simd

struct SemanticRoutePoint: Codable, Equatable {
    var x: Double
    var y: Double

    func distance(to other: SemanticRoutePoint) -> Double {
        hypot(other.x - x, other.y - y)
    }

    func bearingDegrees(to other: SemanticRoutePoint) -> Double {
        let radians = atan2(other.x - x, other.y - y)
        return SemanticRouteMath.normalizedDegrees(radians * 180.0 / .pi)
    }
}

enum SemanticRouteNodeKind: String, Codable, CaseIterable, Identifiable {
    case waypoint
    case entrance
    case aisle
    case intersection
    case shelf
    case destination

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .waypoint: return "Waypoint"
        case .entrance: return "Entrance"
        case .aisle: return "Aisle"
        case .intersection: return "Turn"
        case .shelf: return "Shelf"
        case .destination: return "Target"
        }
    }
}

enum SemanticRouteLandmarkKind: String, Codable, CaseIterable, Identifiable {
    case object
    case recovery
    case destinationContext

    var id: String { rawValue }
}

enum SemanticRouteSide: String, Codable, CaseIterable, Identifiable {
    case center
    case left
    case right
    case ahead
    case behind

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .center: return "Center"
        case .left: return "Left"
        case .right: return "Right"
        case .ahead: return "Ahead"
        case .behind: return "Behind"
        }
    }
}

/// How relative directions are spoken: plain left/right words, or clock-face
/// hours ("turn to 2 o'clock") — the O&M convention many blind users prefer
/// because it encodes the turn magnitude a bare "turn left" loses.
enum SemanticTurnPhrasing: String {
    case leftRight
    case clockFace
}

enum SemanticTurnHint: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case straight
    case corner
    case cornerLeft
    case cornerRight

    var id: String { rawValue }

    /// Corners are small course adjustments to stay on the route, not full
    /// turns — guidance phrasing must say "corner", never "turn".
    var isCorner: Bool {
        self == .corner || self == .cornerLeft || self == .cornerRight
    }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .straight: return "Straight"
        case .corner: return "Corner"
        case .cornerLeft: return "Left corner"
        case .cornerRight: return "Right corner"
        }
    }

    var nodeName: String {
        switch self {
        case .left: return "Left turn"
        case .right: return "Right turn"
        case .straight: return "Straight point"
        case .corner: return "Corner"
        case .cornerLeft: return "Left corner"
        case .cornerRight: return "Right corner"
        }
    }

    /// The same physical turn seen walking the other way. Handedness-free
    /// hints are their own mirror.
    var mirrored: SemanticTurnHint {
        switch self {
        case .left: return .right
        case .right: return .left
        case .cornerLeft: return .cornerRight
        case .cornerRight: return .cornerLeft
        case .straight, .corner: return self
        }
    }

    /// Spoken to the user, so localized. `displayName`/`nodeName` above stay
    /// English — they label nodes in the route-capture UI, not guidance.
    var spokenInstruction: String {
        switch self {
        case .left: return NavLoc.turnLeft()
        case .right: return NavLoc.turnRight()
        case .straight: return NavLoc.continueStraight()
        case .corner: return NavLoc.followCorner()
        case .cornerLeft: return NavLoc.slightLeftAtCorner()
        case .cornerRight: return NavLoc.slightRightAtCorner()
        }
    }
}

struct SemanticRouteNode: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var point: SemanticRoutePoint
    var headingDegrees: Double?
    var kind: SemanticRouteNodeKind
    var turnHint: SemanticTurnHint?
    var aliases: [String]
    var capturedAt: Date
    var poiAnchorId: String?
    /// Destination nodes only: the graspable object pinned for last-meter
    /// reaching. Must match a surface-pinned POI anchor in the linked
    /// ARWorldMap so spatial-target reaching can resolve it after arrival.
    var reachingObjectName: String? = nil
}

struct SemanticRouteEdge: Identifiable, Codable, Equatable {
    var id: String
    var fromNodeID: String
    var toNodeID: String
    var distanceMeters: Double
    var bearingDegrees: Double
    var reverseBearingDegrees: Double
    var walkableWidthMeters: Double?
    var leftContext: String?
    var rightContext: String?
    var spokenContext: String?
    var isBidirectional: Bool
    var confidence: Double
    var keyframeIds: [String]?
    var landmarkIds: [String]?
}

struct SemanticRouteLandmark: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var aliases: [String]
    var nodeID: String
    var edgeID: String?
    var offsetMeters: Double?
    var side: SemanticRouteSide
    var context: String?
    var priority: Int
    var kind: SemanticRouteLandmarkKind?
    var visualFingerprintIds: [String]?
}

struct SemanticRouteKeyframe: Identifiable, Codable, Equatable {
    var id: String
    var segmentID: String?
    var pose: SemanticRoutePoint
    var headingDegrees: Double?
    var distanceFromSegmentStart: Double
    var visualFingerprintId: String?
    var trackingQuality: String
    var capturedAt: Date
}

struct SemanticRouteMap: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var coordinateSpace: String
    /// nil/1 = legacy ar_world_xz maps that stored raw ARKit z as route-y
    /// (left-handed: geometric left/right cues were mirrored). 2 = y is -z,
    /// compass-like. Legacy maps are migrated once on load.
    var axisConvention: Int? = nil
    var arWorldMapId: String?
    var startNodeId: String?
    var destinationNodeIds: [String]?
    /// Endpoints whose 360° anchoring sweep completed in SOME session. The
    /// sweep banks ARKit features into the linked ARWorldMap, which persists —
    /// so "anchored" must persist too, or every later capture/enrichment visit
    /// re-prompts a spin the map has already banked.
    var anchoredNodeIds: [String]? = nil
    var nodes: [SemanticRouteNode]
    var edges: [SemanticRouteEdge]
    var landmarks: [SemanticRouteLandmark]
    var keyframes: [SemanticRouteKeyframe]?
    var visualFingerprints: [String: ARVisualFingerprint]? = nil
    var captureQuality: SemanticRouteCaptureQuality? = nil
    var visualAliasGroups: [SemanticRouteVisualAliasGroup]? = nil
    var visualSamplesVersion: Int? = nil
    var source: String?
    var notes: String?

    var targetNames: [String] {
        let destinationIDs = Set(destinationNodeIds ?? nodes.filter { $0.kind == .destination }.map(\.id))
        // Entrances, shelves, and aisles are queryable too: a route mapped
        // produce→cereal must also answer "take me to produce" in reverse.
        let queryableKinds: Set<SemanticRouteNodeKind> = [.destination, .entrance, .shelf, .aisle]
        let nodeNames = nodes
            .filter { queryableKinds.contains($0.kind) || destinationIDs.contains($0.id) }
            .map(\.name)
            .filter { Self.isQueryableTargetName($0) }
        let landmarkNames = landmarks
            .filter { $0.kind == .destinationContext || $0.priority >= 20 }
            .map(\.name)
            .filter { Self.isQueryableTargetName($0) }
        return Array(Set(nodeNames + landmarkNames)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    /// Generic capture labels are not meaningful spoken destinations and
    /// would pollute the grounding vocabulary offered to the voice layer.
    private static func isQueryableTargetName(_ name: String) -> Bool {
        let lower = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let generic: Set<String> = [
            "", "start", "point a", "waypoint", "turn", "corner",
            "left turn", "right turn", "left corner", "right corner", "straight point"
        ]
        return !generic.contains(lower)
    }
}

enum SemanticNavigationPhase: String {
    case idle
    case mapping
    /// Re-walking a saved route to add visual keyframes (typically in the
    /// reverse direction) without touching the route geometry.
    case enriching
    case ready
    case navigating
    case recovering
    case arrived

    var displayName: String {
        switch self {
        case .idle: return "No semantic map"
        case .mapping: return "Mapping route"
        case .enriching: return "Improving map"
        case .ready: return "Ready"
        case .navigating: return "Guiding"
        case .recovering: return "Recovering"
        case .arrived: return "Arrived"
        }
    }
}

enum RouteLocalizationStatus: String, Codable, Equatable {
    case initializing
    case locked
    case ambiguous
    case recovering
    case lost

    var displayName: String {
        switch self {
        case .initializing: return "Initializing"
        case .locked: return "Route locked"
        case .ambiguous: return "Route ambiguous"
        case .recovering: return "Recovering"
        case .lost: return "Route lost"
        }
    }
}

enum SemanticSpeechPriority {
    case regular
    case priority
    case critical
}

struct SemanticSpeechCue: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let priority: SemanticSpeechPriority
}

/// Where one captured edge sits inside a step that merged several of them.
/// Keyframes and landmarks store their offset relative to the edge they were
/// captured on, so a merged step has to translate those offsets instead of
/// reading them as if they started at the step.
struct SemanticRouteEdgeSpan: Equatable {
    var startMeters: Double
    var lengthMeters: Double
    /// True when the merged step walks this captured edge backwards.
    var reversed: Bool
}

/// Which way the destination sits from the last node the user actually walks
/// to. Narrow aisles mean the final metre of a captured route is a turn to
/// face the shelf, not a leg to walk.
struct SemanticRouteArrivalFacing: Equatable {
    var side: SemanticRouteSide
    var meters: Double
}

struct SemanticRouteStep: Identifiable, Equatable {
    var id: String { edge.id }
    let edge: SemanticRouteEdge
    let from: SemanticRouteNode
    let to: SemanticRouteNode
    /// Empty for a plain one-edge step; populated when route shaping folded a
    /// stub leg into this one, keyed by captured edge id.
    var edgeSpans: [String: SemanticRouteEdgeSpan] = [:]
}

struct SemanticRouteObservation: Equatable {
    var pose: SemanticRoutePoint
    var headingDegrees: Double
    var source: String
    var confidence: Double
    var crossTrackError: Double?
    var visualMatchConfidence: Double?
    var routeStatus: RouteLocalizationStatus = .initializing
    var beliefConfidence: Double = 0
    var beliefMargin: Double = 0
    var uncertaintyMeters: Double = 0
    var isInstructionSafe: Bool = false
    var evidenceSummary: String = ""
}

struct SemanticRouteCaptureQuality: Codable, Equatable {
    var keyframeCount: Int
    var visualSampleCount: Int
    var aliasedVisualSampleCount: Int
    var routeDistanceMeters: Double
    var averageKeyframeSpacingMeters: Double?
    var hasMinimumSpatialEvidence: Bool
    var hasMinimumVisualEvidence: Bool
    var warnings: [String]
    /// Nodes the route passes close to while heading somewhere materially
    /// different — a corridor walked more than once. Distinct from
    /// `aliasedVisualSampleCount`, which only knows whether two places *look*
    /// alike; this counts places that overlap in space. Optional so maps saved
    /// before the check decode as "not measured" rather than failing.
    var overlappingCorridorCount: Int?

    /// Deliberately not part of the pass/fail gate. Retracing a corridor is
    /// often forced by the building — a dead-end wing has to be walked back
    /// out of — so refusing the save would block maps that are the best
    /// obtainable. It is surfaced as a warning instead.
    var isSufficientForGuidance: Bool {
        hasMinimumSpatialEvidence && hasMinimumVisualEvidence && aliasedVisualSampleCount <= max(1, visualSampleCount / 3)
    }
}

struct SemanticRouteVisualAliasGroup: Identifiable, Codable, Equatable {
    var id: String
    var fingerprintIds: [String]
    var representativeNames: [String]
    var similarity: Double
}

struct SemanticRouteRAGContext: Codable, Equatable {
    struct Segment: Codable, Equatable {
        var from: String
        var to: String
        var distanceMeters: Double
        var remainingMeters: Double
        var bearingDegrees: Double
        var leftContext: String?
        var rightContext: String?
        var spokenContext: String?
    }

    var mapName: String
    var target: String
    var phase: String
    var instruction: String
    var confidence: Double
    var routeStatus: String
    var isInstructionSafe: Bool
    var routeRemainingMeters: Double
    var currentSegment: Segment?
    var nearbyLandmarks: [String]
    var recoveryReason: String?
    var hardRules: [String]
}

@MainActor
final class SemanticRouteNavigator: ObservableObject {
    @Published private(set) var maps: [SemanticRouteMap] = []
    @Published private(set) var activeMap: SemanticRouteMap?
    @Published private(set) var phase: SemanticNavigationPhase = .idle
    @Published private(set) var targetName: String = ""
    @Published private(set) var routeSteps: [SemanticRouteStep] = []
    @Published private(set) var currentStepIndex: Int = 0
    @Published private(set) var segmentProgressMeters: Double = 0
    @Published private(set) var segmentRemainingMeters: Double = 0
    @Published private(set) var totalRemainingMeters: Double = 0
    @Published private(set) var confidence: Double = 0
    @Published private(set) var currentInstruction: String = "Capture or load a semantic map."
    @Published private(set) var recoveryReason: String?
    @Published private(set) var lastObservation: SemanticRouteObservation?
    @Published private(set) var routeLocalizationStatus: RouteLocalizationStatus = .initializing
    /// Set when route shaping removed a final stub leg: the destination is that
    /// far to the given side of the last node the user walks to.
    @Published private(set) var arrivalFacing: SemanticRouteArrivalFacing?
    @Published private(set) var ragContextJSON: String = "{}"
    @Published private(set) var capturedPointCount: Int = 0
    @Published private(set) var capturedTurnCount: Int = 0
    @Published private(set) var capturedLandmarkCount: Int = 0
    @Published private(set) var capturedDestinationCount: Int = 0
    @Published private(set) var capturedDistanceMeters: Double = 0
    @Published private(set) var currentSegmentDraftMeters: Double = 0
    @Published private(set) var mappingQualityText: String = "Not mapping"
    @Published private(set) var enrichmentKeyframesAdded: Int = 0
    @Published var speechCue: SemanticSpeechCue?

    private let store = SemanticRouteMapStore()
    private let frameFingerprinter = ARFrameFingerprinter()
    private var activeMapDraft: SemanticRouteMap?
    private var lastCapturedNodeID: String?
    private var lastAutoSampledPoint: SemanticRoutePoint?
    private var lastAutoSampledHeading: Double?
    private var lastAutoSampledAt: Date?
    private var lastIMUStepCount: Int?
    private var lastIMUPosition: Position?
    /// Smallest approach gate already spoken on this leg. Gates only ever come
    /// closer, so one value is the whole schedule: everything larger is behind
    /// the user and spent.
    private var lastSpokenApproachGateMeters: Double?
    /// True once this leg's single mid-walk beat has been spoken.
    private var spokenLegProgressBeat = false
    /// When routine walking speech last went out — the pacing floor that keeps
    /// approach, landmark and reassurance cues from stacking on each other.
    private var lastRoutineCueAt: Date?
    private var spokenDestinationApproachCue = false
    /// Metres past the destination along the final leg, from the live AR pose.
    /// Recomputed every tick next to `lastARNodeDistanceMeters`; nil whenever
    /// the pose cannot answer the question.
    private var destinationOvershootDistanceMeters: Double?
    /// Dead-reckoned distance walked since the final leg's own progress model
    /// saturated. The AR half of the signal needs a localized pose; this half
    /// is what still works when the pose is the thing that has gone stale.
    private var destinationOvershootWalkMeters: Double = 0
    private var destinationOvershootStartedAt: Date?
    private var lastDestinationOvershootCueAt: Date?
    /// Whether this leg's maneuver has been named yet. The first approach gate
    /// names it; the rest of the countdown is bare distances.
    private var spokenLegManeuverCue = false
    /// Recent per-step lengths measured by `IMUSensorManager`, newest last.
    /// Sampled once per confirmed step, never per tick — the same value
    /// repeats across the ~30 ticks between steps and would otherwise swamp
    /// the median with whatever the last step happened to be.
    private var observedStepLengths: [Double] = []
    /// `imuState.stepCount` at the last sample, so a step is counted once.
    private var lastObservedStepCount: Int?
    /// When the walker last stopped, in ANY guidance phase.
    ///
    /// Deliberately not `stillnessStartedAt`: that one is the walk-reprompt
    /// clock and only runs while `.navigating`, so during recovery — the exact
    /// state a user is in when they step aside for a person — it is never set
    /// and cannot answer "have they paused?".
    private var movementStoppedAt: Date?
    /// The place the journey started from, resolved for speech. Not spoken
    /// any more — see `startNavigation` — but still the ground truth for which
    /// node the user was judged to be standing at.
    private(set) var spokenStartLabel: String?
    private var lastAnnouncedLandmarkID: String?
    private var announcedLandmarkIDs: Set<String> = []
    private var recoveryStartedAt: Date?
    private var lastRecoveredAt: Date?
    private var lastRecoveryCueAt: Date?
    private var lastRecoveryCueKey: String?
    private var beliefIssueStartedAt: Date?
    /// When the belief last turned healthy while recovery was active; exit
    /// waits `beliefExitHysteresisSeconds` from here.
    private var beliefHealthySince: Date?
    /// Throttle for the nav.beliefHold trace event, which otherwise fires per
    /// IMU tick (~50 Hz) and floods the export past readability.
    private var lastBeliefHoldTraceAt: Date?
    private var lastBeliefHoldTraceKey: String?
    /// Throttle for the per-tick `nav.evidence` sensor-availability trace.
    private var lastEvidenceTraceAt: Date?
    private var lastRecoveryTraceAt: Date?
    private var lastRecoveryTraceKey: String?
    private var lastSnapAt: Date?
    /// Minimum spacing between recovery snaps — see `applyRecoverySnap`.
    private let recoverySnapCooldownSeconds: TimeInterval = 2.5
    /// Best raw fingerprint similarity seen on the last visual match attempt,
    /// and how many keyframes were even eligible after the heading gate.
    private var lastVisualBestSimilarity: Double?
    private var lastVisualCandidateCount = 0
    /// False until one visual match has landed in this run. While false the
    /// keyframe heading gate is suspended, because it would otherwise assume the
    /// live heading it exists to help check. See `currentVisualRouteMatch`.
    private var didCorroborateHeadingVisually = false
    /// Measured rotation of the live ARKit world frame relative to the saved
    /// map's frame, in degrees, added to every AR heading before guidance uses
    /// it: `mapHeading = arHeading + bias`.
    ///
    /// ## Why this exists
    ///
    /// Relocalization can land on a frame that is rotated relative to the map
    /// and then hold it perfectly steady — the 2026-07-30 cims session ran a
    /// whole journey 26° out, stable the entire time. Nothing on the device can
    /// tell a stable-and-right frame from a stable-and-wrong one by watching
    /// ARKit alone: `deviceYawDegrees` measures rotation, not direction, and
    /// there is no magnetometer anywhere in this app.
    ///
    /// The saved keyframes can. Each carries the heading the camera held when
    /// it was captured, in the map's frame. When the live camera matches one,
    /// `keyframeHeading − liveHeading` is a direct reading of how far the live
    /// frame is rotated from the map's. That session measured it 18 times,
    /// worst −26.8°, against a guidance heading error of 25–26° — the same
    /// number, logged to `nav.visualYaw` and thrown away. This consumes it.
    ///
    /// Yaw only. A rotated frame also displaces position, but the size of that
    /// displacement depends on where the rotation was centred, which a heading
    /// measurement cannot say; position already has its own correction path in
    /// `applyRecoverySnap`.
    private var mapFrameYawBiasDegrees: Double = 0
    /// Keyframe-vs-live heading offsets from accepted matches. Residuals, not
    /// absolutes: `liveHeading` here is already bias-corrected, so each reading
    /// says how much the bias is still wrong by, and applying their median
    /// converges instead of oscillating.
    private var visualYawResiduals: [(at: Date, degrees: Double)] = []
    private var lastYawBiasCorrectionAt: Date?
    /// Set when a correction lands, consumed on the next update tick. The route
    /// must be rebuilt from the corrected heading — it was resolved from one now
    /// known to be wrong — but not from inside the visual matcher, which runs
    /// with `activeStep` already bound for the rest of the tick.
    private var pendingFrameYawRealignment = false
    private var lastTrackingLimitedPrefixAt: Date?
    private var guidanceIntroProtectedUntil: Date?
    private var lastVisualRouteMatchAt: TimeInterval = 0
    private var lastVisualRouteMatch: VisualRouteMatch?
    private var arrivalVisualHoldStartedAt: Date?
    private var lastRouteAdvanceAt: Date?
    private var pendingProgressCorrection: PendingProgressCorrection?
    private var pendingRouteAdvance: PendingRouteAdvance?
    private var shouldSpeakLandmarks = true
    private var shouldEnableErrorRecovery = true
    private var routeEvidenceWindow: [RouteEvidence] = []
    private var routeBeliefState = RouteBeliefState.empty
    /// Gated PDR distance walked since guidance started — the same quantity
    /// that drives `segmentProgressMeters`. Route evidence stamps it so the
    /// belief filter can predict an old sample forward to now instead of
    /// treating where the user *was* as a rival claim about where they *are*.
    private var cumulativeTravelMeters: Double = 0
    /// Last navigation-update inputs, kept only so every trace line — a cue or
    /// a decision — carries the state that produced it. Reading a log where
    /// the cue text is divorced from the heading and leg that caused it is how
    /// two field sessions were spent guessing.
    private var traceLiveHeading: Double?
    private var traceHeadingError: Double?
    private var traceCrossTrack: Double?
    private var traceAlongTrack: Double?
    private var traceARLocalized = false
    private var tracePose: SemanticRoutePoint?
    private var traceLastTickAt: Date?
    private var traceLastStepIndex = -1
    private var traceLastPhase: SemanticNavigationPhase?
    private var traceLastRouteStatus: RouteLocalizationStatus?
    private var traceLastCaptureSampleAt: Date?
    private var lastRouteUpdatePDRDelta: Double = 0
    private var lastPDRDeltaWasCapped = false
    private var lastHeadingAlignmentCueAt: Date?
    private var lastHeadingAlignmentCueKey: String?
    /// Heading error at the last alignment cue, so a turn already underway is
    /// not interrupted by a fresh one.
    private var lastHeadingAlignmentErrorDegrees: Double?
    /// When any turn instruction was last spoken, from whichever subsystem.
    /// The TTS layer queues criticals back to back rather than dropping them,
    /// so two systems each cueing "reasonably often" still reach the user as
    /// one run-on contradiction. This is the floor under all of them.
    private var lastTurnCueAt: Date?
    /// Corrective cues spoken in a row without the user getting back on route.
    ///
    /// A pilot participant on 17 Aug 2026 walked into a group of people, had
    /// to go around them, and heard the route insist on the direction she was
    /// deliberately not taking: "I have to turn left to avoid this person and
    /// it kept saying turn right… it was telling me to walk through the
    /// obstacle." Her verdict on the recovery that was supposed to help was
    /// that it "backfired", and what she wanted was to step aside and have it
    /// be quiet for a second.
    ///
    /// The system cannot see the obstacle, so it cannot know she is right. But
    /// a correction repeated several times without effect is evidence in
    /// itself — either she cannot comply or she has chosen not to — and in
    /// both cases saying it louder and more often is the wrong move. This
    /// counts the repeats so the cue can back off instead of escalating.
    private var consecutiveCorrectiveCues = 0
    /// When the live course first left the corridor's tolerance, and when the
    /// last course nudge was spoken. See the course-correction constants: the
    /// persistence window is what separates a drift from a glance at a shelf.
    private var courseCorrectionSince: Date?
    private var lastCourseCueAt: Date?
    /// Straight-line AR distance to the current step's end node, set every
    /// navigation update while AR is localized. Floors spoken turn/arrival
    /// countdowns so PDR overshoot cannot announce a turn the AR pose clearly
    /// hasn't reached yet.
    private var lastARNodeDistanceMeters: Double?
    /// Along-track remaining from the AR projection, only when cross-track is
    /// small enough to trust it. Used to pull dead-reckoned progress back when
    /// AR contradicts a pending step completion.
    private var lastTrustedARRemainingMeters: Double?
    private var lastRouteRebuildAttemptAt: Date?
    /// Edge whose leg-context phrase ("toward the next turn", "toward 436")
    /// has already been spoken.
    ///
    /// The context belongs to the leg, not to every sentence about it. Said on
    /// each cue it became the thing a participant heard most: "20 meters toward
    /// the next turn" then "19 meters toward the next turn" then "Turn right.
    /// Walk 20 meters toward the next turn" — their words on 25 Aug 2026 were
    /// that after the first one it should just count "16, 14, 3, 2, 1". Once
    /// this matches the active edge, distance cues on it drop to the bare
    /// number; a new leg clears it by simply having a different edge id.
    private var spokenLegContextEdgeID: String?
    /// When ARKit last moved the world frame under the route.
    private var arFrameRealignedAt: Date?
    /// True while the live heading came from the tilt fallback — the phone is
    /// pitched at the floor or the ceiling and its forward vector no longer
    /// says which way the user faces.
    private var headingIsTiltDerived = false
    /// When the "hold the phone up" prompt last went out.
    private var lastHeadingPosturePromptAt: Date?
    /// How long the phone must stay pitched before saying anything. Glancing
    /// down for a moment is normal and must not be narrated.
    private let headingPostureGraceSeconds: TimeInterval = 2.0
    /// Pacing floor for the prompt itself.
    private let headingPostureRepeatSeconds: TimeInterval = 8.0
    /// When the phone first went past the pitch limit in this stretch.
    private var headingTiltStartedAt: Date?
    /// Throttle for the visual-arrival veto trace. The veto is a decision, not
    /// a sample, so it uses `log` rather than the droppable `tick` — but a
    /// persistent lookalike match re-tests it several times a second, and a
    /// decision worth reading is one that has not been written a hundred times.
    private var lastVisualArrivalVetoTraceAt: Date?
    /// How long after a frame realignment corrective heading cues stay quiet.
    /// Long enough for the yaw watch to take a fresh baseline, short enough
    /// that a genuinely misfacing user is not left walking.
    private let alignmentCueFrameSettleSeconds: TimeInterval = 2.5
    private var stillnessStartedAt: Date?
    private var lastStillnessRepromptAt: Date?
    /// When the user first stopped moving while standing near the destination —
    /// the fallback that completes the route when the tight arrival window can't
    /// be satisfied after a sharp turn into a short final segment.
    private var destinationStillnessSince: Date?
    private var pendingAlignmentResumeCue = false
    /// A turn was announced ON ITS OWN and the leg's walk instruction is owed
    /// once the user has actually turned onto it.
    ///
    /// ── Why the cue is split ────────────────────────────────────────────
    /// "Turn left. Walk 6 meters toward the next turn." asserts two things at
    /// once, and the second is only true if the first was obeyed correctly. A
    /// 4 Sep 2026 tester turned the wrong way and the app confidently told
    /// them to walk 6 m in it — the recovery afterwards was fine, but it had
    /// already sent them off in the wrong direction with full confidence.
    /// Naming the maneuver, waiting for it, and only then releasing the walk
    /// means the distance is never spoken against a facing that contradicts
    /// it, and a wrong turn is caught before a step is taken rather than
    /// after several.
    ///
    /// The 11 Aug 2026 pilot finding this must not undo: participants
    /// completed a turn and stood still, because nothing told them to move
    /// again. It still does — `postTurnLegCueMaxWaitSeconds` guarantees the
    /// walk instruction arrives whether or not the turn is ever detected.
    private var pendingPostTurnLegCueStepIndex: Int?
    private var pendingPostTurnLegCueArmedAt: Date?
    /// Longest the walk instruction waits for a turn that may never register —
    /// a user who turns wide, a heading on the tilt fallback, a stationary
    /// user thinking about it. Past this it is spoken regardless.
    private let postTurnLegCueMaxWaitSeconds: TimeInterval = 5.0
    private var didRebuildRouteThisUpdate = false
    private var turnPhrasing: SemanticTurnPhrasing = .leftRight
    /// Heading buckets faced while standing at an endpoint (destination or start),
    /// keyed by node id. A near-full set means the user turned a circle there,
    /// banking the all-direction features cold-start relocalization needs — the
    /// fix for the "pan around then time out" stall when a later journey starts
    /// from this spot.
    private var anchoringHeadingBuckets: [String: Set<Int>] = [:]
    /// Endpoints already prompted to anchor this capture/enrichment session.
    private var anchoringPromptedNodeIDs: Set<String> = []
    /// Endpoints that reached `anchoringRequiredBuckets` this session.
    private var anchoredNodeIDs: Set<String> = []
    private var lastEnrichmentSampledPoint: SemanticRoutePoint?
    private var lastEnrichmentSampledHeading: Double?
    private var lastEnrichmentSampledAt: Date?
    /// Recent AR headings with timestamps. Guidance starts the moment
    /// relocalization confirms — which is usually mid-way through the "turn in
    /// a full circle" sweep the user was just asked to do. A turn command
    /// computed from one instantaneous sample of that sweep is stale before
    /// TTS finishes speaking it; these samples let alignment cues wait until
    /// the heading has actually settled.
    private var recentHeadingSamples: [(at: Date, degrees: Double)] = []
    /// Geometry of a dropped leading stub: the short first leg the user still
    /// physically walks even though it no longer exists as a route step. A
    /// user facing along it is facing the route, and must not be told to turn
    /// toward the (post-stub) first leg they have not reached yet.
    private var leadingStubBearingDegrees: Double?
    private var leadingStubMeters: Double = 0

    private let arrivalThresholdMeters = 0.55
    /// How close to the destination node counts as arrived.
    ///
    /// Raised from 0.75 m on pilot feedback (17 Aug 2026). At 0.75 m the route
    /// was still counting a blind walker down — "one more step, one more step"
    /// — into a shelf she could not see and was already close enough to reach.
    /// Her words: "I was a comfortable distance away to figure out what cereal
    /// I might want, I didn't need to be right up at the shelf." Arrival is
    /// where browsing starts, and browsing starts at arm's length plus room to
    /// stand, not at contact. Reaching guidance takes over from here and is
    /// the thing that closes the last metre.
    private let destinationProximityMeters = 1.35
    /// Stillness-fallback arrival: near the destination and stopped this long
    /// completes the route even when the strict arrival window can't be met.
    private let destinationStillnessRadiusMeters = 1.4
    private let destinationStillnessArrivalSeconds: TimeInterval = 2.0
    /// Standing at the turn: the instruction is the bare command.
    private let turnAnnouncementThresholdMeters = 0.75
    /// Approaching the turn: the instruction is the command plus how far.
    ///
    /// This gate used to be `turnAnnouncementThresholdMeters` as well, which
    /// made the two-branch decision below a coin with one face — the
    /// "Turn right in 3 meters" form was unreachable, so the banner sat on the
    /// leg's distance ("3 meters toward the next turn") the whole way in while
    /// the countdown said something else out loud. Matched to the first
    /// approach gate so screen and voice describe the same turn from the same
    /// distance.
    private let turnPreannouncementMeters = 3.0
    /// Remaining-distance gates on the way to a leg's maneuver. Descending;
    /// only the nearest un-spoken gate ever fires.
    ///
    /// The first gate crossed on a leg names the maneuver ("Turn left in 3
    /// meters"); every gate after it speaks the bare distance ("2", "1").
    /// Naming the maneuver once and then counting down is how a sighted walker
    /// reads a sign and then just watches the distance close — repeating the
    /// whole instruction at each gate is what made the guidance feel like it
    /// was talking over the walk.
    ///
    /// The countdown starts at 3 m, not 6. A reviewer's note on 15 Aug 2026:
    /// "I thought we agreed that the countdown to the turn instruction would
    /// start around 3 meters before the turn." The 6 m gate fired one metre
    /// into a seven-metre leg, so its advance notice was spent long before the
    /// turn and the turn itself then arrived unheralded.
    private let approachCueGatesMeters: [Double] = [3.0, 2.0, 1.0]
    /// A gate only fires on legs enough longer than the gate itself that the
    /// cue cannot land on top of the leg-start instruction which just spoke
    /// the same distance. One metre — roughly a second of walking — is enough
    /// separation now that the pacing floor below is a delay rather than a
    /// deletion; more headroom would push the 3 m gate off every leg under 5 m,
    /// which is most of them.
    private let approachGateHeadroomMeters = 1.0
    /// The single bare-distance beat that carries the walk *above* the approach
    /// gates — one per leg, near its midpoint.
    ///
    /// ── Two pieces of feedback pulling opposite ways ────────────────────
    /// 20 Aug 2026, blind pilot participant: a leg opened with "8 meters toward
    /// the next turn" and said nothing again until "turn right in 3 meters" —
    /// "nothing in between". The 20 s quiet backstop never fired because 5 m of
    /// walking takes well under 20 s. So beats were added every 2 m.
    /// 3 Sep 2026, reviewer: on a 23 m leg that produced "23 … 21 … 18 … 15 …
    /// 11 … 8 … in 3 meters, turn left" — "just extra noise that the user is
    /// being forced to hear".
    ///
    /// Both are right about their own leg. The mistake was measuring the
    /// cadence with a ruler: a fixed 2 m interval gives one beat on a short leg
    /// and six on a long one, when what the user needs is the same thing in
    /// both cases — one confirmation, partway, that the system still has them.
    /// So the count is fixed at one and its POSITION scales with the leg.
    ///
    /// This is deliberately NOT an approach gate. A gate above 3 m would be the
    /// first gate crossed on the leg and would take over the maneuver-naming
    /// cue, which is the regression a reviewer rejected on 15 Aug 2026 —
    /// advance notice spent metres before the turn, leaving the turn itself
    /// unheralded. A beat speaks the remaining distance and nothing else.
    private let walkProgressBeatCount = 1
    /// Beats stop here and hand over to the approach gates.
    ///
    /// A full interval clear of the top gate (3 m) rather than flush against
    /// it: a beat landing at 4 m starts the pacing window barely a second
    /// before the 3 m gate comes due, and the naming cue then slid to 2.4 m.
    /// "Turn right in 3 meters" arriving at 2.4 m is precisely the late advance
    /// notice the 15 Aug 2026 review was about.
    private let walkProgressBeatFloorMeters = 5.0
    /// Shortest leg that gets a beat at all. Below this the leg-start cue and
    /// the 3 m gate are already close enough together to carry it.
    private let walkProgressBeatMinimumLegMeters = 7.0
    /// Pacing floor for the beat, so it cannot land on another cue's heels.
    private let walkProgressBeatMinimumSpacingSeconds: TimeInterval = 3.0
    /// Floor under the maneuver-naming cue specifically.
    ///
    /// It used to share the 6 s routine floor, and that is what deleted the
    /// only advance notice a reviewer's turn ever got: the leg-start cue reset
    /// the window, the 3 m gate arrived four seconds later and was refused, and
    /// the next thing spoken was the turn itself. The floor exists so two cues
    /// do not land on top of each other — a couple of seconds does that. It must
    /// never be long enough to swallow a decision cue whole.
    private let approachCueMinimumSpacingSeconds: TimeInterval = 2.0
    /// A countdown beat is suppressed when the live AR pose says the user is
    /// already standing at the node.
    ///
    /// The beat's distance comes from the more conservative of dead reckoning
    /// and the AR pose, so a lagging belief can speak "3 meters" to someone half
    /// a metre from the turn — and the turn cue then follows it immediately,
    /// which is what made the position estimate sound like it was jumping.
    /// Saying nothing there is honest; the turn is a moment away and owns the
    /// space.
    ///
    /// ⚠️ Must stay strictly below `approachCueGatesMeters.min()`, and this is
    /// load-bearing rather than a matter of taste. The cue distance is
    /// `min(legLength, max(deadReckoned, arDistance))`, so it is never below
    /// the AR distance — which means the final gate becoming eligible
    /// (`cueRemaining <= 1.0`) *implies* `arDistance <= 1.0`. While this was
    /// also 1.0 the two conditions were the same condition, the suppression
    /// fired every single time the last gate came due, and the "1" beat was
    /// unreachable code: the countdown always ended on "2". Pilot report,
    /// 20 Aug 2026 — "after 3 it should be like the countdown 3 meter, 2,
    /// then 1". At 0.6 the beat still lands, and speaks the live distance, so
    /// it is honest at the moment it is said.
    private let approachCueSuppressWithinMeters = 0.6
    /// Floor between two routine spoken cues. Maneuver, arrival and recovery
    /// speech ignores it — those are decisions, not pacing.
    private let routineCueMinimumSpacingSeconds: TimeInterval = 6.0
    /// Longest the walk goes unspoken before the current instruction is
    /// repeated. Sparse guidance is calmer; silent guidance reads as a system
    /// that has stopped tracking, which is the failure mode this bounds.
    private let routineCueQuietMaxSeconds: TimeInterval = 20.0
    private let crossTrackRecoveryThreshold = 1.35
    private let recoverySnapThreshold = 1.15
    /// A snap whose heading disagrees more than this is a position guess, not a
    /// realignment — announcing "realigned, continue" walks the user off at the
    /// wrong angle and the belief collapses again seconds later (CIMS trace:
    /// snap at 99° err → "Guidance realigned" → lost 1.3 s on). The position
    /// still snaps; the announcement becomes the alignment cue instead.
    private let recoverySnapTrustedHeadingErrorDegrees = 55.0
    /// A healthy belief must persist this long before recovery exits and
    /// announces "Back on route": single-tick flickers exited and re-entered
    /// six times in 100 s, each round trip spoken aloud.
    private let beliefExitHysteresisSeconds: TimeInterval = 2.0
    /// After a snap or exit, a fresh "Route lost" announcement stays quiet for
    /// this long — the banner updates, speech does not repeat the episode.
    private let beliefHoldReentryQuietSeconds: TimeInterval = 10.0
    private let headingRecoveryThreshold = 95.0
    private let recoveryHoldSeconds: TimeInterval = 0.6
    private let recoveryCueCooldownSeconds: TimeInterval = 5.0
    private let beliefHoldGraceSeconds: TimeInterval = 1.25
    private let beliefHoldRepeatSeconds: TimeInterval = 7.0
    /// A lost route stays SILENT for this long before it apologises.
    ///
    /// The snap escalation fires at 5 s and clears most holds without the user
    /// ever needing to know one happened, so anything spoken before then is an
    /// interruption about a problem that was already being fixed. Sitting just
    /// past it means the apology only reaches the user when the quick recovery
    /// has actually failed — which is the one case where the pilot participant
    /// wanted to hear something.
    ///
    /// Raised from 5.5 s on 15 Aug 2026. At 5.5 it landed half a second after
    /// the snap escalation started work, so a reviewer heard "Turn to 9 o'clock"
    /// / "Sorry, let me realign." / "Head to 7 o'clock, 7 meters" as one block
    /// and called the recovery instructions very confusing. The apology carries
    /// no action, so it must not sit between the user and one that does; nine
    /// seconds gives the snap a full four to land silently first, while still
    /// leaving a genuinely stuck route with a voice.
    private let beliefHoldSpokenAfterSeconds: TimeInterval = 9.0
    /// After this long in a belief hold, stop asking the user to pan and
    /// actively snap back onto the best-matching route position.
    private let beliefRelocalizeAfterSeconds: TimeInterval = 5.0
    /// After this long, rebuild the whole route from the live pose instead of
    /// looping the same recovery cue.
    private let beliefRebuildAfterSeconds: TimeInterval = 12.0
    private let routeRebuildRetrySeconds: TimeInterval = 4.0
    /// Quiet window after a step advance during which no realignment may
    /// re-plan the route.
    ///
    /// A step advance is the freshest and most specific evidence the navigator
    /// has about where the user is: it fired because the pose reached a node.
    /// A realignment 0.3 s later re-resolves from a pose the advance has
    /// already superseded, and on 25 Aug 2026 one resolved back onto the leg
    /// just finished and re-announced the same turn — which is how a turn cue
    /// arrives AFTER the user has walked into the wall it was meant to save
    /// them from.
    private let routeRebuildAfterAdvanceSeconds: TimeInterval = 2.5
    /// How far a realignment may move progress on the SAME leg and still count
    /// as "nothing the user needs to hear". Inside this, the pose correction is
    /// applied silently.
    private let routeRealignSilentProgressMeters = 1.5
    /// Extra walking a rebuild may add before it reads as a wrong-edge
    /// resolution rather than a correction. Scaled against the remaining route
    /// as well, so short final legs are not judged by an absolute metre count.
    private let routeRebuildRegressionMarginMeters = 3.0
    private let postRecoveryAlignmentWindowSeconds: TimeInterval = 6.0
    /// AR must disagree with a dead-reckoned step completion by more than
    /// this before the advance is blocked.
    private let arStepCompletionSlackMeters = 1.0
    private let destinationJustAheadMeters = 1.6
    /// Minimum gap between the destination's "in 3 meters" cue and its "just
    /// ahead" cue — see `speakDestinationApproachIfDue`.
    private let destinationApproachMinimumSpacingSeconds: TimeInterval = 2.0
    /// How far past the destination, measured along the final leg, before the
    /// user is told they have overshot it.
    ///
    /// Comfortably outside `destinationJustAheadMeters` so the approach cue and
    /// the arrival gate own everything up to the shelf, and outside the metre
    /// or so of belief noise that a stationary user shows: telling someone to
    /// turn around when they have not passed anything is a worse failure than
    /// the silence this replaces.
    private let destinationOvershootMeters = 2.2
    /// And sustained for this long, so one bad pose cannot trigger it.
    private let destinationOvershootHoldSeconds: TimeInterval = 1.5
    /// Repeat cadence while they keep walking the wrong way.
    private let destinationOvershootRepeatSeconds: TimeInterval = 6.0
    private let trackingLimitedPrefixCooldownSeconds: TimeInterval = 10.0
    private let guidanceIntroProtectionSeconds: TimeInterval = 4.0
    private let autoSampleDistanceMeters = 0.60
    private let autoSampleTurnDegrees = 24.0
    private let autoSampleTurnMinimumDistance = 0.25
    private let targetNodeSnapDistance = 0.35
    private let manualNodeSnapDistance = 0.28
    private let routeStartEdgeSnapThreshold = 1.6
    /// How many of the nearest edges start resolution scores. One is not
    /// enough on a route that doubles back through its own corridor; a
    /// handful covers every overlap seen in captured maps without making the
    /// resolve loop meaningfully more expensive.
    private let routeStartEdgeCandidateLimit = 8
    /// A final leg this short was never a walk: in a narrow aisle the mapper
    /// pins a node at arm's length from the shelf so arrival can say which way
    /// to face. Guiding it as a segment sends the user walking into the shelf.
    private let stubLegMaxMeters = 1.5
    /// A leg at or under this is never instructed as a walk — see
    /// `doglegInstruction`. Matches the band `formatMeters` can only describe
    /// as "less than one meter" or "about 1 meter", which is precisely the
    /// phrasing that drew the objection.
    private let microLegMaxMeters = 1.5
    /// Below this a node is not a decision point, so its two legs are one walk.
    /// Matches the band `turnInstruction` already speaks as "continue
    /// straight" — anything it would not announce is not worth a leg boundary.
    private let mergeMaxTurnDegrees = 18.0
    /// How far a folded node may sit off the merged chord. Keeps the merged
    /// leg's geometry inside the cross-track gates that keyframe matching,
    /// progress projection and recovery all measure against.
    private let mergeMaxChordOffsetMeters = 0.6
    /// Longest leg two steps may merge into. Beyond this the folded-away node
    /// is worth more as a mid-corridor re-anchor than the merge is as tidier
    /// phrasing — see `canMerge`. Sized so the shelf-stub and straight-point
    /// artefacts merging was written for still fold, while the long runs
    /// between real waypoints keep their nodes.
    private let mergedLegMaxMeters = 9.0
    /// Below this the geometry has no handedness worth arguing with, so a
    /// recorded turn hint is never overridden.
    private static let hintContradictionMinimumDegrees = 25.0
    private let visualRouteMatchInterval: TimeInterval = 0.45
    /// Similarity that maps to zero confidence (noise floor between unrelated
    /// corridor frames) and the span to full confidence. Field distribution:
    /// min 0.21, mean 0.39-0.49, max 0.45-0.61 across four traces.
    private let visualSimilarityFloor = 0.30
    private let visualSimilaritySpan = 0.35
    /// With the mapping above: 0.40 confidence ≈ 0.44 similarity (contributes
    /// evidence), 0.72 ≈ 0.55 similarity (trusted enough to snap position).
    /// Both were 0.68/0.88 against a mapping that could only ever return 0.
    private let visualRouteMinimumConfidence = 0.40
    private let visualRouteSnapConfidence = 0.72
    private let visualRouteArrivalConfidence = 0.76
    private let visualRouteAmbiguousGap = 0.20
    /// How far the live AR pose may still be from the destination node while a
    /// visual match is allowed to declare arrival.
    ///
    /// A visual match is pose-INDEPENDENT. That is what makes it useful when
    /// the pose is lost, and it is exactly what makes it dangerous when the
    /// pose is good: on a route walked in both directions the enrichment pass
    /// captured the destination's surroundings from the opposite heading, so a
    /// camera 16 m short of 436 can genuinely match a keyframe belonging to it.
    /// On 25 Aug 2026 that is what happened — "Arrived at 436" with the AR pose
    /// reading 4.9 m into a 20.6 m leg, cross-track 0.23 m, localized and
    /// steady. A pose that good is not outvoted by a photograph.
    ///
    /// Generous rather than tight, because the shortcut still has a real job:
    /// dead-reckoned progress lags after a turn, and a user standing at the
    /// shelf must not be told to keep walking.
    private let visualArrivalMaxARRemainingMeters = 3.0
    /// How far apart two near-tied visual matches may sit and still describe
    /// one place. Keyframes are captured about a third of a metre apart, so
    /// several always land inside it.
    private let visualSameRoutePlaceMeters = 1.5
    private let visualRouteAdvanceCooldownSeconds: TimeInterval = 1.4
    // ── Map-frame yaw bias ──────────────────────────────────────────────────
    // How many accepted visual matches must agree before the AR frame is
    // declared rotated. Three, because one match can be a lucky lookalike and
    // two can both be the same wrong place; and because the correction rebuilds
    // the route, which the user hears.
    private let visualYawSamplesRequired = 3
    /// How many of the most recent measurements are weighed. Recency matters
    /// because the frame error is a STEP, not a drift: when ARKit re-orients,
    /// every older reading describes a frame that no longer exists, and mixing
    /// the two populations makes any spread test fail forever. Judging the tail
    /// means the estimate follows the frame instead of averaging across a
    /// change in it.
    private let visualYawRecentSamples = 5
    /// Measurements older than this stop counting at all.
    private let visualYawWindowSeconds: TimeInterval = 45
    /// How far a measurement may sit from the median and still be counted as
    /// agreeing with it. A keyframe matches from a slightly different standpoint
    /// than it was captured from, so individual readings scatter; a real frame
    /// rotation is a common bias underneath that scatter.
    private let visualYawAgreementDegrees: Double = 11
    /// Below this the correction is not worth rebuilding the route for — it is
    /// inside the scatter of the measurement itself.
    private let visualYawActionableDegrees: Double = 12
    /// Above this a "rotation" is far more likely to be three matches from the
    /// wrong corridor than a real frame error, so it is logged and refused
    /// rather than applied. Relocalization, not arithmetic, is the answer to a
    /// frame that far out.
    private let visualYawMaxCorrectionDegrees: Double = 60
    private let visualYawCorrectionCooldownSeconds: TimeInterval = 10
    /// Kept short: at the finish line a long visual-confirmation hold reads
    /// as "the app is lost" and delays the reaching handoff.
    private let visualArrivalMaxHoldSeconds: TimeInterval = 2.5
    private let maxImmediateARProgressCorrectionMeters = 0.75
    private let maxImmediateVisualProgressCorrectionMeters = 1.75
    private let largeProgressCorrectionConfirmationSeconds: TimeInterval = 0.85
    private let largeProgressCorrectionRequiredSamples = 5
    private let visualDecisionAdvanceConfidence = 0.88
    private let visualDecisionImmediateConfidence = 0.96
    private let decisionAdvanceConfirmationSeconds: TimeInterval = 0.65
    private let decisionAdvanceRequiredSamples = 2
    private let routeAdvanceMaxUnconfirmedRemainingMeters = 1.20
    private let routeStartHeadingPenaltyMeters = 1.25
    private let routeStartAlignmentThresholdDegrees = 20.0
    private let routeTurnAlignmentThresholdDegrees = 55.0
    private let routeAlignmentProgressWindowMeters = 1.10
    private let routeAlignmentCueCooldownSeconds: TimeInterval = 3.0
    /// Two alignment cues never land on top of each other, whatever changed.
    /// A person needs about this long to start acting on the first one.
    private let routeAlignmentCueMinimumGapSeconds: TimeInterval = 1.8
    /// Heading error must close by at least this much to count as "already
    /// turning" — smaller than that is head sway, not a turn.
    private let routeAlignmentImprovementDegrees = 15.0
    /// Window and spread for calling the live heading "settled". Samples inside
    /// the window spanning more than the spread mean the user is still turning
    /// (a relocalization sweep, or acting on an earlier cue) — an alignment cue
    /// computed from any single instant of that motion commands a turn against
    /// a facing the user no longer has.
    private let headingSettleWindowSeconds: TimeInterval = 0.9
    private let headingSettleMaxSpreadDegrees = 22.0
    /// How closely the live heading must match a dropped leading stub's bearing
    /// to count as "already facing the route". Wider than the start-alignment
    /// threshold because the stub is short and coarse — a user roughly facing
    /// the hop is doing the right thing and must not be commanded to pre-turn
    /// onto the leg that only starts after it.
    private let leadingStubFacingToleranceDegrees = 40.0
    /// A turn that stops part-way gets one repeat after this long.
    private let routeAlignmentStalledCueSeconds: TimeInterval = 6.0
    // ── Corrective-cue backoff ──────────────────────────────────────────────
    //
    // See `consecutiveCorrectiveCues`. The first few corrections are spoken at
    // full cadence, because most of the time the user simply has not heard yet
    // or is mid-turn. Past that the cue is demonstrably not working, and the
    // pilot's experience of hearing it anyway was "overwhelming" and
    // "stressful" — so each further repeat waits longer, up to a cap that is
    // long enough to walk around a person and rejoin without being talked at.
    private let correctiveCueFreeRepeats = 2
    private let correctiveCueBackoffStepSeconds: TimeInterval = 3.0
    private let correctiveCueBackoffMaxSeconds: TimeInterval = 12.0
    /// How long a user must be stopped before corrections go quiet entirely.
    ///
    /// "I just wanted to step aside and pause and be quiet for a second."
    /// Someone who has stopped walking is not lost, they are dealing with
    /// something — a person in the aisle, a display, a question from a
    /// stranger. Repeating a turn command at a standing user cannot help them
    /// and is the single behaviour the pilot named as making recovery worse
    /// than no recovery. The route is still tracked; it just stops talking
    /// until they move again.
    private let correctiveCueStillnessQuietSeconds: TimeInterval = 1.5
    // ── Course correction (staying centred in the aisle) ────────────────────
    //
    // Pilot, clock-face condition: a participant walking a straight aisle but
    // drifting to the right heard nothing until he brushed the shelf, because
    // the only lateral guidance there is — cross-track recovery — does not arm
    // until the user is over a metre off the centre line, which in a 1.2 m
    // aisle means already in the shelving. And when it does arm it aims at the
    // NEAREST point on the route, i.e. straight sideways: a correction that
    // crosses the centre line instead of joining it, which is what had him
    // bouncing between the two sides.
    //
    // Both come out of one change: steer at a point AHEAD on the leg rather
    // than beside it (pure pursuit). Heading error and lateral offset fold
    // into a single small angle, and following it converges onto the centre of
    // the aisle. In clock-face phrasing that angle lands on 11 or 1 o'clock,
    // which is exactly the nudge that was asked for.
    //
    /// How far ahead on the leg the steering target sits. Larger is gentler:
    /// this is what keeps ordinary aisle offsets inside one clock hour instead
    /// of commanding a sidestep.
    private let courseLookaheadMeters = 2.4
    private let courseMinimumLookaheadMeters = 1.0
    /// Below this the user is walking the corridor well enough to be left
    /// alone. Sized above a walking head-sway and below the ~20° diagonal that
    /// crosses a 1.2 m aisle within four metres.
    private let courseCorrectionThresholdDegrees = 20.0
    /// Above this it is a turn, not a nudge, and the wording would lie: "ease
    /// to 3 o'clock" for an 85° error reads as an adjustment and is a
    /// manoeuvre. Kept just under `routeTurnAlignmentThresholdDegrees` so the
    /// two cues never hold different opinions about the same angle.
    private let courseCorrectionMaxDegrees = 50.0
    /// The error must persist this long before anything is spoken. One sway of
    /// the phone toward a shelf is not a course.
    private let courseCorrectionHoldSeconds: TimeInterval = 2.0
    /// And a nudge is never repeated sooner than this, whatever changed. The
    /// whole point of the cue is that it is rare enough to be worth acting on.
    private let courseCorrectionRepeatSeconds: TimeInterval = 9.0
    /// Nor does one land on the heels of a turn, alignment or recovery cue.
    private let courseCorrectionQuietAfterTurnSeconds: TimeInterval = 6.0
    /// Never fires this close to the end of a leg; the turn cue owns that space
    /// and a nudge there would fight it.
    private let courseCorrectionMinimumRemainingMeters = 1.5
    private let maxPDRDeltaPerUpdateMeters = 1.20
    private let offAxisProgressExtraMeters = 1.25
    private let offAxisProgressMaxMeters = 3.4
    private let backwardProgressCorrectionMaxMeters = 1.15
    private let backwardRecoveryDriftMeters = 0.55
    private let immediateBackwardRecoveryDriftMeters = 0.75
    private let recoveryAdvisoryCrossTrackMeters = 1.05
    private let recoveryCriticalCrossTrackMeters = 1.85
    private let destinationCorridorExtraMeters = 0.55
    private let destinationCorridorMaxMeters = 1.65
    private let routeBeliefWindowSeconds: TimeInterval = 2.4
    private let routeBeliefBucketMeters = 0.85
    /// Same-step candidates closer than this are one belief, not competitors.
    /// Must exceed the bucket width, or ordinary PDR-vs-AR disagreement lands
    /// in adjacent buckets and reads as "ambiguous", spamming pause cues.
    private let routeBeliefAmbiguityMergeMeters = 1.35
    private let routeBeliefMinimumLockedConfidence = 0.62
    private let routeBeliefMinimumInstructionMargin = 0.14
    private let routeBeliefMaximumInstructionUncertainty = 1.70
    private let routeBeliefLargeCorrectionSupportMeters = 0.75
    private let routeBeliefLargeCorrectionMinimumSamples = 3
    private let routeBeliefLargeCorrectionMinimumDuration: TimeInterval = 0.75
    private let routeBeliefPhysicalSlackMeters = 0.85
    /// Predicting an old sample forward inherits the dead-reckoning error of
    /// the distance it was carried over, so its uncertainty grows with that
    /// distance. Keeps a sample from two seconds ago from counting as if it
    /// had just been measured.
    private let routeBeliefPropagationUncertaintyPerMeter = 0.15
    /// A single-node path means "already there" — only believable when the
    /// live pose is genuinely this close to the target node.
    private let immediateArrivalMaxMeters = 2.0
    /// Standing still this long re-speaks the full walk instruction; the
    /// meter-countdown speech only fires while progress changes.
    private let stillnessRepromptAfterSeconds: TimeInterval = 7.0
    private let stillnessRepromptRepeatSeconds: TimeInterval = 18.0
    /// Off-corridor recovery escalates from orientation nudges to a real
    /// rejoin route ("walk N meters back to the route") after this long.
    private let rejoinGuidanceAfterSeconds: TimeInterval = 6.0
    private let rejoinMaxDistanceMeters = 12.0
    private let rejoinMinimumDistanceMeters = 0.75
    /// Appended captures must begin near the existing network so the new
    /// branch connects instead of forming an unroutable island.
    private let appendConnectRadiusMeters = 4.0
    /// Re-marking a spot within this range of an existing turn/waypoint reuses
    /// that node instead of minting a duplicate. Matches the junction snap
    /// radius: anything close enough to stitch is the same physical place, and
    /// duplicating it builds the parallel-chain multigraph that made return
    /// captures unroutable (two antiparallel edges 0.4–0.9 m apart turn start
    /// resolution into a coin flip).
    private let nodeReuseRadiusMeters = 0.9
    /// Re-marking a POI by NAME tolerates much more pose drift: "Mocktail"
    /// marked on a later visit is the same shelf even when relocalization
    /// error puts the new pose meters from the stored node.
    private let namedNodeReuseRadiusMeters = 4.0
    /// New nodes landing this close to an already-mapped node get a
    /// connector edge — crossings become routable junctions.
    private let junctionSnapRadiusMeters = 0.9
    /// Keyframe density pruning (see prunedVisualKeyframes). Static because
    /// the pruning itself is static for testability.
    private static let keyframePruneCellMeters = 0.6
    private static let keyframePruneHeadingBucketDegrees = 60.0
    /// Enough for both directions of a long route at the pruning density
    /// (a 77m route samples ≈130 keyframes per direction). Kept bounded
    /// because alias detection is O(n²) over the fingerprint set.
    private static let maxStoredKeyframes = 320
    /// Alias detection skips pairs whose capture headings differ by more than
    /// this — see `visualAliasGroups`.
    private static let aliasHeadingGateDegrees = 100.0
    /// Live keyframe matches whose stored heading differs from the camera
    /// heading by more than this cannot be looking at the same scene; they
    /// only add aliasing noise once both walking directions are captured.
    private static let visualMatchHeadingGateDegrees = 100.0
    /// Enrichment walk sampling: keyframes while moving along the route,
    /// plus stationary samples while the user turns in place at a POI dwell.
    private let enrichmentSampleDistanceMeters = 0.75
    private let enrichmentDwellHeadingDegrees = 40.0
    private let enrichmentDwellMaxMoveMeters = 0.35
    /// Samples only count while near the mapped corridor; wandering into a
    /// side room must not pollute the route's visual evidence.
    private let enrichmentMaxCrossTrackMeters = 2.0
    private let enrichmentDwellPromptRadiusMeters = 1.6
    /// Endpoint anchoring (deliberate turn-in-place). Heading is quantized into
    /// `360 / anchoringBucketDegrees` buckets; covering `anchoringRequiredBuckets`
    /// of them near an endpoint counts as a full-enough sweep.
    private let anchoringBucketDegrees = 30.0
    private let anchoringRequiredBuckets = 9   // ~270° of a 360° sweep
    private let anchoringPromptRadiusMeters = 1.6

    private typealias RouteProjection = (
        alongTrackMeters: Double,
        crossTrackMeters: Double,
        nearestPoint: SemanticRoutePoint
    )

    private struct RecoveryCueDecision {
        let instruction: String
        let reason: String
        let key: String
    }

    private struct PendingProgressCorrection {
        let stepIndex: Int
        let source: String
        var progressMeters: Double
        var firstSeenAt: Date
        var lastSeenAt: Date
        var sampleCount: Int
    }

    private struct PendingRouteAdvance {
        let key: String
        var firstSeenAt: Date
        var lastSeenAt: Date
        var sampleCount: Int
    }

    private struct RouteEvidence {
        let stepIndex: Int
        let progressMeters: Double
        let confidence: Double
        let uncertaintyMeters: Double
        let source: String
        let capturedAt: Date
        /// `cumulativeTravelMeters` when this sample was taken, so the belief
        /// filter can carry it forward to the present.
        let travelledMeters: Double
        let visualConfidence: Double?
        let crossTrackMeters: Double?
        let summary: String
    }

    private struct RouteBeliefCandidate {
        let stepIndex: Int
        let progressMeters: Double
        let confidence: Double
        let uncertaintyMeters: Double
        let supportCount: Int
        let sources: Set<String>
        let summary: String
    }

    private struct RouteBeliefState {
        var status: RouteLocalizationStatus
        var candidates: [RouteBeliefCandidate]
        var confidence: Double
        var margin: Double
        var uncertaintyMeters: Double
        var isInstructionSafe: Bool
        var evidenceSummary: String
        var updatedAt: Date?

        static let empty = RouteBeliefState(
            status: .initializing,
            candidates: [],
            confidence: 0,
            margin: 0,
            uncertaintyMeters: 0,
            isInstructionSafe: false,
            evidenceSummary: "No route evidence yet.",
            updatedAt: nil
        )
    }

    private struct NavigationStart {
        var nodePath: [String]
        var initialProgressMeters: Double
    }

    /// One edge of the route graph with the pose projected onto it. Named
    /// members rather than a tuple so a ranked list of them stays readable.
    private struct EdgeMatch {
        var edge: SemanticRouteEdge
        var alongTrackMeters: Double
        var crossTrackMeters: Double
    }

    private struct VisualFingerprintSample {
        let id: String
        let fingerprint: ARVisualFingerprint
    }

    private struct VisualRouteMatch {
        let stepIndex: Int
        let progressMeters: Double
        let confidence: Double
        let keyframeID: String?
        let landmarkID: String?
        let landmarkName: String?
        let fingerprintID: String
        let isAliased: Bool
        let cue: String?
    }

    private struct VisualRouteCandidate {
        let stepIndex: Int
        let progressMeters: Double
        let fingerprint: ARVisualFingerprint
        let fingerprintID: String
        let keyframeID: String?
        let landmarkID: String?
        let landmarkName: String?
        let cue: String?
        /// True when the step actually owns this sample (captured on its edge
        /// or listed in its keyframe ids) rather than merely passing close
        /// enough to it for the geometric fallback to claim it.
        let isOwnedByStep: Bool
    }

    init() {
        loadMaps()
    }

    var availableTargets: [String] {
        activeMap?.targetNames ?? maps.first?.targetNames ?? []
    }

    var canSaveCapturedMap: Bool {
        guard let map = activeMapDraft ?? activeMap else { return false }
        return map.nodes.contains { $0.kind == .entrance }
            && map.nodes.contains { $0.kind == .destination }
            && !map.edges.isEmpty
    }

    var saveCapturedMapError: String? {
        guard let map = activeMapDraft ?? activeMap else { return "No active map." }
        if !map.nodes.contains(where: { $0.kind == .entrance }) {
            return "Missing entrance point."
        }
        if !map.nodes.contains(where: { $0.kind == .destination }) {
            return "Missing destination point."
        }
        if map.edges.isEmpty {
            return "Missing route path."
        }
        return nil
    }

    var mappingStageTitle: String {
        guard phase == .mapping else { return phase.displayName }
        guard let map = activeMapDraft ?? activeMap else { return "Start route map" }
        if map.nodes.isEmpty { return "Capture Point A" }
        if !map.nodes.contains(where: { $0.kind == .destination }) { return "Walk and mark turns" }
        return "Review and save route"
    }

    var routeReviewLines: [String] {
        guard let map = activeMapDraft ?? activeMap else { return [] }
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        var lines: [String] = []
        if let start = map.nodes.first(where: { $0.kind == .entrance }) {
            lines.append("Start: \(start.name)")
        }
        for edge in map.edges {
            guard let from = nodeByID[edge.fromNodeID], let to = nodeByID[edge.toNodeID] else { continue }
            let turn = to.turnHint.map { " - \($0.displayName)" } ?? ""
            lines.append("\(Self.formatMeters(edge.distanceMeters)) from \(from.name) to \(to.name)\(turn)")
        }
        for landmark in map.landmarks.sorted(by: { $0.priority > $1.priority }) {
            lines.append("\(landmark.name) \(Self.sidePhrase(landmark.side))")
        }
        return Array(lines.prefix(8))
    }

    var activeStep: SemanticRouteStep? {
        guard currentStepIndex >= 0 && currentStepIndex < routeSteps.count else { return nil }
        return routeSteps[currentStepIndex]
    }

    /// Spoken-label vocabulary across every saved map, used by the voice
    /// layer to ground an ASR target ("serial") against real labels
    /// ("cereal") before the AR session is even opened. Reads the persisted
    /// store directly and touches no live navigator state, so it is safe to
    /// call from any queue.
    nonisolated static func availableTargetVocabulary() -> [[String: String]] {
        let storedMaps = SemanticRouteMapStore().load()
        var seen = Set<String>()
        var entries: [[String: String]] = []
        for map in storedMaps {
            for label in map.targetNames {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard seen.insert("\(trimmed.lowercased())|\(map.id)").inserted else { continue }
                entries.append(["label": trimmed, "mapId": map.id, "mapName": map.name])
            }
        }
        return entries
    }

    func loadMaps() {
        let loaded = store.load()
        let cleaned = loaded.map { Self.sanitizedMap(Self.migratedToNorthUpAxes($0)) }
        if cleaned != loaded {
            store.save(cleaned)
        }
        maps = cleaned
        if activeMap == nil {
            activeMap = maps.first
        }
        phase = activeMap == nil ? .idle : .ready
        rebuildRAGContext()
    }

    func useMap(id: String) {
        guard let map = maps.first(where: { $0.id == id }) else { return }
        stopNavigation()
        activeMap = map
        activeMapDraft = nil
        phase = .ready
        currentInstruction = "Semantic map ready."
        rebuildRAGContext()
    }

    func deleteMap(id: String) {
        let wasActive = activeMap?.id == id || activeMapDraft?.id == id
        stopNavigation(resetInstruction: false)
        maps.removeAll { $0.id == id }
        store.save(maps)

        if wasActive {
            activeMapDraft = nil
            activeMap = maps.first
        } else if let activeMap, maps.contains(where: { $0.id == activeMap.id }) == false {
            self.activeMap = maps.first
        }

        targetName = ""
        routeSteps.removeAll()
        currentStepIndex = 0
        segmentProgressMeters = 0
        segmentRemainingMeters = 0
        totalRemainingMeters = 0
        recoveryReason = nil
        phase = activeMap == nil ? .idle : .ready

        if let activeMap {
            refreshCaptureMetrics(for: activeMap)
            currentInstruction = "Route deleted. Semantic map ready."
        } else {
            capturedPointCount = 0
            capturedTurnCount = 0
            capturedLandmarkCount = 0
            capturedDestinationCount = 0
            capturedDistanceMeters = 0
            currentSegmentDraftMeters = 0
            mappingQualityText = "Not mapping"
            currentInstruction = "Route deleted. No saved semantic routes."
        }

        emitCue(currentInstruction, priority: .regular)
        rebuildRAGContext()
    }

    func linkActiveRouteToARWorldMap(id arWorldMapId: String?) {
        guard let arWorldMapId,
              var map = activeMap,
              map.arWorldMapId != arWorldMapId else {
            return
        }
        map.arWorldMapId = arWorldMapId
        map.updatedAt = Date()
        let cleaned = Self.sanitizedMap(map)
        upsertMap(cleaned, persist: true)
        activeMap = cleaned
        if activeMapDraft?.id == cleaned.id {
            activeMapDraft = cleaned
        }
        rebuildRAGContext()
    }

    func beginRouteCapture(named requestedName: String) {
        let trimmed = Self.sanitizedSpokenLabel(requestedName)
        let name = trimmed.isEmpty ? "Semantic Route \(Self.shortTimestamp())" : trimmed
        let map = SemanticRouteMap(
            id: UUID().uuidString,
            name: name,
            createdAt: Date(),
            updatedAt: Date(),
            coordinateSpace: "ar_world_xz",
            axisConvention: Self.northUpAxisConvention,
            nodes: [],
            edges: [],
            landmarks: [],
            keyframes: [],
            source: "on_device_arkit",
            notes: "Captured on-device with ARKit pose and IMU route memory."
        )
        activeMapDraft = map
        activeMap = map
        lastCapturedNodeID = nil
        lastAutoSampledPoint = nil
        lastAutoSampledHeading = nil
        lastAutoSampledAt = nil
        capturedPointCount = 0
        capturedTurnCount = 0
        capturedLandmarkCount = 0
        capturedDestinationCount = 0
        capturedDistanceMeters = 0
        currentSegmentDraftMeters = 0
        resetEndpointAnchoring()
        mappingQualityText = "Mark Point A"
        stopNavigation(resetInstruction: false)
        phase = .mapping
        currentInstruction = "Mark Point A. Use the detected POI if it is correct, or type a start label."
        emitCue(currentInstruction, priority: .priority)
        rebuildRAGContext()
    }

    /// Continues capture inside an existing saved map instead of starting a
    /// new one. The pilot's "one-way map per trip" workflow came from every
    /// capture creating a fresh map: extend the store map instead, and the
    /// first new node is stitched to the nearest already-mapped node so the
    /// trails form one routable network.
    @discardableResult
    func beginRouteCaptureAppending(toMapID mapID: String) -> Bool {
        guard let existing = maps.first(where: { $0.id == mapID }) else { return false }
        stopNavigation(resetInstruction: false)
        activeMapDraft = existing
        activeMap = existing
        lastCapturedNodeID = nil
        lastAutoSampledPoint = nil
        lastAutoSampledHeading = nil
        lastAutoSampledAt = nil
        currentSegmentDraftMeters = 0
        resetEndpointAnchoring()
        seedAnchoredEndpoints(from: existing)
        refreshCaptureMetrics(for: existing)
        phase = .mapping
        mappingQualityText = "Extending \(existing.name)"
        currentInstruction = "Extending \(existing.name). Walk near the mapped route and mark points; new paths connect to the nearest mapped point."
        emitCue(currentInstruction, priority: .priority)
        rebuildRAGContext()
        return true
    }

    /// Enrichment walk: re-walk an already-saved route (normally in the
    /// reverse direction) to bank visual keyframes from the other viewing
    /// direction. Geometry is never touched — no nodes, no edges — so the
    /// route graph stays exactly as captured while the visual evidence layer
    /// doubles. Requires an already-relocalized AR session, because samples
    /// are only meaningful in the saved map's coordinate frame.
    @discardableResult
    func beginEnrichmentWalk(mapID: String) -> Bool {
        guard let existing = maps.first(where: { $0.id == mapID }) else { return false }
        stopNavigation(resetInstruction: false)
        activeMap = existing
        activeMapDraft = existing
        enrichmentKeyframesAdded = 0
        resetEndpointAnchoring()
        seedAnchoredEndpoints(from: existing)
        lastEnrichmentSampledPoint = nil
        lastEnrichmentSampledHeading = nil
        lastEnrichmentSampledAt = nil
        phase = .enriching
        refreshCaptureMetrics(for: existing)
        currentInstruction = NavLoc.enrichmentStarted(existing.name)
        emitCue(currentInstruction, priority: .critical)
        mappingQualityText = "Improving \(existing.name)"
        rebuildRAGContext()
        return true
    }

    /// Persists the keyframes gathered during an enrichment walk. The caller
    /// must also re-save the ARWorldMap so the enlarged feature set (captured
    /// by ARKit during the same walk) is stored alongside them.
    @discardableResult
    func finishEnrichmentWalk() -> Bool {
        guard phase == .enriching, var map = activeMapDraft ?? activeMap else { return false }
        map.updatedAt = Date()
        let cleaned = Self.sanitizedMap(map)
        upsertMap(cleaned, persist: true)
        activeMap = cleaned
        activeMapDraft = nil
        phase = .ready
        refreshCaptureMetrics(for: cleaned)
        let added = enrichmentKeyframesAdded
        currentInstruction = NavLoc.enrichmentSaved(keyframeCount: added)
        emitCue(currentInstruction, priority: .critical)
        rebuildRAGContext()
        return true
    }

    func cancelEnrichmentWalk() {
        guard phase == .enriching else { return }
        activeMapDraft = nil
        activeMap = maps.first(where: { $0.id == activeMap?.id }) ?? activeMap
        enrichmentKeyframesAdded = 0
        resetEndpointAnchoring()
        phase = activeMap == nil ? .idle : .ready
        currentInstruction = "Map improvement cancelled."
        rebuildRAGContext()
    }

    @discardableResult
    func captureStart(
        named requestedName: String,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState,
        capturedImage: CVPixelBuffer? = nil
    ) -> Bool {
        let trimmed = Self.sanitizedSpokenLabel(requestedName)
        let name = trimmed.isEmpty ? "Start" : trimmed
        return insertManualNode(
            named: name,
            kind: .entrance,
            turnHint: nil,
            arPosition: arPosition,
            arHeading: arHeading,
            imuState: imuState,
            poiAnchorId: name,
            capturedImage: capturedImage
        )
    }

    @discardableResult
    func captureNode(
        named requestedName: String,
        kind: SemanticRouteNodeKind,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState,
        capturedImage: CVPixelBuffer? = nil
    ) -> Bool {
        guard phase == .mapping else { return false }
        let trimmed = Self.sanitizedSpokenLabel(requestedName)
        guard !trimmed.isEmpty else {
            currentInstruction = "Name the route point first."
            return false
        }

        let map = activeMapDraft ?? activeMap
        guard var workingMap = map else { return false }
        let point = Self.routePoint(from: arPosition) ?? SemanticRoutePoint(
            x: imuState.position.x,
            y: imuState.position.y
        )
        let heading = arHeading ?? imuState.bearing
        let node = SemanticRouteNode(
            id: UUID().uuidString,
            name: trimmed,
            point: point,
            headingDegrees: heading,
            kind: kind,
            turnHint: nil,
            aliases: Self.aliases(for: trimmed),
            capturedAt: Date(),
            poiAnchorId: kind == .entrance || kind == .destination ? trimmed : nil
        )

        var nodeKeyframeSegmentID: String?
        var nodeKeyframeDistance: Double = 0
        if let previousID = lastCapturedNodeID,
           let previous = workingMap.nodes.first(where: { $0.id == previousID }) {
            var edge = Self.makeEdge(
                from: previous,
                to: node,
                leftContext: nil,
                rightContext: nil,
                spokenContext: "\(previous.name) to \(node.name)",
                confidence: arPosition == nil ? 0.72 : 0.9
            )
            Self.attachPendingEvidence(to: &edge, in: &workingMap, fromNodeID: previous.id)
            nodeKeyframeSegmentID = edge.id
            nodeKeyframeDistance = edge.distanceMeters
            workingMap.edges.append(edge)
        }

        workingMap.nodes.append(node)
        appendVisualKeyframe(
            to: &workingMap,
            pose: node.point,
            heading: heading,
            distanceFromSegmentStart: nodeKeyframeDistance,
            segmentID: nodeKeyframeSegmentID,
            capturedImage: capturedImage,
            capturedAt: Date()
        )
        if kind == .entrance {
            workingMap.startNodeId = node.id
        } else if kind == .destination {
            workingMap.destinationNodeIds = Array(Set((workingMap.destinationNodeIds ?? []) + [node.id]))
        }
        workingMap.updatedAt = Date()
        activeMapDraft = workingMap
        activeMap = workingMap
        lastCapturedNodeID = node.id
        lastAutoSampledPoint = node.point
        lastAutoSampledHeading = node.headingDegrees
        lastAutoSampledAt = Date()
        phase = .mapping
        currentInstruction = "Captured \(trimmed)."
        emitCue("Captured \(trimmed).", priority: .regular)
        refreshCaptureMetrics(for: workingMap)
        rebuildRAGContext()
        return true
    }

    @discardableResult
    func captureRoutePoint(
        named requestedName: String,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState,
        capturedImage: CVPixelBuffer? = nil
    ) -> Bool {
        let trimmed = Self.sanitizedSpokenLabel(requestedName)
        let pointNumber = ((activeMapDraft ?? activeMap)?.nodes.count ?? 0) + 1
        let name = trimmed.isEmpty ? "Checkpoint \(pointNumber)" : trimmed
        return insertManualNode(
            named: name,
            kind: .waypoint,
            turnHint: nil,
            arPosition: arPosition,
            arHeading: arHeading,
            imuState: imuState,
            poiAnchorId: nil,
            capturedImage: capturedImage
        )
    }

    @discardableResult
    func captureTurn(
        _ hint: SemanticTurnHint,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState,
        capturedImage: CVPixelBuffer? = nil
    ) -> Bool {
        let turnCount = (activeMapDraft ?? activeMap)?.nodes.filter { $0.kind == .intersection }.count ?? 0
        return insertManualNode(
            named: "\(hint.nodeName) \(turnCount + 1)",
            kind: .intersection,
            turnHint: hint,
            arPosition: arPosition,
            arHeading: arHeading,
            imuState: imuState,
            poiAnchorId: nil,
            capturedImage: capturedImage
        )
    }

    private func insertManualNode(
        named name: String,
        kind: SemanticRouteNodeKind,
        turnHint: SemanticTurnHint?,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState,
        poiAnchorId: String?,
        capturedImage: CVPixelBuffer?
    ) -> Bool {
        guard phase == .mapping else { return false }
        guard var workingMap = activeMapDraft ?? activeMap else { return false }
        if workingMap.nodes.isEmpty, kind != .entrance {
            currentInstruction = "Mark Point A before adding turns, landmarks, or the destination."
            emitCue(currentInstruction, priority: .priority)
            return false
        }

        let pose = Self.routePoint(from: arPosition) ?? SemanticRoutePoint(
            x: imuState.position.x,
            y: imuState.position.y
        )
        let heading = arHeading ?? imuState.bearing

        if let previousID = lastCapturedNodeID,
           let previousIndex = workingMap.nodes.firstIndex(where: { $0.id == previousID }),
           workingMap.nodes[previousIndex].point.distance(to: pose) <= manualNodeSnapDistance {
            // ⚠️ A structural mark landing on the node just captured must not
            // erase what that node IS.
            //
            // "Mark the shelf, then mark the turn you take at it" is the normal
            // capture gesture, and when the two marks are made without walking
            // (< `manualNodeSnapDistance`) this branch used to rename the
            // destination into "Left turn 1", flip its kind to .intersection and
            // drop its `poiAnchorId` — and `sanitizedMap` then deleted its
            // `reachingObjectName` too, because it only keeps that field on
            // destinations. In the 2026-08-11 pilot's "Test" map that removed
            // Biscuits from the graph outright: guidance still routed there
            // through the landmark captureLandmark had left behind and still
            // spoke "Arrived at Biscuits", but the node it arrived at carried no
            // reaching object, so the handoff never fired. Onions, whose turn
            // was marked 0.40 m away — just outside this 0.28 m radius — kept
            // its node and reached correctly. That is the whole difference
            // between the first destination and the second.
            //
            // Keep the named point's identity and take only what the new mark
            // actually adds: the turn hint and a fresh heading.
            let existingKind = workingMap.nodes[previousIndex].kind
            let isNamedPoint = existingKind == .destination || existingKind == .entrance
            let isStructuralMark = kind != .destination && kind != .entrance
            let keepsIdentity = isNamedPoint && isStructuralMark
            let existingName = workingMap.nodes[previousIndex].name
            if keepsIdentity {
                // A hintless mark (a plain route point) adds nothing here, and
                // must not wipe a turn already recorded at this shelf.
                workingMap.nodes[previousIndex].turnHint =
                    turnHint ?? workingMap.nodes[previousIndex].turnHint
                workingMap.nodes[previousIndex].headingDegrees = heading
            } else {
                workingMap.nodes[previousIndex].name = name
                workingMap.nodes[previousIndex].kind = kind
                workingMap.nodes[previousIndex].turnHint = turnHint
                workingMap.nodes[previousIndex].headingDegrees = heading
                workingMap.nodes[previousIndex].aliases = Self.aliases(for: name)
                workingMap.nodes[previousIndex].poiAnchorId = poiAnchorId
            }
            if kind == .entrance {
                workingMap.startNodeId = workingMap.nodes[previousIndex].id
            } else if kind == .destination {
                workingMap.destinationNodeIds = Array(Set((workingMap.destinationNodeIds ?? []) + [workingMap.nodes[previousIndex].id]))
            }
            workingMap.updatedAt = Date()
            appendVisualKeyframe(
                to: &workingMap,
                pose: workingMap.nodes[previousIndex].point,
                heading: heading,
                distanceFromSegmentStart: 0,
                segmentID: nil,
                capturedImage: capturedImage,
                capturedAt: Date()
            )
            activeMapDraft = workingMap
            activeMap = workingMap
            lastAutoSampledPoint = workingMap.nodes[previousIndex].point
            lastAutoSampledHeading = heading
            lastAutoSampledAt = Date()
            currentSegmentDraftMeters = 0
            refreshCaptureMetrics(for: workingMap)
            let turnWord = turnHint?.isCorner == true ? "corner" : "turn"
            if keepsIdentity {
                // Name the point the mark landed on, not the label that was
                // discarded: the mapper has to be able to hear that the turn was
                // recorded ON the shelf they just named rather than as a node of
                // its own, because that is what the saved graph now says.
                currentInstruction = kind == .intersection
                    ? "Marked the \(turnWord) at \(existingName). Continue walking after the \(turnWord)."
                    : "Updated \(existingName)."
            } else {
                currentInstruction = kind == .intersection
                    ? "Marked \(name). Continue walking after the \(turnWord)."
                    : "Updated route point \(name)."
            }
            emitCue(currentInstruction, priority: .regular)
            rebuildRAGContext()
            return true
        }

        // ── Re-marking an already-mapped place ──────────────────────────────
        // A return capture walks straight back over the forward trail. Without
        // reuse, every re-marked turn and POI minted a NEW node beside the old
        // one (0.4–0.9 m away), growing a parallel chain whose antiparallel
        // edges made start resolution a coin flip — and every duplicated
        // endpoint re-prompted a 360° sweep the map had already banked.
        if let reused = reusableExistingNode(named: name, kind: kind, near: pose, in: workingMap) {
            if let previousID = lastCapturedNodeID,
               let previous = workingMap.nodes.first(where: { $0.id == previousID }),
               previous.id != reused.id,
               !edgeExists(between: previous.id, and: reused.id, in: workingMap) {
                var edge = Self.makeEdge(
                    from: previous,
                    to: reused,
                    leftContext: nil,
                    rightContext: nil,
                    spokenContext: "toward \(reused.name)",
                    confidence: arPosition == nil ? 0.72 : 0.9
                )
                Self.attachPendingEvidence(to: &edge, in: &workingMap, fromNodeID: previous.id)
                workingMap.edges.append(edge)
            }
            if kind == .entrance {
                workingMap.startNodeId = reused.id
            } else if kind == .destination {
                workingMap.destinationNodeIds = Array(Set((workingMap.destinationNodeIds ?? []) + [reused.id]))
                if let index = workingMap.nodes.firstIndex(where: { $0.id == reused.id }),
                   workingMap.nodes[index].kind != .entrance {
                    workingMap.nodes[index].kind = .destination
                    workingMap.nodes[index].poiAnchorId = workingMap.nodes[index].poiAnchorId ?? name
                }
            }
            // The revisit is fresh visual evidence for the spot — usually from
            // the opposite walking direction, exactly the coverage return
            // journeys were missing.
            appendVisualKeyframe(
                to: &workingMap,
                pose: reused.point,
                heading: heading,
                distanceFromSegmentStart: 0,
                segmentID: nil,
                capturedImage: capturedImage,
                capturedAt: Date()
            )
            workingMap.updatedAt = Date()
            NavigationTrace.shared.log("map.nodeReused", [
                "requestedName": name,
                "requestedKind": kind.rawValue,
                "reusedNode": reused.name,
                "reusedKind": reused.kind.rawValue,
                "distM": reused.point.distance(to: pose),
                "hadPrevious": lastCapturedNodeID != nil
            ])
            activeMapDraft = workingMap
            activeMap = workingMap
            lastCapturedNodeID = reused.id
            lastAutoSampledPoint = reused.point
            lastAutoSampledHeading = heading
            lastAutoSampledAt = Date()
            currentSegmentDraftMeters = 0
            refreshCaptureMetrics(for: workingMap)
            currentInstruction = "\(reused.name) is already mapped here — reusing it. Continue walking."
            emitCue(currentInstruction, priority: .regular)
            rebuildRAGContext()
            return true
        }

        let node = SemanticRouteNode(
            id: UUID().uuidString,
            name: name,
            point: pose,
            headingDegrees: heading,
            kind: kind,
            turnHint: turnHint,
            aliases: Self.aliases(for: name),
            capturedAt: Date(),
            poiAnchorId: poiAnchorId
        )

        var nodeKeyframeSegmentID: String?
        var nodeKeyframeDistance: Double = 0
        if let previousID = lastCapturedNodeID,
           let previous = workingMap.nodes.first(where: { $0.id == previousID }) {
            var edge = Self.makeEdge(
                from: previous,
                to: node,
                leftContext: nil,
                rightContext: nil,
                spokenContext: kind == .destination ? "toward \(name)" : "toward \(name)",
                confidence: arPosition == nil ? 0.72 : 0.94
            )
            Self.attachPendingEvidence(to: &edge, in: &workingMap, fromNodeID: previous.id)
            nodeKeyframeSegmentID = edge.id
            nodeKeyframeDistance = edge.distanceMeters
            workingMap.edges.append(edge)
        } else if !workingMap.nodes.isEmpty {
            // Append mode: no capture predecessor yet — stitch the new branch
            // onto the nearest already-mapped node so the network stays one
            // routable graph instead of growing a disconnected island.
            guard let anchor = nearestNode(in: workingMap, to: pose),
                  anchor.point.distance(to: pose) <= appendConnectRadiusMeters else {
                currentInstruction = "Walk within \(Int(appendConnectRadiusMeters)) meters of the mapped route first so the new path connects, then mark the point again."
                emitCue(currentInstruction, priority: .priority)
                return false
            }
            var edge = Self.makeEdge(
                from: anchor,
                to: node,
                leftContext: nil,
                rightContext: nil,
                spokenContext: "toward \(name)",
                confidence: arPosition == nil ? 0.6 : 0.85
            )
            Self.attachPendingEvidence(to: &edge, in: &workingMap, fromNodeID: anchor.id)
            nodeKeyframeSegmentID = edge.id
            nodeKeyframeDistance = edge.distanceMeters
            workingMap.edges.append(edge)
        }

        workingMap.nodes.append(node)
        // The mapping-side counterpart of `nav.advance`: what the mapper stood
        // at, faced, and labelled, plus the edge geometry that label produced.
        // Diffing these against the guidance run is the whole point of the
        // trace, so it records the incoming edge as well as the node.
        let incomingEdge = workingMap.edges.last
        let precedingEdge = workingMap.edges.dropLast().last
        var mapNodeFields: [String: Any] = [
            "name": name,
            "kind": kind.rawValue,
            "turnHint": turnHint?.rawValue ?? "none",
            "x": pose.x,
            "y": pose.y,
            "headingDeg": heading,
            "hasARPose": arPosition != nil,
            "nodeCount": workingMap.nodes.count
        ]
        if let incomingEdge {
            mapNodeFields["incomingEdgeId"] = incomingEdge.id
            mapNodeFields["incomingBearing"] = incomingEdge.bearingDegrees
            mapNodeFields["incomingDistM"] = incomingEdge.distanceMeters
        }
        if let incomingEdge, let precedingEdge {
            mapNodeFields["precedingBearing"] = precedingEdge.bearingDegrees
            mapNodeFields["signedTurnDeg"] = SemanticRouteMath.signedAngleDifference(
                incomingEdge.bearingDegrees,
                precedingEdge.bearingDegrees
            )
        }
        NavigationTrace.shared.log("map.node", mapNodeFields)
        stitchJunctionIfNeeded(for: node, in: &workingMap)
        appendVisualKeyframe(
            to: &workingMap,
            pose: node.point,
            heading: heading,
            distanceFromSegmentStart: nodeKeyframeDistance,
            segmentID: nodeKeyframeSegmentID,
            capturedImage: capturedImage,
            capturedAt: Date()
        )
        if kind == .entrance {
            workingMap.startNodeId = node.id
        } else if kind == .destination {
            workingMap.destinationNodeIds = Array(Set((workingMap.destinationNodeIds ?? []) + [node.id]))
        }
        workingMap.updatedAt = Date()
        activeMapDraft = workingMap
        activeMap = workingMap
        lastCapturedNodeID = node.id
        lastAutoSampledPoint = node.point
        lastAutoSampledHeading = heading
        lastAutoSampledAt = Date()
        currentSegmentDraftMeters = 0
        refreshCaptureMetrics(for: workingMap)
        currentInstruction = kind == .intersection
            ? "Marked \(name). Continue walking after the \(turnHint?.isCorner == true ? "corner" : "turn")."
            : kind == .entrance
                ? "Point A captured. Walk toward the first turn or destination."
                : kind == .destination
                    ? "Destination \(name) captured. Keep walking to add more stops, or save the map."
                    : "Captured route point \(name)."
        emitCue(currentInstruction, priority: .regular)
        rebuildRAGContext()
        return true
    }

    /// The already-mapped node a new mark should reuse, if any. Named POIs
    /// (entrance/destination) match by spoken name with a generous radius —
    /// relocalization drift moves the pose, not the shelf. Structural marks
    /// (turns, waypoints) match by proximity alone, inside the same radius the
    /// junction stitcher already treats as "the same physical spot".
    private func reusableExistingNode(
        named name: String,
        kind: SemanticRouteNodeKind,
        near pose: SemanticRoutePoint,
        in map: SemanticRouteMap
    ) -> SemanticRouteNode? {
        let candidates = map.nodes.filter { $0.id != lastCapturedNodeID }
        if kind == .entrance || kind == .destination {
            return candidates
                .filter {
                    Self.matches(name, $0.name) &&
                    $0.point.distance(to: pose) <= namedNodeReuseRadiusMeters
                }
                .min(by: { $0.point.distance(to: pose) < $1.point.distance(to: pose) })
        }
        let structuralKinds: Set<SemanticRouteNodeKind> = [.intersection, .waypoint, .aisle]
        return candidates
            .filter {
                structuralKinds.contains($0.kind) &&
                $0.point.distance(to: pose) <= nodeReuseRadiusMeters
            }
            .min(by: { $0.point.distance(to: pose) < $1.point.distance(to: pose) })
    }

    private func edgeExists(between a: String, and b: String, in map: SemanticRouteMap) -> Bool {
        map.edges.contains {
            ($0.fromNodeID == a && $0.toNodeID == b) || ($0.fromNodeID == b && $0.toNodeID == a)
        }
    }

    /// When a newly captured point lands on an already-mapped spot (a trail
    /// crossing an earlier one), add a connector edge so routing can pass
    /// through the junction instead of treating the trails as separate
    /// one-way corridors.
    private func stitchJunctionIfNeeded(for node: SemanticRouteNode, in map: inout SemanticRouteMap) {
        let connectedIDs = Set(map.edges.flatMap { edge in
            edge.fromNodeID == node.id ? [edge.toNodeID] : (edge.toNodeID == node.id ? [edge.fromNodeID] : [])
        })
        let candidates = map.nodes.filter { $0.id != node.id && !connectedIDs.contains($0.id) }
        guard let nearest = candidates.min(by: {
            $0.point.distance(to: node.point) < $1.point.distance(to: node.point)
        }), nearest.point.distance(to: node.point) <= junctionSnapRadiusMeters else {
            return
        }
        let edge = Self.makeEdge(
            from: nearest,
            to: node,
            leftContext: nil,
            rightContext: nil,
            spokenContext: "through the junction",
            confidence: 0.8
        )
        map.edges.append(edge)
    }

    @discardableResult
    func captureLandmark(
        named requestedName: String,
        side: SemanticRouteSide,
        context: String,
        arPosition: simd_float3?,
        capturedImage: CVPixelBuffer? = nil,
        isDestination: Bool = false
    ) -> Bool {
        guard phase == .mapping else { return false }
        let trimmed = Self.sanitizedSpokenLabel(requestedName)
        guard !trimmed.isEmpty else {
            currentInstruction = "Name the target or shelf first."
            return false
        }
        guard var workingMap = activeMapDraft ?? activeMap, !workingMap.nodes.isEmpty else {
            currentInstruction = "Walk a few steps first so I have a route to attach this to."
            return false
        }

        let pose = Self.routePoint(from: arPosition) ?? lastObservation?.pose
        if isDestination,
           let ensured = ensureDestinationNode(
            named: trimmed,
            in: &workingMap,
            at: pose,
            arPositionWasAvailable: arPosition != nil
           ) {
            lastCapturedNodeID = ensured.id
            lastAutoSampledPoint = ensured.point
            lastAutoSampledHeading = ensured.headingDegrees ?? lastAutoSampledHeading
            lastAutoSampledAt = Date()
            currentSegmentDraftMeters = 0
        }

        let liveSegmentNode: SemanticRouteNode?
        if !isDestination,
           let lastCapturedNodeID,
           let currentFromNode = workingMap.nodes.first(where: { $0.id == lastCapturedNodeID }) {
            liveSegmentNode = currentFromNode
        } else {
            liveSegmentNode = nil
        }

        let nearest = liveSegmentNode ?? nearestNode(in: workingMap, to: pose) ?? workingMap.nodes.last
        guard let node = nearest else { return false }
        let edge = liveSegmentNode == nil ? nearestEdge(in: workingMap, to: pose) : nil
        let offsetMeters: Double?
        if let liveSegmentNode {
            offsetMeters = pose.map { liveSegmentNode.point.distance(to: $0) } ?? currentSegmentDraftMeters
        } else {
            offsetMeters = edge?.alongTrackMeters ?? currentSegmentDraftMeters
        }

        if let edgeID = edge?.edge.id,
           let edgeIndex = workingMap.edges.firstIndex(where: { $0.id == edgeID }) {
            Self.attachLandmarkContext(
                name: trimmed,
                side: side,
                to: &workingMap.edges[edgeIndex]
            )
        }
        let visualSample = makeVisualFingerprint(from: capturedImage)
        if let visualSample {
            var fingerprints = workingMap.visualFingerprints ?? [:]
            fingerprints[visualSample.id] = visualSample.fingerprint
            workingMap.visualFingerprints = fingerprints
        }
        let landmark = SemanticRouteLandmark(
            id: UUID().uuidString,
            name: trimmed,
            aliases: Self.aliases(for: trimmed),
            nodeID: node.id,
            edgeID: edge?.edge.id,
            offsetMeters: offsetMeters,
            side: side,
            context: Self.sanitizedSpokenLabel(context).nilIfBlank,
            priority: isDestination ? 20 : 10,
            kind: isDestination ? .destinationContext : .object,
            visualFingerprintIds: visualSample.map { [$0.id] }
        )
        workingMap.landmarks.removeAll { Self.matches($0.name, trimmed) }
        workingMap.landmarks.append(landmark)
        workingMap.updatedAt = Date()
        activeMapDraft = workingMap
        activeMap = workingMap
        refreshCaptureMetrics(for: workingMap)
        currentInstruction = isDestination
            ? "Marked \(trimmed) as a navigation target."
            : "Added \(trimmed) near \(node.name)."
        emitCue(currentInstruction, priority: .regular)
        rebuildRAGContext()
        return true
    }

    /// Links a graspable object to the most recent destination so arrival can
    /// hand off into spatial-target reaching. The caller must also pin the
    /// same name as a surface POI anchor in the active ARWorldMap — that
    /// anchor is what reaching relocalizes against.
    @discardableResult
    func attachReachingObject(
        named requestedName: String,
        capturedImage: CVPixelBuffer? = nil
    ) -> Bool {
        guard phase == .mapping else { return false }
        let trimmed = Self.sanitizedSpokenLabel(requestedName)
        guard !trimmed.isEmpty else {
            currentInstruction = "Name the reaching object first."
            return false
        }
        guard var workingMap = activeMapDraft ?? activeMap else { return false }
        guard let destinationIndex = latestDestinationNodeIndex(in: workingMap) else {
            currentInstruction = "Set the destination before pinning its reaching object."
            emitCue(currentInstruction, priority: .priority)
            return false
        }

        workingMap.nodes[destinationIndex].reachingObjectName = trimmed
        let destinationNode = workingMap.nodes[destinationIndex]

        // The object doubles as a spoken destination alias ("take me to the
        // kettle") and as visual arrival evidence at the destination.
        let visualSample = makeVisualFingerprint(from: capturedImage)
        if let visualSample {
            var fingerprints = workingMap.visualFingerprints ?? [:]
            fingerprints[visualSample.id] = visualSample.fingerprint
            workingMap.visualFingerprints = fingerprints
        }
        let landmark = SemanticRouteLandmark(
            id: UUID().uuidString,
            name: trimmed,
            aliases: Self.aliases(for: trimmed),
            nodeID: destinationNode.id,
            edgeID: nil,
            offsetMeters: nil,
            side: .ahead,
            context: "Reaching object at \(destinationNode.name)",
            priority: 20,
            kind: .destinationContext,
            visualFingerprintIds: visualSample.map { [$0.id] }
        )
        workingMap.landmarks.removeAll { Self.matches($0.name, trimmed) }
        workingMap.landmarks.append(landmark)
        workingMap.updatedAt = Date()
        activeMapDraft = workingMap
        activeMap = workingMap
        refreshCaptureMetrics(for: workingMap)
        currentInstruction = "Linked reaching object \(trimmed) to \(destinationNode.name)."
        emitCue(
            "Reaching object \(trimmed) linked to \(destinationNode.name). After arrival, reaching guidance will target it.",
            priority: .regular
        )
        rebuildRAGContext()
        return true
    }

    /// The reaching object linked to whichever destination `target` resolves
    /// to, or nil when none was marked during capture.
    func reachingObjectName(forTarget target: String) -> String? {
        guard let map = activeMap ?? activeMapDraft else { return nil }
        let trimmed = Self.sanitizedSpokenLabel(target)
        guard !trimmed.isEmpty,
              let node = resolveTarget(trimmed, in: map) else {
            return nil
        }
        return Self.sanitizedSpokenLabel(node.reachingObjectName ?? "").nilIfBlank
    }

    var latestCapturedDestinationName: String? {
        (activeMapDraft ?? activeMap)?.nodes.last(where: { $0.kind == .destination })?.name
    }

    var capturedReachingObjectSummary: (destination: String, object: String)? {
        guard let map = activeMapDraft ?? activeMap,
              let node = map.nodes.last(where: {
                  $0.kind == .destination && ($0.reachingObjectName?.isEmpty == false)
              }),
              let object = node.reachingObjectName else {
            return nil
        }
        return (node.name, object)
    }

    private func latestDestinationNodeIndex(in map: SemanticRouteMap) -> Int? {
        if let lastID = lastCapturedNodeID,
           let index = map.nodes.firstIndex(where: { $0.id == lastID }),
           map.nodes[index].kind == .destination {
            return index
        }
        return map.nodes.lastIndex(where: { $0.kind == .destination })
    }

    @discardableResult
    func saveCapturedMap() -> Bool {
        guard var map = activeMapDraft ?? activeMap else { return false }
        guard canSaveCapturedMap else {
            currentInstruction = "Capture Point A, at least one measured segment, and a destination before saving."
            emitCue(currentInstruction, priority: .priority)
            return false
        }
        map.updatedAt = Date()
        let cleaned = Self.sanitizedMap(map)
        if let quality = cleaned.captureQuality,
           !quality.isSufficientForGuidance {
            currentInstruction = quality.warnings.first ?? "Add more visual route evidence before saving."
            emitCue(currentInstruction, priority: .priority)
            activeMapDraft = cleaned
            activeMap = cleaned
            refreshCaptureMetrics(for: cleaned)
            rebuildRAGContext()
            return false
        }
        upsertMap(cleaned, persist: true)
        NavigationTrace.shared.log("map.saved", [
            "graph": traceMapGraph(cleaned),
            "captureQualityPass": cleaned.captureQuality?.isSufficientForGuidance ?? false,
            "warnings": cleaned.captureQuality?.warnings ?? []
        ])
        activeMap = cleaned
        activeMapDraft = nil
        phase = .ready
        pruneFrameThumbnails()
        refreshCaptureMetrics(for: cleaned)
        currentInstruction = "Saved local map: \(capturedPointCount) points, \(Self.formatMeters(capturedDistanceMeters))."
        emitCue("Local navigation map saved.", priority: .regular)
        rebuildRAGContext()
        return true
    }

    func discardCapture() {
        activeMapDraft = nil
        lastCapturedNodeID = nil
        activeMap = maps.first
        stopNavigation(resetInstruction: false)
        phase = activeMap == nil ? .idle : .ready
        currentInstruction = activeMap == nil ? "Capture or load a semantic map." : "Semantic map ready."
        rebuildRAGContext()
    }

    @discardableResult
    func startNavigation(
        to requestedTarget: String,
        arPosition: simd_float3?,
        imuState: IMUState,
        activeARWorldMapID: String? = nil,
        speakLandmarks: Bool = true,
        errorRecovery: Bool = true,
        clockFaceDirections: Bool = false,
        arHeading: Double? = nil
    ) -> Bool {
        guard let map = activeMap else {
            currentInstruction = "No semantic map loaded."
            return false
        }
        let trimmed = Self.sanitizedSpokenLabel(requestedTarget)
        guard !trimmed.isEmpty else {
            currentInstruction = "Choose a target."
            return false
        }
        if let requiredARMapID = map.arWorldMapId,
           requiredARMapID != activeARWorldMapID {
            currentInstruction = NavLoc.loadMatchingARMap()
            emitCue(currentInstruction, priority: .priority)
            return false
        }
        if map.coordinateSpace == "ar_world_xz", arPosition == nil {
            currentInstruction = NavLoc.startARMapFirst()
            emitCue(currentInstruction, priority: .priority)
            return false
        }
        guard let resolved = resolveTargetDetailed(trimmed, in: map) else {
            currentInstruction = NavLoc.notInMap(trimmed)
            emitCue(NavLoc.notInMap(trimmed), priority: .priority)
            return false
        }
        let targetNode = resolved.node
        // Always the MAPPED label, never the user's wording.
        //
        // This used to adopt the map's name only when the match was inexact,
        // but `resolveTargetDetailed` reports a normalized hit ("onion" for
        // "Onions", "400 lounge room" for "400 Lounge") as EXACT — so the app
        // spent the rest of the journey repeating the user's approximation
        // back at them. Speaking the mapped name is also how the user learns
        // what the place is actually called, which is what they have to say
        // next time.
        let spokenTarget = Self.sanitizedSpokenLabel(targetNode.name, fallback: trimmed)
        turnPhrasing = clockFaceDirections ? .clockFace : .leftRight
        guard let start = resolveNavigationStart(
            in: map,
            targetNodeID: targetNode.id,
            arPosition: arPosition,
            imuState: imuState,
            headingDegrees: arHeading ?? imuState.bearing
        ) else {
            currentInstruction = "Could not resolve a start point."
            return false
        }

        let path = start.nodePath
        guard path.count >= 2 else {
            // "Already there" is only believable when the live pose is truly
            // near the target: a bad relocalization snapping to the
            // destination node must not fire the reaching handoff from
            // across the store.
            let pose = map.coordinateSpace == "ar_world_xz"
                ? Self.routePoint(from: arPosition)
                : SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)
            let distanceToTarget = pose?.distance(to: targetNode.point)
            guard let distanceToTarget, distanceToTarget <= immediateArrivalMaxMeters else {
                currentInstruction = NavLoc.cannotConfirmAt(targetNode.name)
                emitCue(currentInstruction, priority: .priority)
                return false
            }
            phase = .arrived
            targetName = spokenTarget
            // No route was built, so nothing describes a facing here.
            arrivalFacing = nil
            currentInstruction = NavLoc.alreadyAt(targetNode.name)
            emitCue(currentInstruction, priority: .critical)
            rebuildRAGContext()
            return true
        }

        let shaped = shapeRouteSteps(buildSteps(for: path, in: map), allowLeadingStubDrop: true)
        let steps = shaped.steps
        guard !steps.isEmpty else {
            currentInstruction = NavLoc.noWalkableRoute(trimmed)
            return false
        }

        targetName = spokenTarget
        routeSteps = steps
        arrivalFacing = shaped.arrivalFacing
        currentStepIndex = 0
        leadingStubBearingDegrees = shaped.droppedLeadingStubBearingDegrees
        leadingStubMeters = shaped.droppedLeadingStubMeters
        segmentProgressMeters = shaped.droppedLeadingStub
            ? 0
            : min(max(start.initialProgressMeters, 0), steps.first?.edge.distanceMeters ?? 0)
        lastIMUStepCount = imuState.stepCount
        lastIMUPosition = imuState.position
        cumulativeTravelMeters = 0
        resetLegCueSchedule()
        lastAnnouncedLandmarkID = nil
        announcedLandmarkIDs.removeAll()
        shouldSpeakLandmarks = speakLandmarks
        shouldEnableErrorRecovery = errorRecovery
        recoveryStartedAt = nil
        lastRecoveredAt = nil
        lastRecoveryCueAt = nil
        beliefIssueStartedAt = nil
        beliefHealthySince = nil
        lastBeliefHoldTraceAt = nil
        lastBeliefHoldTraceKey = nil
        lastTrackingLimitedPrefixAt = nil
        lastVisualRouteMatchAt = 0
        lastVisualRouteMatch = nil
        // `didCorroborateHeadingVisually` is cleared by resetMapFrameYawBias().
        resetMapFrameYawBias()
        arrivalVisualHoldStartedAt = nil
        lastRouteAdvanceAt = nil
        lastPDRDeltaWasCapped = false
        lastHeadingAlignmentCueAt = nil
        lastHeadingAlignmentCueKey = nil
        lastHeadingAlignmentErrorDegrees = nil
        lastTurnCueAt = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        lastRouteRebuildAttemptAt = nil
        spokenLegContextEdgeID = nil
        headingTiltStartedAt = nil
        lastHeadingPosturePromptAt = nil
        stillnessStartedAt = nil
        lastStillnessRepromptAt = nil
        movementStoppedAt = nil
        pendingAlignmentResumeCue = false
        pendingPostTurnLegCueStepIndex = nil
        pendingPostTurnLegCueArmedAt = nil
        resetRouteCorrectionGuards()
        resetCourseCorrectionState()
        resetRouteBelief(status: .initializing)
        guidanceIntroProtectedUntil = Date().addingTimeInterval(guidanceIntroProtectionSeconds)
        recoveryReason = nil
        phase = .navigating
        updateInstruction(forceSpeech: false)
        // Where the user is standing, as it would be said out loud. The opening
        // cue no longer speaks it, but resolving it still matters: it is the
        // shelf the user is at rather than the aisle node the route starts
        // from, and a dropped leading stub must not move it. Kept as state so
        // the trace and the regression tests can both see what was resolved.
        let startName = Self.sanitizedSpokenLabel(
            shaped.startNodeName ?? steps.first?.from.name,
            fallback: "your current location"
        )
        spokenStartLabel = startName
        let startHeading = arHeading ?? imuState.bearing
        var firstInstruction = currentInstruction
        // On a one-leg route the opening would state the same number twice —
        // "Milk is 8 meters away. 8 meters, toward Milk." The distance is
        // already said; what the leg cue still has to contribute is the
        // direction, so keep that and drop the repeat. Matched against the
        // exact routine-leg phrasing so no other opening instruction (an
        // arrival that is already in reach, a landmark cue) is touched.
        let totalDistanceText = Self.formatDistance(totalRemainingMeters)
        if let step = activeStep {
            let openingContext = walkContext(for: step)
            if currentInstruction == NavLoc.legDistance(
                distance: totalDistanceText,
                context: openingContext
            ) {
                firstInstruction = "\(Self.sentenceCased(openingContext))."
            }
        }
        // Two reasons the opening announcement must NOT command a turn:
        //  • the heading is still sweeping — guidance starts the moment
        //    relocalization confirms, which is usually mid-way through the
        //    "turn a full circle" pan, so this instant's heading is not the
        //    user's facing;
        //  • the user already faces a dropped leading stub — that is the
        //    correct facing for the walk they start with, and the turn the cue
        //    would command only exists at the stub's far end.
        // In both cases the per-tick alignment logic re-judges against the
        // live, settled heading and still speaks a cue if one is truly owed.
        let startHeadingIsSettled = isLiveHeadingSettled()
        let startFacingDroppedStub = isFacingDroppedLeadingStub(liveHeading: startHeading)
        if startHeadingIsSettled,
           !startFacingDroppedStub,
           let headingCue = initialHeadingAlignmentInstruction(
            on: steps[0],
            liveHeading: startHeading
        ) {
            firstInstruction = "\(headingCue) Then \(firstInstruction.lowercased())"
            // This sentence IS an alignment cue. Without claiming the cue slot,
            // the very next update tick spoke the same turn again on top of the
            // opening announcement.
            lastHeadingAlignmentCueAt = Date()
            lastHeadingAlignmentCueKey = "align_\(Self.relativeTurnCommand(from: startHeading, to: steps[0].edge.bearingDegrees, style: turnPhrasing).key)_0"
            lastHeadingAlignmentErrorDegrees = abs(
                SemanticRouteMath.signedAngleDifference(startHeading, steps[0].edge.bearingDegrees)
            )
            lastTurnCueAt = Date()
            pendingAlignmentResumeCue = true
        }
        // The opening cue has to state the whole journey. Without it the first
        // thing a user hears on a 22 m route can be a single leg's countdown,
        // which reads as "this thing has no idea where it is sending me".
        currentInstruction = NavLoc.startingJourney(
            destination: spokenTarget,
            distance: totalDistanceText,
            turns: Self.turnCount(in: steps),
            firstInstruction: firstInstruction
        )
        NavigationTrace.shared.log("nav.start", [
            "requestedTarget": requestedTarget,
            "resolvedTarget": spokenTarget,
            "targetNode": targetNode.name,
            "exactMatch": resolved.isExact,
            "startName": startName,
            "startHeadingDeg": startHeading,
            "arHeadingDeg": arHeading ?? NSNull(),
            "imuBearingDeg": imuState.bearing,
            "arPoseX": Self.routePoint(from: arPosition)?.x ?? NSNull(),
            "arPoseY": Self.routePoint(from: arPosition)?.y ?? NSNull(),
            "nodePath": path,
            "droppedLeadingStub": shaped.droppedLeadingStub,
            "droppedStubBearingDeg": shaped.droppedLeadingStubBearingDegrees ?? NSNull(),
            "droppedStubMeters": shaped.droppedLeadingStubMeters,
            "startHeadingSettled": startHeadingIsSettled,
            "startFacingDroppedStub": startFacingDroppedStub,
            "initialProgressM": segmentProgressMeters,
            "arrivalFacing": shaped.arrivalFacing.map { "\($0.side.rawValue) \($0.meters)m" } ?? NSNull(),
            "legs": traceLegs(),
            "map": activeMap.map { traceMapGraph($0) } ?? NSNull(),
            "openingInstruction": currentInstruction
        ])
        // No exit instruction here. It used to be taught once per launch, on
        // this cue, because the Done button was the only way out and nothing
        // else named it. The exit is now the whole screen — on this one and on
        // the reaching screen that follows arrival — so the sentence buys
        // nothing and costs the participant a longer opening announcement in
        // front of the part that matters: where they are going and the first
        // turn. Destinations with no reaching object attached are told so
        // directly rather than by a generic hint bolted onto every journey.
        emitCue(currentInstruction, priority: .critical)
        noteLegContextSpoken(on: steps[0])
        rebuildRAGContext()
        return true
    }

    func stopNavigation(resetInstruction: Bool = true) {
        routeSteps.removeAll()
        arrivalFacing = nil
        currentStepIndex = 0
        segmentProgressMeters = 0
        segmentRemainingMeters = 0
        totalRemainingMeters = 0
        confidence = 0
        currentSegmentDraftMeters = 0
        recoveryReason = nil
        lastIMUStepCount = nil
        lastIMUPosition = nil
        cumulativeTravelMeters = 0
        lastPDRDeltaWasCapped = false
        resetLegCueSchedule()
        lastAnnouncedLandmarkID = nil
        announcedLandmarkIDs.removeAll()
        recoveryStartedAt = nil
        lastRecoveryCueAt = nil
        beliefIssueStartedAt = nil
        beliefHealthySince = nil
        lastBeliefHoldTraceAt = nil
        lastBeliefHoldTraceKey = nil
        lastTrackingLimitedPrefixAt = nil
        lastVisualRouteMatchAt = 0
        lastVisualRouteMatch = nil
        // `didCorroborateHeadingVisually` is cleared by resetMapFrameYawBias().
        resetMapFrameYawBias()
        arrivalVisualHoldStartedAt = nil
        lastRouteAdvanceAt = nil
        lastHeadingAlignmentCueAt = nil
        lastHeadingAlignmentCueKey = nil
        lastHeadingAlignmentErrorDegrees = nil
        lastTurnCueAt = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        lastRouteRebuildAttemptAt = nil
        stillnessStartedAt = nil
        lastStillnessRepromptAt = nil
        pendingAlignmentResumeCue = false
        pendingPostTurnLegCueStepIndex = nil
        pendingPostTurnLegCueArmedAt = nil
        leadingStubBearingDegrees = nil
        leadingStubMeters = 0
        resetRouteCorrectionGuards()
        resetCourseCorrectionState()
        resetRouteBelief(status: .initializing)
        guidanceIntroProtectedUntil = nil
        capturedPointCount = activeMap?.nodes.count ?? 0
        capturedTurnCount = activeMap?.nodes.filter { $0.kind == .intersection }.count ?? 0
        capturedLandmarkCount = activeMap?.landmarks.count ?? 0
        capturedDestinationCount = activeMap?.nodes.filter { $0.kind == .destination }.count ?? 0
        capturedDistanceMeters = activeMap?.edges.reduce(0) { $0 + $1.distanceMeters } ?? 0
        mappingQualityText = activeMap == nil ? "Not mapping" : "Loaded map"
        if phase == .navigating || phase == .recovering || phase == .arrived {
            phase = activeMap == nil ? .idle : .ready
        }
        if resetInstruction {
            currentInstruction = activeMap == nil ? "Capture or load a semantic map." : "Semantic map ready."
        }
        rebuildRAGContext()
    }

    func update(
        imuState: IMUState,
        arPosition: simd_float3?,
        arHeading rawARHeading: Double?,
        arLocalized: Bool,
        capturedImage: CVPixelBuffer? = nil,
        /// True when `arHeading` was derived from the camera's UP vector
        /// because the phone is pitched too far to use its forward vector.
        /// The value is still a number; it is not a facing. See
        /// `ARMappingManager.arHeadingUsedTiltFallback`.
        headingUsedTiltFallback: Bool = false
    ) {
        headingIsTiltDerived = headingUsedTiltFallback
        // Everything below this line works in the MAP's frame. The ARKit world
        // frame can be rotated relative to it — see `mapFrameYawBiasDegrees` —
        // and correcting once at the ingress is what keeps guidance, the
        // overlay and the spoken turns from each holding a different opinion
        // about which way the user faces. The bias is 0 until the keyframes
        // prove otherwise, so this is a no-op on a correctly aligned session.
        //
        // Guidance phases only. A capture or enrichment walk WRITES keyframe
        // headings into the map, and those must be recorded in the frame they
        // were observed in; correcting them against a bias measured from an
        // earlier journey would bake the correction into the map itself.
        let isGuiding = phase == .navigating || phase == .recovering
        let arHeading = isGuiding ? mapFrameHeading(rawARHeading) : rawARHeading
        // Learn the walker's stride from the walker, and notice when they stop.
        observeStepLength(imuState)
        recordMovementState(imuState)
        // Sampled in every phase: the sweep to expose is the relocalization
        // pan that happens BEFORE guidance starts.
        recordHeadingSample(arHeading)
        if phase == .mapping {
            updatePassiveObservation(imuState: imuState, arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            autoSampleWalkthrough(
                arPosition: arPosition,
                arHeading: arHeading,
                arLocalized: arLocalized,
                capturedImage: capturedImage
            )
            return
        }

        if phase == .enriching {
            updatePassiveObservation(imuState: imuState, arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            sampleEnrichmentWalk(
                arPosition: arPosition,
                arHeading: arHeading,
                arLocalized: arLocalized,
                capturedImage: capturedImage
            )
            return
        }

        guard phase == .navigating || phase == .recovering else {
            lastIMUStepCount = imuState.stepCount
            lastIMUPosition = imuState.position
            updatePassiveObservation(imuState: imuState, arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            return
        }
        guard let step = activeStep else { return }

        let visualMatch = currentVisualRouteMatch(
            capturedImage: capturedImage,
            timestamp: Date().timeIntervalSinceReferenceDate,
            liveHeading: arHeading ?? imuState.bearing
        )
        // The match above can have proved the frame is rotated, which makes the
        // route resolved from the old heading — and `step`, bound just above —
        // stale. Rebuild and yield the tick; the next one runs on the corrected
        // frame.
        if consumePendingFrameYawRealignment(
            arPosition: arPosition,
            imuState: imuState,
            heading: mapFrameHeading(rawARHeading)
        ) {
            return
        }
        let pdrDelta = pdrDistanceDelta(from: imuState)
        lastRouteUpdatePDRDelta = pdrDelta
        let expectedHeading = step.edge.bearingDegrees
        let liveHeading = arHeading ?? imuState.bearing
        let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, expectedHeading))
        let previousSegmentProgressMeters = segmentProgressMeters
        let progressScale = max(0, cos(min(headingError, 90) * .pi / 180.0))
        let gatedDelta = headingError > 65 ? pdrDelta * 0.2 : pdrDelta * progressScale
        segmentProgressMeters += max(0, gatedDelta)
        // Same quantity, kept as a journey-long odometer so route evidence can
        // be predicted forward to the present in `refreshRouteBeliefState`.
        cumulativeTravelMeters += max(0, gatedDelta)
        recordRouteEvidence(
            stepIndex: currentStepIndex,
            progressMeters: segmentProgressMeters,
            confidence: lastPDRDeltaWasCapped ? 0.36 : (imuState.isMoving ? 0.54 : 0.44),
            uncertaintyMeters: pdrUncertaintyMeters(imuState: imuState, pdrDelta: pdrDelta, headingError: headingError),
            source: "pdr_prediction",
            summary: lastPDRDeltaWasCapped ? "PDR capped" : "PDR"
        )

        traceLiveHeading = liveHeading
        traceHeadingError = headingError
        traceARLocalized = arLocalized

        var crossTrackError: Double?
        var routeProjection: RouteProjection?
        var observationConfidence = 0.58
        let arPoint = Self.routePoint(from: arPosition)
        tracePose = arPoint
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        destinationOvershootDistanceMeters = nil
        if let arPoint,
           activeMap?.coordinateSpace == "ar_world_xz" {
            let projection = Self.projectDetailed(arPoint, onto: step)
            routeProjection = projection
            crossTrackError = projection.crossTrackMeters
            if arLocalized {
                lastARNodeDistanceMeters = arPoint.distance(to: step.to.point)
                // `projectDetailed` clamps to the leg, so its along-track can
                // never say "past the end" — which is exactly the state that
                // needs saying on the final leg. Measure it unclamped.
                if currentStepIndex >= routeSteps.count - 1 {
                    let beyond = Self.metersBeyondNode(arPoint, on: step)
                    if beyond > 0 { destinationOvershootDistanceMeters = beyond }
                }
                if projection.crossTrackMeters <= offAxisProgressThresholdMeters(for: step) {
                    lastTrustedARRemainingMeters = max(0, step.edge.distanceMeters - projection.alongTrackMeters)
                }
                recordRouteEvidence(
                    stepIndex: currentStepIndex,
                    progressMeters: projection.alongTrackMeters,
                    confidence: max(0.28, 0.82 - min(projection.crossTrackMeters / 4.0, 0.42)),
                    uncertaintyMeters: 0.45 + min(projection.crossTrackMeters, 2.5) * 0.55,
                    source: "ar_projection",
                    crossTrackMeters: projection.crossTrackMeters,
                    summary: "AR"
                )
            }
            if arLocalized && projection.crossTrackMeters <= crossTrackRecoveryThreshold {
                if let correctedProgress = guardedSegmentProgressCorrection(
                    toward: projection.alongTrackMeters,
                    on: step,
                    source: "ar_projection",
                    maxImmediateForwardMeters: maxImmediateARProgressCorrectionMeters
                ) {
                    segmentProgressMeters = correctedProgress
                    observationConfidence = 0.86 - min(projection.crossTrackMeters / 4.0, 0.35)
                } else {
                    observationConfidence = 0.40
                }
            } else if arLocalized && shouldTrustOffAxisProgress(projection, on: step) {
                if let correctedProgress = guardedSegmentProgressCorrection(
                    toward: projection.alongTrackMeters,
                    on: step,
                    source: "ar_projection",
                    maxImmediateForwardMeters: maxImmediateARProgressCorrectionMeters
                ) {
                    segmentProgressMeters = correctedProgress
                    observationConfidence = 0.70 - min(projection.crossTrackMeters / 6.0, 0.28)
                } else {
                    observationConfidence = 0.36
                }
            } else if arLocalized {
                observationConfidence = 0.48
            }
        }

        if let visualMatch,
           visualMatch.confidence >= visualRouteMinimumConfidence {
            recordRouteEvidence(
                stepIndex: visualMatch.stepIndex,
                progressMeters: visualMatch.progressMeters,
                confidence: min(0.96, 0.60 + visualMatch.confidence * 0.32 - (visualMatch.isAliased ? 0.18 : 0)),
                uncertaintyMeters: visualMatch.isAliased
                    ? 1.85
                    : (visualMatch.confidence >= visualRouteSnapConfidence ? 0.85 : 1.35),
                source: "visual_route",
                visualConfidence: visualMatch.confidence,
                summary: visualMatch.landmarkName.map { visualMatch.isAliased ? "Aliased visual \($0)" : "Visual \($0)" }
                    ?? (visualMatch.isAliased ? "Aliased visual" : "Visual")
            )
        }

        // Which sensors actually reached the belief this tick.
        //
        // The CIMS trace showed every belief candidate carrying only
        // `pdr_prediction` for a whole journey — no AR projection, no visual
        // match — i.e. guidance was dead-reckoning while the UI said
        // "Localized". Nothing in the log said WHY, so this records the three
        // preconditions directly: whether the AR pose was trusted, whether a
        // camera frame arrived to fingerprint, and what the map offers to match
        // against. Throttled to 1 Hz; this is a per-tick path.
        let evidenceTraceAge = lastEvidenceTraceAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if evidenceTraceAge >= 1.0 {
            lastEvidenceTraceAt = Date()
            NavigationTrace.shared.tick("nav.evidence", [
                "arLocalized": arLocalized,
                "hasARPoint": arPoint != nil,
                "coordinateSpace": activeMap?.coordinateSpace ?? "none",
                "headingSource": arHeading == nil ? "imu_bearing" : "ar",
                "liveHeadingDeg": liveHeading,
                "imuBearingDeg": imuState.bearing,
                "hasCapturedImage": capturedImage != nil,
                "mapFingerprints": activeMap?.visualFingerprints?.count ?? 0,
                "mapKeyframes": activeMap?.keyframes?.count ?? 0,
                "visualMatchConf": visualMatch?.confidence ?? NSNull(),
                "visualMatchStep": visualMatch?.stepIndex ?? NSNull(),
                // Why a match failed: how close the best keyframe came, how
                // many survived the heading gate, and the bar it had to clear.
                "visualBestSimilarity": lastVisualBestSimilarity ?? NSNull(),
                "visualCandidates": lastVisualCandidateCount,
                // ⚠️ Must stay the exact inverse of `visualConfidence(from:)`.
                // This was hard-coded to the PRE-FIX mapping (0.62 + conf*0.26),
                // so it reported a bar of 0.724 when the real one is 0.44. The
                // trace analyzer then printed "never reached the bar — the
                // threshold, not the matcher, is what blocks visual evidence"
                // for the 2026-07-29 IGA session, whose best similarity of
                // 0.460 was in fact ABOVE the real bar. Two rounds of guidance
                // fixes were aimed at that phantom threshold. Derive it, never
                // restate it.
                "visualRequiredSimilarity": visualSimilarityFloor
                    + visualRouteMinimumConfidence * visualSimilaritySpan,
                "crossTrackM": crossTrackError ?? NSNull()
            ])
        }

        if let visualMatch,
           visualMatch.stepIndex == currentStepIndex,
           visualMatch.confidence >= visualRouteMinimumConfidence {
            observationConfidence = max(observationConfidence, 0.80 + min(visualMatch.confidence * 0.18, 0.18))
            if visualMatch.confidence >= visualRouteSnapConfidence {
                let correctedProgress = min(max(visualMatch.progressMeters, 0), step.edge.distanceMeters)
                let nearDecisionPoint = correctedProgress >= max(0, step.edge.distanceMeters - visualDecisionWindowMeters(for: step))
                if abs(correctedProgress - segmentProgressMeters) <= 3.0 ||
                    phase == .recovering ||
                    observationConfidence < 0.45 ||
                    nearDecisionPoint {
                    if let guardedProgress = guardedSegmentProgressCorrection(
                        toward: correctedProgress,
                        on: step,
                        source: "visual_route",
                        maxImmediateForwardMeters: maxImmediateVisualProgressCorrectionMeters,
                        visualConfidence: visualMatch.confidence
                    ) {
                        segmentProgressMeters = guardedProgress
                    } else {
                        observationConfidence = min(observationConfidence, 0.58)
                    }
                }
            }
        }

        traceCrossTrack = routeProjection?.crossTrackMeters
        traceAlongTrack = routeProjection?.alongTrackMeters

        segmentProgressMeters = min(segmentProgressMeters, step.edge.distanceMeters)
        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)

        // ── Overshoot, the dead-reckoned half ────────────────────────────────
        //
        // The clamp directly above is why nothing could ever say "you have gone
        // too far": progress saturates at the leg length and the excess is
        // discarded every tick. On 11 Aug 2026 that reached a pilot participant
        // as "about 1 meter, toward Onions" repeating while she walked past the
        // shelf and away — the belief was pinned at the end of the leg and the
        // AR pose, which is the other half of this signal, was not localized
        // enough to contradict it.
        //
        // So bank the excess instead: once the route says the final leg is
        // finished and the user is still taking steps, every one of those steps
        // is distance away from the destination. `isAtFinalDestination` runs
        // earlier in this tick and returns before here whenever arrival is
        // plausible, so this only ever accumulates once that check has already
        // declined — i.e. the user is walking, past the end, and not arriving.
        if currentStepIndex >= routeSteps.count - 1 {
            if segmentRemainingMeters <= 0.01, imuState.isMoving {
                destinationOvershootWalkMeters += max(0, gatedDelta)
            } else if segmentRemainingMeters > 0.5 {
                destinationOvershootWalkMeters = 0
            }
            if destinationOvershootWalkMeters > 0 {
                destinationOvershootDistanceMeters = max(
                    destinationOvershootDistanceMeters ?? 0,
                    destinationOvershootWalkMeters
                )
            }
        } else {
            destinationOvershootWalkMeters = 0
        }
        confidence = Self.confidence(
            observationConfidence: observationConfidence,
            headingError: headingError,
            crossTrackError: crossTrackError,
            isARLocalized: arLocalized,
            isMoving: imuState.isMoving
        )
        lastObservation = SemanticRouteObservation(
            pose: Self.routePoint(from: arPosition) ?? SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y),
            headingDegrees: liveHeading,
            source: arPosition == nil ? "pdr" : "ar_pdr",
            confidence: confidence,
            crossTrackError: crossTrackError,
            visualMatchConfidence: visualMatch?.confidence,
            routeStatus: routeLocalizationStatus,
            beliefConfidence: routeBeliefState.confidence,
            beliefMargin: routeBeliefState.margin,
            uncertaintyMeters: routeBeliefState.uncertaintyMeters,
            isInstructionSafe: routeBeliefState.isInstructionSafe,
            evidenceSummary: routeBeliefState.evidenceSummary
        )

        traceNavigationTick(
            visualMatch: visualMatch,
            pdrDelta: pdrDelta,
            gatedDelta: gatedDelta,
            isMoving: imuState.isMoving
        )

        // ── Stillness-fallback arrival ───────────────────────────────
        // A sharp turn into a short final segment can leave the AR pose just
        // outside even the widened arrival window while the user is physically
        // standing at the target. If they are near the destination and have
        // stopped moving, complete the route rather than leaving them waiting on
        // a cue that never comes.
        if currentStepIndex >= routeSteps.count - 1,
           arLocalized,
           let stillPoint = arPoint,
           stillPoint.distance(to: step.to.point) <= destinationStillnessRadiusMeters {
            if imuState.isMoving {
                destinationStillnessSince = nil
            } else {
                let now = Date()
                let since = destinationStillnessSince ?? now
                destinationStillnessSince = since
                if now.timeIntervalSince(since) >= destinationStillnessArrivalSeconds {
                    destinationStillnessSince = nil
                    advanceStepOrArrive()
                    rebuildRAGContext()
                    return
                }
            }
        } else {
            destinationStillnessSince = nil
        }

        // ── Destination proximity check ──────────────────────────────
        // Runs before the belief hold on purpose: standing at the target
        // with ambiguous evidence must still complete the route instead of
        // looping "pause and scan" forever at the finish line.
        if isAtFinalDestination(on: step, arPoint: arPoint, visualMatch: visualMatch, arLocalized: arLocalized) {
            // A localized AR pose on the destination node is direct evidence;
            // don't stall arrival waiting for a visual confirmation.
            let strongARArrival = arLocalized &&
                (arPoint.map { $0.distance(to: step.to.point) <= destinationArrivalRadiusMeters(for: step) } ?? false)
            if !strongARArrival, shouldHoldForVisualArrival(on: step, visualMatch: visualMatch) {
                rebuildRAGContext()
                return
            }
            advanceStepOrArrive()
            rebuildRAGContext()
            return
        }

        // ── Turn/node proximity check ────────────────────────────────
        // If AR pose is close to the next node, advance the step even
        // if PDR progress is lagging due to heading gating after a turn.
        //
        // Runs ahead of the belief hold and the alignment nudge for the same
        // reason destination proximity does: a localized pose standing on the
        // turn node is direct evidence, and holding it back means the user
        // walks through the turn hearing "pan the phone slowly" — or gets
        // nagged to face a leg they have already finished.
        if let arPoint,
           arLocalized,
           arPoint.distance(to: step.to.point) <= nodeArrivalRadiusMeters(for: step),
           shouldAdvanceFromARNodeProximity(on: step, visualMatch: visualMatch) {
            if currentStepIndex >= routeSteps.count - 1,
               shouldHoldForVisualArrival(on: step, visualMatch: visualMatch) {
                rebuildRAGContext()
                return
            }
            advanceStepOrArrive()
            rebuildRAGContext()
            return
        }

        if handleRouteBeliefHoldIfNeeded(
            arPosition: arPosition,
            arPoint: arPoint,
            liveHeading: liveHeading,
            visualMatch: visualMatch,
            imuState: imuState,
            arLocalized: arLocalized
        ) {
            rebuildRAGContext()
            return
        }

        if issueHeadingAlignmentCueIfNeeded(
            on: step,
            liveHeading: liveHeading,
            headingError: headingError,
            isMoving: imuState.isMoving
        ) {
            rebuildRAGContext()
            return
        }

        // The walk instruction a solo turn cue left owed. Runs before the
        // resume cue below so the two cannot both speak on the same tick.
        //
        // Deliberately NOT followed by an early return while it is still
        // pending. Blocking the rest of this function for up to five seconds
        // would also block the step advance, the visual decision point and the
        // whole recovery path — trading a cue-ordering nicety for a stalled
        // route. The alignment cue above already runs first, so a user who
        // turns the WRONG way is corrected while this waits.
        releasePostTurnLegCueIfDue(headingError: headingError)

        if pendingAlignmentResumeCue, headingError <= routeStartAlignmentThresholdDegrees, phase == .navigating {
            // The corrective turn just completed. Without an explicit "walk"
            // resumption the user stands still waiting for permission to
            // move — the pilot heard only turn cues after pausing.
            pendingAlignmentResumeCue = false
        pendingPostTurnLegCueStepIndex = nil
        pendingPostTurnLegCueArmedAt = nil
            updateInstruction(forceSpeech: false)
            currentInstruction = NavLoc.goodPrefix() + resumeWalkCue()
            emitCue(currentInstruction, priority: .priority)
            stillnessStartedAt = nil
            lastStillnessRepromptAt = nil
        }

        if advanceFromVisualDecisionPoint(visualMatch, on: step) {
            rebuildRAGContext()
            return
        }

        if shouldEnableErrorRecovery {
            let backwardDriftMeters = routeProjection.map {
                max(0, previousSegmentProgressMeters - $0.alongTrackMeters)
            } ?? 0
            updateRecoveryIfNeeded(
                headingError: headingError,
                crossTrackError: crossTrackError,
                isMoving: imuState.isMoving,
                arLocalized: arLocalized,
                pose: arPoint ?? SemanticRoutePoint(x: Double(imuState.position.x), y: Double(imuState.position.y)),
                liveHeading: liveHeading,
                visualMatch: visualMatch,
                routeProjection: routeProjection,
                backwardDriftMeters: backwardDriftMeters
            )
            if didRebuildRouteThisUpdate {
                // Rejoin guidance replaced routeSteps; the local `step`
                // binding is stale, so later checks must not run this tick.
                didRebuildRouteThisUpdate = false
                rebuildRAGContext()
                return
            }
        }

        if phase == .recovering {
            // During recovery, still check segment-based arrival but
            // skip normal instruction updates.
            if segmentRemainingMeters <= stepCompletionWindowMeters(for: step),
               !arContradictsStepCompletion(on: step, arPoint: arPoint, arLocalized: arLocalized) {
                if currentStepIndex >= routeSteps.count - 1,
                   shouldHoldForVisualArrival(on: step, visualMatch: visualMatch) {
                    rebuildRAGContext()
                    return
                }
                advanceStepOrArrive()
            }
            rebuildRAGContext()
            return
        }

        // Runs after recovery so a genuinely lost user hears recovery's cue
        // instead of a nudge, and before the walking instruction so the nudge
        // it speaks is what the banner shows.
        if issueCourseCorrectionCueIfNeeded(
            on: step,
            liveHeading: liveHeading,
            pose: arPoint,
            routeProjection: routeProjection,
            isMoving: imuState.isMoving,
            arLocalized: arLocalized
        ) {
            rebuildRAGContext()
            return
        }

        if segmentRemainingMeters <= stepCompletionWindowMeters(for: step) {
            if arContradictsStepCompletion(on: step, arPoint: arPoint, arLocalized: arLocalized) {
                // Dead reckoning says the node is reached but the AR pose is
                // clearly short of it — hold the advance and pull progress
                // back so the turn is not announced early.
                holdBackProgressTowardTrustedAR(on: step)
                updateInstruction(forceSpeech: false)
            } else if currentStepIndex >= routeSteps.count - 1,
                      shouldHoldForVisualArrival(on: step, visualMatch: visualMatch) {
                rebuildRAGContext()
                return
            } else {
                advanceStepOrArrive()
            }
        } else {
            updateInstruction(forceSpeech: false)
            announceVisualLandmarkIfNeeded(visualMatch)
            repromptWalkIfStalled(imuState: imuState)
        }
        rebuildRAGContext()
    }

    /// Meter-countdown speech only fires while progress changes, so a paused
    /// user hears nothing actionable. Re-speak the full walk instruction
    /// after a stretch of stillness, repeating on a slow cadence.
    private func repromptWalkIfStalled(imuState: IMUState) {
        if imuState.isMoving {
            stillnessStartedAt = nil
            lastStillnessRepromptAt = nil
            return
        }
        guard phase == .navigating else { return }
        let now = Date()
        guard guidanceIntroProtectedUntil.map({ now >= $0 }) ?? true else { return }
        guard let stillSince = stillnessStartedAt else {
            stillnessStartedAt = now
            return
        }
        guard now.timeIntervalSince(stillSince) >= stillnessRepromptAfterSeconds else { return }
        if let last = lastStillnessRepromptAt,
           now.timeIntervalSince(last) < stillnessRepromptRepeatSeconds {
            return
        }
        lastStillnessRepromptAt = now
        updateInstruction(forceSpeech: true)
    }

    /// True when a localized AR pose is still clearly short of the step's end
    /// node while dead-reckoned progress claims completion. PDR step-length
    /// overshoot otherwise announces turns before the user reaches them.
    private func arContradictsStepCompletion(
        on step: SemanticRouteStep,
        arPoint: SemanticRoutePoint?,
        arLocalized: Bool
    ) -> Bool {
        guard arLocalized, let arPoint,
              activeMap?.coordinateSpace == "ar_world_xz" else {
            return false
        }
        return arPoint.distance(to: step.to.point) >
            stepCompletionWindowMeters(for: step) + arStepCompletionSlackMeters
    }

    private func holdBackProgressTowardTrustedAR(on step: SemanticRouteStep) {
        guard let arRemaining = lastTrustedARRemainingMeters else { return }
        let arProgress = max(0, step.edge.distanceMeters - arRemaining)
        if arProgress < segmentProgressMeters {
            segmentProgressMeters = arProgress
            segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        }
    }

    func snapToNearestGraphPose(arPosition: simd_float3?, imuState: IMUState) {
        guard let map = activeMap else { return }
        let pose = Self.routePoint(from: arPosition) ?? SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)
        guard let edgeMatch = nearestEdge(in: map, to: pose) else {
            currentInstruction = "No route edge available to snap."
            return
        }
        let matchedBaseID = Self.baseEdgeID(edgeMatch.edge.id)
        if let index = routeSteps.firstIndex(where: { Self.baseEdgeID($0.edge.id) == matchedBaseID }) {
            let matchedStep = routeSteps[index]
            let snappedProgress = matchedStep.edge.id.hasSuffix(".reverse")
                ? max(0, matchedStep.edge.distanceMeters - edgeMatch.alongTrackMeters)
                : edgeMatch.alongTrackMeters
            currentStepIndex = index
            segmentProgressMeters = min(max(snappedProgress, 0), matchedStep.edge.distanceMeters)
            segmentRemainingMeters = max(0, matchedStep.edge.distanceMeters - segmentProgressMeters)
            phase = .navigating
            recoveryReason = nil
            resetRouteCorrectionGuards()
            resetRouteBelief(status: .locked)
            updateInstruction(forceSpeech: true)
        } else {
            currentInstruction = "Nearest graph edge is \(Self.sanitizedSpokenLabel(edgeMatch.edge.spokenContext, fallback: "a saved route segment"))."
        }
        rebuildRAGContext()
    }

    /// The walked path during mapping and enrichment, at the same cadence the
    /// guidance trail is sampled. Without it the log can say what the graph
    /// ended up as but not what the mapper actually walked to produce it.
    private func traceCaptureSample(pose: SemanticRoutePoint, heading: Double?, arLocalized: Bool) {
        let now = Date()
        guard traceLastCaptureSampleAt.map({ now.timeIntervalSince($0) >= 0.25 }) ?? true else { return }
        traceLastCaptureSampleAt = now
        NavigationTrace.shared.tick("map.pose", [
            "phase": phase.rawValue,
            "x": pose.x,
            "y": pose.y,
            "headingDeg": heading ?? NSNull(),
            "arLocalized": arLocalized,
            "segmentDraftM": currentSegmentDraftMeters
        ])
    }

    private func updatePassiveObservation(imuState: IMUState, arPosition: simd_float3?, arHeading: Double?, arLocalized: Bool) {
        let pose = Self.routePoint(from: arPosition) ?? SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)
        if phase == .mapping || phase == .enriching {
            traceCaptureSample(pose: pose, heading: arHeading ?? imuState.bearing, arLocalized: arLocalized)
        }
        lastObservation = SemanticRouteObservation(
            pose: pose,
            headingDegrees: arHeading ?? imuState.bearing,
            source: arPosition == nil ? "pdr" : "ar",
            confidence: arLocalized ? 0.76 : 0.45,
            crossTrackError: nil,
            visualMatchConfidence: nil,
            routeStatus: routeLocalizationStatus,
            beliefConfidence: routeBeliefState.confidence,
            beliefMargin: routeBeliefState.margin,
            uncertaintyMeters: routeBeliefState.uncertaintyMeters,
            isInstructionSafe: routeBeliefState.isInstructionSafe,
            evidenceSummary: routeBeliefState.evidenceSummary
        )
    }

    private func autoSampleWalkthrough(
        arPosition: simd_float3?,
        arHeading: Double?,
        arLocalized: Bool,
        capturedImage: CVPixelBuffer?
    ) {
        guard arLocalized, let pose = Self.routePoint(from: arPosition), var workingMap = activeMapDraft ?? activeMap else {
            mappingQualityText = "Waiting for AR tracking"
            currentSegmentDraftMeters = 0
            return
        }

        let now = Date()
        let heading = arHeading ?? lastAutoSampledHeading ?? 0

        // Coach the endpoint anchor whenever the user is standing at a start or
        // destination during capture — the last 0.6 m into a destination banks
        // too few features on its own to cold-relocalize from later.
        if updateEndpointAnchoring(at: pose, heading: arHeading, in: &workingMap) {
            activeMapDraft = workingMap
            activeMap = workingMap
        }

        if workingMap.nodes.isEmpty {
            mappingQualityText = "Ready for Point A"
            currentInstruction = "Mark Point A before walking."
            return
        }

        guard let previousID = lastCapturedNodeID,
              let previousNode = workingMap.nodes.first(where: { $0.id == previousID }) else {
            lastAutoSampledPoint = pose
            lastAutoSampledHeading = heading
            lastAutoSampledAt = now
            return
        }

        currentSegmentDraftMeters = previousNode.point.distance(to: pose)
        capturedDistanceMeters = workingMap.edges.reduce(0) { $0 + $1.distanceMeters } + currentSegmentDraftMeters

        let keyframeDistance = (lastAutoSampledPoint ?? previousNode.point).distance(to: pose)
        let headingDelta = abs(SemanticRouteMath.signedAngleDifference(heading, lastAutoSampledHeading ?? heading))
        let timeDelta = now.timeIntervalSince(lastAutoSampledAt ?? .distantPast)
        let shouldSampleByDistance = keyframeDistance >= 0.75
        let shouldSampleByTurn = keyframeDistance >= autoSampleTurnMinimumDistance && headingDelta >= autoSampleTurnDegrees
        guard timeDelta >= 0.25, shouldSampleByDistance || shouldSampleByTurn else {
            mappingQualityText = String(format: "Live segment %.1fm", currentSegmentDraftMeters)
            return
        }

        appendVisualKeyframe(
            to: &workingMap,
            pose: pose,
            heading: heading,
            distanceFromSegmentStart: currentSegmentDraftMeters,
            segmentID: nil,
            capturedImage: capturedImage,
            capturedAt: now
        )
        workingMap.updatedAt = now
        activeMapDraft = workingMap
        activeMap = workingMap
        lastAutoSampledPoint = pose
        lastAutoSampledHeading = heading
        lastAutoSampledAt = now
        refreshCaptureMetrics(for: workingMap)
        mappingQualityText = String(format: "Live segment %.1fm, %d keyframes", currentSegmentDraftMeters, workingMap.keyframes?.count ?? 0)
        rebuildRAGContext()
    }

    /// Enrichment sampling. Two triggers, both requiring a localized pose near
    /// the mapped corridor:
    ///  • walking — a keyframe every `enrichmentSampleDistanceMeters`
    ///  • dwelling — a keyframe every `enrichmentDwellHeadingDegrees` of
    ///    in-place rotation, which is what fills in the 360° coverage at the
    ///    destinations journeys actually start from.
    /// `segmentID` is deliberately nil: keyframes attach to edges by geometric
    /// projection at match time (keyframeProgressMeters), so a reverse-walk
    /// sample lands on the right segment without any edge bookkeeping.
    private func sampleEnrichmentWalk(
        arPosition: simd_float3?,
        arHeading: Double?,
        arLocalized: Bool,
        capturedImage: CVPixelBuffer?
    ) {
        guard arLocalized,
              let pose = Self.routePoint(from: arPosition),
              var workingMap = activeMapDraft ?? activeMap else {
            mappingQualityText = "Waiting for AR tracking"
            return
        }

        // Off-corridor frames describe somewhere the route does not go.
        guard let nearest = nearestEdge(in: workingMap, to: pose),
              nearest.crossTrackMeters <= enrichmentMaxCrossTrackMeters else {
            mappingQualityText = "Walk back onto the mapped route"
            return
        }

        let now = Date()
        let heading = arHeading ?? lastEnrichmentSampledHeading
        if updateEndpointAnchoring(at: pose, heading: arHeading, in: &workingMap) {
            activeMapDraft = workingMap
            activeMap = workingMap
        }

        let movedMeters = lastEnrichmentSampledPoint.map { pose.distance(to: $0) } ?? .greatestFiniteMagnitude
        let turnedDegrees: Double = {
            guard let heading, let previous = lastEnrichmentSampledHeading else { return 0 }
            return abs(SemanticRouteMath.signedAngleDifference(heading, previous))
        }()
        let sampledByWalking = movedMeters >= enrichmentSampleDistanceMeters
        let sampledByTurning = movedMeters <= enrichmentDwellMaxMoveMeters &&
            turnedDegrees >= enrichmentDwellHeadingDegrees
        let timeDelta = now.timeIntervalSince(lastEnrichmentSampledAt ?? .distantPast)
        guard timeDelta >= 0.25, sampledByWalking || sampledByTurning else {
            mappingQualityText = String(
                format: "Improving map, %d new keyframes",
                enrichmentKeyframesAdded
            )
            return
        }

        appendVisualKeyframe(
            to: &workingMap,
            pose: pose,
            heading: heading,
            distanceFromSegmentStart: nearest.alongTrackMeters,
            segmentID: nil,
            capturedImage: capturedImage,
            capturedAt: now
        )
        workingMap.updatedAt = now
        activeMapDraft = workingMap
        activeMap = workingMap
        lastEnrichmentSampledPoint = pose
        lastEnrichmentSampledHeading = heading
        lastEnrichmentSampledAt = now
        enrichmentKeyframesAdded += 1
        refreshCaptureMetrics(for: workingMap)
        mappingQualityText = String(
            format: "Improving map, %d new keyframes",
            enrichmentKeyframesAdded
        )
    }

    /// Drives the deliberate turn-in-place anchor at an endpoint (destination or
    /// route start). Standing there and sweeping the phone through a full circle
    /// banks features from every direction — the fix for the cold-start "pan
    /// around then time out" stall a later journey hits when it begins from this
    /// spot. Tracks which heading buckets have been covered, prompts once on
    /// arrival, and announces completion. Runs during both initial capture and
    /// the enrichment walk; only the endpoint kinds get anchored, never turns.
    /// Returns true when an endpoint newly completed its sweep this call, so
    /// the caller must write `map` (now carrying the persisted anchor) back to
    /// the active map even if no keyframe sampled this tick.
    @discardableResult
    private func updateEndpointAnchoring(at pose: SemanticRoutePoint, heading: Double?, in map: inout SemanticRouteMap) -> Bool {
        let anchorKinds: Set<SemanticRouteNodeKind> = [.destination, .entrance]
        guard let node = map.nodes
            .filter({ anchorKinds.contains($0.kind) })
            .min(by: { $0.point.distance(to: pose) < $1.point.distance(to: pose) }),
              node.point.distance(to: pose) <= anchoringPromptRadiusMeters,
              !anchoredNodeIDs.contains(node.id) else {
            return false
        }

        // Prompt the sweep the first time we stand at this endpoint.
        if !anchoringPromptedNodeIDs.contains(node.id) {
            anchoringPromptedNodeIDs.insert(node.id)
            currentInstruction = NavLoc.anchorEndpointPrompt(node.name)
            emitCue(currentInstruction, priority: .critical)
        }

        guard let heading else { return false }
        let normalizedHeading = (heading.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        let bucket = Int(normalizedHeading / anchoringBucketDegrees)
        var buckets = anchoringHeadingBuckets[node.id] ?? []
        let addedBucket = buckets.insert(bucket).inserted
        anchoringHeadingBuckets[node.id] = buckets

        if buckets.count >= anchoringRequiredBuckets {
            anchoredNodeIDs.insert(node.id)
            // Persist: the sweep's features live in the saved ARWorldMap, so
            // "anchored" outlives this session. Without this, every later
            // capture or enrichment visit re-prompted a spin at the same shelf.
            map.anchoredNodeIds = Array(Set((map.anchoredNodeIds ?? []) + [node.id]))
            map.updatedAt = Date()
            currentInstruction = NavLoc.anchorEndpointComplete(node.name)
            emitCue(currentInstruction, priority: .priority)
            return true
        } else if addedBucket {
            mappingQualityText = NavLoc.anchorEndpointProgress(
                node.name,
                covered: buckets.count,
                required: anchoringRequiredBuckets
            )
        }
        return false
    }

    /// Marks endpoints whose sweep completed in an earlier session as already
    /// anchored, from the persisted flag plus the map's own keyframe coverage
    /// (an enrichment dwell banks direction-spread keyframes at the spot even
    /// when the flag predates this field).
    private func seedAnchoredEndpoints(from map: SemanticRouteMap) {
        for persisted in map.anchoredNodeIds ?? [] {
            anchoredNodeIDs.insert(persisted)
            anchoringPromptedNodeIDs.insert(persisted)
        }
        let anchorKinds: Set<SemanticRouteNodeKind> = [.destination, .entrance]
        for node in map.nodes where anchorKinds.contains(node.kind) && !anchoredNodeIDs.contains(node.id) {
            var buckets: Set<Int> = []
            for keyframe in map.keyframes ?? [] where keyframe.pose.distance(to: node.point) <= anchoringPromptRadiusMeters {
                guard let heading = keyframe.headingDegrees else { continue }
                buckets.insert(Int(SemanticRouteMath.normalizedDegrees(heading) / anchoringBucketDegrees))
            }
            if buckets.count >= anchoringRequiredBuckets {
                anchoredNodeIDs.insert(node.id)
                anchoringPromptedNodeIDs.insert(node.id)
            }
        }
    }

    /// Clears in-progress sweep state but KEEPS nodes already anchored in this
    /// map. Re-prompting a full 360° at a node that was anchored during capture
    /// — again on the walk back, and again when the route is re-run in reverse —
    /// is pure redundancy: the features are already banked, and asking a user to
    /// spin repeatedly at the same shelf destroys trust in the instructions.
    private func resetEndpointAnchoring() {
        anchoringHeadingBuckets = anchoringHeadingBuckets.filter { anchoredNodeIDs.contains($0.key) }
        anchoringPromptedNodeIDs = anchoringPromptedNodeIDs.intersection(anchoredNodeIDs)
    }

    private func ensureDestinationNode(
        named name: String,
        in map: inout SemanticRouteMap,
        at pose: SemanticRoutePoint?,
        arPositionWasAvailable: Bool
    ) -> SemanticRouteNode? {
        guard let pose else {
            if let lastIndex = map.nodes.indices.last {
                map.nodes[lastIndex].name = name
                map.nodes[lastIndex].kind = .destination
                map.nodes[lastIndex].aliases = Self.aliases(for: name)
                map.nodes[lastIndex].poiAnchorId = name
                map.destinationNodeIds = Array(Set((map.destinationNodeIds ?? []) + [map.nodes[lastIndex].id]))
                return map.nodes[lastIndex]
            }
            return nil
        }

        if let lastID = lastCapturedNodeID,
           let lastIndex = map.nodes.firstIndex(where: { $0.id == lastID }),
           map.nodes[lastIndex].point.distance(to: pose) <= targetNodeSnapDistance {
            map.nodes[lastIndex].name = name
            map.nodes[lastIndex].kind = .destination
            map.nodes[lastIndex].aliases = Self.aliases(for: name)
            map.nodes[lastIndex].poiAnchorId = name
            map.destinationNodeIds = Array(Set((map.destinationNodeIds ?? []) + [map.nodes[lastIndex].id]))
            return map.nodes[lastIndex]
        }

        // A destination this map already knows by name is the same shelf, not
        // a second one: adopt it instead of minting a duplicate beside it.
        if let existingIndex = map.nodes.firstIndex(where: {
            $0.id != lastCapturedNodeID &&
            Self.matches(name, $0.name) &&
            $0.point.distance(to: pose) <= namedNodeReuseRadiusMeters
        }) {
            if map.nodes[existingIndex].kind != .entrance {
                map.nodes[existingIndex].kind = .destination
            }
            map.nodes[existingIndex].poiAnchorId = map.nodes[existingIndex].poiAnchorId ?? name
            map.destinationNodeIds = Array(Set((map.destinationNodeIds ?? []) + [map.nodes[existingIndex].id]))
            if let previousID = lastCapturedNodeID,
               let previous = map.nodes.first(where: { $0.id == previousID }),
               previous.id != map.nodes[existingIndex].id,
               !edgeExists(between: previous.id, and: map.nodes[existingIndex].id, in: map) {
                var edge = Self.makeEdge(
                    from: previous,
                    to: map.nodes[existingIndex],
                    leftContext: nil,
                    rightContext: nil,
                    spokenContext: "toward \(name)",
                    confidence: arPositionWasAvailable ? 0.9 : 0.7
                )
                Self.attachPendingEvidence(to: &edge, in: &map, fromNodeID: previous.id)
                map.edges.append(edge)
            }
            map.updatedAt = Date()
            return map.nodes[existingIndex]
        }

        let target = SemanticRouteNode(
            id: UUID().uuidString,
            name: name,
            point: pose,
            headingDegrees: lastObservation?.headingDegrees,
            kind: .destination,
            turnHint: nil,
            aliases: Self.aliases(for: name),
            capturedAt: Date(),
            poiAnchorId: name
        )

        if let previousID = lastCapturedNodeID,
           let previous = map.nodes.first(where: { $0.id == previousID }) {
            var edge = Self.makeEdge(
                from: previous,
                to: target,
                leftContext: nil,
                rightContext: nil,
                spokenContext: "toward \(name)",
                confidence: arPositionWasAvailable ? 0.9 : 0.7
            )
            Self.attachPendingEvidence(to: &edge, in: &map, fromNodeID: previous.id)
            map.edges.append(edge)
        }

        map.nodes.append(target)
        map.destinationNodeIds = Array(Set((map.destinationNodeIds ?? []) + [target.id]))
        map.updatedAt = Date()
        return target
    }

    private func refreshCaptureMetrics(for map: SemanticRouteMap) {
        capturedPointCount = map.nodes.count
        capturedTurnCount = map.nodes.filter { $0.kind == .intersection }.count
        capturedLandmarkCount = map.landmarks.count
        capturedDestinationCount = map.nodes.filter { $0.kind == .destination }.count
        capturedDistanceMeters = map.edges.reduce(0) { $0 + $1.distanceMeters }
        if phase == .mapping {
            capturedDistanceMeters += currentSegmentDraftMeters
        }
        if phase == .mapping {
            if let warning = map.captureQuality?.warnings.first {
                mappingQualityText = warning
            } else {
                mappingQualityText = capturedPointCount < 2
                    ? "Need Point A and destination"
                    : String(format: "%d route points, %.1fm", capturedPointCount, capturedDistanceMeters)
            }
        } else {
            mappingQualityText = String(format: "%d points, %.1fm", capturedPointCount, capturedDistanceMeters)
        }
    }

    private func makeVisualFingerprint(from capturedImage: CVPixelBuffer?) -> VisualFingerprintSample? {
        guard let capturedImage,
              let fingerprint = frameFingerprinter.makeFingerprint(from: capturedImage) else {
            return nil
        }

        let sample = VisualFingerprintSample(
            id: UUID().uuidString,
            fingerprint: fingerprint
        )
        SemanticRouteFrameStore.saveThumbnail(from: capturedImage, fingerprintID: sample.id)
        return sample
    }

    private func appendVisualKeyframe(
        to map: inout SemanticRouteMap,
        pose: SemanticRoutePoint,
        heading: Double?,
        distanceFromSegmentStart: Double,
        segmentID: String?,
        capturedImage: CVPixelBuffer?,
        capturedAt: Date
    ) {
        let visualSample = makeVisualFingerprint(from: capturedImage)
        if let visualSample {
            var fingerprints = map.visualFingerprints ?? [:]
            fingerprints[visualSample.id] = visualSample.fingerprint
            map.visualFingerprints = fingerprints
        }

        let keyframe = SemanticRouteKeyframe(
            id: UUID().uuidString,
            segmentID: segmentID,
            pose: pose,
            headingDegrees: heading,
            distanceFromSegmentStart: distanceFromSegmentStart,
            visualFingerprintId: visualSample?.id,
            trackingQuality: visualSample == nil ? "ar_world_tracking" : "ar_world_tracking_visual",
            capturedAt: capturedAt
        )
        var keyframes = map.keyframes ?? []
        keyframes.append(keyframe)
        map.keyframes = Self.prunedVisualKeyframes(keyframes)
    }

    /// Bounds keyframe growth by density, not recency. The old
    /// `suffix(120)` cap silently evicted the entire forward pass as soon as
    /// a reverse enrichment walk appended its keyframes, trading one viewing
    /// direction for the other. Instead keep at most one keyframe per
    /// ~0.6m grid cell per 60° heading bucket, newest wins — forward and
    /// reverse imagery of the same corridor occupy different buckets and
    /// coexist.
    static func prunedVisualKeyframes(_ keyframes: [SemanticRouteKeyframe]) -> [SemanticRouteKeyframe] {
        guard keyframes.count > 1 else { return keyframes }
        var kept: [SemanticRouteKeyframe] = []
        kept.reserveCapacity(keyframes.count)
        var seenBuckets: Set<String> = []
        for keyframe in keyframes.reversed() {
            let cellX = Int((keyframe.pose.x / keyframePruneCellMeters).rounded())
            let cellY = Int((keyframe.pose.y / keyframePruneCellMeters).rounded())
            let headingBucket = keyframe.headingDegrees.map { heading -> Int in
                let normalized = (heading.truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                return Int(normalized / keyframePruneHeadingBucketDegrees) % 6
            } ?? -1
            let bucket = "\(cellX)|\(cellY)|\(headingBucket)"
            if seenBuckets.insert(bucket).inserted {
                kept.append(keyframe)
            }
        }
        kept.reverse()
        if kept.count > maxStoredKeyframes {
            kept.removeFirst(kept.count - maxStoredKeyframes)
        }
        return kept
    }

    private func resetRouteBelief(status: RouteLocalizationStatus = .initializing) {
        routeEvidenceWindow.removeAll()
        var empty = RouteBeliefState.empty
        empty.status = status
        routeBeliefState = empty
        routeLocalizationStatus = status
    }

    private func recordRouteEvidence(
        stepIndex: Int,
        progressMeters: Double,
        confidence: Double,
        uncertaintyMeters: Double,
        source: String,
        visualConfidence: Double? = nil,
        crossTrackMeters: Double? = nil,
        summary: String
    ) {
        guard stepIndex >= 0, stepIndex < routeSteps.count else { return }
        let step = routeSteps[stepIndex]
        let evidence = RouteEvidence(
            stepIndex: stepIndex,
            progressMeters: min(max(progressMeters, 0), step.edge.distanceMeters),
            confidence: min(max(confidence, 0), 1),
            uncertaintyMeters: max(0.20, uncertaintyMeters),
            source: source,
            capturedAt: Date(),
            travelledMeters: cumulativeTravelMeters,
            visualConfidence: visualConfidence,
            crossTrackMeters: crossTrackMeters,
            summary: summary
        )
        routeEvidenceWindow.append(evidence)
        refreshRouteBeliefState(now: evidence.capturedAt)
    }

    private func refreshRouteBeliefState(now: Date) {
        routeEvidenceWindow.removeAll { now.timeIntervalSince($0.capturedAt) > routeBeliefWindowSeconds }
        guard !routeEvidenceWindow.isEmpty else {
            routeBeliefState = RouteBeliefState.empty
            routeLocalizationStatus = routeBeliefState.status
            return
        }

        struct Accumulator {
            var weightedProgress: Double = 0
            var confidenceSum: Double = 0
            var uncertaintySum: Double = 0
            var supportCount: Int = 0
            var sources: Set<String> = []
            var latestSummary: String = ""
        }

        var accumulators: [String: Accumulator] = [:]
        for evidence in routeEvidenceWindow {
            // ── Motion compensation ──────────────────────────────────────
            // Every sample in the window is a claim about where the user was
            // when it was taken, not where they are now. Bucketing the raw
            // value made a walking user's own trail compete with itself: at
            // 1.2 m/s the 2.4 s window spans three buckets, two of them far
            // enough apart to count as rival places, so the status sat on
            // "ambiguous" for the whole leg and the belief hold swallowed the
            // turn cues. Carry each sample forward by the distance walked
            // since it was taken, and charge it the dead-reckoning error of
            // that carry. A trajectory then collapses to one candidate, while
            // sources that genuinely disagree still stand apart.
            let carriedMeters = max(0, cumulativeTravelMeters - evidence.travelledMeters)
            let stepLength = routeSteps.indices.contains(evidence.stepIndex)
                ? routeSteps[evidence.stepIndex].edge.distanceMeters
                : evidence.progressMeters
            let predictedProgress = min(max(evidence.progressMeters + carriedMeters, 0), stepLength)
            let predictedUncertainty = evidence.uncertaintyMeters +
                carriedMeters * routeBeliefPropagationUncertaintyPerMeter

            let bucket = Int((predictedProgress / routeBeliefBucketMeters).rounded())
            let key = "\(evidence.stepIndex):\(bucket)"
            var accumulator = accumulators[key] ?? Accumulator()
            accumulator.weightedProgress += predictedProgress * max(evidence.confidence, 0.05)
            accumulator.confidenceSum += evidence.confidence
            accumulator.uncertaintySum += predictedUncertainty
            accumulator.supportCount += 1
            accumulator.sources.insert(evidence.source)
            accumulator.latestSummary = evidence.summary
            accumulators[key] = accumulator
        }

        let candidates = accumulators.compactMap { key, accumulator -> RouteBeliefCandidate? in
            guard accumulator.supportCount > 0,
                  let stepID = key.split(separator: ":").first,
                  let stepIndex = Int(String(stepID)) else {
                return nil
            }
            let averageConfidence = accumulator.confidenceSum / Double(accumulator.supportCount)
            let supportRatio = Double(accumulator.supportCount) / Double(max(routeEvidenceWindow.count, 1))
            let diversityBonus = min(0.18, Double(max(0, accumulator.sources.count - 1)) * 0.08)
            let supportBonus = min(0.16, supportRatio * 0.18)
            let uncertainty = accumulator.uncertaintySum / Double(accumulator.supportCount) + routeBeliefBucketMeters / 2.0
            let uncertaintyPenalty = min(0.30, uncertainty / 8.0)
            let confidence = min(0.98, max(0.05, averageConfidence + diversityBonus + supportBonus - uncertaintyPenalty))
            let progress = accumulator.weightedProgress / max(accumulator.confidenceSum, 0.05)
            return RouteBeliefCandidate(
                stepIndex: stepIndex,
                progressMeters: progress,
                confidence: confidence,
                uncertaintyMeters: uncertainty,
                supportCount: accumulator.supportCount,
                sources: accumulator.sources,
                summary: accumulator.latestSummary
            )
        }
        .sorted { $0.confidence > $1.confidence }

        guard let best = candidates.first else {
            routeBeliefState = RouteBeliefState.empty
            routeLocalizationStatus = routeBeliefState.status
            return
        }

        let competing = candidates.dropFirst().first { !isSameBeliefPlace($0, best) }
        let margin = competing.map { best.confidence - $0.confidence } ?? best.confidence
        let status: RouteLocalizationStatus
        if best.confidence < 0.34 {
            status = .lost
        } else if competing != nil && margin < routeBeliefMinimumInstructionMargin {
            status = .ambiguous
        } else if best.uncertaintyMeters > 2.6 {
            status = .recovering
        } else if best.confidence >= routeBeliefMinimumLockedConfidence {
            status = .locked
        } else {
            status = .recovering
        }

        let instructionSafe = status == .locked &&
            margin >= routeBeliefMinimumInstructionMargin &&
            best.uncertaintyMeters <= routeBeliefMaximumInstructionUncertainty
        let competingText = competing.map {
            String(format: " vs step %d %.1fm", $0.stepIndex + 1, $0.progressMeters)
        } ?? ""
        let summary = String(
            format: "%@ step %d %.1fm %.0f%%%@",
            best.summary,
            best.stepIndex + 1,
            best.progressMeters,
            best.confidence * 100,
            competingText
        )

        routeBeliefState = RouteBeliefState(
            status: status,
            candidates: candidates,
            confidence: best.confidence,
            margin: margin,
            uncertaintyMeters: best.uncertaintyMeters,
            isInstructionSafe: instructionSafe,
            evidenceSummary: summary,
            updatedAt: now
        )
        routeLocalizationStatus = status
    }

    private func isSameBeliefPlace(_ lhs: RouteBeliefCandidate, _ rhs: RouteBeliefCandidate) -> Bool {
        lhs.stepIndex == rhs.stepIndex &&
            abs(lhs.progressMeters - rhs.progressMeters) <= routeBeliefAmbiguityMergeMeters
    }

    private func pdrUncertaintyMeters(imuState: IMUState, pdrDelta: Double, headingError: Double) -> Double {
        var uncertainty = max(imuState.pdrUncertaintyMeters, 0.45) + pdrDelta * 0.35
        if lastPDRDeltaWasCapped { uncertainty += 1.10 }
        if !imuState.isMoving { uncertainty += 0.20 }
        if headingError > 45 { uncertainty += min(0.85, (headingError - 45) / 90.0) }
        if !imuState.isStepCalibrationValid { uncertainty += 0.35 }
        return uncertainty
    }

    private func routeBeliefSupportsLargeCorrection(
        stepIndex: Int,
        observedProgress: Double,
        source: String,
        visualConfidence: Double?
    ) -> Bool {
        let now = Date()
        let nearbyEvidence = routeEvidenceWindow.filter { evidence in
            evidence.stepIndex == stepIndex &&
                abs(evidence.progressMeters - observedProgress) <= routeBeliefLargeCorrectionSupportMeters &&
                now.timeIntervalSince(evidence.capturedAt) <= routeBeliefWindowSeconds
        }
        guard nearbyEvidence.count >= routeBeliefLargeCorrectionMinimumSamples else { return false }

        let sources = Set(nearbyEvidence.map(\.source))
        let timestamps = nearbyEvidence.map(\.capturedAt)
        let duration = (timestamps.max() ?? now).timeIntervalSince(timestamps.min() ?? now)
        let hasCrossSourceSupport = sources.count >= 2
        let hasVeryStrongVisual = source == "visual_route" &&
            (visualConfidence ?? 0) >= visualDecisionImmediateConfidence &&
            nearbyEvidence.filter { $0.source == source }.count >= routeBeliefLargeCorrectionMinimumSamples + 1

        return duration >= routeBeliefLargeCorrectionMinimumDuration &&
            (hasCrossSourceSupport || hasVeryStrongVisual)
    }

    private func markRouteEvidenceConflict(source: String, observedProgress: Double) {
        routeLocalizationStatus = .ambiguous
        routeBeliefState.status = .ambiguous
        routeBeliefState.isInstructionSafe = false
        routeBeliefState.evidenceSummary = String(
            format: "%@ proposed %.1fm, but route belief disagrees.",
            source,
            observedProgress
        )
        // The belief bookkeeping above always runs; the user-facing recovery
        // banner only exists when the user left error recovery on.
        if shouldEnableErrorRecovery {
            recoveryReason = "Route evidence disagrees."
        }
    }

    private func handleRouteBeliefHoldIfNeeded(
        arPosition: simd_float3?,
        arPoint: SemanticRoutePoint?,
        liveHeading: Double,
        visualMatch: VisualRouteMatch?,
        imuState: IMUState,
        arLocalized: Bool
    ) -> Bool {
        guard shouldEnableErrorRecovery,
              phase == .navigating || phase == .recovering else {
            return false
        }

        let now = Date()
        guard routeLocalizationStatus == .ambiguous || routeLocalizationStatus == .lost else {
            beliefIssueStartedAt = nil
            if phase == .recovering, routeBeliefState.isInstructionSafe {
                // A single healthy tick is a flicker, not a recovery — exiting
                // on it produced "Back on route" / "Route lost" round trips
                // seconds apart, spoken in full each time. Hold the phase until
                // the belief stays healthy, silently.
                if beliefHealthySince == nil {
                    beliefHealthySince = now
                }
                if now.timeIntervalSince(beliefHealthySince ?? now) >= beliefExitHysteresisSeconds {
                    beliefHealthySince = nil
                    exitRecovery(announce: true)
                    return false
                }
                return true
            }
            beliefHealthySince = nil
            return false
        }

        beliefHealthySince = nil
        if beliefIssueStartedAt == nil {
            beliefIssueStartedAt = now
        }
        // Ambiguity flickers for a moment whenever PDR and AR briefly disagree.
        // Keep guiding through those; hold only when the conflict persists.
        if phase != .recovering,
           now.timeIntervalSince(beliefIssueStartedAt ?? now) < beliefHoldGraceSeconds {
            return false
        }

        let holdDuration = now.timeIntervalSince(beliefIssueStartedAt ?? now)

        // Escalation 1: after a short hold, stop asking the user to keep
        // panning and actively snap back onto the best-matching route
        // position. Panning alone rarely resolves a persistent conflict.
        if holdDuration >= beliefRelocalizeAfterSeconds,
           let snap = bestRecoverySnap(
            pose: arPoint,
            liveHeading: liveHeading,
            visualMatch: visualMatch,
            searchAllSteps: routeLocalizationStatus == .lost
           ),
           snap.crossTrackMeters <= recoverySnapThreshold ||
            ((snap.visualConfidence ?? 0) >= visualRouteSnapConfidence && snap.crossTrackMeters <= 3.0) {
            applyRecoverySnap(snap, liveHeading: liveHeading, announce: true)
            return true
        }

        // Escalation 2: rebuild the route from the live pose. This is the
        // hard fallback that ends the "pan slowly" loop for good.
        if holdDuration >= beliefRebuildAfterSeconds, arLocalized {
            let attemptAge = lastRouteRebuildAttemptAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
            if attemptAge >= routeRebuildRetrySeconds {
                lastRouteRebuildAttemptAt = now
                if rebuildRouteFromCurrentPose(
                    arPosition: arPosition,
                    imuState: imuState,
                    heading: liveHeading
                ) {
                    return true
                }
            }
        }

        let key = "route_belief_\(routeLocalizationStatus.rawValue)"
        let cueChanged = key != lastRecoveryCueKey
        let cueAge = lastRecoveryCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        phase = .recovering
        recoveryReason = routeBeliefState.evidenceSummary
        // On hold start, status change, or every 2 s — NOT per tick. Per-tick
        // logging wrote ~50 identical lines a second, which both burned the
        // trace budget and made the exported analysis unreadable.
        let traceAge = lastBeliefHoldTraceAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if key != lastBeliefHoldTraceKey || traceAge >= 2.0 {
            lastBeliefHoldTraceAt = now
            lastBeliefHoldTraceKey = key
            NavigationTrace.shared.log("nav.beliefHold", traceState(extra: [
                "holdSeconds": holdDuration,
                "candidates": routeBeliefState.candidates.prefix(4).map { candidate in
                    [
                        "step": candidate.stepIndex,
                        "progressM": candidate.progressMeters,
                        "conf": candidate.confidence,
                        "uncM": candidate.uncertaintyMeters,
                        "support": candidate.supportCount,
                        "sources": candidate.sources.sorted()
                    ] as [String: Any]
                }
            ]))
        }
        // Both of these were raw English, so a French session heard them in the
        // wrong language, and both told the user to stop and work the camera.
        // Pilot feedback, 11 Aug 2026: the user does not want a job here, and
        // usually there is nothing to do — the hold clears on its own. The
        // system now says what IT is doing, and only once it has been at it
        // long enough to be worth mentioning.
        currentInstruction = routeLocalizationStatus == .lost
            ? NavLoc.realigningApology()
            : NavLoc.realigningStatus()

        // A re-entry moments after a snap or exit is the same episode, not
        // news; speech stays quiet inside the re-entry window while the banner
        // still shows the state.
        //
        // The ordinary hold is now silent entirely. It resolves in a second or
        // two on its own, and narrating it ("Hold on. Pan the phone slowly.")
        // handed the user a job they did not need to do and made a routine
        // internal wobble sound like the route had been lost. The banner still
        // shows it, the recovery still runs, and the cue the hold was masking
        // — the turn at the end of the leg — arrives on time. A genuinely lost
        // route keeps its voice: that one the user does have to act on.
        //
        // Even a lost route now waits: recovery usually lands inside
        // `beliefHoldSpokenAfterSeconds` (the snap and the rebuild escalations
        // above both fire before it), and announcing a wobble the system is
        // about to fix itself is what made a working route sound broken.
        let holdIsSpoken = routeLocalizationStatus == .lost
            && holdDuration >= beliefHoldSpokenAfterSeconds
        if holdIsSpoken,
           (cueChanged && cueAge >= beliefHoldReentryQuietSeconds) || cueAge >= beliefHoldRepeatSeconds {
            emitCue(currentInstruction, priority: .critical)
            lastRecoveryCueAt = now
            lastRecoveryCueKey = key
        }
        return true
    }

    /// ARKit finished aligning to the saved map after guidance had already
    /// started, so the route was resolved from a pose the user was never
    /// standing at. Re-resolve it from the corrected pose.
    ///
    /// This is deliberately NOT `startNavigation`. Restarting the journey
    /// re-announces it from the top ("Starting at X, N meters away, turn …"),
    /// and because the corrected pose can resolve a different start edge, the
    /// turn word changes too. Doing that two or three times while a blind user
    /// is trying to take their first step is how a working route turned into
    /// contradictory turn commands. A realignment is a correction to a journey
    /// already under way: same target, one "route realigned" cue, no restart.
    @discardableResult
    func realignRouteToCorrectedPose(
        arPosition: simd_float3?,
        imuState: IMUState,
        heading: Double?
    ) -> Bool {
        guard phase == .navigating || phase == .recovering else { return false }
        let now = Date()
        if let last = lastRouteRebuildAttemptAt,
           now.timeIntervalSince(last) < routeRebuildRetrySeconds {
            return false
        }
        // A step advance outranks a frame realignment. See
        // `routeRebuildAfterAdvanceSeconds`: re-planning on the heels of one
        // argues with the best evidence the navigator has and speaks the turn
        // a second time, seconds after the user has taken it.
        if let lastRouteAdvanceAt,
           now.timeIntervalSince(lastRouteAdvanceAt) < routeRebuildAfterAdvanceSeconds {
            return false
        }
        lastRouteRebuildAttemptAt = now
        return rebuildRouteFromCurrentPose(
            arPosition: arPosition,
            imuState: imuState,
            heading: heading
        )
    }

    /// Re-resolves the path to the current target from the live pose and
    /// restarts guidance on it. Last-resort recovery when route belief cannot
    /// converge; announces the realignment so the user knows why the
    /// instructions changed.
    private func rebuildRouteFromCurrentPose(
        arPosition: simd_float3?,
        imuState: IMUState,
        heading: Double?
    ) -> Bool {
        guard let map = activeMap,
              !targetName.isEmpty,
              let targetNode = resolveTarget(targetName, in: map),
              let start = resolveNavigationStart(
                in: map,
                targetNodeID: targetNode.id,
                arPosition: arPosition,
                imuState: imuState,
                headingDegrees: heading
              ),
              start.nodePath.count >= 2 else {
            return false
        }
        let shaped = shapeRouteSteps(buildSteps(for: start.nodePath, in: map), allowLeadingStubDrop: true)
        let steps = shaped.steps
        guard let firstStep = steps.first else { return false }

        let proposedProgress = shaped.droppedLeadingStub
            ? 0
            : min(max(start.initialProgressMeters, 0), firstStep.edge.distanceMeters)
        if let regression = routeRebuildRegression(
            proposedSteps: steps,
            proposedProgressMeters: proposedProgress,
            arPosition: arPosition,
            imuState: imuState,
            in: map
        ) {
            // Walking the user backwards is worse than admitting confusion. One
            // captured session had them 6.4 m from the destination on the final
            // leg when a rebuild resolved onto a parallel edge 0.34 m away and
            // handed back a 12.5 m route through a POI already passed; the next
            // 16 s were contradictory turn cues. Refusing leaves the belief hold
            // in charge, which stops the user instead of misrouting them, and
            // the retry timer takes another look once evidence moves.
            NavigationTrace.shared.log("nav.rebuildRejected", traceState(extra: [
                "reason": "backward_regression",
                "currentTotalRemainingM": regression.currentTotalMeters,
                "proposedTotalRemainingM": regression.proposedTotalMeters,
                "crossTrackToCurrentRouteM": regression.crossTrackMeters,
                "nodePath": start.nodePath
            ]))
            return false
        }

        // ── Realignment that changes nothing ────────────────────────────
        // The frame moved; the plan did not. Same leg, same remaining legs,
        // same place on it — so there is no instruction to give, and giving one
        // anyway is what produced eighteen spoken rebuilds in a ninety-second
        // walk on 25 Aug 2026, most of them the identical sentence. Take the
        // pose correction, say nothing, and leave the leg's cue schedule alone
        // so the countdown keeps descending instead of restarting.
        if let currentStep = activeStep,
           firstStep.edge.id == currentStep.edge.id,
           steps.map(\.edge.id) == remainingEdgeIDs(),
           abs(proposedProgress - segmentProgressMeters) <= routeRealignSilentProgressMeters {
            segmentProgressMeters = proposedProgress
            segmentRemainingMeters = max(0, firstStep.edge.distanceMeters - proposedProgress)
            NavigationTrace.shared.log("nav.rebuildSilent", traceState(extra: [
                "reason": "plan_unchanged",
                "proposedProgressM": proposedProgress,
                "nodePath": start.nodePath
            ]))
            rebuildRAGContext()
            return true
        }

        routeSteps = steps
        arrivalFacing = shaped.arrivalFacing
        currentStepIndex = 0
        leadingStubBearingDegrees = shaped.droppedLeadingStubBearingDegrees
        leadingStubMeters = shaped.droppedLeadingStubMeters
        segmentProgressMeters = proposedProgress
        segmentRemainingMeters = max(0, firstStep.edge.distanceMeters - segmentProgressMeters)
        resetLegCueSchedule()
        lastAnnouncedLandmarkID = nil
        recoveryStartedAt = nil
        recoveryReason = nil
        lastRecoveryCueKey = nil
        beliefIssueStartedAt = nil
        lastRecoveredAt = Date()
        arrivalVisualHoldStartedAt = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        resetRouteCorrectionGuards()
        resetRouteBelief(status: .initializing)
        phase = .navigating
        updateInstruction(forceSpeech: false)
        // Banner keeps the prefix, speech drops it. A realignment is bookkeeping
        // the user cannot act on, and it is not rare: five rebuilds fired in the
        // 19 s after one relocalization, so the ear got "Route realigned from
        // your position" five times and the direction that followed it four
        // times too late to matter. The instruction alone is the actionable part.
        //
        // And when the rebuilt route starts off at an angle to the way the user
        // is facing, that instruction has to open with the turn. This path
        // claims the turn slot below — which silenced the alignment cue that
        // would otherwise have spoken it — while itself speaking nothing but a
        // distance. Same silent-turn failure as the snap above.
        let facingDroppedStub = shaped.droppedLeadingStub
            && (heading.map { isFacingDroppedLeadingStub(liveHeading: $0) } ?? false)
        let spokenInstruction = turnPrefixedLegCue(
            on: firstStep,
            liveHeading: heading,
            facingDroppedStub: facingDroppedStub
        )
        currentInstruction = NavLoc.routeRealignedPrefix() + spokenInstruction
        NavigationTrace.shared.log("nav.rebuild", traceState(extra: [
            "nodePath": start.nodePath,
            "droppedLeadingStub": shaped.droppedLeadingStub,
            "legs": traceLegs()
        ]))
        emitCue(spokenInstruction, priority: .critical)
        noteLegContextSpoken(on: firstStep)
        // The realignment cue carries the new direction, so it claims the turn
        // slot: an alignment nudge on the very next tick would stack a second
        // turn command onto it.
        lastTurnCueAt = Date()
        lastHeadingAlignmentCueAt = Date()
        lastHeadingAlignmentCueKey = nil
        lastHeadingAlignmentErrorDegrees = nil
        rebuildRAGContext()
        return true
    }

    /// The current leg cue, opened with the turn that gets the user onto it.
    ///
    /// Returns `currentInstruction` unchanged when no turn is owed — when the
    /// heading is unknown, when the user already faces the leg, or when they
    /// are facing along a dropped leading stub, which IS facing the route.
    private func turnPrefixedLegCue(
        on step: SemanticRouteStep,
        liveHeading: Double?,
        facingDroppedStub: Bool
    ) -> String {
        guard let liveHeading, !facingDroppedStub else { return currentInstruction }
        let bearingError = abs(
            SemanticRouteMath.signedAngleDifference(liveHeading, step.edge.bearingDegrees)
        )
        guard bearingError >= routeStartAlignmentThresholdDegrees else { return currentInstruction }
        let command = Self.relativeTurnCommand(
            from: liveHeading,
            to: step.edge.bearingDegrees,
            style: turnPhrasing
        )
        // The turn still has to be spoken — it is the actionable half — but the
        // leg context after it is a repeat once the leg has already been named.
        let cue = NavLoc.turnThenWalkLeg(
            prefix: "",
            turn: Self.withoutTrailingPeriod(command.text),
            distance: Self.formatDistance(segmentRemainingMeters),
            context: spokenLegContextEdgeID == step.edge.id ? "" : walkContext(for: step)
        )
        return Self.tidiedSpacing(cue)
    }

    /// "Hold the phone at chest height" — the one thing that fixes an
    /// unusable heading.
    ///
    /// Held for `headingPostureGraceSeconds` first: glancing down at the phone
    /// is normal and must not be narrated. Paced by
    /// `headingPostureRepeatSeconds` so a user who keeps it low hears it
    /// occasionally rather than continuously.
    private func promptHeadingPostureIfDue() {
        guard phase == .navigating || phase == .recovering else { return }
        let now = Date()
        guard let since = headingTiltStartedAt else {
            headingTiltStartedAt = now
            return
        }
        guard now.timeIntervalSince(since) >= headingPostureGraceSeconds else { return }
        if let last = lastHeadingPosturePromptAt,
           now.timeIntervalSince(last) < headingPostureRepeatSeconds {
            return
        }
        lastHeadingPosturePromptAt = now
        currentInstruction = NavLoc.holdPhoneUpForHeading()
        emitCue(currentInstruction, priority: .priority)
        NavigationTrace.shared.log("nav.headingPosturePrompt", traceState(extra: [
            "sinceSeconds": now.timeIntervalSince(since)
        ]))
    }

    /// Records that this leg's context phrase has now been spoken.
    ///
    /// Called only where a cue carrying it was actually EMITTED — never from
    /// `updateInstruction`, which recomputes the banner every tick without
    /// speaking. Claiming it there would let the banner silently consume the
    /// one announcement the leg gets, and a leg reached by a rebuild would be
    /// introduced as "Turn right. Walk 20 meters." with no idea what is at the
    /// end of it.
    private func noteLegContextSpoken(on step: SemanticRouteStep) {
        spokenLegContextEdgeID = step.edge.id
    }

    /// Collapses the double space and the space-before-period left behind when
    /// a leg context is dropped from a template that expected one.
    private static func tidiedSpacing(_ text: String) -> String {
        text
            .replacingOccurrences(of: "  ", with: " ")
            .replacingOccurrences(of: " .", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Edge ids of the legs still to be walked, current one first. The shape a
    /// rebuild has to reproduce to count as "the same plan".
    private func remainingEdgeIDs() -> [String] {
        guard currentStepIndex < routeSteps.count else { return [] }
        return routeSteps[currentStepIndex...].map(\.edge.id)
    }

    private static func withoutTrailingPeriod(_ text: String) -> String {
        text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    /// Detects a rebuild that would send a user who is demonstrably still on
    /// their route substantially further from the destination than they
    /// already are — the signature of start resolution latching onto the wrong
    /// edge in a corridor the route retraces.
    ///
    /// The on-route test is what keeps this from blocking honest rebuilds: a
    /// user who really has wandered off sits far from every remaining leg, and
    /// for them a longer route is the correct answer, not a regression.
    /// Returns nil when the rebuild is acceptable.
    private func routeRebuildRegression(
        proposedSteps: [SemanticRouteStep],
        proposedProgressMeters: Double,
        arPosition: simd_float3?,
        imuState: IMUState,
        in map: SemanticRouteMap
    ) -> (currentTotalMeters: Double, proposedTotalMeters: Double, crossTrackMeters: Double)? {
        let livePose = map.coordinateSpace == "ar_world_xz"
            ? Self.routePoint(from: arPosition)
            : SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)
        guard !proposedSteps.isEmpty,
              currentStepIndex < routeSteps.count,
              let pose = livePose
        else { return nil }

        // Only the legs still to be walked. Standing on an already-completed
        // leg means the user genuinely did go backwards, and re-routing them
        // the long way round is then the honest answer.
        let remainingSteps = routeSteps[currentStepIndex...]
        let crossTrack = remainingSteps
            .map { Self.project(pose, onto: $0).crossTrackMeters }
            .min() ?? .greatestFiniteMagnitude
        guard crossTrack <= recoverySnapThreshold else { return nil }

        let currentTotal = remainingSteps.enumerated().reduce(0.0) { partial, pair in
            pair.offset == 0
                ? partial + max(0, pair.element.edge.distanceMeters - segmentProgressMeters)
                : partial + pair.element.edge.distanceMeters
        }
        guard currentTotal > 0 else { return nil }

        let proposedTotal = proposedSteps.enumerated().reduce(0.0) { partial, pair in
            pair.offset == 0
                ? partial + max(0, pair.element.edge.distanceMeters - proposedProgressMeters)
                : partial + pair.element.edge.distanceMeters
        }

        let allowance = max(routeRebuildRegressionMarginMeters, currentTotal * 0.5)
        guard proposedTotal > currentTotal + allowance else { return nil }
        return (currentTotal, proposedTotal, crossTrack)
    }

    /// Off-corridor recovery beyond orientation nudges: routes from the live
    /// pose back to the best network node, then onward to the target, so the
    /// user hears real "walk N meters" countdown guidance instead of bare
    /// turn cues with no follow-up.
    private func startRejoinGuidance(from pose: SemanticRoutePoint, liveHeading: Double) -> Bool {
        guard let map = activeMap,
              !targetName.isEmpty,
              let targetNode = resolveTarget(targetName, in: map) else {
            return false
        }

        var best: (node: SemanticRouteNode, path: [String], cost: Double)?
        for node in map.nodes {
            let approach = pose.distance(to: node.point)
            guard approach <= rejoinMaxDistanceMeters else { continue }
            let path = node.id == targetNode.id ? [node.id] : shortestPath(in: map, from: node.id, to: targetNode.id)
            guard !path.isEmpty else { continue }
            let cost = approach + pathCost(for: path, in: map)
            if cost < (best?.cost ?? .greatestFiniteMagnitude) {
                best = (node, path, cost)
            }
        }
        guard let best, pose.distance(to: best.node.point) >= rejoinMinimumDistanceMeters else {
            return false
        }

        let hereNode = SemanticRouteNode(
            id: "rejoin_start_\(UUID().uuidString)",
            name: "your position",
            point: pose,
            headingDegrees: liveHeading,
            kind: .waypoint,
            turnHint: nil,
            aliases: [],
            capturedAt: Date(),
            poiAnchorId: nil
        )
        let rejoinEdge = Self.makeEdge(
            from: hereNode,
            to: best.node,
            leftContext: nil,
            rightContext: nil,
            spokenContext: "back to the route",
            confidence: 0.6
        )
        // The tail is shaped like any other route, but its first leg follows the
        // rejoin hop rather than the user's own position, so it is never a
        // leading stub to drop.
        let shapedTail = shapeRouteSteps(buildSteps(for: best.path, in: map), allowLeadingStubDrop: false)
        routeSteps = [SemanticRouteStep(edge: rejoinEdge, from: hereNode, to: best.node)] + shapedTail.steps
        arrivalFacing = shapedTail.arrivalFacing
        currentStepIndex = 0
        leadingStubBearingDegrees = nil
        leadingStubMeters = 0
        segmentProgressMeters = 0
        segmentRemainingMeters = rejoinEdge.distanceMeters
        resetLegCueSchedule()
        lastAnnouncedLandmarkID = nil
        recoveryStartedAt = nil
        recoveryReason = nil
        lastRecoveryCueKey = nil
        beliefIssueStartedAt = nil
        lastRecoveredAt = Date()
        arrivalVisualHoldStartedAt = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        pendingAlignmentResumeCue = false
        pendingPostTurnLegCueStepIndex = nil
        pendingPostTurnLegCueArmedAt = nil
        resetRouteCorrectionGuards()
        resetRouteBelief(status: .initializing)
        phase = .navigating
        didRebuildRouteThisUpdate = true

        let turn = Self.relativeTurnCommand(from: liveHeading, to: rejoinEdge.bearingDegrees, style: turnPhrasing)
        let nodeName = Self.spokenNodeLabel(best.node).nilIfBlank ?? NavLoc.defaultRouteLabel()
        let rejoinDistance = Self.formatDistance(rejoinEdge.distanceMeters)
        currentInstruction = turn.key == "straight"
            ? NavLoc.rejoinStraight(distance: rejoinDistance, node: nodeName)
            : NavLoc.rejoinWithTurn(turn: turn.text, distance: rejoinDistance, node: nodeName)
        NavigationTrace.shared.log("nav.rejoin", traceState(extra: [
            "rejoinNode": best.node.name,
            "rejoinDistM": rejoinEdge.distanceMeters,
            "rejoinBearing": rejoinEdge.bearingDegrees,
            "liveHeading": liveHeading,
            "turnKey": turn.key,
            "legs": traceLegs()
        ]))
        emitCue(currentInstruction, priority: .critical)
        rebuildRAGContext()
        return true
    }

    /// Leaves the recovering phase and, when a recovery cue was actually
    /// spoken, tells the user guidance is trustworthy again — a silent flip
    /// back leaves them unsure whether to keep pausing.
    private func exitRecovery(announce: Bool) {
        let hadSpokenCue = lastRecoveryCueKey != nil
        phase = .navigating
        recoveryReason = nil
        recoveryStartedAt = nil
        beliefIssueStartedAt = nil
        beliefHealthySince = nil
        lastRecoveryCueKey = nil
        lastRecoveredAt = Date()
        // Re-sync progress from the trusted AR projection before speaking the
        // next instruction: dead reckoning drifted during the hold, and
        // resuming from its stale progress produces wrong guidance.
        //
        // Through the SAME guard every other correction uses. Assigning
        // directly let one exit teleport the user 1.3 m → 4.5 m along a 5.45 m
        // leg in 0.67 s — nobody walks 3.2 m in two thirds of a second — which
        // landed them on the turn node and fired "Turn left" while they were
        // still mid-corridor. That is where a "false turn" with no mapped node
        // behind it comes from: not the graph, a pose jump wearing guidance's
        // voice. A correction this large means the belief is still wrong, so
        // stay where dead reckoning says and let evidence re-converge.
        if let arRemaining = lastTrustedARRemainingMeters, let step = activeStep {
            let observed = min(max(step.edge.distanceMeters - arRemaining, 0), step.edge.distanceMeters)
            if let guarded = guardedSegmentProgressCorrection(
                toward: observed,
                on: step,
                source: "recovery_exit",
                maxImmediateForwardMeters: maxImmediateARProgressCorrectionMeters
            ) {
                segmentProgressMeters = guarded
                segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
            }
        }
        updateInstruction(forceSpeech: false)
        if announce, hadSpokenCue {
            // Banner keeps the prefix, speech drops it — same reasoning as the
            // realignment cue. "Back on route" was spoken 12 times in a single
            // 2-minute walk; re-stating the direction already tells the user
            // guidance is live again, without spending a sentence saying so.
            let spokenInstruction = resumeWalkCue()
            currentInstruction = NavLoc.backOnRoutePrefix() + spokenInstruction
            emitCue(spokenInstruction, priority: .priority)
        }
    }

    private func pdrDistanceDelta(from imuState: IMUState) -> Double {
        lastPDRDeltaWasCapped = false
        defer {
            lastIMUStepCount = imuState.stepCount
            lastIMUPosition = imuState.position
        }

        if let lastStep = lastIMUStepCount {
            let stepDelta = max(0, imuState.stepCount - lastStep)
            if stepDelta > 0 {
                let rawDelta = Double(stepDelta) * max(imuState.currentStepLength, 0.35)
                if rawDelta > maxPDRDeltaPerUpdateMeters {
                    lastPDRDeltaWasCapped = true
                    return maxPDRDeltaPerUpdateMeters
                }
                return rawDelta
            }
        }

        guard let previous = lastIMUPosition else { return 0 }
        let delta = hypot(imuState.position.x - previous.x, imuState.position.y - previous.y)
        guard delta.isFinite else { return 0 }
        let boundedDelta = max(delta, 0)
        if boundedDelta > maxPDRDeltaPerUpdateMeters {
            lastPDRDeltaWasCapped = true
            return maxPDRDeltaPerUpdateMeters
        }
        return boundedDelta
    }

    private func recordHeadingSample(_ arHeading: Double?) {
        guard let arHeading else { return }
        let now = Date()
        recentHeadingSamples.append((at: now, degrees: arHeading))
        let cutoff = now.addingTimeInterval(-2.0)
        recentHeadingSamples.removeAll { $0.at < cutoff }
    }

    /// True when the live heading has held one direction long enough to be a
    /// facing rather than one instant of a turn still in progress. No history
    /// (cold start) counts as settled — the caller's single reading is all the
    /// evidence there is.
    private func isLiveHeadingSettled(now: Date = Date()) -> Bool {
        let windowStart = now.addingTimeInterval(-headingSettleWindowSeconds)
        let window = recentHeadingSamples.filter { $0.at >= windowStart }
        guard window.count >= 2, let reference = window.first?.degrees else { return true }
        var minOffset = 0.0
        var maxOffset = 0.0
        for sample in window.dropFirst() {
            let offset = SemanticRouteMath.signedAngleDifference(sample.degrees, reference)
            minOffset = min(minOffset, offset)
            maxOffset = max(maxOffset, offset)
        }
        return maxOffset - minOffset <= headingSettleMaxSpreadDegrees
    }

    /// True while the user stands before a dropped leading stub facing roughly
    /// along it. That IS facing the route — the turn onto the first real leg
    /// only exists at the stub's far end, and commanding it early points the
    /// user into the shelf they are standing beside.
    private func isFacingDroppedLeadingStub(liveHeading: Double) -> Bool {
        guard currentStepIndex == 0,
              let stubBearing = leadingStubBearingDegrees,
              segmentProgressMeters <= leadingStubMeters + 0.6 else {
            return false
        }
        let error = abs(SemanticRouteMath.signedAngleDifference(liveHeading, stubBearing))
        return error <= leadingStubFacingToleranceDegrees
    }

    private func initialHeadingAlignmentInstruction(
        on step: SemanticRouteStep,
        liveHeading: Double
    ) -> String? {
        let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, step.edge.bearingDegrees))
        guard headingError >= routeStartAlignmentThresholdDegrees else { return nil }
        return Self.routeAlignmentInstruction(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing)
    }

    /// Floor between any two spoken turn instructions, whichever subsystem
    /// raised them.
    ///
    /// Clock-face phrasing needs a wider one. Its twelve bands mean a user
    /// mid-turn crosses several while acting on a single cue, and each crossing
    /// is a candidate for a fresh sentence; at the left/right floor that
    /// reached the pilot as a stream faster than anyone could follow. The
    /// left/right value is left exactly where it was tuned.
    private var sharedTurnCueMinimumGapSeconds: TimeInterval {
        turnPhrasing == .clockFace ? 3.2 : routeAlignmentCueMinimumGapSeconds
    }

    /// Extra silence owed on top of a corrective cue's normal cooldown,
    /// because the same correction has already been given and not taken.
    private var correctiveCueBackoffSeconds: TimeInterval {
        let extra = consecutiveCorrectiveCues - correctiveCueFreeRepeats
        guard extra > 0 else { return 0 }
        return min(correctiveCueBackoffMaxSeconds, Double(extra) * correctiveCueBackoffStepSeconds)
    }

    /// True once the correction is repeating itself. Past this point a cue
    /// whose WORDS changed no longer earns an immediate re-speak: a user
    /// turning to get around something sweeps through several bands, and
    /// "turn left… turn sharp left… turn around" inside a few seconds is the
    /// run-on contradiction the pilot described being unable to follow.
    private var isCorrectiveCueBackingOff: Bool {
        consecutiveCorrectiveCues > correctiveCueFreeRepeats
    }

    /// Has the user deliberately stopped after already being corrected once?
    /// See `correctiveCueStillnessQuietSeconds`.
    ///
    /// The FIRST correction is never suppressed, however still the user is:
    /// someone standing at the start of a route facing the wrong way needs to
    /// hear it, and silence there is the bug this would otherwise introduce.
    /// What the pilot asked for was an end to the repeats — "it kept saying
    /// turn right" — while she stood still sorting out an obstacle.
    private func isPausedForCorrectiveQuiet(isMoving: Bool) -> Bool {
        guard consecutiveCorrectiveCues > 0 else { return false }
        guard !isMoving, let since = movementStoppedAt else { return false }
        return Date().timeIntervalSince(since) >= correctiveCueStillnessQuietSeconds
    }

    /// The user is back where the route wants them; the next problem starts
    /// its own count rather than inheriting the last one's patience.
    private func resetCorrectiveCueBackoff() {
        consecutiveCorrectiveCues = 0
    }

    private func issueHeadingAlignmentCueIfNeeded(
        on step: SemanticRouteStep,
        liveHeading: Double,
        headingError: Double,
        isMoving: Bool
    ) -> Bool {
        // Alignment nudges are corrective guidance. With error recovery
        // disabled the user asked for turn-by-turn only — no "turn around"
        // interjections, even when the heading disagrees with the route.
        guard shouldEnableErrorRecovery else { return false }
        guard phase == .navigating else { return false }
        guard headingError >= routeTurnAlignmentThresholdDegrees else { return false }
        // ── The heading is not a facing right now ───────────────────────────
        // Past ~73° of pitch the forward vector's horizontal component is
        // noise, so the heading falls back to the camera's UP vector — which
        // only equals the real facing at zero roll. Steering a blind user by
        // it is worse than saying nothing: on 4 Sep 2026 a tester on a
        // STRAIGHT leg pointed the phone at the floor and was told to turn
        // left. Say what would actually fix it instead.
        if headingIsTiltDerived {
            promptHeadingPostureIfDue()
            NavigationTrace.shared.tick("nav.alignmentCue.deferred", [
                "reason": "heading_tilt_unreliable",
                "liveHeading": liveHeading,
                "targetBearing": step.edge.bearingDegrees
            ])
            return false
        }
        headingTiltStartedAt = nil
        // The frame this error was measured in has just moved. See
        // `noteARFrameRealigned`.
        if let arFrameRealignedAt,
           Date().timeIntervalSince(arFrameRealignedAt) < alignmentCueFrameSettleSeconds {
            NavigationTrace.shared.tick("nav.alignmentCue.deferred", [
                "reason": "frame_realigning",
                "liveHeading": liveHeading,
                "targetBearing": step.edge.bearingDegrees
            ])
            return false
        }
        // Facing along a dropped leading stub is facing the route: the heading
        // error against the post-stub leg is the turn that comes LATER, at the
        // stub's far end. Nagging it now told users who had already turned the
        // right way to turn again.
        if isFacingDroppedLeadingStub(liveHeading: liveHeading) { return false }
        // A sweeping heading (relocalization pan, or a turn already underway)
        // is not a facing. Judge alignment once it settles; a cue computed
        // mid-sweep commands a turn against a direction already abandoned.
        guard isLiveHeadingSettled() else {
            NavigationTrace.shared.tick("nav.alignmentCue.deferred", [
                "reason": "heading_sweeping",
                "liveHeading": liveHeading,
                "targetBearing": step.edge.bearingDegrees
            ])
            return false
        }

        let recentlyAdvanced = lastRouteAdvanceAt.map {
            Date().timeIntervalSince($0) <= visualRouteAdvanceCooldownSeconds
        } ?? false
        // After recovery the user has been panning and may face anywhere;
        // give them an alignment cue before resuming walking guidance.
        let recentlyRecovered = lastRecoveredAt.map {
            Date().timeIntervalSince($0) <= postRecoveryAlignmentWindowSeconds
        } ?? false
        let nearStepStart = segmentProgressMeters <= routeAlignmentProgressWindowMeters
        guard nearStepStart || recentlyAdvanced || recentlyRecovered else { return false }

        // ⚠️ This cue and the turn at a mapped node are the SAME sentence — a
        // bare "Turn right." — so a walker cannot tell "the corner is here"
        // from "you have drifted off the line". A 25 Aug 2026 tester walking
        // with his eyes shut took a corrective one for a corner and turned into
        // a wall. The distinguishing clause ("… to face the route") was removed
        // on reviewer instruction on 15 Aug 2026 for being too wordy, so
        // reinstating it is the reviewer's call, not this code's; what IS fixed
        // here is the frame-settle guard above, which is what let a corrective
        // cue fire off a map frame that had just rotated 90°.
        let command = Self.relativeTurnCommand(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing)
        let instruction = command.text
        let key = "align_\(command.key)_\(currentStepIndex)"
        let now = Date()
        let cueChanged = !Self.isSameSpokenCorrection(key, as: lastHeadingAlignmentCueKey)
        let cueAge = lastHeadingAlignmentCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        currentInstruction = instruction
        confidence = min(confidence, 0.48)
        recoveryReason = nil
        guidanceIntroProtectedUntil = nil
        // `tick`, not `log`: this fires on every evaluation, not every cue. The
        // 4 Sep 2026 session wrote 6,085 of them plus 5,771 deferrals — twelve
        // thousand unthrottled disk writes during a walk, which both cost I/O
        // on the guidance path and crowd the decisions out of the trace. The
        // cue that actually SPEAKS is already recorded by `emitCue`.
        NavigationTrace.shared.tick("nav.alignmentCue", traceState(extra: [
            "instruction": instruction,
            "key": key,
            "targetBearing": step.edge.bearingDegrees,
            "nearStepStart": nearStepStart,
            "recentlyAdvanced": recentlyAdvanced,
            "recentlyRecovered": recentlyRecovered
        ]))

        // A user part-way through a turn sweeps across every band — around,
        // sharp left, left — and the old rule spoke on each crossing because
        // the cue text had changed. What reached the user was "turn around…
        // turn sharp left… turn left" inside three seconds, which sounds like
        // the app contradicting itself and is worse than saying nothing.
        // One cue, then room to act on it.
        let isTurningTowardRoute = lastHeadingAlignmentErrorDegrees.map {
            headingError <= $0 - routeAlignmentImprovementDegrees
        } ?? false
        let sinceAnyTurnCue = lastTurnCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        let shouldSpeak: Bool
        if sinceAnyTurnCue < sharedTurnCueMinimumGapSeconds {
            shouldSpeak = false
        } else if isPausedForCorrectiveQuiet(isMoving: isMoving) {
            // Stopped on purpose. Say nothing until they walk again.
            shouldSpeak = false
        } else if isTurningTowardRoute {
            // They are already turning the right way; only speak again if the
            // turn stalls part-way.
            shouldSpeak = cueAge >= routeAlignmentStalledCueSeconds
        } else if isCorrectiveCueBackingOff {
            shouldSpeak = cueAge >= routeAlignmentCueCooldownSeconds + correctiveCueBackoffSeconds
        } else {
            shouldSpeak = cueChanged || cueAge >= routeAlignmentCueCooldownSeconds
        }

        if shouldSpeak {
            emitCue(currentInstruction, priority: .critical)
            lastHeadingAlignmentCueAt = now
            lastHeadingAlignmentCueKey = key
            lastHeadingAlignmentErrorDegrees = headingError
            lastTurnCueAt = now
            consecutiveCorrectiveCues += 1
            // Once the user finishes this turn, follow up with an explicit
            // "walk" resumption instead of going silent.
            pendingAlignmentResumeCue = true
        }
        return true
    }

    /// The point on the leg the user should be steering at: a fixed distance
    /// ahead of wherever they currently project onto it, clamped to the leg's
    /// far end.
    ///
    /// Aiming here rather than at the nearest point is the whole difference
    /// between converging on the centre of the aisle and crossing it. The
    /// angle it produces also degrades correctly: at an offset far larger than
    /// the lookahead it approaches the sideways aim the old cue always used.
    private func coursePursuitPoint(on step: SemanticRouteStep, alongTrackMeters: Double) -> SemanticRoutePoint {
        let legLength = max(step.edge.distanceMeters, 0.0001)
        let lookahead = max(courseMinimumLookaheadMeters, min(courseLookaheadMeters, legLength))
        let target = min(legLength, max(0, alongTrackMeters) + lookahead)
        let t = target / legLength
        return SemanticRoutePoint(
            x: step.from.point.x + t * (step.to.point.x - step.from.point.x),
            y: step.from.point.y + t * (step.to.point.y - step.from.point.y)
        )
    }

    /// A small, rare correction that keeps the user near the middle of the
    /// aisle instead of waiting for them to hit a shelf.
    ///
    /// Returns true only on the tick it actually speaks, so it never blocks
    /// progress, arrival or the normal walking instruction. Runs after
    /// recovery and only while `.navigating`: a user who is genuinely off
    /// route gets recovery's cue, not a nudge.
    private func issueCourseCorrectionCueIfNeeded(
        on step: SemanticRouteStep,
        liveHeading: Double,
        pose: SemanticRoutePoint?,
        routeProjection: RouteProjection?,
        isMoving: Bool,
        arLocalized: Bool
    ) -> Bool {
        // Corrective guidance, same as the alignment nudge: the study
        // condition that turns error recovery off asks for turn-by-turn only.
        guard shouldEnableErrorRecovery else { return false }
        guard phase == .navigating, isMoving, arLocalized else {
            courseCorrectionSince = nil
            return false
        }
        // Never lands on top of the opening announcement — the user is still
        // hearing where they are being taken.
        guard guidanceIntroProtectedUntil.map({ Date() >= $0 }) ?? true else { return false }
        guard let pose, let routeProjection else {
            courseCorrectionSince = nil
            return false
        }
        // Needs room ahead on the leg for a lookahead point to mean anything,
        // and must stay out of the turn cue's space at the end of it. Floored
        // by the live AR distance for the same reason the countdown is: a
        // dead-reckoned belief that lags the pose would let a nudge land on a
        // user already standing at the turn.
        let remaining = min(segmentRemainingMeters, lastARNodeDistanceMeters ?? .greatestFiniteMagnitude)
        guard remaining >= courseCorrectionMinimumRemainingMeters else {
            courseCorrectionSince = nil
            return false
        }
        // A sweeping heading is not a course. Same reasoning as the alignment
        // cue: a correction computed mid-sweep argues with a facing the user
        // has already left. A tilt-derived one is not a facing at all.
        guard !headingIsTiltDerived else {
            courseCorrectionSince = nil
            return false
        }
        guard isLiveHeadingSettled() else { return false }

        let targetBearing = pose.bearingDegrees(
            to: coursePursuitPoint(on: step, alongTrackMeters: routeProjection.alongTrackMeters)
        )
        let courseError = SemanticRouteMath.signedAngleDifference(targetBearing, liveHeading)
        let magnitude = abs(courseError)
        guard magnitude >= courseCorrectionThresholdDegrees,
              magnitude <= courseCorrectionMaxDegrees else {
            courseCorrectionSince = nil
            return false
        }

        let now = Date()
        let since = courseCorrectionSince ?? now
        courseCorrectionSince = since
        guard now.timeIntervalSince(since) >= courseCorrectionHoldSeconds else { return false }

        let sinceAnyTurnCue = lastTurnCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard sinceAnyTurnCue >= courseCorrectionQuietAfterTurnSeconds else { return false }

        let cue = Self.courseCorrectionCue(forSignedDegrees: courseError, style: turnPhrasing)
        let cueAge = lastCourseCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        // Unlike the turn cues, a changed key does NOT license an immediate
        // repeat. Drifting a little further is not new information — the user
        // already knows which way to ease, and hearing it again two seconds
        // later is the flooding this whole cue is meant to replace.
        guard cueAge >= courseCorrectionRepeatSeconds else { return false }

        currentInstruction = cue.text
        lastCourseCueAt = now
        lastTurnCueAt = now
        courseCorrectionSince = nil
        NavigationTrace.shared.log("nav.courseCorrection", traceState(extra: [
            "instruction": cue.text,
            "key": cue.key,
            "courseErrorDeg": courseError,
            "crossTrackM": routeProjection.crossTrackMeters,
            "alongTrackM": routeProjection.alongTrackMeters,
            "targetBearing": targetBearing,
            "legBearing": step.edge.bearingDegrees,
            "liveHeading": liveHeading
        ]))
        emitCue(cue.text, priority: .priority)
        return true
    }

    /// Phrasing for a course correction. Clock-face mode carries the magnitude
    /// in the hour ("ease to 11 o'clock"); left/right mode says only that the
    /// adjustment is a slight one, because "turn left" for a 25° drift is what
    /// walked pilot users into the opposite shelf.
    private static func courseCorrectionCue(
        forSignedDegrees diff: Double,
        style: SemanticTurnPhrasing
    ) -> (text: String, key: String) {
        if style == .clockFace {
            let hour = clockHour(forSignedDegrees: diff)
            return (NavLoc.easeToClock(hour: hour), "course_clock_\(hour)")
        }
        return diff > 0
            ? (NavLoc.bearRightSlightly(), "course_right")
            : (NavLoc.bearLeftSlightly(), "course_left")
    }

    private func resetCourseCorrectionState() {
        courseCorrectionSince = nil
        lastCourseCueAt = nil
    }

    private func advanceFromVisualDecisionPoint(
        _ visualMatch: VisualRouteMatch?,
        on step: SemanticRouteStep
    ) -> Bool {
        guard let visualMatch,
              visualMatch.confidence >= visualDecisionAdvanceConfidence else {
            return false
        }
        if let lastRouteAdvanceAt,
           Date().timeIntervalSince(lastRouteAdvanceAt) < visualRouteAdvanceCooldownSeconds {
            return false
        }

        let nearCurrentBelief = visualMatch.stepIndex == currentStepIndex &&
            abs(visualMatch.progressMeters - segmentProgressMeters) <= routeBeliefLargeCorrectionSupportMeters
        let supportedByBelief = routeBeliefSupportsLargeCorrection(
            stepIndex: visualMatch.stepIndex,
            observedProgress: visualMatch.progressMeters,
            source: "visual_route",
            visualConfidence: visualMatch.confidence
        )
        guard nearCurrentBelief || supportedByBelief else {
            markRouteEvidenceConflict(source: "visual_route", observedProgress: visualMatch.progressMeters)
            return false
        }

        if visualMatch.stepIndex == currentStepIndex {
            let nearStepEnd = visualMatch.progressMeters >= max(0, step.edge.distanceMeters - visualDecisionWindowMeters(for: step))

            if currentStepIndex >= routeSteps.count - 1,
               isVisualArrivalConfirmed(on: step, visualMatch: visualMatch) {
                guard shouldConfirmRouteAdvance(
                    key: "visual_arrival_\(currentStepIndex)",
                    confidence: visualMatch.confidence
                ) else {
                    return false
                }
                segmentProgressMeters = step.edge.distanceMeters
                segmentRemainingMeters = 0
                advanceStepOrArrive()
                return true
            }

            if currentStepIndex < routeSteps.count - 1, nearStepEnd {
                guard shouldConfirmRouteAdvance(
                    key: "visual_step_end_\(currentStepIndex)",
                    confidence: visualMatch.confidence
                ) else {
                    return false
                }
                segmentProgressMeters = step.edge.distanceMeters
                segmentRemainingMeters = 0
                advanceStepOrArrive()
                return true
            }
        }

        if visualMatch.stepIndex == currentStepIndex + 1,
           currentStepIndex < routeSteps.count - 1,
           visualMatch.progressMeters <= visualDecisionWindowMeters(for: routeSteps[currentStepIndex + 1]) {
            guard shouldConfirmRouteAdvance(
                key: "visual_next_step_\(currentStepIndex + 1)",
                confidence: visualMatch.confidence
            ) else {
                return false
            }
            segmentProgressMeters = step.edge.distanceMeters
            segmentRemainingMeters = 0
            advanceStepOrArrive()
            return true
        }

        return false
    }

    private func visualDecisionWindowMeters(for step: SemanticRouteStep) -> Double {
        min(0.70, max(0.30, step.edge.distanceMeters * 0.35))
    }

    private func visualArrivalWindowMeters(for step: SemanticRouteStep) -> Double {
        min(0.65, max(0.30, step.edge.distanceMeters * 0.30))
    }

    private func nodeArrivalRadiusMeters(for step: SemanticRouteStep) -> Double {
        min(0.70, max(0.32, step.edge.distanceMeters * 0.35))
    }

    private func destinationArrivalRadiusMeters(for step: SemanticRouteStep) -> Double {
        // Floor raised to 1.0 m with `destinationProximityMeters`: a short
        // final segment (e.g. 0.6 m right after a sharp turn) collapses the
        // scaled radius so tight that the AR pose at the user's real stopping
        // point — after 50 m of accumulated drift — never lands inside it, and
        // "arrived" never fires. It is also the case where the walker is most
        // obviously already there. Only affects destination arrival; mid-route
        // turns use nodeArrivalRadiusMeters.
        min(destinationProximityMeters, max(1.0, step.edge.distanceMeters * 0.30))
    }

    private func stepCompletionWindowMeters(for step: SemanticRouteStep) -> Double {
        min(arrivalThresholdMeters, max(0.24, step.edge.distanceMeters * 0.30))
    }

    private func offAxisProgressThresholdMeters(for step: SemanticRouteStep) -> Double {
        let halfWidth = max(0, (step.edge.walkableWidthMeters ?? 1.2) / 2.0)
        return min(
            offAxisProgressMaxMeters,
            max(crossTrackRecoveryThreshold, halfWidth + offAxisProgressExtraMeters)
        )
    }

    private func shouldTrustOffAxisProgress(
        _ projection: RouteProjection,
        on step: SemanticRouteStep
    ) -> Bool {
        projection.crossTrackMeters <= offAxisProgressThresholdMeters(for: step) &&
        projection.alongTrackMeters >= 0 &&
        projection.alongTrackMeters <= step.edge.distanceMeters
    }

    private func stabilizedSegmentProgress(
        toward observedProgress: Double,
        on step: SemanticRouteStep,
        allowBackward: Bool
    ) -> Double {
        let observed = min(max(observedProgress, 0), step.edge.distanceMeters)
        if observed >= segmentProgressMeters {
            return observed
        }
        guard allowBackward else {
            return segmentProgressMeters
        }

        let correctionLimit = min(
            backwardProgressCorrectionMaxMeters,
            max(0.35, step.edge.distanceMeters * 0.30)
        )
        return max(observed, segmentProgressMeters - correctionLimit)
    }

    private func guardedSegmentProgressCorrection(
        toward observedProgress: Double,
        on step: SemanticRouteStep,
        source: String,
        maxImmediateForwardMeters: Double,
        visualConfidence: Double? = nil
    ) -> Double? {
        let observed = min(max(observedProgress, 0), step.edge.distanceMeters)
        let forwardDelta = observed - segmentProgressMeters
        if forwardDelta <= maxImmediateForwardMeters {
            pendingProgressCorrection = nil
            return stabilizedSegmentProgress(toward: observed, on: step, allowBackward: true)
        }

        let strongVisualEvidence = (visualConfidence ?? 0) >= visualDecisionAdvanceConfidence
        let immediateVisualEvidence = (visualConfidence ?? 0) >= visualDecisionImmediateConfidence
        let physicalForwardLimit = maxImmediateForwardMeters +
            max(routeBeliefPhysicalSlackMeters, lastRouteUpdatePDRDelta * 1.6 + routeBeliefPhysicalSlackMeters)
        let beliefSupportsCorrection = routeBeliefSupportsLargeCorrection(
            stepIndex: currentStepIndex,
            observedProgress: observed,
            source: source,
            visualConfidence: visualConfidence
        )

        if immediateVisualEvidence && (forwardDelta <= physicalForwardLimit || beliefSupportsCorrection) {
            pendingProgressCorrection = nil
            return stabilizedSegmentProgress(toward: observed, on: step, allowBackward: true)
        }

        if forwardDelta > physicalForwardLimit && !beliefSupportsCorrection {
            markRouteEvidenceConflict(source: source, observedProgress: observed)
            stagePendingProgressCorrection(source: source, observedProgress: observed)
            return nil
        }

        let decisionWindowStart = max(
            0,
            step.edge.distanceMeters - max(routeAdvanceMaxUnconfirmedRemainingMeters, visualDecisionWindowMeters(for: step))
        )
        if observed >= decisionWindowStart, !strongVisualEvidence {
            stagePendingProgressCorrection(source: source, observedProgress: observed)
            return nil
        }

        guard isLargeProgressCorrectionConfirmed(source: source, observedProgress: observed) else {
            return nil
        }

        return stabilizedSegmentProgress(toward: observed, on: step, allowBackward: true)
    }

    @discardableResult
    private func stagePendingProgressCorrection(
        source: String,
        observedProgress: Double
    ) -> PendingProgressCorrection {
        let now = Date()
        if var pending = pendingProgressCorrection,
           pending.stepIndex == currentStepIndex,
           pending.source == source,
           abs(pending.progressMeters - observedProgress) <= 0.90,
           now.timeIntervalSince(pending.lastSeenAt) <= 1.40 {
            pending.progressMeters = (pending.progressMeters + observedProgress) / 2.0
            pending.lastSeenAt = now
            pending.sampleCount += 1
            pendingProgressCorrection = pending
            return pending
        }

        let pending = PendingProgressCorrection(
            stepIndex: currentStepIndex,
            source: source,
            progressMeters: observedProgress,
            firstSeenAt: now,
            lastSeenAt: now,
            sampleCount: 1
        )
        pendingProgressCorrection = pending
        return pending
    }

    private func isLargeProgressCorrectionConfirmed(
        source: String,
        observedProgress: Double
    ) -> Bool {
        let pending = stagePendingProgressCorrection(
            source: source,
            observedProgress: observedProgress
        )
        let oldEnough = Date().timeIntervalSince(pending.firstSeenAt) >= largeProgressCorrectionConfirmationSeconds
        let enoughSamples = pending.sampleCount >= largeProgressCorrectionRequiredSamples
        if oldEnough && enoughSamples {
            pendingProgressCorrection = nil
            return true
        }
        return false
    }

    private func shouldConfirmRouteAdvance(
        key: String,
        confidence: Double
    ) -> Bool {
        if confidence >= visualDecisionImmediateConfidence {
            pendingRouteAdvance = nil
            return true
        }

        let now = Date()
        if var pending = pendingRouteAdvance,
           pending.key == key,
           now.timeIntervalSince(pending.lastSeenAt) <= 1.40 {
            pending.lastSeenAt = now
            pending.sampleCount += 1
            pendingRouteAdvance = pending
        } else {
            pendingRouteAdvance = PendingRouteAdvance(
                key: key,
                firstSeenAt: now,
                lastSeenAt: now,
                sampleCount: 1
            )
        }

        guard let pending = pendingRouteAdvance else { return false }
        let oldEnough = now.timeIntervalSince(pending.firstSeenAt) >= decisionAdvanceConfirmationSeconds
        let enoughSamples = pending.sampleCount >= decisionAdvanceRequiredSamples
        if oldEnough && enoughSamples {
            pendingRouteAdvance = nil
            return true
        }
        return false
    }

    private func shouldAdvanceFromARNodeProximity(
        on step: SemanticRouteStep,
        visualMatch: VisualRouteMatch?
    ) -> Bool {
        if segmentRemainingMeters <= routeAdvanceMaxUnconfirmedRemainingMeters {
            pendingRouteAdvance = nil
            return true
        }

        // A localized pose standing ON the node, square on the route line, is a
        // direct measurement of where the user is. Dead reckoning is an
        // estimate of the same thing, and when the two disagree the measurement
        // wins — asking a photograph to break the tie means the turn is not
        // called until the estimate catches up, which is how a turn cue arrives
        // after the user has already walked into the corner. That is the
        // "postarrival" half of the 3 Sep 2026 wall-collision report, and it
        // had a red test (`testTurnCueTellsTheUserToWalkAndLaterCuesDoNot`)
        // sitting on it.
        //
        // `lastTrustedARRemainingMeters` is only set while AR is localized AND
        // the cross-track is inside the leg's corridor, so this cannot fire for
        // a pose that is merely near the node in open space; and the caller has
        // already checked the node radius. `isAtFinalDestination` has always
        // trusted the pose alone on the more consequential decision — arrival —
        // so requiring a second witness only here was never consistent.
        if lastTrustedARRemainingMeters != nil {
            pendingRouteAdvance = nil
            return true
        }

        guard let visualMatch,
              visualMatch.confidence >= visualDecisionAdvanceConfidence else {
            return false
        }

        let nearCurrentStepEnd = visualMatch.stepIndex == currentStepIndex &&
            visualMatch.progressMeters >= max(0, step.edge.distanceMeters - visualDecisionWindowMeters(for: step))
        let nearNextStepStart = visualMatch.stepIndex == currentStepIndex + 1 &&
            currentStepIndex < routeSteps.count - 1 &&
            visualMatch.progressMeters <= visualDecisionWindowMeters(for: routeSteps[currentStepIndex + 1])
        guard nearCurrentStepEnd || nearNextStepStart else {
            return false
        }

        return shouldConfirmRouteAdvance(
            key: "visual_ar_node_\(currentStepIndex)",
            confidence: visualMatch.confidence
        )
    }

    private func destinationArrivalCorridorMeters(for step: SemanticRouteStep) -> Double {
        let halfWidth = max(0, (step.edge.walkableWidthMeters ?? 1.2) / 2.0)
        return min(destinationCorridorMaxMeters, max(0.85, halfWidth + destinationCorridorExtraMeters))
    }

    /// How much of the final leg may still be unwalked and still count as
    /// arrived. Capped at `destinationProximityMeters` deliberately: the
    /// radius says the pose is at the shelf and this says the progress model
    /// agrees, so the two must call arrival at the same distance or the
    /// looser one silently becomes the real threshold.
    private func destinationAlongTrackArrivalWindowMeters(for step: SemanticRouteStep) -> Double {
        min(destinationProximityMeters, max(1.0, step.edge.distanceMeters * 0.35))
    }

    private func isAtFinalDestination(
        on step: SemanticRouteStep,
        arPoint: SemanticRoutePoint?,
        visualMatch: VisualRouteMatch?,
        arLocalized: Bool
    ) -> Bool {
        guard currentStepIndex >= routeSteps.count - 1 else { return false }

        if isVisualArrivalConfirmed(on: step, visualMatch: visualMatch) {
            return true
        }

        guard arLocalized, let arPoint else { return false }
        if arPoint.distance(to: step.to.point) <= destinationArrivalRadiusMeters(for: step) {
            // The AR pose is directly on the destination node. Dead-reckoned
            // progress may still be lagging (missed steps, heading gating) —
            // snap it up from the AR projection instead of telling a user who
            // is standing at the target to keep walking.
            let projection = Self.project(arPoint, onto: step)
            segmentProgressMeters = max(segmentProgressMeters, projection.alongTrackMeters)
            segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
            return segmentRemainingMeters <= max(
                routeAdvanceMaxUnconfirmedRemainingMeters,
                destinationAlongTrackArrivalWindowMeters(for: step)
            )
        }

        let projection = Self.project(arPoint, onto: step)
        let destinationWindowStart = max(0, step.edge.distanceMeters - destinationAlongTrackArrivalWindowMeters(for: step))
        return projection.alongTrackMeters >= destinationWindowStart &&
            projection.crossTrackMeters <= destinationArrivalCorridorMeters(for: step) &&
            segmentRemainingMeters <= max(
                routeAdvanceMaxUnconfirmedRemainingMeters,
                destinationAlongTrackArrivalWindowMeters(for: step)
            )
    }

    private func updateRecoveryIfNeeded(
        headingError: Double,
        crossTrackError: Double?,
        isMoving: Bool,
        arLocalized: Bool,
        pose: SemanticRoutePoint?,
        liveHeading: Double,
        visualMatch: VisualRouteMatch?,
        routeProjection: RouteProjection?,
        backwardDriftMeters: Double
    ) {
        guard let step = activeStep else { return }

        let stepDistance = step.edge.distanceMeters
        let crossTrackLimit = recoveryCrossTrackThresholdMeters(for: step)
        let observedCrossTrack = crossTrackError ?? routeProjection?.crossTrackMeters ?? 0
        let shortSegment = stepDistance > 0 && stepDistance < 2.0
        let nearDecisionPoint = segmentProgressMeters < 0.7 || segmentRemainingMeters < 1.0
        let awayFromDecisionPoint = segmentProgressMeters > 1.2 && segmentRemainingMeters > 1.4
        let clearBackwardDrift = backwardDriftMeters >= immediateBackwardRecoveryDriftMeters
        let crossTrackBad = arLocalized && !nearDecisionPoint && observedCrossTrack > crossTrackLimit
        let backwardBad = arLocalized &&
            isMoving &&
            stepDistance > 1.4 &&
            backwardDriftMeters >= backwardRecoveryDriftMeters &&
            (!nearDecisionPoint || clearBackwardDrift)
        let headingBad = arLocalized && !shortSegment && awayFromDecisionPoint && headingError > headingRecoveryThreshold
        let lowConfidenceBad = isMoving && !shortSegment && !nearDecisionPoint && confidence < 0.30
        let localizationBad = !arLocalized && isMoving && !nearDecisionPoint && segmentProgressMeters > 1.2

        if let visualMatch,
           visualMatch.confidence >= visualRouteSnapConfidence,
           visualMatch.stepIndex >= currentStepIndex,
           visualMatch.stepIndex <= currentStepIndex + 1 {
            resetCorrectiveCueBackoff()
            if phase == .recovering {
                exitRecovery(announce: true)
            } else {
                recoveryStartedAt = nil
                recoveryReason = nil
                lastRecoveryCueKey = nil
            }
            return
        }

        guard crossTrackBad || backwardBad || headingBad || lowConfidenceBad || localizationBad else {
            // Nothing is wrong any more: whatever the user was doing, they are
            // back. The next problem gets the full cue cadence again.
            resetCorrectiveCueBackoff()
            if phase == .recovering {
                let sinceRecovery = lastRecoveredAt?.timeIntervalSinceNow ?? -10
                if arLocalized || sinceRecovery < -1.0 {
                    exitRecovery(announce: true)
                } else {
                    recoveryStartedAt = nil
                    lastRecoveryCueKey = nil
                }
            } else {
                recoveryStartedAt = nil
                lastRecoveryCueKey = nil
            }
            return
        }

        if let snap = bestRecoverySnap(pose: pose, liveHeading: liveHeading, visualMatch: visualMatch),
           shouldAcceptRecoverySnap(
            snap,
            crossTrackBad: crossTrackBad,
            headingBad: headingBad,
            backwardBad: backwardBad,
            localizationBad: localizationBad
           ) {
            applyRecoverySnap(snap, liveHeading: liveHeading, announce: phase == .recovering)
            return
        }

        let now = Date()

        if recoveryStartedAt == nil {
            recoveryStartedAt = now
        }

        if phase != .recovering,
           now.timeIntervalSince(recoveryStartedAt ?? now) < recoveryHoldSeconds {
            return
        }

        // Heading-only badness while the heading is still sweeping is a turn
        // in progress, not a lost user. Cue once it settles — a turn command
        // computed mid-sweep is stale before it is spoken. Any positional
        // badness still cues immediately; position does not sweep.
        if headingBad, !crossTrackBad, !backwardBad, !localizationBad, !isLiveHeadingSettled() {
            return
        }

        let cue = recoveryCue(
            on: step,
            crossTrackBad: crossTrackBad,
            backwardBad: backwardBad,
            headingBad: headingBad,
            localizationBad: localizationBad,
            observedCrossTrack: observedCrossTrack,
            headingError: headingError,
            liveHeading: liveHeading,
            pose: pose,
            routeProjection: routeProjection,
            backwardDriftMeters: backwardDriftMeters
        )
        let cueChanged = !Self.isSameSpokenCorrection(cue.key, as: lastRecoveryCueKey)
        let cueAge = lastRecoveryCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        phase = .recovering
        recoveryReason = cue.reason
        // Same per-tick flood the belief hold had: 159 identical lines inside
        // 0.8 s in the field trace. Log on reason change or every 2 s.
        let recoveryTraceAge = lastRecoveryTraceAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        if cue.key != lastRecoveryTraceKey || recoveryTraceAge >= 2.0 {
            lastRecoveryTraceAt = now
            lastRecoveryTraceKey = cue.key
            NavigationTrace.shared.log("nav.recovery", traceState(extra: [
                "instruction": cue.instruction,
                "key": cue.key,
                "reason": cue.reason,
                "crossTrackBad": crossTrackBad,
                "backwardBad": backwardBad,
                "headingBad": headingBad,
                "lowConfidenceBad": lowConfidenceBad,
                "localizationBad": localizationBad,
                "observedCrossTrackM": observedCrossTrack,
                "crossTrackLimitM": crossTrackLimit,
                "backwardDriftM": backwardDriftMeters,
                "targetBearing": step.edge.bearingDegrees
            ]))
        }

        // Escalation past orientation nudges: still off the corridor after
        // several seconds of cues means the user walked off the mapped path
        // (pilot: "points us back but gives no walking instructions"). Build
        // a real rejoin route so they get walk-N-meters countdown guidance.
        if crossTrackBad,
           arLocalized,
           let pose,
           let startedAt = recoveryStartedAt,
           now.timeIntervalSince(startedAt) >= rejoinGuidanceAfterSeconds,
           lastRouteRebuildAttemptAt.map({ now.timeIntervalSince($0) >= routeRebuildRetrySeconds }) ?? true {
            lastRouteRebuildAttemptAt = now
            if startRejoinGuidance(from: pose, liveHeading: liveHeading) {
                return
            }
        }

        // The banner belongs to whatever phase is showing. Throttling used to
        // return before this line, leaving the previous phase's sentence under
        // a "Recovering" badge — the screen said "Turn right to face the
        // route" while the navigator had already given up on that instruction.
        // Throttle the speech, never the displayed truth.
        currentInstruction = cue.instruction

        // Recovery cues are turn commands too, and they change key on every
        // band the user's heading sweeps through while turning. Same floor as
        // the alignment cue, and shared with it: alternating between the two
        // subsystems was still a run-on contradiction to the person listening.
        let sinceAnyTurnCue = lastTurnCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude
        guard sinceAnyTurnCue >= sharedTurnCueMinimumGapSeconds else { return }
        // Stopped on purpose — see `correctiveCueStillnessQuietSeconds`. The
        // recovery state stays exactly as it is; only the speech waits.
        guard !isPausedForCorrectiveQuiet(isMoving: isMoving) else { return }
        if isCorrectiveCueBackingOff {
            guard cueAge >= recoveryCueCooldownSeconds + correctiveCueBackoffSeconds else { return }
        } else {
            guard cueChanged || cueAge >= recoveryCueCooldownSeconds else { return }
        }

        emitCue(currentInstruction, priority: .critical)
        lastRecoveryCueAt = now
        lastRecoveryCueKey = cue.key
        lastTurnCueAt = now
        consecutiveCorrectiveCues += 1
    }

    private func recoveryCue(
        on step: SemanticRouteStep,
        crossTrackBad: Bool,
        backwardBad: Bool,
        headingBad: Bool,
        localizationBad: Bool,
        observedCrossTrack: Double,
        headingError: Double,
        liveHeading: Double,
        pose: SemanticRoutePoint?,
        routeProjection: RouteProjection?,
        backwardDriftMeters: Double
    ) -> RecoveryCueDecision {
        if backwardBad {
            // "Wrong direction." named the problem and stopped there, so the
            // user had to wait for a later cue — often a different subsystem's,
            // in different words — to learn what to do about it. A reviewer's
            // instruction on 15 Aug 2026 was explicit: say it only when the
            // corrective is ready, and then say only the corrective. Walking
            // backwards along the leg has exactly one.
            return RecoveryCueDecision(
                instruction: NavLoc.turnAroundCommand(),
                reason: "Backward movement \(Self.formatShortMeters(backwardDriftMeters)).",
                key: "wrong_direction"
            )
        }

        if headingBad, headingError >= 135 {
            let turn = Self.relativeTurnCommand(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing)
            return RecoveryCueDecision(
                instruction: turn.text,
                reason: String(format: "Heading %.0f degrees off.", headingError),
                key: "heading_\(turn.key)"
            )
        }

        if crossTrackBad {
            if let pose, let routeProjection {
                // Aim at a point AHEAD on the leg, not the nearest point
                // beside it. The nearest point is a sideways dash that
                // overshoots the centre line and needs correcting back — the
                // zigzag a pilot participant walked. The pursuit point puts
                // them on a converging line.
                //
                // The distance to that point used to be spoken alongside the
                // direction. It is not any more: see `NavLoc.recoveryNudge`.
                let pursuit = coursePursuitPoint(on: step, alongTrackMeters: routeProjection.alongTrackMeters)
                let routeBearing = pose.bearingDegrees(to: pursuit)
                let command = Self.relativeRecoveryCommand(from: liveHeading, to: routeBearing, style: turnPhrasing)
                let context = recoveryContext(on: step, progressMeters: routeProjection.alongTrackMeters)
                return RecoveryCueDecision(
                    instruction: NavLoc.recoveryNudge(command.text),
                    reason: "Off route \(Self.formatShortMeters(observedCrossTrack)), \(context).",
                    key: "off_route_\(command.key)"
                )
            }
            return RecoveryCueDecision(
                instruction: NavLoc.offRoute(),
                reason: "Off route \(Self.formatShortMeters(observedCrossTrack)).",
                key: "off_route"
            )
        }

        if headingBad {
            let turn = Self.relativeTurnCommand(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing)
            return RecoveryCueDecision(
                instruction: turn.text,
                reason: String(format: "Heading %.0f degrees off.", headingError),
                key: "heading_\(turn.key)"
            )
        }

        if localizationBad {
            return RecoveryCueDecision(
                instruction: NavLoc.scanSlowly(),
                reason: "AR localization weak.",
                key: "localization"
            )
        }

        return RecoveryCueDecision(
            instruction: NavLoc.slowDown(),
            reason: "Route confidence low.",
            key: "low_confidence"
        )
    }

    private func recoveryCrossTrackThresholdMeters(for step: SemanticRouteStep) -> Double {
        let halfWidth = max(0, (step.edge.walkableWidthMeters ?? 1.2) / 2.0)
        return min(
            recoveryCriticalCrossTrackMeters,
            max(recoveryAdvisoryCrossTrackMeters, halfWidth + 0.45)
        )
    }

    private struct RecoverySnapCandidate {
        let stepIndex: Int
        let progressMeters: Double
        let crossTrackMeters: Double
        let headingError: Double
        let score: Double
        let context: String
        let visualConfidence: Double?
    }

    private func bestRecoverySnap(
        pose: SemanticRoutePoint?,
        liveHeading: Double,
        visualMatch: VisualRouteMatch?,
        searchAllSteps: Bool = false
    ) -> RecoverySnapCandidate? {
        guard let pose, !routeSteps.isEmpty else { return nil }
        return routeSteps.enumerated().compactMap { pair -> RecoverySnapCandidate? in
            let index = pair.offset
            guard searchAllSteps || abs(index - currentStepIndex) <= 1 else { return nil }
            let step = pair.element
            let projection = Self.project(pose, onto: step)
            let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, step.edge.bearingDegrees))
            let keyframeDistance = nearestKeyframeDistance(on: step, to: pose)
            let evidenceBonus = keyframeDistance.map { max(0, 0.45 - min($0 / 4.0, 0.45)) } ?? 0
            let visualForStep = visualMatch?.stepIndex == index ? visualMatch : nil
            let visualBonus = visualForStep.map { min(0.82, max(0, $0.confidence - visualRouteMinimumConfidence) * 3.0) } ?? 0
            let indexPenalty = Double(abs(index - currentStepIndex)) * 0.22
            let headingPenalty = min(headingError / 120.0, 1.0) * 0.42
            let score = projection.crossTrackMeters + indexPenalty + headingPenalty - evidenceBonus - visualBonus
            let progress = visualForStep?.progressMeters ?? projection.alongTrackMeters
            let context = visualForStep?.cue.map { "near \($0)" }
                ?? recoveryContext(on: step, progressMeters: progress)
            return RecoverySnapCandidate(
                stepIndex: index,
                progressMeters: progress,
                crossTrackMeters: projection.crossTrackMeters,
                headingError: headingError,
                score: score,
                context: context,
                visualConfidence: visualForStep?.confidence
            )
        }
        .min { $0.score < $1.score }
    }

    private func shouldAcceptRecoverySnap(
        _ candidate: RecoverySnapCandidate,
        crossTrackBad: Bool,
        headingBad: Bool,
        backwardBad: Bool,
        localizationBad: Bool
    ) -> Bool {
        let hasStrongVisualEvidence = (candidate.visualConfidence ?? 0) >= visualDecisionAdvanceConfidence
        if backwardBad && !hasStrongVisualEvidence {
            return false
        }
        if localizationBad {
            return hasStrongVisualEvidence &&
                candidate.stepIndex >= currentStepIndex &&
                candidate.crossTrackMeters <= max(1.50, recoverySnapThreshold)
        }
        if candidate.stepIndex > currentStepIndex, !hasStrongVisualEvidence {
            return false
        }
        if candidate.stepIndex == currentStepIndex,
           candidate.progressMeters - segmentProgressMeters > maxImmediateARProgressCorrectionMeters,
           !hasStrongVisualEvidence {
            return false
        }
        if let visualConfidence = candidate.visualConfidence,
           visualConfidence >= visualRouteSnapConfidence,
           candidate.crossTrackMeters <= max(3.0, recoverySnapThreshold * 2.2) {
            let nearCurrentProgress = candidate.stepIndex == currentStepIndex &&
                abs(candidate.progressMeters - segmentProgressMeters) <= routeBeliefLargeCorrectionSupportMeters
            return nearCurrentProgress || routeBeliefSupportsLargeCorrection(
                stepIndex: candidate.stepIndex,
                observedProgress: candidate.progressMeters,
                source: "visual_route",
                visualConfidence: visualConfidence
            )
        }
        if headingBad && !crossTrackBad {
            return candidate.crossTrackMeters <= 0.75 && candidate.headingError <= 75
        }
        if crossTrackBad {
            return candidate.crossTrackMeters <= recoverySnapThreshold
        }
        if backwardBad && !crossTrackBad {
            return candidate.stepIndex == currentStepIndex && candidate.crossTrackMeters <= crossTrackRecoveryThreshold
        }
        return candidate.crossTrackMeters <= recoverySnapThreshold || candidate.score <= 1.25
    }

    private func applyRecoverySnap(
        _ candidate: RecoverySnapCandidate,
        liveHeading: Double,
        announce: Bool
    ) {
        guard candidate.stepIndex >= 0, candidate.stepIndex < routeSteps.count else { return }
        // One snap per settling period. Unthrottled, this fired 34 times in
        // 0.7 s in the field — each one re-running `updateInstruction`, so the
        // user heard "7 meters" thirty times in under a second while the pose
        // twitched. A snap is a decision, not a per-frame correction.
        if let lastSnapAt, Date().timeIntervalSince(lastSnapAt) < recoverySnapCooldownSeconds {
            return
        }
        lastSnapAt = Date()
        NavigationTrace.shared.log("nav.snap", traceState(extra: [
            "toStep": candidate.stepIndex,
            "toProgressM": candidate.progressMeters,
            "snapCrossM": candidate.crossTrackMeters,
            "snapHeadingErrDeg": candidate.headingError,
            "snapScore": candidate.score,
            "snapVisualConf": candidate.visualConfidence ?? NSNull(),
            "announce": announce
        ]))
        let step = routeSteps[candidate.stepIndex]
        let leftPreviousLeg = candidate.stepIndex != currentStepIndex
        currentStepIndex = candidate.stepIndex
        segmentProgressMeters = min(max(candidate.progressMeters, 0), step.edge.distanceMeters)
        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        resetLegCueSchedule()
        recoveryStartedAt = nil
        recoveryReason = nil
        lastRecoveryCueKey = nil
        beliefIssueStartedAt = nil
        lastRecoveredAt = Date()
        arrivalVisualHoldStartedAt = nil
        guidanceIntroProtectedUntil = nil
        resetRouteCorrectionGuards()
        // The snap is the new best belief; drop the conflicting evidence
        // window so the very next update doesn't re-enter the hold loop.
        resetRouteBelief(status: .locked)
        phase = .navigating
        beliefHealthySince = nil
        updateInstruction(forceSpeech: false)
        // A snap that lands on a DIFFERENT leg has quietly walked the user
        // through a turn: `advanceStepOrArrive` is the only thing that speaks a
        // maneuver, and this path bypasses it. What the user heard instead was
        // the new leg's distance — "7 meters toward the next turn" — with no
        // word about the turn that leg starts after. A reviewer caught it twice
        // on 15 Aug 2026 ("missing the actual turn instruction at the point the
        // participant should turn"; "you're turning *before* any instruction").
        //
        // The per-tick alignment cue does not cover this: it waits for the live
        // heading to settle, and a user already turning of their own accord has
        // settled onto the right bearing by the time it looks, so it stays
        // silent and the turn is never spoken at all.
        let bearingError = abs(
            SemanticRouteMath.signedAngleDifference(liveHeading, step.edge.bearingDegrees)
        )
        if leftPreviousLeg, bearingError >= routeTurnAlignmentThresholdDegrees {
            currentInstruction = Self.routeAlignmentInstruction(
                from: liveHeading,
                to: step.edge.bearingDegrees,
                style: turnPhrasing
            )
            emitCue(currentInstruction, priority: .critical)
            lastTurnCueAt = Date()
            lastHeadingAlignmentCueAt = Date()
            lastHeadingAlignmentCueKey = nil
            lastHeadingAlignmentErrorDegrees = bearingError
            // Once they finish it, the resume cue gives them the walk.
            pendingAlignmentResumeCue = true
            rebuildRAGContext()
            return
        }
        // "Realigned, continue" is a promise the pose AND facing are right. A
        // snap that only fixed the position while the heading still disagrees
        // by ~90° (a real trace value) must not tell the user to continue —
        // walking off at that angle is what re-derails the belief seconds
        // later. Stay quiet; the per-tick alignment cue speaks the actual turn
        // from the live heading on the next update.
        let orientationTrusted = candidate.headingError <= recoverySnapTrustedHeadingErrorDegrees ||
            (candidate.visualConfidence ?? 0) >= visualRouteSnapConfidence
        if announce, orientationTrusted {
            currentInstruction = NavLoc.guidanceRealigned()
            emitCue(currentInstruction, priority: .priority)
        }
        rebuildRAGContext()
    }

    private func advanceStepOrArrive() {
        lastRouteAdvanceAt = Date()
        resetRouteCorrectionGuards()
        // A new leg has its own centre line; nothing measured against the old
        // one should throttle or shape the first nudge on this one.
        resetCourseCorrectionState()
        guard currentStepIndex < routeSteps.count - 1 else {
            phase = .arrived
            resetRouteBelief(status: .locked)
            segmentProgressMeters = activeStep?.edge.distanceMeters ?? segmentProgressMeters
            segmentRemainingMeters = 0
            totalRemainingMeters = 0
            recoveryReason = nil
            beliefIssueStartedAt = nil
            arrivalVisualHoldStartedAt = nil
            // The final stub leg was never walked, so arrival is where the user
            // is standing and the facing tells them which way to turn — the
            // whole reason that node was pinned during capture.
            currentInstruction = arrivalFacing.map {
                NavLoc.arrivedAtOnSide(targetName, side: Self.sidePhrase($0.side))
            } ?? NavLoc.arrivedAt(targetName)
            emitCue(currentInstruction, priority: .critical)
            rebuildRAGContext()
            return
        }

        let current = routeSteps[currentStepIndex]
        let next = routeSteps[currentStepIndex + 1]
        let turn = turnInstruction(at: current.to, from: current.edge.bearingDegrees, to: next.edge.bearingDegrees)
        NavigationTrace.shared.log("nav.advance", traceState(extra: [
            "atNode": current.to.name,
            "recordedTurnHint": current.to.turnHint?.rawValue ?? "none",
            "incomingBearing": current.edge.bearingDegrees,
            "outgoingBearing": next.edge.bearingDegrees,
            "signedTurnDeg": SemanticRouteMath.signedAngleDifference(
                next.edge.bearingDegrees,
                current.edge.bearingDegrees
            ),
            "spokenTurn": turn,
            "nextLegDistM": next.edge.distanceMeters
        ]))
        let decisionLandmarkCue = shouldSpeakLandmarks
            ? nearbyLandmarkCue(on: current, after: max(segmentProgressMeters, current.edge.distanceMeters - 0.75))
            : nil
        currentStepIndex += 1
        resetRouteBelief(status: .initializing)
        segmentProgressMeters = 0
        segmentRemainingMeters = next.edge.distanceMeters
        resetLegCueSchedule()
        lastAnnouncedLandmarkID = nil
        recoveryStartedAt = nil
        recoveryReason = nil
        beliefIssueStartedAt = nil
        arrivalVisualHoldStartedAt = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        pendingAlignmentResumeCue = false
        pendingPostTurnLegCueStepIndex = nil
        pendingPostTurnLegCueArmedAt = nil
        stillnessStartedAt = nil
        lastStillnessRepromptAt = nil
        if phase == .recovering { phase = .navigating }
        let nextContext = walkContext(for: next)
        let landmarkPrefix: String
        if let decisionLandmarkCue,
           !announcedLandmarkIDs.contains(decisionLandmarkCue.id) {
            announcedLandmarkIDs.insert(decisionLandmarkCue.id)
            lastAnnouncedLandmarkID = decisionLandmarkCue.id
            landmarkPrefix = "\(decisionLandmarkCue.phrase) "
        } else {
            landmarkPrefix = ""
        }
        // "Walk" belongs on exactly this cue and no other: it is what tells the
        // user the turn is finished and they should start moving again. Pilot
        // participants completed the turn and then stood still waiting for a
        // further instruction. Every later cue on the leg drops back to the
        // bare `legDistance` phrasing, so the word never becomes filler.
        //
        // Unless there is no walk. A leg this short is a dogleg the mapper
        // pinned between two turns, and instructing it produced "Walk less than
        // one meter toward the next turn" — which a reviewer called confusing
        // at best and dangerous at more likely, on 15 Aug 2026, with the note
        // that a distance that short before a turn should convey only the turn
        // information. So it does, and it conveys BOTH turns: the second one is
        // a second away, and springing it on a user already mid-stride is how
        // the same reviewer ended up turning before anything had told them to.
        // A real maneuver is announced ALONE and the walk follows once it has
        // been made — see `pendingPostTurnLegCueStepIndex`. A dogleg keeps its
        // combined form (both ends are one instruction), and a leg entered
        // straight-on has no maneuver to wait for, so it keeps the walk.
        let isRealTurn = next.edge.distanceMeters > microLegMaxMeters
            && !Self.isStraightAheadInstruction(turn)
        if isRealTurn {
            currentInstruction = landmarkPrefix + "\(Self.sentenceCased(turn))."
            pendingPostTurnLegCueStepIndex = currentStepIndex
            pendingPostTurnLegCueArmedAt = Date()
        } else {
            currentInstruction = landmarkPrefix + (
                next.edge.distanceMeters <= microLegMaxMeters
                    ? doglegInstruction(turn: turn, acrossHopTo: next)
                    : NavLoc.turnThenWalkLeg(
                        prefix: "",
                        turn: Self.sentenceCased(turn),
                        distance: Self.formatDistance(next.edge.distanceMeters),
                        context: nextContext
                    )
            )
            // This is the leg's opening cue and the one place its context
            // belongs. Every later distance on it counts down bare.
            noteLegContextSpoken(on: next)
        }
        emitCue(currentInstruction, priority: .critical)
        // This already told them which way to turn, so the alignment cue must
        // not repeat it a tick later while they are still turning.
        lastHeadingAlignmentCueAt = Date()
        lastHeadingAlignmentCueKey = nil
        lastHeadingAlignmentErrorDegrees = nil
        lastTurnCueAt = Date()
    }

    /// Both ends of a hop too short to walk, spoken as one instruction.
    ///
    /// `hop` is the newly active step — already short enough that its distance
    /// is not worth saying — and `turn` is the fragment for the maneuver at its
    /// near end. Called with `currentStepIndex` already advanced onto `hop`.
    private func doglegInstruction(turn: String, acrossHopTo hop: SemanticRouteStep) -> String {
        let first = Self.sentenceCased(turn)
        guard currentStepIndex < routeSteps.count - 1 else {
            // The hop ends at the destination: the user turns and it is there.
            let destination = Self.sanitizedSpokenLabel(
                targetName,
                fallback: NavLoc.defaultDestinationLabel()
            )
            let arrival = arrivalFacing.map {
                NavLoc.destinationAheadOnSide(destination, side: Self.sidePhrase($0.side))
            } ?? NavLoc.destinationJustAhead(destination)
            return NavLoc.turnThenDestination(turn: first, destination: arrival)
        }
        let following = routeSteps[currentStepIndex + 1]
        let secondTurn = turnInstruction(
            at: hop.to,
            from: hop.edge.bearingDegrees,
            to: following.edge.bearingDegrees
        )
        return NavLoc.turnThenTurn(first: first, second: secondTurn)
    }

    /// Uppercases only the first letter — String.capitalized would title-case
    /// every word of multi-word instructions ("Take A Slight Left…").
    /// True when a maneuver phrase is really "keep going" rather than a turn.
    ///
    /// Compared against the localized straight-ahead phrases rather than
    /// matched on English words, so French behaves identically.
    private static func isStraightAheadInstruction(_ turn: String) -> Bool {
        let normalized = turn
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }
        return [NavLoc.continueStraight(), NavLoc.goStraight()]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .contains(normalized)
    }

    /// Releases the walk instruction that a solo turn cue left owed.
    ///
    /// Fires when the user has actually come round onto the new leg, or when
    /// `postTurnLegCueMaxWaitSeconds` expires — whichever first. The timeout is
    /// what keeps the 11 Aug 2026 failure (turn completed, user standing still
    /// waiting for permission to move) from coming back on a turn the heading
    /// never confirms.
    private func releasePostTurnLegCueIfDue(headingError: Double?) {
        guard let armedStep = pendingPostTurnLegCueStepIndex,
              let armedAt = pendingPostTurnLegCueArmedAt,
              let step = activeStep else { return }
        // The leg moved on without it — a rebuild, an advance, an arrival.
        guard armedStep == currentStepIndex else {
            pendingPostTurnLegCueStepIndex = nil
            pendingPostTurnLegCueArmedAt = nil
            return
        }
        guard phase == .navigating else { return }

        let turned = (headingError.map { $0 <= routeStartAlignmentThresholdDegrees } ?? false)
            && !headingIsTiltDerived
        let waited = Date().timeIntervalSince(armedAt) >= postTurnLegCueMaxWaitSeconds
        guard turned || waited else { return }

        pendingPostTurnLegCueStepIndex = nil
        pendingPostTurnLegCueArmedAt = nil
        currentInstruction = NavLoc.legDistance(
            distance: Self.formatDistance(segmentRemainingMeters),
            context: walkContext(for: step)
        )
        noteLegContextSpoken(on: step)
        emitCue(currentInstruction, priority: .critical)
        NavigationTrace.shared.log("nav.postTurnLegCue", traceState(extra: [
            "releasedBy": turned ? "turn_completed" : "timeout",
            "headingErrDeg": headingError ?? NSNull(),
            "waitedSeconds": Date().timeIntervalSince(armedAt)
        ]))
    }

    private static func sentenceCased(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
    }

    /// What this leg is walked toward: a corner, the next turn, a named place,
    /// or just straight on. Straight points are capture artefacts, not places —
    /// "toward Straight point 1" means nothing to someone who can't see it.
    private func walkContext(for step: SemanticRouteStep) -> String {
        if let hint = step.to.turnHint, hint.isCorner { return NavLoc.towardTheCorner() }
        if let hint = step.to.turnHint, hint != .straight { return NavLoc.towardTheNextTurn() }
        if step.to.turnHint == .straight { return NavLoc.straightAheadContext() }
        return NavLoc.towardPlace(Self.spokenNodeLabel(step.to))
    }

    /// A node's name as it should be SPOKEN, with capture bookkeeping stripped.
    ///
    /// Turn nodes are auto-named "Left turn 2" / "Corner 1" at capture time so
    /// the mapper can tell them apart in the inspector. Read aloud, the ordinal
    /// is a number the user cannot use and cannot look for. A hintless turn
    /// node — which is how "10 meters, toward Left turn 2" reached a pilot
    /// participant, since `walkContext` only generalises nodes that still carry
    /// their hint — is caught here by its label instead.
    ///
    /// Real places (destinations, entrances, named landmarks) keep their names:
    /// those are what the user asked for.
    private static func spokenNodeLabel(_ node: SemanticRouteNode) -> String {
        let name = sanitizedSpokenLabel(node.name)
        if let hint = node.turnHint {
            switch hint {
            case .left: return NavLoc.theLeftTurn()
            case .right: return NavLoc.theRightTurn()
            case .corner, .cornerLeft, .cornerRight: return NavLoc.theCornerLabel()
            case .straight: break
            }
        }
        guard node.kind == .intersection || name.isEmpty else { return name }
        // Auto-generated labels are always built from `SemanticTurnHint
        // .nodeName` plus an ordinal, in English, whatever the app language is.
        let lowered = name.lowercased()
        if lowered.hasPrefix("left turn") { return NavLoc.theLeftTurn() }
        if lowered.hasPrefix("right turn") { return NavLoc.theRightTurn() }
        if lowered.hasPrefix("corner") || lowered.hasPrefix("left corner")
            || lowered.hasPrefix("right corner") {
            return NavLoc.theCornerLabel()
        }
        if name.isEmpty || lowered.hasPrefix("turn") || lowered.hasPrefix("straight point") {
            return NavLoc.theNextTurnLabel()
        }
        return name
    }

    // MARK: - Session trace

    /// Every spoken cue goes through here so the trace records which function
    /// produced it. "Turn right" and "turn around" arriving back to back are
    /// indistinguishable in a log that only has the words — knowing one came
    /// from `issueHeadingAlignmentCueIfNeeded` and the other from
    /// `updateRecoveryIfNeeded` is the whole diagnosis.
    private func emitCue(
        _ text: String,
        priority: SemanticSpeechPriority,
        caller: String = #function,
        line: Int = #line
    ) {
        speechCue = SemanticSpeechCue(text: text, priority: priority)
        // Every spoken cue — turn, recovery, alignment, arrival — starts the
        // routine pacing window. An approach or reassurance cue landing right
        // behind a maneuver cue is exactly the stacking the pacing floor
        // exists to prevent, so the window is kept here rather than at each
        // routine call site.
        lastRoutineCueAt = Date()
        NavigationTrace.shared.log("cue", traceState(extra: [
            "text": text,
            "priority": String(describing: priority),
            "from": caller,
            "line": line
        ]))
    }

    /// Guidance state at ~4 Hz, plus an immediate sample whenever the leg, the
    /// phase or the belief status changes so no transition can hide between
    /// two throttled ticks.
    private func traceNavigationTick(
        visualMatch: VisualRouteMatch?,
        pdrDelta: Double,
        gatedDelta: Double,
        isMoving: Bool
    ) {
        let now = Date()
        let changed = currentStepIndex != traceLastStepIndex ||
            phase != traceLastPhase ||
            routeLocalizationStatus != traceLastRouteStatus
        let due = traceLastTickAt.map { now.timeIntervalSince($0) >= 0.25 } ?? true
        guard changed || due else { return }
        traceLastTickAt = now
        traceLastStepIndex = currentStepIndex
        traceLastPhase = phase
        traceLastRouteStatus = routeLocalizationStatus

        var extra: [String: Any] = [
            "pdrDeltaM": pdrDelta,
            "gatedDeltaM": gatedDelta,
            "pdrCapped": lastPDRDeltaWasCapped,
            "moving": isMoving,
            "instruction": currentInstruction
        ]
        if let visualMatch {
            extra["visualStep"] = visualMatch.stepIndex
            extra["visualProgressM"] = visualMatch.progressMeters
            extra["visualConf"] = visualMatch.confidence
            extra["visualAliased"] = visualMatch.isAliased
            extra["visualLandmark"] = visualMatch.landmarkName ?? NSNull()
        }
        if changed { extra["transition"] = true }
        NavigationTrace.shared.tick("nav.tick", traceState(extra: extra))
    }

    private func traceState(extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "phase": phase.rawValue,
            "target": targetName,
            "stepIndex": currentStepIndex,
            "stepCount": routeSteps.count,
            "progressM": segmentProgressMeters,
            "remainingM": segmentRemainingMeters,
            "totalRemainingM": totalRemainingMeters,
            "beliefStatus": routeLocalizationStatus.rawValue,
            "beliefConf": routeBeliefState.confidence,
            "beliefMargin": routeBeliefState.margin,
            "beliefUncM": routeBeliefState.uncertaintyMeters,
            "beliefSafe": routeBeliefState.isInstructionSafe,
            "beliefEvidence": routeBeliefState.evidenceSummary,
            "arLocalized": traceARLocalized,
            "confidence": confidence,
            "travelledM": cumulativeTravelMeters
        ]
        if let step = activeStep {
            fields["legFrom"] = step.from.name
            fields["legTo"] = step.to.name
            fields["legBearing"] = step.edge.bearingDegrees
            fields["legDistM"] = step.edge.distanceMeters
            fields["legEdgeId"] = step.edge.id
            fields["legTurnHint"] = step.to.turnHint?.rawValue ?? "none"
        }
        if let heading = traceLiveHeading { fields["heading"] = heading }
        // `heading` above is MAP-frame; `ar.frame`'s `headingDeg` is raw ARKit.
        // Without this field the two columns differ by an unexplained constant
        // and the next trace reader has to guess which one lies.
        if mapFrameYawBiasDegrees != 0 { fields["mapFrameYawBiasDeg"] = mapFrameYawBiasDegrees }
        if let headingError = traceHeadingError { fields["headingErrDeg"] = headingError }
        if let crossTrack = traceCrossTrack { fields["crossM"] = crossTrack }
        if let alongTrack = traceAlongTrack { fields["alongM"] = alongTrack }
        if let pose = tracePose {
            fields["x"] = pose.x
            fields["y"] = pose.y
        }
        if let recoveryReason { fields["recoveryReason"] = recoveryReason }
        for (key, value) in extra { fields[key] = value }
        return fields
    }

    /// The shaped legs guidance will actually walk, as spoken distances and
    /// bearings — the thing to diff against the captured graph.
    private func traceLegs() -> [[String: Any]] {
        routeSteps.enumerated().map { index, step in
            [
                "i": index,
                "from": step.from.name,
                "to": step.to.name,
                "distM": step.edge.distanceMeters,
                "bearing": step.edge.bearingDegrees,
                "edgeId": step.edge.id,
                "turnHintAtEnd": step.to.turnHint?.rawValue ?? "none",
                "spokenTurnAtEnd": index + 1 < routeSteps.count
                    ? turnInstruction(
                        at: step.to,
                        from: step.edge.bearingDegrees,
                        to: routeSteps[index + 1].edge.bearingDegrees
                    )
                    : "arrive"
            ]
        }
    }

    private func traceMapGraph(_ map: SemanticRouteMap) -> [String: Any] {
        [
            "id": map.id,
            "name": map.name,
            "coordinateSpace": map.coordinateSpace,
            "axisConvention": map.axisConvention ?? 1,
            "arWorldMapId": map.arWorldMapId ?? NSNull(),
            "nodes": map.nodes.map { node in
                [
                    "id": node.id,
                    "name": node.name,
                    "kind": node.kind.rawValue,
                    "turnHint": node.turnHint?.rawValue ?? "none",
                    "x": node.point.x,
                    "y": node.point.y,
                    "headingDeg": node.headingDegrees ?? NSNull()
                ] as [String: Any]
            },
            "edges": map.edges.map { edge in
                [
                    "id": edge.id,
                    "from": edge.fromNodeID,
                    "to": edge.toNodeID,
                    "distM": edge.distanceMeters,
                    "bearing": edge.bearingDegrees,
                    "reverseBearing": edge.reverseBearingDegrees
                ] as [String: Any]
            },
            "keyframeCount": map.keyframes?.count ?? 0,
            "fingerprintCount": map.visualFingerprints?.count ?? 0
        ]
    }

    private func updateInstruction(forceSpeech: Bool) {
        guard let step = activeStep else {
            currentInstruction = activeMap == nil ? "Capture or load a semantic map." : "Semantic map ready."
            return
        }

        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        totalRemainingMeters = routeSteps.enumerated().reduce(0) { partial, pair in
            if pair.offset < currentStepIndex { return partial }
            if pair.offset == currentStepIndex { return partial + segmentRemainingMeters }
            return partial + pair.element.edge.distanceMeters
        }

        // Countdown cues are floored by the live AR distance to the node:
        // dead-reckoned progress alone announces turns early when the step
        // model overshoots. Capped at the leg length so a pose that disagrees
        // with the route belief can't speak a distance the leg doesn't have —
        // "walk 10 meters" on a 1.4 m leg is how the belief error reaches the
        // user as a bogus instruction instead of as recovery.
        let cueRemainingMeters = lastARNodeDistanceMeters
            .map { min(step.edge.distanceMeters, max(segmentRemainingMeters, $0)) }
            ?? segmentRemainingMeters

        let context = walkContext(for: step)
        if cueRemainingMeters <= turnPreannouncementMeters, currentStepIndex < routeSteps.count - 1 {
            let next = routeSteps[currentStepIndex + 1]
            let turn = turnInstruction(at: step.to, from: step.edge.bearingDegrees, to: next.edge.bearingDegrees)
            if cueRemainingMeters <= turnAnnouncementThresholdMeters {
                // At the turn there is nothing left to say but the turn. "At
                // the turn, turn right" spent its first three words on a fact
                // the user was already standing in.
                currentInstruction = "\(Self.sentenceCased(turn))."
            } else {
                // Bare fragment, NOT sentence-cased. `turnInDistance` leads
                // with the distance, so the capital belongs to that — this site
                // was producing "In 3 meters, Turn right." with a stray capital
                // mid-sentence while `approachCuePhrase` produced the correct
                // form for the identical cue.
                currentInstruction = NavLoc.turnInDistance(
                    turn: turn,
                    distance: Self.formatDistance(cueRemainingMeters)
                )
            }
        } else if currentStepIndex >= routeSteps.count - 1,
                  (lastARNodeDistanceMeters ?? cueRemainingMeters) <= destinationJustAheadMeters {
            // Final approach: "keep walking X meters" reads as being lost when
            // the target is within arm's-plus reach. With a facing the target
            // is beside the route, not down it — saying "just ahead" would walk
            // the user straight past it.
            let destination = Self.sanitizedSpokenLabel(targetName, fallback: NavLoc.defaultDestinationLabel())
            currentInstruction = arrivalFacing.map {
                NavLoc.destinationAheadOnSide(destination, side: Self.sidePhrase($0.side))
            } ?? NavLoc.destinationJustAhead(destination)
        } else {
            // No landmark clause here. `nearbyLandmarkCue` below already
            // announces the landmark as its own cue, timed to when the user
            // reaches it; appending it to the leg distance said the same thing
            // a second time and turned the opening cue into "Onions is 25
            // meters away. 6 meters, toward the next turn. Passing Biscuits
            // ahead in less than one meter." — three clauses before the user
            // has taken a step, one of which was about a shelf they were
            // already standing at. Pilot feedback, 11 Aug 2026: too much text
            // at the start.
            // The context is the leg's, not this sentence's. Once it has been
            // said for this edge every later cue on it is a bare number, which
            // is what turns "20 meters toward the next turn / 19 meters toward
            // the next turn / 16 meters toward the next turn" into "20 meters
            // toward the next turn / 19 / 16".
            currentInstruction = spokenLegContextEdgeID == step.edge.id
                ? NavLoc.distanceOnly(Self.formatDistance(cueRemainingMeters))
                : NavLoc.legDistance(distance: Self.formatDistance(cueRemainingMeters), context: context)
        }

        let pastIntroProtection = guidanceIntroProtectedUntil.map { Date() >= $0 } ?? true
        if confidence < 0.45, pastIntroProtection {
            // Say it once per stretch of weak tracking, not on every cue.
            let now = Date()
            let prefixAge = lastTrackingLimitedPrefixAt.map { now.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            if prefixAge >= trackingLimitedPrefixCooldownSeconds {
                currentInstruction = NavLoc.trackingLimitedPrefix() + currentInstruction
                lastTrackingLimitedPrefixAt = now
            }
        }

        // Ahead of the intro protection and the pacing floor both: walking away
        // from the destination is the one thing on this leg the user cannot
        // afford to hear late, and every cue below it describes a route that is
        // now behind them.
        if speakDestinationOvershootIfDue() { return }

        let routineSpeechAllowed = forceSpeech || guidanceIntroProtectedUntil.map { Date() >= $0 } ?? true
        guard routineSpeechAllowed else { return }

        if forceSpeech {
            // A forced re-announcement is always a repeat of something the user
            // has already been told, so it speaks the short resumption form
            // rather than the leg cue verbatim. See `resumeWalkCue`.
            emitCue(resumeWalkCue(), priority: .priority)
            return
        }

        if shouldSpeakLandmarks,
           let landmarkCue = nearbyLandmarkCue(on: step, after: segmentProgressMeters),
           !announcedLandmarkIDs.contains(landmarkCue.id) {
            lastAnnouncedLandmarkID = landmarkCue.id
            announcedLandmarkIDs.insert(landmarkCue.id)
            emitCue(landmarkCue.phrase, priority: .priority)
            return
        }

        if speakDestinationApproachIfDue(remainingMeters: cueRemainingMeters) { return }
        if speakApproachCueIfDue(on: step, remainingMeters: cueRemainingMeters) { return }
        if speakWalkProgressCueIfDue(on: step, remainingMeters: cueRemainingMeters) { return }
        // ⚠️ Exactly one distance beat per leg now, from the call above.
        //
        // There used to be one every 2 m above the 5 m floor, which on a 23 m
        // leg spoke "23 meters toward the next turn", then 21, 18, 15, 11, 8,
        // then "in 3 meters, turn left". A reviewer's verdict on 3 Sep 2026:
        // everything between the first and the last of those is noise the user
        // is forced to listen to. They are not decisions — the leg was already
        // named, and the turn is announced at 3 m regardless.
        // Anything longer than that is carried by the 20 s quiet-period
        // backstop, which counts seconds rather than metres — so a slow walker
        // on a very long leg still gets told the system has them, and a brisk
        // one is not read a list of numbers.
        speakQuietPeriodReassuranceIfDue(remainingMeters: cueRemainingMeters)
    }

    /// The user has walked past the destination and is still walking.
    ///
    /// Nothing used to say so. `segmentProgressMeters` saturates at the end of
    /// the leg and `cueRemainingMeters` is capped by the leg length, so the
    /// guidance model's most emphatic statement about an overshoot is "about 1
    /// meter, toward Onions" — which is what a pilot participant heard on
    /// repeat, walking away, until they worked it out for themselves.
    ///
    /// Returns true when it spoke, so the routine cue for a leg the user has
    /// left behind does not follow it out.
    private func speakDestinationOvershootIfDue() -> Bool {
        guard phase == .navigating || phase == .recovering,
              currentStepIndex >= routeSteps.count - 1,
              let overshoot = destinationOvershootDistanceMeters,
              overshoot >= destinationOvershootMeters else {
            destinationOvershootStartedAt = nil
            return false
        }

        let now = Date()
        guard let since = destinationOvershootStartedAt else {
            destinationOvershootStartedAt = now
            return false
        }
        guard now.timeIntervalSince(since) >= destinationOvershootHoldSeconds else {
            return false
        }

        let isFirstCue = lastDestinationOvershootCueAt == nil
        if let last = lastDestinationOvershootCueAt,
           now.timeIntervalSince(last) < destinationOvershootRepeatSeconds {
            return false
        }
        lastDestinationOvershootCueAt = now

        let destination = Self.sanitizedSpokenLabel(
            targetName,
            fallback: NavLoc.defaultDestinationLabel()
        )
        // First call names the correction; repeats give the distance back, so
        // someone who has already turned around hears progress rather than the
        // same sentence.
        currentInstruction = isFirstCue
            ? NavLoc.passedDestinationTurnAround(destination)
            : NavLoc.passedDestinationWalkBack(
                destination,
                distance: Self.formatDistance(overshoot)
            )
        NavigationTrace.shared.log("nav.destinationOvershoot", traceState(extra: [
            "overshootM": overshoot,
            "heldSeconds": now.timeIntervalSince(since),
            "text": currentInstruction
        ]))
        emitCue(currentInstruction, priority: .critical)
        return true
    }

    /// The last thing spoken before arrival is what tells a blind user to slow
    /// down and get ready to reach. The old meter countdown carried it by
    /// accident at "one meter"; with the countdown gone it is explicit and
    /// fires once per route. It keeps a short floor of its own so it cannot
    /// land on the heels of the "in 3 meters" cue, but it is only ever delayed
    /// by it — arrival is a decision, not chatter.
    private func speakDestinationApproachIfDue(remainingMeters: Double) -> Bool {
        guard phase == .navigating,
              currentStepIndex >= routeSteps.count - 1,
              !spokenDestinationApproachCue,
              (lastARNodeDistanceMeters ?? remainingMeters) <= destinationJustAheadMeters else {
            return false
        }
        // Room to breathe after the "in 3 meters" cue. Both fire inside the
        // final couple of metres, and stacked back to back they read as one
        // run-on sentence rather than two stages of an approach. Not dropped —
        // held, and spoken on a later tick.
        if let last = lastRoutineCueAt,
           Date().timeIntervalSince(last) < destinationApproachMinimumSpacingSeconds {
            return false
        }
        spokenDestinationApproachCue = true
        emitCue(currentInstruction, priority: .priority)
        return true
    }

    /// Counts the leg down to its maneuver: "Turn left in 3 meters." → "2." →
    /// "1." The gate decides *when* to speak; the phrase always carries the
    /// live distance, so a cue delayed by the pacing floor still states the
    /// distance the user actually has left.
    private func speakApproachCueIfDue(on step: SemanticRouteStep, remainingMeters: Double) -> Bool {
        guard phase == .navigating else { return false }
        let isFinalLeg = currentStepIndex >= routeSteps.count - 1
        // The final leg gets the naming cue and nothing else. "Beer in 3
        // meters." → "2." → "Beer is just ahead." → "Arrived at Beer." was four
        // announcements inside three metres of walking, which a reviewer heard
        // on 15 Aug 2026 as everything happening at once. Approaching a shelf,
        // the bare beats add no decision the arrival cue does not already carry.
        let gates = isFinalLeg
            ? (approachCueGatesMeters.max().map { [$0] } ?? [])
            : approachCueGatesMeters
        let eligible = gates.filter { gate in
            gate < (lastSpokenApproachGateMeters ?? .greatestFiniteMagnitude)
                && remainingMeters <= gate
                && step.edge.distanceMeters >= gate + approachGateHeadroomMeters
        }
        // Nearest gate the user has crossed. Taking the largest instead would
        // announce "in 3 meters" to someone standing 1 m out whenever two
        // gates fall inside one pacing window.
        guard let gate = eligible.min() else { return false }

        // Already at the node as far as the pose is concerned — the turn cue
        // owns this space. Retire the gate so a stale beat cannot surface a
        // second later, but say nothing.
        if let arDistance = lastARNodeDistanceMeters, arDistance <= approachCueSuppressWithinMeters {
            lastSpokenApproachGateMeters = gate
            return false
        }

        let now = Date()
        // Once the maneuver has been named, the rest of the gates are one- or
        // two-word countdown beats and no floor applies to them: the last 3 m
        // of a leg is walked in a couple of seconds, and a floor there would
        // leave the user counting down to nothing. The first cue on the leg —
        // the one carrying the instruction — waits only long enough not to
        // land on the heels of another cue, and is retried on the next tick
        // rather than dropped.
        if !spokenLegManeuverCue,
           let last = lastRoutineCueAt,
           now.timeIntervalSince(last) < approachCueMinimumSpacingSeconds {
            return false
        }
        // Every larger gate is now behind the user, so mark this one spoken and
        // let the guard above retire the rest.
        lastSpokenApproachGateMeters = gate
        emitCue(approachCuePhrase(on: step, remainingMeters: remainingMeters), priority: .priority)
        return true
    }

    /// One bare-distance confirmation, partway along the leg.
    ///
    /// Placed by proportion rather than by a fixed interval — see
    /// `walkProgressBeatCount` for the two pieces of field feedback that
    /// forced that. On an 8 m leg it lands around 6 m; on a 23 m leg around
    /// 13 m; on either it is the ONLY thing said between the leg's opening
    /// instruction and the 3 m turn announcement.
    ///
    /// The phrase always carries the live distance, so a beat delayed by the
    /// pacing floor still states what the user actually has left.
    private func speakWalkProgressCueIfDue(on step: SemanticRouteStep, remainingMeters: Double) -> Bool {
        guard phase == .navigating, !spokenLegProgressBeat else { return false }
        // Below the floor the approach gates own the cadence.
        guard remainingMeters > walkProgressBeatFloorMeters else { return false }

        let legDistance = step.edge.distanceMeters
        guard legDistance >= walkProgressBeatMinimumLegMeters else { return false }

        // Evenly spaced between the leg's start and the floor. With a count of
        // one that is the midpoint of the walkable stretch.
        let span = legDistance - walkProgressBeatFloorMeters
        guard span > 0 else { return false }
        let dueAt = walkProgressBeatFloorMeters + span * Double(walkProgressBeatCount) / Double(walkProgressBeatCount + 1)
        guard remainingMeters <= dueAt else { return false }

        if let last = lastRoutineCueAt,
           Date().timeIntervalSince(last) < walkProgressBeatMinimumSpacingSeconds {
            // Not dropped — retried on the next tick, where it will speak
            // whatever distance is true then.
            return false
        }

        spokenLegProgressBeat = true
        emitCue(NavLoc.distanceOnly(Self.formatDistance(remainingMeters)), priority: .regular)
        return true
    }

    /// Backstop for long legs: a 25 m straight has no gate between its start
    /// and 3 m to go, and a blind walker has nothing but the cues to confirm
    /// the system still has them. Speaks the bare remaining distance — the
    /// full instruction was already spoken when the leg started, and repeating
    /// "12 meters toward the next turn" verbatim is the repetition that made
    /// the guidance feel like it was filling silence rather than reporting.
    private func speakQuietPeriodReassuranceIfDue(remainingMeters: Double) {
        guard phase == .navigating else { return }
        let now = Date()
        guard let last = lastRoutineCueAt else {
            lastRoutineCueAt = now
            return
        }
        guard now.timeIntervalSince(last) >= routineCueQuietMaxSeconds else { return }
        emitCue(NavLoc.distanceOnly(Self.formatDistance(remainingMeters)), priority: .regular)
    }

    /// What an approach gate says. The first gate crossed on a leg names the
    /// maneuver waiting at the end of it — "4 meters" alone is 4 meters of
    /// what? — and every gate after it is the bare distance, because by then
    /// the user is counting down to something they have already been told.
    private func approachCuePhrase(on step: SemanticRouteStep, remainingMeters: Double) -> String {
        let distance = Self.formatDistance(remainingMeters)
        guard !spokenLegManeuverCue else {
            return NavLoc.distanceOnly(Self.formatCountdownDistance(remainingMeters))
        }
        spokenLegManeuverCue = true
        guard currentStepIndex < routeSteps.count - 1 else {
            let destination = Self.sanitizedSpokenLabel(targetName, fallback: NavLoc.defaultDestinationLabel())
            return NavLoc.destinationInDistance(destination, distance: distance)
        }
        let next = routeSteps[currentStepIndex + 1]
        let turn = turnInstruction(at: step.to, from: step.edge.bearingDegrees, to: next.edge.bearingDegrees)
        // Bare fragment, not sentence-cased: `turnInDistance` now leads with
        // the distance, so the capital belongs to that.
        return NavLoc.turnInDistance(turn: turn, distance: distance)
    }

    /// What to SAY when re-announcing a leg the user is already walking.
    ///
    /// Three paths re-state an in-progress leg: the stillness reprompt, the
    /// resumption after a corrective turn, and the exit from recovery. All
    /// three used to re-speak `currentInstruction`, which on an ordinary leg is
    /// the full "8 meters toward the next turn" — so a reviewer heard that
    /// sentence twice inside five seconds, and heard its context clause again
    /// at 8, 7, 6 and 3 metres of the same leg. Nothing about the leg has
    /// changed; only the distance has. "Walk 8 meters." says that, and its verb
    /// is what makes it a resumption rather than a countdown beat.
    ///
    /// Anything that is NOT a routine leg cue — an arrival, an overshoot, a
    /// turn — is passed through untouched: those sentences are the message.
    private func resumeWalkCue() -> String {
        guard phase == .navigating, let step = activeStep else { return currentInstruction }
        let context = walkContext(for: step)
        let distance = Self.formatDistance(
            lastARNodeDistanceMeters
                .map { min(step.edge.distanceMeters, max(segmentRemainingMeters, $0)) }
                ?? segmentRemainingMeters
        )
        // A routine leg cue now has TWO shapes, not one: the leg's opening cue
        // carries its context ("8 meters toward the next turn."), and every
        // later cue on the same edge is the bare number ("8 meters.") once
        // `spokenLegContextEdgeID` has claimed it. Matching only the first
        // shape meant that for nearly the whole of every leg this guard fell
        // through and handed the countdown beat straight back — so the three
        // resumptions spoke "Good. 8 meters." where the verb is the entire
        // point of the cue. That is the exact failure this function was
        // written to prevent: pilot participants finished a corrective turn
        // and stood still, waiting for something to tell them to walk.
        let isRoutineLegCue = currentInstruction == NavLoc.legDistance(distance: distance, context: context)
            || currentInstruction == NavLoc.distanceOnly(distance)
        guard isRoutineLegCue else { return currentInstruction }
        return NavLoc.walkDistance(distance)
    }

    /// Clears the per-leg speech schedule so a new or re-anchored leg announces
    /// its own gates from the top.
    private func resetLegCueSchedule() {
        lastSpokenApproachGateMeters = nil
        spokenLegProgressBeat = false
        spokenDestinationApproachCue = false
        spokenLegManeuverCue = false
        destinationOvershootStartedAt = nil
        lastDestinationOvershootCueAt = nil
        destinationOvershootWalkMeters = 0
        lastRoutineCueAt = Date()
        // Reaching a new leg is the clearest evidence there is that the user
        // is where the route wants them.
        resetCorrectiveCueBackoff()
    }

    private func rebuildRAGContext() {
        let segment: SemanticRouteRAGContext.Segment?
        if let step = activeStep {
            segment = SemanticRouteRAGContext.Segment(
                from: step.from.name,
                to: step.to.name,
                distanceMeters: step.edge.distanceMeters,
                remainingMeters: segmentRemainingMeters,
                bearingDegrees: step.edge.bearingDegrees,
                leftContext: step.edge.leftContext,
                rightContext: step.edge.rightContext,
                spokenContext: step.edge.spokenContext
            )
        } else {
            segment = nil
        }

        let nearby = nearbyLandmarkNames()
        let context = SemanticRouteRAGContext(
            mapName: activeMap?.name ?? "none",
            target: targetName,
            phase: phase.displayName,
            instruction: currentInstruction,
            confidence: confidence,
            routeStatus: routeLocalizationStatus.displayName,
            isInstructionSafe: routeBeliefState.isInstructionSafe,
            routeRemainingMeters: totalRemainingMeters,
            currentSegment: segment,
            nearbyLandmarks: nearby,
            recoveryReason: recoveryReason,
            hardRules: [
                "Do not invent distances, turns, targets, hazards, or landmarks.",
                "Only verbalize the provided deterministic route state.",
                "If isInstructionSafe is false, do not speak normal walking guidance.",
                "When phase is Recovering, tell the user to pause and relocalize before walking."
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(context), let json = String(data: data, encoding: .utf8) {
            ragContextJSON = json
        } else {
            ragContextJSON = "{}"
        }
    }

    private func resetRouteCorrectionGuards() {
        pendingProgressCorrection = nil
        pendingRouteAdvance = nil
    }

    private func nearbyLandmarkNames() -> [String] {
        guard let map = activeMap, let step = activeStep else { return [] }
        let ids = Set([step.from.id, step.to.id])
        let edgeID = Self.baseEdgeID(step.edge.id)
        return map.landmarks
            .filter { landmark in
                ids.contains(landmark.nodeID) || landmark.edgeID == edgeID
            }
            .sorted { $0.priority > $1.priority }
            .compactMap { landmark in
                let name = Self.sanitizedSpokenLabel(landmark.name)
                guard !name.isEmpty else { return nil }
                if let context = Self.sanitizedSpokenLabel(landmark.context ?? "").nilIfBlank {
                    return "\(name): \(context)"
                }
                return name
            }
    }

    private func nextLandmarkPhrase(on step: SemanticRouteStep, after progressMeters: Double) -> String? {
        guard let map = activeMap else { return nil }
        let reversed = step.edge.id.hasSuffix(".reverse")
        let edgeID = Self.baseEdgeID(step.edge.id)
        return map.landmarks.compactMap { landmark -> (ahead: Double, phrase: String)? in
            guard let landmarkProgress = landmarkProgressMeters(for: landmark, on: step, baseEdgeID: edgeID, reversed: reversed) else {
                return nil
            }
            let ahead = landmarkProgress - progressMeters
            guard ahead >= 0.25, ahead <= 4.0 else { return nil }
            let side = Self.side(landmark.side, reversed: reversed)
            let name = Self.sanitizedSpokenLabel(landmark.name)
            guard !name.isEmpty else { return nil }
            return (ahead, NavLoc.landmarkAhead(
                name: name,
                side: Self.sidePhrase(side),
                distance: Self.formatDistance(ahead)
            ))
        }
        .min { $0.ahead < $1.ahead }?
        .phrase
    }

    private func nearbyLandmarkCue(on step: SemanticRouteStep, after progressMeters: Double) -> (id: String, phrase: String)? {
        guard let map = activeMap else { return nil }
        let reversed = step.edge.id.hasSuffix(".reverse")
        let edgeID = Self.baseEdgeID(step.edge.id)
        return map.landmarks.compactMap { landmark -> (ahead: Double, id: String, phrase: String)? in
            guard let landmarkProgress = landmarkProgressMeters(for: landmark, on: step, baseEdgeID: edgeID, reversed: reversed) else {
                return nil
            }
            let ahead = landmarkProgress - progressMeters
            guard ahead >= -0.9, ahead <= 3.0 else { return nil }
            let side = Self.side(landmark.side, reversed: reversed)
            let name = Self.sanitizedSpokenLabel(landmark.name)
            guard !name.isEmpty else { return nil }
            if ahead > 1.0 {
                let phrase = NavLoc.landmarkAhead(
                    name: name,
                    side: Self.sidePhrase(side),
                    distance: Self.formatDistance(ahead)
                )
                return (ahead, landmark.id, "\(phrase).")
            }
            let phrase = NavLoc.passingLandmark(name: name, side: Self.sidePhrase(side))
            return (abs(ahead), landmark.id, "\(phrase).")
        }
        .min { $0.ahead < $1.ahead }
        .map { ($0.id, $0.phrase) }
    }

    private func currentVisualRouteMatch(
        capturedImage: CVPixelBuffer?,
        timestamp: TimeInterval,
        liveHeading: Double? = nil
    ) -> VisualRouteMatch? {
        guard let map = activeMap,
              let fingerprints = map.visualFingerprints,
              !fingerprints.isEmpty,
              !routeSteps.isEmpty else {
            lastVisualRouteMatch = nil
            return nil
        }

        if timestamp - lastVisualRouteMatchAt < visualRouteMatchInterval {
            return lastVisualRouteMatch
        }

        lastVisualRouteMatchAt = timestamp
        guard let capturedImage,
              let liveFingerprint = frameFingerprinter.makeFingerprint(from: capturedImage) else {
            lastVisualRouteMatch = nil
            return nil
        }

        // ⚠️ The heading gate is only legitimate once the live heading has been
        // corroborated at least once. Applying it from the first frame is
        // circular: it discards every keyframe that disagrees with the live
        // heading, so when the AR frame's yaw is the thing that is wrong, the
        // correct keyframes are exactly the ones thrown away — and the one
        // pose-independent mechanism that could expose the bad yaw is disabled
        // by the bad yaw. The 2026-07-29 IGA session shows it: 121 fingerprints
        // in the map, 29–37 eligible after the ±100° gate, one weak match, and a
        // frame ~140° out for the whole run. Match ungated until something lands;
        // once one has, the gate is earned and worth having for its real purpose
        // (rejecting the opposite-direction capture of the same aisle).
        let gateHeading = didCorroborateHeadingVisually ? liveHeading : nil
        let eligible = visualRouteCandidates(in: map, fingerprints: fingerprints, liveHeading: gateHeading)
        // How close the best candidate came, whether or not it passed. With a
        // 0.68 confidence bar the raw similarity has to clear ~0.80, and a
        // field run matched NOTHING across a whole journey with 41 keyframes
        // loaded — leaving the threshold and the matcher indistinguishable as
        // causes. Recording the near-miss makes the bar calibratable against
        // real corridors instead of guessed at.
        var bestSimilarity: Float = 0
        for candidate in eligible {
            bestSimilarity = max(bestSimilarity, frameFingerprinter.similarity(liveFingerprint, candidate.fingerprint))
        }
        lastVisualBestSimilarity = Double(bestSimilarity)
        lastVisualCandidateCount = eligible.count

        let matches = eligible
            .compactMap { candidate -> VisualRouteMatch? in
                let similarity = frameFingerprinter.similarity(liveFingerprint, candidate.fingerprint)
                let isAliased = isVisualFingerprintAliased(candidate.fingerprintID, in: map)
                let confidence = max(0, visualConfidence(from: similarity) - (isAliased ? 0.18 : 0))
                guard confidence >= visualRouteMinimumConfidence else { return nil }
                return VisualRouteMatch(
                    stepIndex: candidate.stepIndex,
                    progressMeters: candidate.progressMeters,
                    confidence: confidence,
                    keyframeID: candidate.keyframeID,
                    landmarkID: candidate.landmarkID,
                    landmarkName: candidate.landmarkName,
                    fingerprintID: candidate.fingerprintID,
                    isAliased: isAliased,
                    cue: candidate.cue
                )
            }
            .sorted { $0.confidence > $1.confidence }

        guard let best = matches.first else {
            lastVisualRouteMatch = nil
            return nil
        }

        if let second = matches.dropFirst().first,
           best.confidence - second.confidence < visualRouteAmbiguousGap {
            guard isSameRoutePlace(
                stepIndex: best.stepIndex,
                progressMeters: best.progressMeters,
                otherStepIndex: second.stepIndex,
                otherProgressMeters: second.progressMeters
            ) else {
                lastVisualRouteMatch = nil
                return nil
            }
        }

        // A match that survived the ambiguity check is independent evidence
        // about where the camera is looking, which is what earns the heading
        // gate for every later frame. Measure the offset between the keyframe's
        // saved map-frame heading and the live one while we have both: a large,
        // consistent offset means the AR frame's yaw is rotated relative to the
        // map, and it is the only absolute yaw evidence available on-device
        // (there is no magnetometer anywhere in this app).
        if let liveHeading,
           let keyframeID = best.keyframeID,
           let keyframeHeading = (map.keyframes ?? [])
               .first(where: { $0.id == keyframeID })?.headingDegrees {
            let offset = SemanticRouteMath.signedAngleDifference(keyframeHeading, liveHeading)
            // `log`, not `tick`: this fires only on an accepted match (rare), and
            // it is the only absolute yaw evidence the device can produce. Losing
            // it to the tick soft-limit on a long journey would lose the one
            // measurement that says whether the map frame is rotated.
            NavigationTrace.shared.log("nav.visualYaw", [
                "keyframeID": keyframeID,
                "keyframeHeadingDeg": keyframeHeading,
                "liveHeadingDeg": liveHeading,
                "offsetDeg": offset,
                "confidence": best.confidence,
                "gateWasApplied": didCorroborateHeadingVisually,
                "biasDeg": mapFrameYawBiasDegrees
            ])
            ingestVisualYawResidual(offset, match: best)
        }
        didCorroborateHeadingVisually = true
        lastVisualRouteMatch = best
        return best
    }

    // MARK: - Map-frame yaw bias

    /// The live AR heading expressed in the saved map's frame. Every consumer
    /// of a heading — guidance, the overlay, the on-screen error readout — must
    /// go through this, or they disagree about which way the user is facing.
    func mapFrameHeading(_ arHeading: Double?) -> Double? {
        guard let arHeading else { return nil }
        guard mapFrameYawBiasDegrees != 0 else { return arHeading }
        return SemanticRouteMath.normalizedDegrees(arHeading + mapFrameYawBiasDegrees)
    }

    /// Route polyline rotated out of the map's frame and into the live ARKit
    /// world frame, for the floor overlay.
    ///
    /// The overlay used to write route coordinates straight into AR world
    /// coordinates, which is only correct while the two frames agree. When they
    /// do not, the arrows are drawn rotated — the "route drifts off through the
    /// wall" screenshot — even though the route data is perfect. The rotation is
    /// centred on the user rather than on the map origin: their AR position is
    /// the one place the two frames are known to coincide, so the path always
    /// starts at their feet and only its direction is corrected.
    func arFrameRoutePolyline(userARPosition: SIMD3<Float>) -> [SemanticRoutePoint] {
        let polyline = remainingRoutePolyline()
        guard mapFrameYawBiasDegrees != 0, !polyline.isEmpty else { return polyline }
        let user = SemanticRoutePoint(x: Double(userARPosition.x), y: -Double(userARPosition.z))
        let radians = mapFrameYawBiasDegrees * .pi / 180.0
        let cosBias = cos(radians)
        let sinBias = sin(radians)
        return polyline.map { point in
            // Headings here are compass-style: measured clockwise from +y, so a
            // point at bearing B sits at (sin B, cos B). Re-expressing a
            // map-frame bearing B in the AR frame means B − bias, which on the
            // components is this rotation.
            let dx = point.x - user.x
            let dy = point.y - user.y
            return SemanticRoutePoint(
                x: user.x + dx * cosBias - dy * sinBias,
                y: user.y + dx * sinBias + dy * cosBias
            )
        }
    }

    /// One keyframe-vs-live heading reading, measured against the already
    /// corrected heading, so it is what the bias is still wrong by.
    private func ingestVisualYawResidual(_ residualDegrees: Double, match: VisualRouteMatch) {
        guard phase == .navigating || phase == .recovering else { return }
        // An aliased keyframe is one whose view repeats elsewhere on the route,
        // so its saved heading may belong to a different place entirely. Good
        // enough to contribute position evidence, where the ambiguity is
        // between two points on the same route; not good enough to rotate the
        // world by, where it is between two directions.
        guard !match.isAliased else { return }
        // The evidence bar, and nothing above it.
        //
        // ⚠️ This carried its own higher bar (0.50) for one build and that made
        // the whole correction inert: the 2026-07-30 ECSE map's best matches
        // ran 0.433–0.466 similarity, i.e. every single one landed under it,
        // and five measurements agreeing on −29.2° produced no correction at
        // all. Real corridors match weakly. Agreement across independent
        // matches is the filter here, not per-match strength — three
        // lookalikes that all lie by the same angle is a far less likely
        // accident than one weak match being right.
        guard match.confidence >= visualRouteMinimumConfidence else { return }
        let now = Date()
        visualYawResiduals.append((at: now, degrees: residualDegrees))
        visualYawResiduals.removeAll { now.timeIntervalSince($0.at) > visualYawWindowSeconds }
        applyFrameYawCorrectionIfWarranted()
    }

    /// Turns a run of agreeing measurements into one correction to the bias.
    ///
    /// Median-and-agreement rather than a peak-to-peak spread test over
    /// everything in the window. A plain spread test deadlocks the moment the
    /// frame changes mid-journey: the window then holds readings from two
    /// different frames, they can never agree, and the correction that would
    /// fix the newer one is refused forever. Taking the median of the recent
    /// tail and keeping only what agrees with it lets the minority population
    /// — the stale frame — simply be outvoted.
    private func applyFrameYawCorrectionIfWarranted() {
        guard visualYawResiduals.count >= visualYawSamplesRequired else { return }
        let now = Date()
        if let last = lastYawBiasCorrectionAt,
           now.timeIntervalSince(last) < visualYawCorrectionCooldownSeconds {
            return
        }
        // Not `map(\.degrees)`: Swift key paths do not address tuple members.
        let recent = visualYawResiduals.suffix(visualYawRecentSamples).map { $0.degrees }
        let sorted = recent.sorted()
        let median = sorted[sorted.count / 2]
        let agreeing = sorted.filter {
            abs(SemanticRouteMath.signedAngleDifference($0, median)) <= visualYawAgreementDegrees
        }
        let spread = (sorted.last ?? 0) - (sorted.first ?? 0)
        guard agreeing.count >= visualYawSamplesRequired else {
            NavigationTrace.shared.log("nav.frameYawCorrection", [
                "applied": false,
                "reason": "measurements_disagree",
                "samples": recent.count,
                "agreeing": agreeing.count,
                "spreadDeg": spread,
                "medianDeg": median,
                "biasDeg": mapFrameYawBiasDegrees
            ])
            return
        }
        // The median of what agreed, not of everything: outliers must not drag
        // the correction they were excluded from.
        let correction = agreeing[agreeing.count / 2]
        guard abs(correction) >= visualYawActionableDegrees else { return }
        guard abs(correction) <= visualYawMaxCorrectionDegrees else {
            // Deliberately not applied. A frame this far out is a relocalization
            // failure, and rotating the route by 100° on three fingerprint
            // matches would be a far worse outcome than the wrong route the user
            // already has.
            NavigationTrace.shared.log("nav.frameYawCorrection", [
                "applied": false,
                "reason": "implausible_rotation",
                "samples": recent.count,
                "agreeing": agreeing.count,
                "spreadDeg": spread,
                "correctionDeg": correction,
                "biasDeg": mapFrameYawBiasDegrees
            ])
            visualYawResiduals.removeAll()
            return
        }

        let previousBias = mapFrameYawBiasDegrees
        mapFrameYawBiasDegrees = SemanticRouteMath.signedAngleDifference(
            mapFrameYawBiasDegrees + correction,
            0
        )
        lastYawBiasCorrectionAt = now
        visualYawResiduals.removeAll()
        // The heading history now straddles two frames, so "has the user held
        // one direction" is unanswerable from it — every sample before this
        // instant is offset from every sample after it by the correction, which
        // would read as a turn the user never made. Start the window again.
        recentHeadingSamples.removeAll()
        pendingFrameYawRealignment = true
        NavigationTrace.shared.log("nav.frameYawCorrection", [
            "applied": true,
            "samples": recent.count,
            "agreeing": agreeing.count,
            "spreadDeg": spread,
            "correctionDeg": correction,
            "medianDeg": median,
            "previousBiasDeg": previousBias,
            "biasDeg": mapFrameYawBiasDegrees
        ])
    }

    /// Rebuilds the route from the corrected heading, at a tick boundary.
    /// Returns true when the caller must abandon the rest of this tick, whose
    /// `activeStep` no longer describes the route.
    private func consumePendingFrameYawRealignment(
        arPosition: simd_float3?,
        imuState: IMUState,
        heading: Double?
    ) -> Bool {
        guard pendingFrameYawRealignment else { return false }
        // Cleared before the rebuild, not after: `rebuildRouteFromCurrentPose`
        // speaks a cue and refreshes state, and clearing afterwards would let
        // any flag raised during that work be swallowed.
        pendingFrameYawRealignment = false
        guard realignRouteToCorrectedPose(
            arPosition: arPosition,
            imuState: imuState,
            heading: heading
        ) else {
            // The rebuild retry window swallowed it; re-arm and try on a later
            // tick rather than losing the correction.
            pendingFrameYawRealignment = true
            return false
        }
        return true
    }

    /// Clears everything measured about the AR frame's rotation.
    ///
    /// Journey-scoped on purpose. The bias is a property of the AR session, not
    /// of the leg being walked, so carrying it across a warm retarget would be
    /// defensible — but a bias carried into a session that has since
    /// re-relocalized is silently applied to a frame it was never measured
    /// against, and there is no evidence on hand to notice that. Re-measuring
    /// costs a few visual matches at the start of the next leg.
    /// Clearing the bias MUST also disarm the heading gate. The gate filters
    /// keyframes against the live heading, and it is only legitimate because a
    /// match once confirmed that heading. Discarding the bias discards exactly
    /// that confirmation, so leaving the gate armed points it at a heading now
    /// known to be uncorrected — and it then throws away the keyframes that
    /// disagree, which are the very ones that could re-measure the bias.
    ///
    /// That is not hypothetical. In the 2026-08-01 IGA run a bias of +13.6°
    /// measured from 3 keyframes agreeing to within 0.3° was cleared by a frame
    /// realignment at t=35.7 s. The gate stayed on, visual matching fell from
    /// 37% to 8.5% (mean similarity 0.406 against a 0.440 bar), no residual
    /// could be gathered, and the frame ran 64.6° out for the rest of the walk
    /// with no way back. The two journey-scoped callers already paired these
    /// two resets by hand; keeping the pairing here makes it structural.
    private func resetMapFrameYawBias() {
        mapFrameYawBiasDegrees = 0
        visualYawResiduals.removeAll()
        lastYawBiasCorrectionAt = nil
        pendingFrameYawRealignment = false
        didCorroborateHeadingVisually = false
    }

    /// ARKit itself moved the world frame. Everything measured about the old
    /// frame's rotation is void — the error may have been corrected, made
    /// worse, or replaced — so the bias goes back to zero and the keyframes
    /// re-measure against whatever frame is now live, ungated until one lands.
    func noteARFrameRealigned() {
        // Whatever the heading error reads right now, it was measured against a
        // map frame ARKit has just rotated. On 25 Aug 2026 those rotations came
        // in at 28°, 42°, 90° and −161° inside a few seconds, and the alignment
        // cue read each of them as the user facing the wrong way and said
        // "Turn right." mid-corridor. That is the cue the professor followed
        // into a wall with his eyes shut. Hold corrective heading cues until
        // the frame has stood still long enough to measure against.
        arFrameRealignedAt = Date()
        guard mapFrameYawBiasDegrees != 0 || !visualYawResiduals.isEmpty
            || didCorroborateHeadingVisually else { return }
        NavigationTrace.shared.log("nav.frameYawBiasCleared", [
            "reason": "ar_frame_realigned",
            "discardedBiasDeg": mapFrameYawBiasDegrees,
            "discardedSamples": visualYawResiduals.count,
            "gateWasArmed": didCorroborateHeadingVisually
        ])
        resetMapFrameYawBias()
    }

    /// Two near-tied matches describe one place, not a real ambiguity.
    ///
    /// Comparing step indices alone treated the metre either side of a turn
    /// node as two different places, so keyframes captured a third of a metre
    /// apart across a node vetoed each other — silencing visual matching at
    /// every decision point. Adjacent steps share that node, so compare where
    /// the two matches actually sit. Non-adjacent legs stay a real ambiguity
    /// even when they run close together: parallel aisles are exactly the case
    /// this guard exists for.
    func isSameRoutePlace(
        stepIndex: Int,
        progressMeters: Double,
        otherStepIndex: Int,
        otherProgressMeters: Double
    ) -> Bool {
        if stepIndex == otherStepIndex {
            return abs(progressMeters - otherProgressMeters) <= visualSameRoutePlaceMeters
        }
        guard abs(stepIndex - otherStepIndex) == 1,
              let left = routeWorldPoint(stepIndex: stepIndex, progressMeters: progressMeters),
              let right = routeWorldPoint(stepIndex: otherStepIndex, progressMeters: otherProgressMeters) else {
            return false
        }
        return left.distance(to: right) <= visualSameRoutePlaceMeters
    }

    /// The remaining route as a route-frame polyline, for the sighted-developer
    /// AR arrow overlay: from the believed position on the active leg through
    /// every remaining node to the destination. Empty unless guiding on an
    /// AR-frame map — the overlay draws in the AR session's world, so a PDR
    /// route has nowhere meaningful to draw.
    func remainingRoutePolyline() -> [SemanticRoutePoint] {
        guard phase == .navigating || phase == .recovering,
              activeMap?.coordinateSpace == "ar_world_xz",
              routeSteps.indices.contains(currentStepIndex) else {
            return []
        }
        var points: [SemanticRoutePoint] = []
        if let believed = routeWorldPoint(stepIndex: currentStepIndex, progressMeters: segmentProgressMeters) {
            points.append(believed)
        }
        for index in currentStepIndex..<routeSteps.count {
            points.append(routeSteps[index].to.point)
        }
        return points
    }

    /// Signed turn from `liveHeading` to the leg guidance is steering along:
    /// positive means the route runs to the user's right. Exposed so the AR
    /// screen can show the very number every spoken turn is derived from,
    /// rather than a second opinion computed somewhere else.
    func headingErrorToActiveLeg(liveHeading: Double) -> Double? {
        guard phase == .navigating || phase == .recovering,
              routeSteps.indices.contains(currentStepIndex) else {
            return nil
        }
        return SemanticRouteMath.signedAngleDifference(
            routeSteps[currentStepIndex].edge.bearingDegrees,
            liveHeading
        )
    }

    /// Where a point at `progressMeters` along a step sits in the route frame.
    private func routeWorldPoint(stepIndex: Int, progressMeters: Double) -> SemanticRoutePoint? {
        guard routeSteps.indices.contains(stepIndex) else { return nil }
        let step = routeSteps[stepIndex]
        let fraction = min(max(progressMeters / max(step.edge.distanceMeters, 0.0001), 0), 1)
        return SemanticRoutePoint(
            x: step.from.point.x + (step.to.point.x - step.from.point.x) * fraction,
            y: step.from.point.y + (step.to.point.y - step.from.point.y) * fraction
        )
    }

    private func keyframeProgressMeters(
        for keyframe: SemanticRouteKeyframe,
        on step: SemanticRouteStep,
        baseEdgeID: String,
        keyframeIDs: Set<String>,
        reversed: Bool
    ) -> (progressMeters: Double, isOwned: Bool)? {
        if let segmentID = keyframe.segmentID,
           let span = step.edgeSpans[segmentID] {
            return (Self.progress(inside: span, atEdgeOffset: keyframe.distanceFromSegmentStart, on: step), true)
        }

        if keyframe.segmentID == baseEdgeID || keyframeIDs.contains(keyframe.id) {
            let progress = reversed
                ? max(0, step.edge.distanceMeters - keyframe.distanceFromSegmentStart)
                : min(max(keyframe.distanceFromSegmentStart, 0), step.edge.distanceMeters)
            return (progress, true)
        }

        let projection = Self.project(keyframe.pose, onto: step)
        let nearFrom = keyframe.pose.distance(to: step.from.point) <= 0.75
        let nearTo = keyframe.pose.distance(to: step.to.point) <= 0.95
        let nearSegment = projection.crossTrackMeters <= 0.85 &&
            projection.alongTrackMeters >= -0.5 &&
            projection.alongTrackMeters <= step.edge.distanceMeters + 0.5

        guard nearFrom || nearTo || nearSegment else { return nil }

        if nearTo { return (step.edge.distanceMeters, false) }
        if nearFrom { return (0, false) }
        return (min(max(projection.alongTrackMeters, 0), step.edge.distanceMeters), false)
    }

    private func visualRouteCandidates(
        in map: SemanticRouteMap,
        fingerprints: [String: ARVisualFingerprint],
        liveHeading: Double? = nil
    ) -> [VisualRouteCandidate] {
        var candidates: [VisualRouteCandidate] = []
        let keyframes = map.keyframes ?? []

        for pair in routeSteps.enumerated() {
            let stepIndex = pair.offset
            let step = pair.element
            let baseEdgeID = Self.baseEdgeID(step.edge.id)
            let keyframeIDs = Set(step.edge.keyframeIds ?? [])
            let reversed = step.edge.id.hasSuffix(".reverse")

            for keyframe in keyframes {
                // A keyframe facing the opposite way photographed a different
                // scene; with both walking directions captured it can only
                // produce false matches. Heading-less keyframes stay eligible.
                if let liveHeading,
                   let keyframeHeading = keyframe.headingDegrees,
                   abs(SemanticRouteMath.signedAngleDifference(liveHeading, keyframeHeading)) > Self.visualMatchHeadingGateDegrees {
                    continue
                }
                guard let attribution = keyframeProgressMeters(
                        for: keyframe,
                        on: step,
                        baseEdgeID: baseEdgeID,
                        keyframeIDs: keyframeIDs,
                        reversed: reversed
                      ),
                      let fingerprintID = keyframe.visualFingerprintId,
                      let fingerprint = fingerprints[fingerprintID] else {
                    continue
                }

                candidates.append(
                    VisualRouteCandidate(
                        stepIndex: stepIndex,
                        progressMeters: attribution.progressMeters,
                        fingerprint: fingerprint,
                        fingerprintID: fingerprintID,
                        keyframeID: keyframe.id,
                        landmarkID: nil,
                        landmarkName: nil,
                        cue: nil,
                        isOwnedByStep: attribution.isOwned
                    )
                )
            }

            for landmark in map.landmarks {
                guard let progress = landmarkProgressMeters(
                    for: landmark,
                    on: step,
                    baseEdgeID: baseEdgeID,
                    reversed: reversed
                ) else {
                    continue
                }

                let name = Self.sanitizedSpokenLabel(landmark.name)
                let side = Self.side(landmark.side, reversed: reversed)
                let cue = name.isEmpty ? nil : "Passing \(name) \(Self.sidePhrase(side))."

                for fingerprintID in landmark.visualFingerprintIds ?? [] {
                    guard let fingerprint = fingerprints[fingerprintID] else { continue }
                    candidates.append(
                        VisualRouteCandidate(
                            stepIndex: stepIndex,
                            progressMeters: min(max(progress, 0), step.edge.distanceMeters),
                            fingerprint: fingerprint,
                            fingerprintID: fingerprintID,
                            keyframeID: nil,
                            landmarkID: landmark.id,
                            landmarkName: name,
                            cue: cue,
                            isOwnedByStep: (step.edge.landmarkIds ?? []).contains(landmark.id)
                        )
                    )
                }
            }
        }

        return deduplicatedByFingerprint(candidates)
    }

    /// One saved image belongs to one place, so it must enter the ranking once.
    ///
    /// Every step is offered every keyframe, and the geometric fallback in
    /// `keyframeProgressMeters` claims any sample lying near the step's line —
    /// which at a shared node is guaranteed: the same image is `nearTo` the
    /// step that ends there and `nearFrom` the step that starts there. Both
    /// copies then scored identically against the live frame, so the ambiguity
    /// guard in `currentVisualRouteMatch` saw a dead tie between two different
    /// step indices and threw the match away. Visual evidence was therefore
    /// discarded at exactly the turns and destinations it exists to confirm.
    ///
    /// Attribution order: the step that actually recorded the sample wins;
    /// failing that, the step nearest the one being guided.
    private func deduplicatedByFingerprint(_ candidates: [VisualRouteCandidate]) -> [VisualRouteCandidate] {
        var best: [String: VisualRouteCandidate] = [:]
        var order: [String] = []
        for candidate in candidates {
            guard let incumbent = best[candidate.fingerprintID] else {
                best[candidate.fingerprintID] = candidate
                order.append(candidate.fingerprintID)
                continue
            }
            if incumbent.isOwnedByStep != candidate.isOwnedByStep {
                if candidate.isOwnedByStep { best[candidate.fingerprintID] = candidate }
                continue
            }
            let incumbentDistance = abs(incumbent.stepIndex - currentStepIndex)
            let candidateDistance = abs(candidate.stepIndex - currentStepIndex)
            if candidateDistance < incumbentDistance {
                best[candidate.fingerprintID] = candidate
            }
        }
        return order.compactMap { best[$0] }
    }

    /// Maps raw fingerprint similarity onto 0…1 confidence.
    ///
    /// ⚠️ Calibrated from field measurements, not from intuition. The previous
    /// mapping subtracted 0.62 before scaling — but every similarity ever
    /// recorded in a real corridor fell between 0.21 and 0.61, so the numerator
    /// was always negative and this function returned **exactly zero, always**.
    /// The visual layer could not contribute evidence under any threshold; that
    /// is why guidance had nothing but dead reckoning to correct ARKit's yaw
    /// with, and why a reloaded map could not fix its own frame.
    ///
    /// The band below is the observed distribution: ~0.30 is the noise floor
    /// between unrelated corridor frames, ~0.65 is a confident same-place match
    /// a step or two from where the keyframe was taken.
    private func visualConfidence(from similarity: Float) -> Double {
        let confidence = (Double(similarity) - visualSimilarityFloor) / visualSimilaritySpan
        return min(max(confidence, 0), 1)
    }

    private func isVisualFingerprintAliased(_ fingerprintID: String, in map: SemanticRouteMap) -> Bool {
        (map.visualAliasGroups ?? []).contains { group in
            group.fingerprintIds.contains(fingerprintID)
        }
    }

    private func announceVisualLandmarkIfNeeded(_ visualMatch: VisualRouteMatch?) {
        guard shouldSpeakLandmarks,
              let visualMatch,
              visualMatch.stepIndex == currentStepIndex,
              visualMatch.confidence >= visualRouteSnapConfidence,
              let landmarkID = visualMatch.landmarkID,
              let cue = visualMatch.cue,
              !announcedLandmarkIDs.contains(landmarkID) else {
            return
        }

        let routineSpeechAllowed = guidanceIntroProtectedUntil.map { Date() >= $0 } ?? true
        guard routineSpeechAllowed else { return }

        announcedLandmarkIDs.insert(landmarkID)
        lastAnnouncedLandmarkID = landmarkID
        emitCue(cue, priority: .priority)
    }

    private func shouldHoldForVisualArrival(
        on step: SemanticRouteStep,
        visualMatch: VisualRouteMatch?
    ) -> Bool {
        guard hasDestinationVisualEvidence(on: step) else {
            arrivalVisualHoldStartedAt = nil
            return false
        }

        if isVisualArrivalConfirmed(on: step, visualMatch: visualMatch) {
            arrivalVisualHoldStartedAt = nil
            return false
        }

        let now = Date()
        if arrivalVisualHoldStartedAt == nil {
            arrivalVisualHoldStartedAt = now
            currentInstruction = NavLoc.nearTargetConfirm(targetName)
            emitCue(currentInstruction, priority: .priority)
        }

        if let started = arrivalVisualHoldStartedAt,
           now.timeIntervalSince(started) >= visualArrivalMaxHoldSeconds {
            arrivalVisualHoldStartedAt = nil
            return false
        }

        return true
    }

    private func hasDestinationVisualEvidence(on step: SemanticRouteStep) -> Bool {
        guard currentStepIndex >= routeSteps.count - 1,
              let map = activeMap,
              let fingerprints = map.visualFingerprints,
              !fingerprints.isEmpty else {
            return false
        }

        let baseEdgeID = Self.baseEdgeID(step.edge.id)
        let keyframeIDs = Set(step.edge.keyframeIds ?? [])
        let destinationWindowStart = max(0, step.edge.distanceMeters - visualArrivalWindowMeters(for: step))

        if (map.keyframes ?? []).contains(where: { keyframe in
            let belongsToStep = keyframe.segmentID == baseEdgeID || keyframeIDs.contains(keyframe.id)
            guard belongsToStep,
                  keyframe.distanceFromSegmentStart >= destinationWindowStart,
                  let fingerprintID = keyframe.visualFingerprintId else {
                return false
            }
            return fingerprints[fingerprintID] != nil
        }) {
            return true
        }

        return map.landmarks.contains { landmark in
            guard landmark.kind == .destinationContext || landmark.priority >= 20 || landmark.nodeID == step.to.id,
                  let progress = landmarkProgressMeters(
                    for: landmark,
                    on: step,
                    baseEdgeID: baseEdgeID,
                    reversed: step.edge.id.hasSuffix(".reverse")
                  ),
                  progress >= destinationWindowStart else {
                return false
            }
            return (landmark.visualFingerprintIds ?? []).contains { fingerprints[$0] != nil }
        }
    }

    private func isVisualArrivalConfirmed(
        on step: SemanticRouteStep,
        visualMatch: VisualRouteMatch?
    ) -> Bool {
        guard currentStepIndex >= routeSteps.count - 1,
              let visualMatch,
              visualMatch.stepIndex == currentStepIndex,
              visualMatch.confidence >= visualRouteArrivalConfidence else {
            return false
        }

        // The live pose has the final say on WHERE, always.
        //
        // Both branches below decide arrival from a photograph, and a
        // photograph cannot tell 436-seen-from-here from 436-seen-from-16 m-
        // back-down-the-same-corridor — the enrichment walk deliberately
        // captured both. When a localized pose is available and says the
        // destination is still metres away, it is the pose that is right.
        // Without this, one lookalike frame ended a 20.6 m leg 16 m early with
        // "Arrived at 436" (25 Aug 2026), which for a blind walker is not a
        // missed cue but a wrong one: it stops them in the middle of a
        // corridor and hands them to reaching for an object that is not there.
        if let arRemaining = lastTrustedARRemainingMeters ?? lastARNodeDistanceMeters,
           arRemaining > visualArrivalMaxARRemainingMeters {
            let now = Date()
            let sinceTrace = lastVisualArrivalVetoTraceAt.map { now.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            if sinceTrace >= 1.0 {
                lastVisualArrivalVetoTraceAt = now
                NavigationTrace.shared.log("nav.visualArrivalVetoed", traceState(extra: [
                    "arRemainingM": arRemaining,
                    "allowedM": visualArrivalMaxARRemainingMeters,
                    "visualProgressM": visualMatch.progressMeters,
                    "visualConfidence": visualMatch.confidence,
                    "landmarkID": visualMatch.landmarkID ?? NSNull()
                ]))
            }
            return false
        }

        if let landmarkID = visualMatch.landmarkID,
           isDestinationLandmark(landmarkID, on: step) {
            return true
        }

        let destinationWindowStart = max(0, step.edge.distanceMeters - visualArrivalWindowMeters(for: step))
        return visualMatch.progressMeters >= destinationWindowStart
    }

    private func isDestinationLandmark(_ landmarkID: String, on step: SemanticRouteStep) -> Bool {
        guard let landmark = activeMap?.landmarks.first(where: { $0.id == landmarkID }) else {
            return false
        }
        return landmark.kind == .destinationContext || landmark.priority >= 20 || landmark.nodeID == step.to.id
    }

    private func recoveryContext(on step: SemanticRouteStep, progressMeters: Double) -> String {
        if let landmark = closestLandmarkContext(on: step, progressMeters: progressMeters) {
            return "near \(landmark)"
        }
        let from = Self.sanitizedSpokenLabel(step.from.name, fallback: "the last point")
        let to = Self.sanitizedSpokenLabel(step.to.name, fallback: "the next point")
        return "on the route from \(from) to \(to)"
    }

    private func closestLandmarkContext(on step: SemanticRouteStep, progressMeters: Double) -> String? {
        guard let map = activeMap else { return nil }
        let reversed = step.edge.id.hasSuffix(".reverse")
        let edgeID = Self.baseEdgeID(step.edge.id)
        return map.landmarks.compactMap { landmark -> (distance: Double, phrase: String)? in
            guard let landmarkProgress = landmarkProgressMeters(for: landmark, on: step, baseEdgeID: edgeID, reversed: reversed) else {
                return nil
            }
            let distance = abs(landmarkProgress - progressMeters)
            guard distance <= 3.0 else { return nil }
            let name = Self.sanitizedSpokenLabel(landmark.name)
            guard !name.isEmpty else { return nil }
            return (distance, "\(name) \(Self.sidePhrase(Self.side(landmark.side, reversed: reversed)))")
        }
        .min { $0.distance < $1.distance }?
        .phrase
    }

    private func nearestKeyframeDistance(on step: SemanticRouteStep, to pose: SemanticRoutePoint) -> Double? {
        guard let keyframes = activeMap?.keyframes, !keyframes.isEmpty else { return nil }
        let baseEdgeID = Self.baseEdgeID(step.edge.id)
        let ids = Set(step.edge.keyframeIds ?? [])
        return keyframes.compactMap { keyframe -> Double? in
            let belongsToStep = keyframe.segmentID == baseEdgeID || ids.contains(keyframe.id)
            guard belongsToStep else { return nil }
            return keyframe.pose.distance(to: pose)
        }
        .min()
    }

    private func landmarkProgressMeters(
        for landmark: SemanticRouteLandmark,
        on step: SemanticRouteStep,
        baseEdgeID: String,
        reversed: Bool
    ) -> Double? {
        // A node-anchored reaching object IS its node — it has no position
        // along any leg, so every edge rule below would be answering a
        // question it cannot be asked. Straight to the node fallbacks.
        //
        // This is also what heals maps saved before `attachPendingEvidence`
        // stopped sweeping these onto the destination's outgoing edge: the
        // stale edgeID is simply never consulted. The study's already-mapped
        // stores keep working without a re-capture.
        if Self.isNodeAnchored(landmark) {
            // Only on the leg that ARRIVES at the node. Reaching objects exist
            // to confirm an arrival, so narrating one on the way out of the
            // destination that owns it ("All Brain Kelloggs ahead", walking
            // away from cereals) is noise on a route already criticised for
            // talking too much.
            guard landmark.nodeID == step.to.id else { return nil }
            return max(0, step.edge.distanceMeters - 0.5)
        }

        if let landmarkEdgeID = landmark.edgeID,
           let span = step.edgeSpans[landmarkEdgeID] {
            guard let offset = landmark.offsetMeters else {
                return min(span.startMeters + span.lengthMeters * 0.5, step.edge.distanceMeters)
            }
            return Self.progress(inside: span, atEdgeOffset: offset, on: step)
        }

        // A landmark assigned to a segment belongs ONLY to that segment. Its
        // anchor node is usually the turn that starts the segment, and the
        // node fallbacks below would otherwise surface it near the END of the
        // previous step — announcing an object before the turn it sits behind.
        if let landmarkEdgeID = landmark.edgeID {
            guard landmarkEdgeID == baseEdgeID else { return nil }
            if let offset = landmark.offsetMeters {
                let progress = reversed ? step.edge.distanceMeters - offset : offset
                return min(max(progress, 0), step.edge.distanceMeters)
            }
        }
        if landmark.nodeID == step.from.id {
            return min(0.8, step.edge.distanceMeters)
        }
        if landmark.nodeID == step.to.id {
            return max(0, step.edge.distanceMeters - 0.5)
        }
        return nil
    }

    private func resolveTarget(_ target: String, in map: SemanticRouteMap) -> SemanticRouteNode? {
        resolveTargetDetailed(target, in: map)?.node
    }

    private func resolveTargetDetailed(_ target: String, in map: SemanticRouteMap) -> (node: SemanticRouteNode, isExact: Bool)? {
        if let landmark = map.landmarks.first(where: { Self.matches($0.name, target) || $0.aliases.contains(where: { Self.matches($0, target) }) }),
           let node = map.nodes.first(where: { $0.id == landmark.nodeID }) {
            return (node, true)
        }
        if let node = map.nodes.first(where: { node in
            Self.matches(node.name, target) || node.aliases.contains { Self.matches($0, target) }
        }) {
            return (node, true)
        }
        // Fuzzy/phonetic fallback: ASR noise ("serial", "onion") must still
        // resolve instead of dead-ending guidance with "not in this map".
        if let landmark = map.landmarks.first(where: {
            Self.fuzzyMatchesSpokenTarget($0.name, target) ||
            $0.aliases.contains(where: { Self.fuzzyMatchesSpokenTarget($0, target) })
        }), let node = map.nodes.first(where: { $0.id == landmark.nodeID }) {
            return (node, false)
        }
        if let node = map.nodes.first(where: { node in
            Self.fuzzyMatchesSpokenTarget(node.name, target) ||
            node.aliases.contains { Self.fuzzyMatchesSpokenTarget($0, target) }
        }) {
            return (node, false)
        }
        // Extra-word tolerance ("400 lounge room" → "400 lounge"), last because
        // it is the loosest rule — every exact/fuzzy/phonetic hit outranks it.
        if let node = bestContainmentMatch(for: target, in: map, scorer: Self.containmentScore) {
            return (node, false)
        }
        // Same rule over phonetic keys, strictly after the literal pass so a
        // label that matches literally is never displaced by one that only
        // matches by sound. This is what rescues a partial or filler-carrying
        // target whose tokens are also misheard — "crave", "serials", and
        // "crave cereal aisle" all against a saved "Krave cereal" — none of
        // which reach any earlier rung.
        if let node = bestContainmentMatch(for: target, in: map, scorer: Self.phoneticContainmentScore) {
            return (node, false)
        }
        return nil
    }

    /// Most specific label whose tokens are contained in the spoken target (or
    /// vice versa). A tie between two different labels resolves to nothing:
    /// walking a blind user to the wrong room is worse than asking again.
    private func bestContainmentMatch(
        for target: String,
        in map: SemanticRouteMap,
        scorer: (String, String) -> Int
    ) -> SemanticRouteNode? {
        var best: (node: SemanticRouteNode, key: String, score: Int)?
        var isAmbiguous = false

        func consider(_ node: SemanticRouteNode, name: String, aliases: [String]) {
            let score = ([name] + aliases)
                .map { scorer($0, target) }
                .max() ?? 0
            guard score > 0 else { return }
            let key = Self.normalizedLookupKey(name)
            guard let current = best else {
                best = (node, key, score)
                return
            }
            if score > current.score {
                best = (node, key, score)
                isAmbiguous = false
            } else if score == current.score, key != current.key {
                isAmbiguous = true
            }
        }

        for landmark in map.landmarks {
            guard let node = map.nodes.first(where: { $0.id == landmark.nodeID }) else { continue }
            consider(node, name: landmark.name, aliases: landmark.aliases)
        }
        for node in map.nodes {
            consider(node, name: node.name, aliases: node.aliases)
        }

        return isAmbiguous ? nil : best?.node
    }

    private func resolveNavigationStart(
        in map: SemanticRouteMap,
        targetNodeID: String,
        arPosition: simd_float3?,
        imuState: IMUState,
        headingDegrees: Double?
    ) -> NavigationStart? {
        let pose = map.coordinateSpace == "ar_world_xz"
            ? Self.routePoint(from: arPosition)
            : SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)

        // Every edge the user could plausibly be standing on, not just the
        // closest. Costs below are absolute metres-to-target, so they compare
        // across edges as readily as they compare the two directions along one.
        let candidateEdges = nearestEdges(in: map, to: pose, limit: routeStartEdgeCandidateLimit)
            .filter { $0.crossTrackMeters <= routeStartEdgeSnapThreshold }
        if !candidateEdges.isEmpty {
            var options: [(path: [String], progress: Double, cost: Double, edgeID: String, crossTrack: Double)] = []

            for edgeMatch in candidateEdges {
                // Stepping onto a candidate edge costs the walk out to it. Without
                // this the comparison would rate an edge 1.5 m away exactly as
                // highly as the one under the user's feet.
                let approachCost = edgeMatch.crossTrackMeters

                let forwardTail = shortestPath(in: map, from: edgeMatch.edge.toNodeID, to: targetNodeID)
                // A tail that immediately doubles back through the node behind the
                // user describes the reverse option with a pointless out-and-back
                // leg bolted on. Their costs tie when the user stands on the node,
                // so the heading penalty alone could pick the U-turn.
                let forwardTailDoublesBack = forwardTail.count >= 2 && forwardTail[1] == edgeMatch.edge.fromNodeID
                if !forwardTail.isEmpty, !forwardTailDoublesBack {
                    let path = [edgeMatch.edge.fromNodeID] + forwardTail
                    let progress = edgeMatch.alongTrackMeters
                    let headingPenalty = routeStartHeadingPenalty(
                        liveHeading: headingDegrees,
                        routeBearing: edgeMatch.edge.bearingDegrees
                    )
                    let cost = max(0, edgeMatch.edge.distanceMeters - edgeMatch.alongTrackMeters)
                        + pathCost(for: forwardTail, in: map)
                        + headingPenalty
                        + approachCost
                    options.append((path, progress, cost, edgeMatch.edge.id, edgeMatch.crossTrackMeters))
                }

                let reverseTail = shortestPath(in: map, from: edgeMatch.edge.fromNodeID, to: targetNodeID)
                let reverseTailDoublesBack = reverseTail.count >= 2 && reverseTail[1] == edgeMatch.edge.toNodeID
                if !reverseTail.isEmpty, !reverseTailDoublesBack {
                    let path = [edgeMatch.edge.toNodeID] + reverseTail
                    let progress = max(0, edgeMatch.edge.distanceMeters - edgeMatch.alongTrackMeters)
                    let headingPenalty = routeStartHeadingPenalty(
                        liveHeading: headingDegrees,
                        routeBearing: SemanticRouteMath.normalizedDegrees(edgeMatch.edge.bearingDegrees + 180)
                    )
                    let cost = max(0, edgeMatch.alongTrackMeters) + pathCost(for: reverseTail, in: map)
                        + headingPenalty
                        + approachCost
                    options.append((path, progress, cost, edgeMatch.edge.id, edgeMatch.crossTrackMeters))
                }
            }

            let nearestMatch = candidateEdges[0]
            NavigationTrace.shared.log("nav.start.resolve", [
                "mode": "edge_snap",
                "poseX": pose?.x ?? NSNull(),
                "poseY": pose?.y ?? NSNull(),
                "headingDeg": headingDegrees ?? NSNull(),
                "snappedEdge": nearestMatch.edge.id,
                "snappedEdgeBearing": nearestMatch.edge.bearingDegrees,
                "snappedEdgeReverseBearing": nearestMatch.edge.reverseBearingDegrees,
                "alongTrackM": nearestMatch.alongTrackMeters,
                "crossTrackM": nearestMatch.crossTrackMeters,
                "candidateEdges": candidateEdges.map { candidate in
                    [
                        "edge": candidate.edge.id,
                        "bearing": candidate.edge.bearingDegrees,
                        "alongTrackM": candidate.alongTrackMeters,
                        "crossTrackM": candidate.crossTrackMeters
                    ] as [String: Any]
                },
                "options": options.map { option in
                    [
                        "path": option.path,
                        "initialProgressM": option.progress,
                        "cost": option.cost,
                        "edge": option.edgeID,
                        "crossTrackM": option.crossTrack
                    ] as [String: Any]
                },
                "chosen": options.min(by: { $0.cost < $1.cost })?.path ?? []
            ])
            if let best = options.min(by: { $0.cost < $1.cost }) {
                return NavigationStart(nodePath: best.path, initialProgressMeters: best.progress)
            }
        }

        if let pose, let nearest = nearestNode(in: map, to: pose) {
            let path = shortestPath(in: map, from: nearest.id, to: targetNodeID)
            if !path.isEmpty {
                NavigationTrace.shared.log("nav.start.resolve", [
                    "mode": "nearest_node",
                    "poseX": pose.x,
                    "poseY": pose.y,
                    "headingDeg": headingDegrees ?? NSNull(),
                    "nearestNode": nearest.name,
                    "nearestNodeDistM": pose.distance(to: nearest.point),
                    "chosen": path
                ])
                return NavigationStart(nodePath: path, initialProgressMeters: 0)
            }
        }

        let fallbackPath = shortestPath(in: map, from: map.nodes.first?.id ?? "", to: targetNodeID)
        NavigationTrace.shared.log("nav.start.resolve", [
            "mode": "map_first_node_fallback",
            "poseX": pose?.x ?? NSNull(),
            "poseY": pose?.y ?? NSNull(),
            "headingDeg": headingDegrees ?? NSNull(),
            "chosen": fallbackPath
        ])
        return fallbackPath.isEmpty ? nil : NavigationStart(nodePath: fallbackPath, initialProgressMeters: 0)
    }

    private func resolveStartNode(in map: SemanticRouteMap, arPosition: simd_float3?, imuState: IMUState) -> SemanticRouteNode? {
        let pose = map.coordinateSpace == "ar_world_xz"
            ? Self.routePoint(from: arPosition)
            : SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)
        if let pose, let nearest = nearestNode(in: map, to: pose) {
            return nearest
        }
        return map.nodes.first
    }

    private func shortestPath(in map: SemanticRouteMap, from startID: String, to targetID: String) -> [String] {
        guard startID != targetID else { return [startID] }
        var distances: [String: Double] = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, Double.greatestFiniteMagnitude) })
        var previous: [String: String] = [:]
        var unvisited = Set(map.nodes.map(\.id))
        distances[startID] = 0

        while let current = unvisited.min(by: { (distances[$0] ?? .greatestFiniteMagnitude) < (distances[$1] ?? .greatestFiniteMagnitude) }) {
            if current == targetID { break }
            unvisited.remove(current)
            let outgoing = map.edges.filter { edge in
                edge.fromNodeID == current || (edge.isBidirectional && edge.toNodeID == current)
            }
            for edge in outgoing {
                let neighbor = edge.fromNodeID == current ? edge.toNodeID : edge.fromNodeID
                guard unvisited.contains(neighbor) else { continue }
                let alternative = (distances[current] ?? .greatestFiniteMagnitude) + edge.distanceMeters
                if alternative < (distances[neighbor] ?? .greatestFiniteMagnitude) {
                    distances[neighbor] = alternative
                    previous[neighbor] = current
                }
            }
        }

        guard previous[targetID] != nil else { return [] }
        var path = [targetID]
        var cursor = targetID
        while let predecessor = previous[cursor] {
            path.insert(predecessor, at: 0)
            cursor = predecessor
        }
        return path
    }

    private func pathCost(for nodePath: [String], in map: SemanticRouteMap) -> Double {
        guard nodePath.count >= 2 else { return 0 }
        var total = 0.0
        for index in 0..<(nodePath.count - 1) {
            let fromID = nodePath[index]
            let toID = nodePath[index + 1]
            guard let edge = map.edges.first(where: {
                ($0.fromNodeID == fromID && $0.toNodeID == toID) ||
                ($0.isBidirectional && $0.fromNodeID == toID && $0.toNodeID == fromID)
            }) else {
                return Double.greatestFiniteMagnitude
            }
            total += edge.distanceMeters
        }
        return total
    }

    private func routeStartHeadingPenalty(
        liveHeading: Double?,
        routeBearing: Double
    ) -> Double {
        guard let liveHeading else { return 0 }
        let error = abs(SemanticRouteMath.signedAngleDifference(liveHeading, routeBearing))
        return min(error / 90.0, 1.0) * routeStartHeadingPenaltyMeters
    }

    private func buildSteps(for nodePath: [String], in map: SemanticRouteMap) -> [SemanticRouteStep] {
        guard nodePath.count >= 2 else { return [] }
        var steps: [SemanticRouteStep] = []
        for index in 0..<(nodePath.count - 1) {
            let fromID = nodePath[index]
            let toID = nodePath[index + 1]
            guard let from = map.nodes.first(where: { $0.id == fromID }),
                  let to = map.nodes.first(where: { $0.id == toID }),
                  let storedEdge = map.edges.first(where: {
                      ($0.fromNodeID == fromID && $0.toNodeID == toID) ||
                      ($0.isBidirectional && $0.fromNodeID == toID && $0.toNodeID == fromID)
                  }) else { continue }

            let edge: SemanticRouteEdge
            if storedEdge.fromNodeID == fromID {
                edge = storedEdge
            } else {
                edge = SemanticRouteEdge(
                    id: "\(storedEdge.id).reverse",
                    fromNodeID: fromID,
                    toNodeID: toID,
                    distanceMeters: storedEdge.distanceMeters,
                    bearingDegrees: storedEdge.reverseBearingDegrees,
                    reverseBearingDegrees: storedEdge.bearingDegrees,
                    walkableWidthMeters: storedEdge.walkableWidthMeters,
                    leftContext: storedEdge.rightContext,
                    rightContext: storedEdge.leftContext,
                    spokenContext: "toward \(to.name)",
                    isBidirectional: true,
                    confidence: storedEdge.confidence,
                    keyframeIds: storedEdge.keyframeIds,
                    landmarkIds: storedEdge.landmarkIds
                )
            }
            steps.append(SemanticRouteStep(edge: edge, from: from, to: to))
        }
        return steps
    }

    private struct ShapedRoute {
        var steps: [SemanticRouteStep]
        var arrivalFacing: SemanticRouteArrivalFacing?
        /// Where a dropped leading stub started — still the place the user is
        /// standing, and so still the place to name when guidance opens.
        var startNodeName: String?
        /// True when a stub first leg was removed, so the caller must not carry
        /// the along-track progress it had measured on that leg.
        var droppedLeadingStub: Bool
        /// The dropped stub's direction and length. The user still physically
        /// walks it, so alignment cues must accept this bearing as "facing the
        /// route" until the stub is behind them.
        var droppedLeadingStubBearingDegrees: Double?
        var droppedLeadingStubMeters: Double
    }

    /// Turns the raw captured graph path into legs a person can actually walk.
    ///
    /// Capture in a narrow aisle produces sub-metre legs that are orientation,
    /// not travel: a node pinned an arm's length off the shelf so arrival can
    /// say "on your left", and straight points dropped a step apart. Walking
    /// guidance over those legs is what makes a short route unusable — the
    /// first cue of a 22 m journey becomes "walk less than one meter, toward
    /// the next turn", and the last one sends the user walking into a shelf.
    ///
    /// Three passes: fold stub legs into the neighbour they are collinear with,
    /// convert a final stub into an arrival facing, and drop a leading stub the
    /// user is already standing beside.
    private func shapeRouteSteps(
        _ raw: [SemanticRouteStep],
        allowLeadingStubDrop: Bool
    ) -> ShapedRoute {
        var shaped: [SemanticRouteStep] = []
        for step in raw {
            guard let previous = shaped.last else {
                shaped.append(step)
                continue
            }
            if canMerge(previous, step) {
                shaped[shaped.count - 1] = Self.mergedStep(previous, step)
            } else {
                shaped.append(step)
            }
        }

        var arrivalFacing: SemanticRouteArrivalFacing?
        if shaped.count >= 2, let last = shaped.last, last.edge.distanceMeters <= stubLegMaxMeters {
            // Collinear stubs were folded above, so a stub still standing here
            // is a real turn onto the target: the user faces it, they don't
            // walk it. The last walked node becomes the arrival point.
            let previous = shaped[shaped.count - 2]
            let diff = SemanticRouteMath.signedAngleDifference(
                last.edge.bearingDegrees,
                previous.edge.bearingDegrees
            )
            arrivalFacing = SemanticRouteArrivalFacing(
                side: Self.facingSide(forSignedDegrees: diff),
                meters: last.edge.distanceMeters
            )
            shaped.removeLast()
        }

        var droppedLeadingStub = false
        var droppedStubBearingDegrees: Double?
        var droppedStubMeters = 0.0
        var startNodeName: String?
        if allowLeadingStubDrop,
           shaped.count >= 2,
           let first = shaped.first,
           first.edge.distanceMeters <= stubLegMaxMeters {
            // Mirror case: the user is standing at the shelf they mapped and
            // the stub is the hop back into the aisle. Only drop it when where
            // they stand is somewhere the navigator would call on-route anyway
            // — dropping a stub that leaves them outside the corridor opens
            // guidance already in recovery, and a stub running back along the
            // next leg's own axis is real walking that has to stay. The bound
            // is the corridor width the rest of the system measures against,
            // not a number of its own.
            let offset = Self.projectDetailed(first.from.point, onto: shaped[1]).crossTrackMeters
            if offset <= crossTrackRecoveryThreshold {
                // They are still standing at the shelf, whatever the route now
                // starts from: "Starting at Onions", not "at Left turn 4".
                startNodeName = first.from.name
                droppedStubBearingDegrees = first.edge.bearingDegrees
                droppedStubMeters = first.edge.distanceMeters
                shaped.removeFirst()
                droppedLeadingStub = true
            }
        }

        return ShapedRoute(
            steps: shaped,
            arrivalFacing: arrivalFacing,
            startNodeName: startNodeName,
            droppedLeadingStub: droppedLeadingStub,
            droppedLeadingStubBearingDegrees: droppedStubBearingDegrees,
            droppedLeadingStubMeters: droppedStubMeters
        )
    }

    /// A node only earns a leg boundary if it is a decision point. When the
    /// bearing barely changes and the mapper marked no turn there, the two legs
    /// are one straight walk, and splitting them just adds a "continue
    /// straight" nobody needed plus a fresh chance to re-cue an alignment.
    ///
    /// Deliberately not a length rule: the first field map's shelf stub was
    /// 1.4 m and the next capture of the same aisle measured 1.6 m, so any
    /// threshold sits right where the data does. Collinearity is what actually
    /// defines the artefact.
    private func canMerge(_ first: SemanticRouteStep, _ second: SemanticRouteStep) -> Bool {
        // Never merge across a destination: its name is what the user is told
        // to walk toward, and passing one silently loses that cue.
        guard first.to.kind != .destination else { return false }
        // A hint recorded at the node means the mapper called it a turn, even
        // if the geometry looks mild. Their judgement wins.
        if let hint = first.to.turnHint, hint != .straight { return false }
        let turn = abs(SemanticRouteMath.signedAngleDifference(
            second.edge.bearingDegrees,
            first.edge.bearingDegrees
        ))
        guard turn <= mergeMaxTurnDegrees else { return false }
        // A merged leg must still be short enough to stay trustworthy.
        //
        // Merging exists to delete sub-metre capture artefacts, not to erase
        // the waypoints of a long corridor. Every node is a re-anchor: progress
        // resets there, and the belief gets a fresh geometric fix. Folding two
        // straight points away turned a real 4-leg walk into ONE 21 m leg, so
        // dead-reckoning drift accumulated across the whole corridor with
        // nothing to correct against — and that is the leg where the field
        // trace teleported the user 3.2 m onto the turn node. Past this length
        // the intermediate node is worth more than the tidier phrasing.
        guard first.edge.distanceMeters + second.edge.distanceMeters <= mergedLegMaxMeters else {
            return false
        }
        // Merging replaces the bend with its chord, and every projection gate
        // downstream measures cross-track against that line. Keep the folded
        // node close enough to it that a keyframe captured at the bend still
        // lands on the merged step.
        let offset = Self.project(
            first.to.point,
            from: first.from.point,
            to: second.to.point,
            distance: first.from.point.distance(to: second.to.point)
        ).crossTrackMeters
        return offset <= mergeMaxChordOffsetMeters
    }

    /// Folds two consecutive steps into one straight leg. The merged edge gets
    /// a synthetic id and no keyframe/landmark ids so nothing resolves through
    /// the by-id fast path with the wrong origin; `edgeSpans` carries the exact
    /// offsets instead, and anything not listed there still lands by geometry.
    private static func mergedStep(
        _ first: SemanticRouteStep,
        _ second: SemanticRouteStep
    ) -> SemanticRouteStep {
        let distance = max(first.from.point.distance(to: second.to.point), 0.1)
        let bearing = first.from.point.bearingDegrees(to: second.to.point)
        let dominant = first.edge.distanceMeters >= second.edge.distanceMeters ? first : second
        let edge = SemanticRouteEdge(
            id: "\(first.edge.id)+\(second.edge.id)",
            fromNodeID: first.from.id,
            toNodeID: second.to.id,
            distanceMeters: distance,
            bearingDegrees: bearing,
            reverseBearingDegrees: second.to.point.bearingDegrees(to: first.from.point),
            walkableWidthMeters: dominant.edge.walkableWidthMeters,
            leftContext: dominant.edge.leftContext,
            rightContext: dominant.edge.rightContext,
            spokenContext: dominant.edge.spokenContext,
            isBidirectional: first.edge.isBidirectional && second.edge.isBidirectional,
            confidence: min(first.edge.confidence, second.edge.confidence),
            keyframeIds: nil,
            landmarkIds: nil
        )
        var spans = edgeSpans(of: first, startingAt: 0)
        for (id, span) in edgeSpans(of: second, startingAt: first.edge.distanceMeters) {
            spans[id] = span
        }
        return SemanticRouteStep(edge: edge, from: first.from, to: second.to, edgeSpans: spans)
    }

    private static func edgeSpans(
        of step: SemanticRouteStep,
        startingAt offset: Double
    ) -> [String: SemanticRouteEdgeSpan] {
        guard step.edgeSpans.isEmpty else {
            return step.edgeSpans.mapValues {
                SemanticRouteEdgeSpan(
                    startMeters: $0.startMeters + offset,
                    lengthMeters: $0.lengthMeters,
                    reversed: $0.reversed
                )
            }
        }
        return [
            baseEdgeID(step.edge.id): SemanticRouteEdgeSpan(
                startMeters: offset,
                lengthMeters: step.edge.distanceMeters,
                reversed: step.edge.id.hasSuffix(".reverse")
            )
        ]
    }

    /// Translates an offset measured along a captured edge into progress along
    /// the merged step that swallowed it.
    private static func progress(
        inside span: SemanticRouteEdgeSpan,
        atEdgeOffset offset: Double,
        on step: SemanticRouteStep
    ) -> Double {
        let local = min(max(offset, 0), span.lengthMeters)
        let alongSpan = span.reversed ? span.lengthMeters - local : local
        return min(max(span.startMeters + alongSpan, 0), step.edge.distanceMeters)
    }

    private static func facingSide(forSignedDegrees diff: Double) -> SemanticRouteSide {
        let magnitude = abs(diff)
        if magnitude < 25 { return .ahead }
        if magnitude > 150 { return .behind }
        return diff > 0 ? .right : .left
    }

    private func upsertMap(_ map: SemanticRouteMap, persist: Bool) {
        let cleaned = Self.sanitizedMap(map)
        maps.removeAll { $0.id == cleaned.id || Self.matches($0.name, cleaned.name) }
        maps.insert(cleaned, at: 0)
        if persist {
            store.save(maps)
        }
    }

    private func nearestNode(in map: SemanticRouteMap, to pose: SemanticRoutePoint?) -> SemanticRouteNode? {
        guard let pose else { return nil }
        return map.nodes.min { $0.point.distance(to: pose) < $1.point.distance(to: pose) }
    }

    private func nearestEdge(in map: SemanticRouteMap, to pose: SemanticRoutePoint?) -> EdgeMatch? {
        nearestEdges(in: map, to: pose, limit: 1).first
    }

    /// Edges sorted by cross-track distance from `pose`, nearest first.
    ///
    /// Start resolution needs more than the single nearest edge. A route that
    /// retraces its own corridor puts unrelated edges within centimetres of
    /// each other — in one captured map "Left turn 7" sat 0.25 m off the
    /// "Left turn 6 → 5103" edge — so the nearest edge is regularly the wrong
    /// one, and a resolver that only ever saw that one edge had no way to
    /// notice. Ranking a handful of candidates lets the heading penalty, which
    /// already knows which way the user faces, discard the impostor.
    private func nearestEdges(
        in map: SemanticRouteMap,
        to pose: SemanticRoutePoint?,
        limit: Int
    ) -> [EdgeMatch] {
        guard let pose, limit > 0 else { return [] }
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        return map.edges.compactMap { edge -> EdgeMatch? in
            guard let from = nodeByID[edge.fromNodeID], let to = nodeByID[edge.toNodeID] else { return nil }
            let projection = Self.project(pose, from: from.point, to: to.point, distance: edge.distanceMeters)
            return EdgeMatch(
                edge: edge,
                alongTrackMeters: projection.alongTrackMeters,
                crossTrackMeters: projection.crossTrackMeters
            )
        }
        .sorted { $0.crossTrackMeters < $1.crossTrackMeters }
        .prefix(limit)
        .map { $0 }
    }

    private static func project(_ point: SemanticRoutePoint, onto step: SemanticRouteStep) -> (alongTrackMeters: Double, crossTrackMeters: Double) {
        project(point, from: step.from.point, to: step.to.point, distance: step.edge.distanceMeters)
    }

    private static func projectDetailed(_ point: SemanticRoutePoint, onto step: SemanticRouteStep) -> RouteProjection {
        let dx = step.to.point.x - step.from.point.x
        let dy = step.to.point.y - step.from.point.y
        let lengthSquared = max(dx * dx + dy * dy, 0.0001)
        let rawT = ((point.x - step.from.point.x) * dx + (point.y - step.from.point.y) * dy) / lengthSquared
        let t = max(0, min(1, rawT))
        let nearestPoint = SemanticRoutePoint(
            x: step.from.point.x + t * dx,
            y: step.from.point.y + t * dy
        )
        return (
            alongTrackMeters: step.edge.distanceMeters * t,
            crossTrackMeters: point.distance(to: nearestPoint),
            nearestPoint: nearestPoint
        )
    }

    /// Signed metres past `step.to`, measured along the leg's own direction.
    /// Negative before the node, positive after it. Unclamped on purpose —
    /// `projectDetailed` saturates at the node and cannot express an overshoot.
    private static func metersBeyondNode(_ point: SemanticRoutePoint, on step: SemanticRouteStep) -> Double {
        let dx = step.to.point.x - step.from.point.x
        let dy = step.to.point.y - step.from.point.y
        let lengthSquared = max(dx * dx + dy * dy, 0.0001)
        let rawT = ((point.x - step.from.point.x) * dx + (point.y - step.from.point.y) * dy) / lengthSquared
        return (rawT - 1.0) * step.edge.distanceMeters
    }

    private static func project(_ point: SemanticRoutePoint, from: SemanticRoutePoint, to: SemanticRoutePoint, distance: Double) -> (alongTrackMeters: Double, crossTrackMeters: Double) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let lengthSquared = max(dx * dx + dy * dy, 0.0001)
        let t = max(0, min(1, ((point.x - from.x) * dx + (point.y - from.y) * dy) / lengthSquared))
        let projection = SemanticRoutePoint(x: from.x + t * dx, y: from.y + t * dy)
        return (distance * t, point.distance(to: projection))
    }

    private static func confidence(
        observationConfidence: Double,
        headingError: Double,
        crossTrackError: Double?,
        isARLocalized: Bool,
        isMoving: Bool
    ) -> Double {
        var value = observationConfidence
        value -= min(headingError / 180.0, 0.35)
        if let crossTrackError {
            value -= min(crossTrackError / 5.0, 0.30)
        }
        if !isARLocalized { value -= 0.08 }
        if isMoving { value += 0.04 }
        return min(max(value, 0.05), 0.98)
    }

    private static func routePoint(from arPosition: simd_float3?) -> SemanticRoutePoint? {
        guard let arPosition else { return nil }
        // Route frame is compass-like: y must grow toward the camera's initial
        // facing (-Z) so that bearingDegrees = atan2(dx, dy) increases on
        // physical RIGHT turns, matching relativeTurnCommand and the PDR
        // (east, north) frame. Storing raw +z here mirrors every left/right
        // cue and the exported top-down plot.
        return SemanticRoutePoint(x: Double(arPosition.x), y: -Double(arPosition.z))
    }

    fileprivate static func makeEdge(
        from: SemanticRouteNode,
        to: SemanticRouteNode,
        leftContext: String?,
        rightContext: String?,
        spokenContext: String?,
        confidence: Double
    ) -> SemanticRouteEdge {
        let distance = max(from.point.distance(to: to.point), 0.1)
        let bearing = from.point.bearingDegrees(to: to.point)
        let reverse = to.point.bearingDegrees(to: from.point)
        return SemanticRouteEdge(
            id: "\(from.id)__\(to.id)",
            fromNodeID: from.id,
            toNodeID: to.id,
            distanceMeters: distance,
            bearingDegrees: bearing,
            reverseBearingDegrees: reverse,
            walkableWidthMeters: nil,
            leftContext: leftContext,
            rightContext: rightContext,
            spokenContext: spokenContext,
            isBidirectional: true,
            confidence: confidence,
            keyframeIds: nil,
            landmarkIds: nil
        )
    }

    private static func attachLandmarkContext(
        name: String,
        side: SemanticRouteSide,
        to edge: inout SemanticRouteEdge
    ) {
        let phrase = "\(name) \(sidePhrase(side))"
        switch side {
        case .left:
            edge.leftContext = appendedContext(edge.leftContext, phrase)
        case .right:
            edge.rightContext = appendedContext(edge.rightContext, phrase)
        case .center, .ahead, .behind:
            edge.spokenContext = appendedContext(edge.spokenContext, phrase)
        }
    }

    /// A landmark pinned AT a node rather than somewhere along an edge.
    ///
    /// `attachReachingObject` creates exactly these: the object sits at the
    /// destination, so it has no offset along any leg and faces whoever is
    /// standing there. `captureRoutePoint`'s landmarks always carry an offset,
    /// because they were passed at a measured distance into a leg.
    ///
    /// The distinction matters because `edgeID == nil` means two different
    /// things — "not on an edge at all" for these, and "the edge does not
    /// exist yet" for a landmark captured at a node the walk is about to leave
    /// — and `attachPendingEvidence` used to resolve the ambiguity the wrong
    /// way for reaching objects. See there.
    private static func isNodeAnchored(_ landmark: SemanticRouteLandmark) -> Bool {
        landmark.kind == .destinationContext && landmark.offsetMeters == nil
    }

    /// Adopts landmarks and keyframes captured at `fromNodeID` into the edge
    /// that has just been created leaving it.
    ///
    /// Node-anchored reaching objects are deliberately excluded. Sweeping them
    /// in is what broke the first reaching anchor of every multi-destination
    /// map: a participant on 17 Aug 2026 pinned "All Brain Kelloggs" at
    /// Cereals, kept walking to Onions, and the walk's next edge (Cereals →
    /// Left turn 4) claimed the Cereals object on its way past. Arriving at
    /// Cereals afterwards, `landmarkProgressMeters` refused it — correctly,
    /// for a landmark that belongs to a different segment — so the anchor
    /// never surfaced. The object at Onions worked only because the walk ended
    /// there and no outgoing edge was ever built to steal it.
    private static func attachPendingEvidence(
        to edge: inout SemanticRouteEdge,
        in map: inout SemanticRouteMap,
        fromNodeID: String
    ) {
        var landmarkIds = edge.landmarkIds ?? []
        for index in map.landmarks.indices {
            guard map.landmarks[index].edgeID == nil,
                  map.landmarks[index].nodeID == fromNodeID,
                  !isNodeAnchored(map.landmarks[index]) else {
                continue
            }
            map.landmarks[index].edgeID = edge.id
            if let offset = map.landmarks[index].offsetMeters {
                map.landmarks[index].offsetMeters = min(max(offset, 0), edge.distanceMeters)
            }
            landmarkIds.append(map.landmarks[index].id)
            attachLandmarkContext(
                name: map.landmarks[index].name,
                side: map.landmarks[index].side,
                to: &edge
            )
        }
        edge.landmarkIds = landmarkIds.isEmpty ? nil : Array(Set(landmarkIds))

        var keyframeIds = edge.keyframeIds ?? []
        guard var keyframes = map.keyframes else { return }
        for index in keyframes.indices {
            guard keyframes[index].segmentID == nil,
                  keyframes[index].distanceFromSegmentStart <= edge.distanceMeters + 0.75 else {
                continue
            }
            keyframes[index].segmentID = edge.id
            keyframes[index].distanceFromSegmentStart = min(max(keyframes[index].distanceFromSegmentStart, 0), edge.distanceMeters)
            keyframeIds.append(keyframes[index].id)
        }
        map.keyframes = keyframes
        edge.keyframeIds = keyframeIds.isEmpty ? nil : Array(Set(keyframeIds))
    }

    private static func appendedContext(_ existing: String?, _ addition: String) -> String {
        let cleanAddition = sanitizedSpokenLabel(addition)
        guard !cleanAddition.isEmpty else { return existing ?? "" }
        guard let existing = sanitizedSpokenLabel(existing ?? "").nilIfBlank else { return cleanAddition }
        if existing.localizedCaseInsensitiveContains(cleanAddition) { return existing }
        return "\(existing); \(cleanAddition)"
    }

    private static func baseEdgeID(_ id: String) -> String {
        id.hasSuffix(".reverse") ? String(id.dropLast(".reverse".count)) : id
    }

    private static func side(_ side: SemanticRouteSide, reversed: Bool) -> SemanticRouteSide {
        guard reversed else { return side }
        switch side {
        case .left: return .right
        case .right: return .left
        default: return side
        }
    }

    private static func sidePhrase(_ side: SemanticRouteSide) -> String {
        switch side {
        case .left: return NavLoc.onYourLeft()
        case .right: return NavLoc.onYourRight()
        case .center: return NavLoc.nearTheCenter()
        case .ahead: return NavLoc.ahead()
        case .behind: return NavLoc.behindYou()
        }
    }

    private static func relativeRecoveryCommand(
        from heading: Double,
        to targetBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> (text: String, key: String) {
        let diff = SemanticRouteMath.signedAngleDifference(targetBearing, heading)
        let magnitude = abs(diff)
        if magnitude < 25 { return (NavLoc.forward(), "forward") }
        if magnitude >= turnAroundMinimumDegrees {
            return (NavLoc.turnAroundNudge(), "turn_around")
        }
        if style == .clockFace {
            let hour = clockHour(forSignedDegrees: diff)
            return (NavLoc.clockNudge(hour: hour), "clock_\(hour)")
        }
        if magnitude < 75 { return diff > 0 ? (NavLoc.stepRight(), "right") : (NavLoc.stepLeft(), "left") }
        if magnitude < 135 { return diff > 0 ? (NavLoc.turnRightNudge(), "turn_right") : (NavLoc.turnLeftNudge(), "turn_left") }
        return (NavLoc.turnAroundNudge(), "turn_around")
    }

    /// Past this a correction is a turn-around whatever the phrasing style.
    ///
    /// Left/right mode always said so. Clock-face mode did not: its branch ran
    /// ahead of every magnitude test, so a 210° correction was spoken as "Head
    /// to 7 o'clock, 7 meters" and a 180° one as "Turn to 6 o'clock" — an hour
    /// that names no direction to rotate in, attached to a seven-metre diagonal.
    /// A reviewer flagged both on 15 Aug 2026, in the same breath as asking for
    /// the recovery output to be reduced to "turn around". 150° is where the
    /// left/right chain already draws the line, so the two styles agree.
    private static let turnAroundMinimumDegrees = 150.0

    /// Signed heading offset → clock hour: +90° is 3 o'clock, −90° is 9,
    /// ±180° is 6. Callers handle the near-straight band before calling.
    private static func clockHour(forSignedDegrees diff: Double) -> Int {
        var hour = Int((diff / 30.0).rounded())
        while hour <= 0 { hour += 12 }
        while hour > 12 { hour -= 12 }
        return hour
    }

    /// Whether a freshly computed cue says the same thing as the one already
    /// spoken.
    ///
    /// Left/right phrasing has five bands across 360°, so a key change really
    /// is new information. Clock-face phrasing has twelve: an ordinary walking
    /// sway renames the cue every couple of seconds, and the old
    /// `key != lastKey` test spoke on each rename. That is what turned the
    /// clock-face condition of the pilot into a stream of corrections nobody
    /// could act on ("2 o'clock… 3 o'clock… 2 o'clock"). Neighbouring hours are
    /// one correction; only a two-hour move is worth interrupting for.
    static func isSameSpokenCorrection(_ candidate: String, as previous: String?) -> Bool {
        guard let previous else { return false }
        if candidate == previous { return true }
        guard let lhs = clockCueParts(candidate),
              let rhs = clockCueParts(previous),
              lhs.prefix == rhs.prefix,
              lhs.suffix == rhs.suffix else {
            return false
        }
        let separation = abs(lhs.hour - rhs.hour)
        return min(separation, 12 - separation) <= 1
    }

    /// Splits a cue key such as `align_clock_2_0` around its clock hour, so two
    /// keys are only ever compared by hour when everything else about them —
    /// which subsystem raised them, which leg they belong to — matches.
    private static func clockCueParts(_ key: String) -> (prefix: String, hour: Int, suffix: String)? {
        guard let marker = key.range(of: "clock_") else { return nil }
        let tail = key[marker.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        guard let hour = Int(digits) else { return nil }
        return (String(key[..<marker.lowerBound]), hour, String(tail.dropFirst(digits.count)))
    }

    private static func relativeTurnCommand(
        from heading: Double,
        to targetBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> (text: String, key: String) {
        let diff = SemanticRouteMath.signedAngleDifference(targetBearing, heading)
        let magnitude = abs(diff)
        if magnitude < 25 { return (NavLoc.goStraight(), "straight") }
        // Before the style branch: see `turnAroundMinimumDegrees`.
        if magnitude >= turnAroundMinimumDegrees {
            return (NavLoc.turnAroundCommand(), "around")
        }
        if style == .clockFace {
            let hour = clockHour(forSignedDegrees: diff)
            return (NavLoc.clockCommand(hour: hour), "clock_\(hour)")
        }
        // A "sharp" band keeps a 130° aisle-end turn from being spoken the
        // same as a gentle 50° one — under-specified turns walked the pilot
        // users into shelves.
        if magnitude < 110 { return diff > 0 ? (NavLoc.turnRightCommand(), "right") : (NavLoc.turnLeftCommand(), "left") }
        if magnitude < 150 { return diff > 0 ? (NavLoc.turnSharpRightCommand(), "sharp_right") : (NavLoc.turnSharpLeftCommand(), "sharp_left") }
        return (NavLoc.turnAroundCommand(), "around")
    }

    /// The turn that puts the user back on the leg's bearing — and nothing else.
    ///
    /// This used to append "to face the route" to every command it built. The
    /// clause named the goal instead of the action, arrived after the word the
    /// user has to act on, and made this cue sound like a different species of
    /// instruction from the identical command `updateRecoveryIfNeeded` speaks.
    /// Removed on reviewer instruction, 15 Aug 2026.
    private static func routeAlignmentInstruction(
        from heading: Double,
        to targetBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> String {
        relativeTurnCommand(from: heading, to: targetBearing, style: style).text
    }

    /// How many real turns the route contains, for the opening overview.
    ///
    /// Counts joints, not nodes: a route of N legs has N−1 joints, and a joint
    /// the walker crosses without changing direction is not a turn they need
    /// to be warned about. The 18° floor is `turnInstruction`'s own
    /// straight-ahead threshold, so the overview promises exactly as many
    /// turns as the route will go on to speak.
    private static func turnCount(in steps: [SemanticRouteStep]) -> Int {
        guard steps.count > 1 else { return 0 }
        return zip(steps, steps.dropFirst()).reduce(into: 0) { total, pair in
            let diff = SemanticRouteMath.signedAngleDifference(
                pair.1.edge.bearingDegrees,
                pair.0.edge.bearingDegrees
            )
            if abs(diff) >= straightAheadMaximumDegrees { total += 1 }
        }
    }

    private static let straightAheadMaximumDegrees = 18.0

    private static func turnInstruction(
        from currentBearing: Double,
        to nextBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> String {
        let diff = SemanticRouteMath.signedAngleDifference(nextBearing, currentBearing)
        let magnitude = abs(diff)
        if magnitude < straightAheadMaximumDegrees { return NavLoc.continueStraight() }
        // Before the style branch: see `turnAroundMinimumDegrees`.
        if magnitude >= turnAroundMinimumDegrees { return NavLoc.turnAroundFragment() }
        if style == .clockFace {
            return NavLoc.clockFragment(hour: clockHour(forSignedDegrees: diff))
        }
        if magnitude < 45 { return diff > 0 ? NavLoc.slightRight() : NavLoc.slightLeft() }
        if magnitude < 110 { return diff > 0 ? NavLoc.turnRight() : NavLoc.turnLeft() }
        if magnitude < 150 { return diff > 0 ? NavLoc.turnSharpRight() : NavLoc.turnSharpLeft() }
        return NavLoc.turnAroundFragment()
    }

    private func turnInstruction(at node: SemanticRouteNode, from currentBearing: Double, to nextBearing: Double) -> String {
        // Corners keep their dedicated phrasing in every mode; recorded
        // left/right hints lose to computed geometry in clock-face mode
        // because the hint carries no magnitude.
        if let hint = node.turnHint, turnPhrasing == .leftRight || hint.isCorner {
            return Self.directionCorrected(hint, from: currentBearing, to: nextBearing).spokenInstruction
        }
        return Self.turnInstruction(from: currentBearing, to: nextBearing, style: turnPhrasing)
    }

    /// A recorded hint is a label from the capture walk. Walked the other way
    /// the same node turns the opposite way, and the stored hint does not move
    /// — so on every return journey "Left turn 2" was spoken as "turn left"
    /// while the user had to go right. Mirror the hint when the live geometry
    /// clearly contradicts it, which keeps its phrasing (a corner stays a
    /// corner) while pointing the right way. Only a decisive disagreement
    /// counts: near-straight geometry has no handedness to contradict, and the
    /// mapper's label is the better guide there.
    private static func directionCorrected(
        _ hint: SemanticTurnHint,
        from currentBearing: Double,
        to nextBearing: Double
    ) -> SemanticTurnHint {
        let diff = SemanticRouteMath.signedAngleDifference(nextBearing, currentBearing)
        guard abs(diff) >= hintContradictionMinimumDegrees else { return hint }
        switch hint {
        case .left, .cornerLeft: return diff > 0 ? hint.mirrored : hint
        case .right, .cornerRight: return diff < 0 ? hint.mirrored : hint
        case .straight, .corner: return hint
        }
    }

    /// Feeds the walker's own stride into the spoken step count.
    ///
    /// A pilot participant heard "20 steps" and arrived in 12 to 14, on every
    /// leg, and asked the right question: the route metres were correct, so
    /// why was the count not? Because the count was metres ÷ 0.65, and 0.65 m
    /// was never her stride. `IMUSensorManager` had been measuring the real
    /// one all along — per step, and calibrated per user — and nothing was
    /// reading it.
    ///
    /// A median, not a mean: step length is `beta * pvDiff^0.25`, and a single
    /// stumble or a jostle in a crowded aisle produces an outlier that a mean
    /// would carry into every distance spoken afterwards.
    /// `stepLengthMinimumSamples` must land before the estimate is trusted at
    /// all, so a route's opening cue is not built on two steps of evidence.
    ///
    /// Guidance phases only. A capture walk is paced by whoever is mapping the
    /// store, and their stride is not the stride the participant who later
    /// walks the route will take.
    private func observeStepLength(_ imuState: IMUState) {
        guard phase == .navigating || phase == .recovering else { return }
        guard imuState.stepCount > (lastObservedStepCount ?? -1) else { return }
        lastObservedStepCount = imuState.stepCount
        let measured = imuState.currentStepLength
        guard measured.isFinite,
              measured >= NavigationDistanceUnit.minimumMetersPerStep,
              measured <= NavigationDistanceUnit.maximumMetersPerStep else {
            return
        }
        observedStepLengths.append(measured)
        if observedStepLengths.count > Self.stepLengthWindow {
            observedStepLengths.removeFirst(observedStepLengths.count - Self.stepLengthWindow)
        }
        guard observedStepLengths.count >= Self.stepLengthMinimumSamples else { return }
        let sorted = observedStepLengths.sorted()
        NavigationUnits.metersPerStep = sorted[sorted.count / 2]
    }

    private static let stepLengthWindow = 20
    private static let stepLengthMinimumSamples = 8

    /// Tracks whether the walker is moving, independently of the walk-reprompt
    /// clock. See `movementStoppedAt`.
    private func recordMovementState(_ imuState: IMUState) {
        if imuState.isMoving {
            movementStoppedAt = nil
        } else if movementStoppedAt == nil {
            movementStoppedAt = Date()
        }
    }

    /// A distance as the user asked to hear it. Every SPOKEN distance goes
    /// through here; `formatMeters` stays literal metres for the mapping
    /// screen and the diagnostic reason strings, which are read by whoever is
    /// debugging a route rather than by whoever is walking it.
    private static func formatDistance(_ meters: Double) -> String {
        switch NavigationUnits.current {
        case .meters: return formatMeters(meters)
        case .feet: return formatFeet(meters)
        case .steps: return formatSteps(meters)
        }
    }

    /// A countdown beat. The last two counts drop the unit — "2", "1" — because
    /// by then it has been said twice already and the user is counting paces
    /// into a maneuver, not measuring a distance.
    ///
    /// The count is taken in whatever unit is active, never in metres and then
    /// spoken as if it were steps: at 2 m a steps-mode user is three steps out,
    /// and a bare "2" there would stop them a step early.
    private static func formatCountdownDistance(_ meters: Double) -> String {
        let clamped = max(0, meters)
        let count: Int
        switch NavigationUnits.current {
        case .meters:
            count = max(1, Int(clamped.rounded()))
        case .feet:
            count = max(1, Int((clamped * NavigationDistanceUnit.feetPerMeter).rounded()))
        case .steps:
            count = max(1, Int((clamped / NavigationUnits.metersPerStep).rounded()))
        }
        return count <= 2 ? String(count) : formatDistance(clamped)
    }

    /// Metres → walking steps. Never returns zero: "less than one step" is not
    /// something a walking user can act on, and every call site here is
    /// already guarded by an arrival check for the genuinely-there case.
    ///
    /// The divisor is the WALKER's measured stride, not a constant — see
    /// `NavigationUnits.metersPerStep`.
    private static func formatSteps(_ meters: Double) -> String {
        let raw = max(0, meters) / NavigationUnits.metersPerStep
        let count = max(1, Int(raw.rounded()))
        if count == 1 { return NavLoc.oneStep() }
        // Past this the exact count is false precision — it is well inside the
        // spread of one person's stride — and a round number is easier to hold.
        if count > stepCountRoundingThreshold {
            let rounded = Int((Double(count) / 5.0).rounded()) * 5
            return NavLoc.aboutSteps(max(5, rounded))
        }
        return NavLoc.steps(count)
    }

    private static let stepCountRoundingThreshold = 20

    /// Metres → feet, rounded the way a walker can hold: exact under 20 ft,
    /// to the nearest 5 above it.
    private static func formatFeet(_ meters: Double) -> String {
        let raw = max(0, meters) * NavigationDistanceUnit.feetPerMeter
        if raw < 1 { return NavLoc.lessThanOneFoot() }
        let count = max(1, Int(raw.rounded()))
        if count == 1 { return NavLoc.oneFoot() }
        if count > feetRoundingThreshold {
            let rounded = Int((Double(count) / 5.0).rounded()) * 5
            return NavLoc.aboutFeet(max(5, rounded))
        }
        return NavLoc.feet(count)
    }

    private static let feetRoundingThreshold = 20

    private static func formatMeters(_ meters: Double) -> String {
        let clamped = max(0, meters)
        if clamped < 1 {
            return NavLoc.lessThanOneMeter()
        }
        if clamped < 1.5 {
            return NavLoc.aboutOneMeter()
        }
        return NavLoc.meters(Int(round(clamped)))
    }

    private static func formatShortMeters(_ meters: Double) -> String {
        let clamped = max(0, meters)
        if clamped < 1.5 {
            return NavLoc.oneMeter()
        }
        return NavLoc.meters(Int(round(clamped)))
    }

    private static func aliases(for name: String) -> [String] {
        let lower = sanitizedSpokenLabel(name).lowercased()
        guard !lower.isEmpty else { return [] }
        var aliases: Set<String> = [lower]
        aliases.insert(lower.replacingOccurrences(of: "_", with: " "))
        aliases.insert(lower.replacingOccurrences(of: "-", with: " "))
        let withoutLeadingArticles = normalizedLookupKey(lower)
        if !withoutLeadingArticles.isEmpty {
            aliases.insert(withoutLeadingArticles)
        }
        if lower.hasSuffix("s") {
            aliases.insert(String(lower.dropLast()))
        } else {
            aliases.insert("\(lower)s")
        }
        return Array(aliases).sorted()
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        normalizedLookupKey(lhs) == normalizedLookupKey(rhs)
    }

    /// Tolerant spoken-label match for ASR noise: absorbs plural drift
    /// ("onion" vs "onions") via edit distance and accent-driven phonetic
    /// swaps ("serial" vs "cereal") via a consonant-skeleton key. Exact
    /// matching must always be tried first — this is the fallback layer.
    static func fuzzyMatchesSpokenTarget(_ lhs: String, _ rhs: String) -> Bool {
        let a = normalizedLookupKey(lhs)
        let b = normalizedLookupKey(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        // Numbered labels must stay exact on the number: one edit is all
        // that separates "aisle 3" from "aisle 4". Short labels ("milk")
        // stay exact-only so one edit can't cross to a different word.
        if digitTokens(a) == digitTokens(b) {
            let shorter = min(a.count, b.count)
            let allowedEdits = shorter >= 8 ? 2 : (shorter >= 5 ? 1 : 0)
            if allowedEdits > 0, levenshteinDistance(a, b) <= allowedEdits { return true }
        }
        let phoneticA = phoneticKey(a)
        return phoneticA.count >= 2 && phoneticA == phoneticKey(b)
    }

    /// Token-containment score between a saved label and a spoken target.
    ///
    /// Edit distance and the phonetic key both compare whole strings, so
    /// "400 lounge room" never reaches the saved "400 lounge". Treat the
    /// shorter token list being wholly contained in the longer one as a match
    /// and return how many tokens lined up, so the caller can prefer the most
    /// specific label and refuse ties. Digit tokens must agree exactly, or
    /// "lounge" would match "400 lounge" and "500 lounge" equally well.
    ///
    /// ⚠️ Mirrors `containmentScore` in `src/services/TargetGroundingService.ts`.
    static func containmentScore(_ lhs: String, _ rhs: String) -> Int {
        let a = normalizedLookupKey(lhs)
        let b = normalizedLookupKey(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        guard digitTokens(a) == digitTokens(b) else { return 0 }

        let lhsTokens = a.split(separator: " ").map(String.init)
        let rhsTokens = b.split(separator: " ").map(String.init)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }

        return consumeTokens(lhsTokens, rhsTokens)
    }

    /// Token containment where the tokens are compared by phonetic key.
    ///
    /// `containmentScore` compares tokens literally, so a single ASR slip
    /// anywhere in a multi-word label collapses the rung entirely. The saved
    /// label "Krave cereal" is the field case: dictation hears "crave",
    /// "serial", or both, and the target handed down is often only part of the
    /// label ("crave") or the label plus a filler ("crave cereal aisle").
    /// None of those reach the whole-string phonetic key either, because that
    /// compares the full string — so guidance dead-ended, and whether a query
    /// worked came down to whether the classifier happened to return the exact
    /// full label.
    ///
    /// Comparing token keys makes them collide deterministically. The guards
    /// are unchanged: digit tokens must agree exactly, one-character skeletons
    /// are refused as too weak to be evidence, and the caller still declines
    /// to guess between two labels that tie.
    ///
    /// ⚠️ Mirrors `phoneticContainmentScore` in
    ///    `src/services/TargetGroundingService.ts`.
    static func phoneticContainmentScore(_ lhs: String, _ rhs: String) -> Int {
        let a = normalizedLookupKey(lhs)
        let b = normalizedLookupKey(rhs)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        guard digitTokens(a) == digitTokens(b) else { return 0 }

        // Digits pass through phoneticKey unchanged, so the digit guard above
        // still holds after keying.
        let lhsKeys = a.split(separator: " ").map { phoneticKey(String($0)) }
        let rhsKeys = b.split(separator: " ").map { phoneticKey(String($0)) }
        guard !lhsKeys.isEmpty, !rhsKeys.isEmpty else { return 0 }
        // Digits are exempt from the minimum-skeleton test: phoneticKey passes
        // them through unchanged, so a single digit is a literal rather than a
        // weak skeleton. Without the exemption "Aisle 3" keys to ["asl", "3"],
        // the "3" trips the test, and this rung is silently dead for every
        // numbered label — while the digit guard above is already what keeps
        // "aisle 3" and "aisle 4" apart.
        let tooWeak: (String) -> Bool = { key in
            !key.allSatisfy(\.isNumber) && key.count < 2
        }
        guard !(lhsKeys + rhsKeys).contains(where: tooWeak) else { return 0 }

        return consumeTokens(lhsKeys, rhsKeys)
    }

    /// Is the shorter token list wholly contained in the longer one? Matches
    /// are consumed so a repeated token needs a partner on both sides.
    private static func consumeTokens(_ lhsTokens: [String], _ rhsTokens: [String]) -> Int {
        let shorter = lhsTokens.count <= rhsTokens.count ? lhsTokens : rhsTokens
        var pool = lhsTokens.count <= rhsTokens.count ? rhsTokens : lhsTokens

        for token in shorter {
            guard let index = pool.firstIndex(of: token) else { return 0 }
            pool.remove(at: index)
        }
        return shorter.count
    }

    private static func digitTokens(_ s: String) -> String {
        s.split(separator: " ")
            .filter { $0.allSatisfy(\.isNumber) }
            .joined(separator: " ")
    }

    private static func levenshteinDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Consonant-skeleton phonetic key: soft/hard c resolution plus common
    /// digraphs, then vowels dropped and doubles collapsed, so "cereal" and
    /// "serial" both reduce to "srl". Digit-only tokens are kept verbatim so
    /// "aisle 3" and "aisle 4" never collide.
    static func phoneticKey(_ raw: String) -> String {
        AppLocale.current == .fr ? phoneticKeyFrench(raw) : phoneticKeyEnglish(raw)
    }

    /// Fold Latin-1 diacritics to ASCII so "crème" survives the alphanumeric
    /// filters below. Mirrors `foldDiacritics` in TargetGroundingService.ts.
    ///
    /// Ligatures are expanded explicitly: `.folding(.diacriticInsensitive)`
    /// leaves "œ" intact, and because Swift counts it as alphanumeric while the
    /// JS side's ASCII regex does not, "œuf" would key differently on each
    /// side. Expanding to "oe" makes both agree and is the correct reading.
    static func foldDiacritics(_ raw: String) -> String {
        raw
            .folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "Œ", with: "OE")
            .replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "Æ", with: "AE")
    }

    /// French consonant-skeleton key.
    ///
    /// ⚠️ Mirrors `phoneticKeyFrench` in `src/services/TargetGroundingService.ts`.
    /// The two must stay identical — JS grounds the target before the AR
    /// session opens and native re-matches it afterwards; if they disagree, a
    /// target that grounds in JS dead-ends natively.
    static func phoneticKeyFrench(_ raw: String) -> String {
        var keys: [String] = []
        for word in foldDiacritics(raw).lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted) where !word.isEmpty {
            if word.allSatisfy(\.isNumber) {
                keys.append(word)
                continue
            }

            // Digraphs first — order matters: 'eau' before 'au', 'ch' before 'c'.
            var normalized = word
                .replacingOccurrences(of: "eau", with: "o")
                .replacingOccurrences(of: "au", with: "o")
                .replacingOccurrences(of: "ou", with: "u")
                .replacingOccurrences(of: "ai", with: "e")
                .replacingOccurrences(of: "ei", with: "e")
                .replacingOccurrences(of: "ay", with: "e")
                .replacingOccurrences(of: "ey", with: "e")
                .replacingOccurrences(of: "ph", with: "f")
                .replacingOccurrences(of: "ch", with: "S")
                .replacingOccurrences(of: "gn", with: "N")
                .replacingOccurrences(of: "qu", with: "k")
                .replacingOccurrences(of: "th", with: "t")
                .replacingOccurrences(of: "h", with: "")

            // Silent word-final letters, stripped in this order and BEFORE the
            // single-character swaps below. French stacks them — "haricots"
            // ends in a plural 's' on top of an already-silent 't' — so a
            // single pass, or a pass after 'x' has become 'ks', leaves
            // singular and plural with different keys. Order is load-bearing:
            //   1. plural marker   haricots → haricot,  eaux → eau
            //   2. silent final e  creme    → crem
            //   3. silent final consonant   haricot → harico
            if let last = normalized.last, "sx".contains(last) {
                normalized = String(normalized.dropLast())
            }
            if normalized.hasSuffix("e") { normalized = String(normalized.dropLast()) }
            if let last = normalized.last, "tdpzgs".contains(last) {
                normalized = String(normalized.dropLast())
            }

            // Soft/hard c, then the remaining one-to-one swaps.
            let cChars = Array(normalized)
            var afterC = ""
            for (index, ch) in cChars.enumerated() {
                if ch == "c" {
                    let next = index + 1 < cChars.count ? cChars[index + 1] : " "
                    afterC.append("eiy".contains(next) ? "s" : "k")
                } else {
                    afterC.append(ch)
                }
            }
            normalized = afterC
                .replacingOccurrences(of: "z", with: "s")
                .replacingOccurrences(of: "x", with: "ks")
                .replacingOccurrences(of: "y", with: "i")

            var key = ""
            for (index, ch) in normalized.enumerated() {
                if index > 0, "aeiou".contains(ch) { continue }
                if let last = key.last, last == ch { continue }
                key.append(ch)
            }
            keys.append(key)
        }
        return keys.joined(separator: " ")
    }

    static func phoneticKeyEnglish(_ raw: String) -> String {
        var keys: [String] = []
        for word in raw.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted) where !word.isEmpty {
            if word.allSatisfy(\.isNumber) {
                keys.append(word)
                continue
            }
            var normalized = word
                .replacingOccurrences(of: "ph", with: "f")
                .replacingOccurrences(of: "gh", with: "g")
                .replacingOccurrences(of: "wh", with: "w")
            if normalized.hasPrefix("wr") { normalized = String(normalized.dropFirst()) }
            if normalized.hasPrefix("kn") { normalized = String(normalized.dropFirst()) }
            // Strip a single trailing plural 's' before the skeleton is built,
            // the same silent-letter pass phoneticKeyFrench already does.
            // Without it a spoken plural ("cereals") stacked on a phonetic
            // slip ("serials") keys differently from a singular saved label
            // ("Cereal") — "srls" vs "srl" — even though fuzzyMatchesSpokenTarget's
            // edit-distance rung already absorbs plural drift on its own for
            // words with no phonetic slip.
            if normalized.hasSuffix("s") { normalized = String(normalized.dropLast()) }

            let chars = Array(normalized)
            var mapped = ""
            for (index, ch) in chars.enumerated() {
                switch ch {
                case "c":
                    let next = index + 1 < chars.count ? chars[index + 1] : " "
                    mapped.append("eiy".contains(next) ? "s" : "k")
                case "q":
                    mapped.append("k")
                case "z":
                    mapped.append("s")
                case "x":
                    mapped.append("ks")
                default:
                    mapped.append(ch)
                }
            }

            var key = ""
            for (index, ch) in mapped.enumerated() {
                if index > 0, "aeiou".contains(ch) { continue }
                if let last = key.last, last == ch { continue }
                key.append(ch)
            }
            keys.append(key)
        }
        return keys.joined(separator: " ")
    }

    /// Leading articles stripped before lookup, per language. French adds the
    /// partitives ("des oignons", "de la crème") — a shopper never says the
    /// bare noun, so without these the target misses its own map label.
    private static var lookupArticles: Set<String> {
        AppLocale.current == .fr
            ? ["le", "la", "les", "l", "un", "une", "des", "du", "de", "au", "aux"]
            : ["the", "a", "an"]
    }

    private static func normalizedLookupKey(_ raw: String) -> String {
        let tokens = foldDiacritics(sanitizedSpokenLabel(raw))
            .lowercased()
            .replacingOccurrences(of: "doorknob", with: "door knob")
            .replacingOccurrences(of: "doorhandle", with: "door handle")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let lookupNoise = Set(["room", "rm", "suite", "office"])
        let articles = lookupArticles
        let withoutArticles = tokens.drop { articles.contains($0) }
        let meaningfulTokens = withoutArticles.filter { lookupNoise.contains($0) == false }
        return canonicalizedLookupTokens(Array(meaningfulTokens)).joined(separator: " ")
    }

    private static func canonicalizedLookupTokens(_ tokens: [String]) -> [String] {
        var canonical: [String] = []
        var index = 0
        while index < tokens.count {
            if index + 1 < tokens.count {
                let pair = "\(tokens[index]) \(tokens[index + 1])"
                if pair == "door knob" {
                    canonical.append("doorknob")
                    index += 2
                    continue
                }
                if pair == "door handle" {
                    canonical.append("doorhandle")
                    index += 2
                    continue
                }
            }
            canonical.append(tokens[index])
            index += 1
        }
        return canonical
    }

    /// Two samples are only a navigation hazard when they look alike AND come
    /// from different places on the route (perceptual aliasing). Neighboring
    /// keyframes along a corridor are SUPPOSED to look similar — counting them
    /// as aliases blocked every save of a normal corridor walkthrough.
    private static let aliasMinimumSeparationMeters: Double = 3.0

    private static func visualAliasGroups(in map: SemanticRouteMap) -> [SemanticRouteVisualAliasGroup] {
        guard let fingerprints = map.visualFingerprints, fingerprints.count >= 2 else { return [] }
        let fingerprinter = ARFrameFingerprinter()
        let ordered = fingerprints.keys.sorted()
        let capturePositions = fingerprintCapturePositions(in: map)
        let captureHeadings = fingerprintCaptureHeadings(in: map)
        // Unarchive each Vision feature print once, not once per pair.
        let observations = Dictionary(uniqueKeysWithValues: ordered.compactMap { id in
            fingerprints[id].flatMap { fingerprinter.featurePrintObservation(for: $0).map { obs in (id, obs) } }
        })
        var groups: [SemanticRouteVisualAliasGroup] = []

        for leftIndex in 0..<(ordered.count - 1) {
            for rightIndex in (leftIndex + 1)..<ordered.count {
                let leftID = ordered[leftIndex]
                let rightID = ordered[rightIndex]
                guard let left = fingerprints[leftID],
                      let right = fingerprints[rightID] else {
                    continue
                }
                if let leftPoint = capturePositions[leftID],
                   let rightPoint = capturePositions[rightID],
                   leftPoint.distance(to: rightPoint) < aliasMinimumSeparationMeters {
                    continue
                }
                // Opposite-facing keyframes are never candidates in the same
                // live match (visualRouteCandidates gates on heading), so they
                // cannot confuse guidance and are not an alias pair. Skipping
                // them also keeps this O(n²) pass affordable once a route
                // carries both walking directions.
                if let leftHeading = captureHeadings[leftID],
                   let rightHeading = captureHeadings[rightID],
                   abs(SemanticRouteMath.signedAngleDifference(leftHeading, rightHeading)) > aliasHeadingGateDegrees {
                    continue
                }
                let similarity = fingerprinter.similarity(
                    left, right,
                    lhsObservation: observations[leftID],
                    rhsObservation: observations[rightID]
                )
                guard similarity >= 0.82 else { continue }
                let names = [
                    representativeName(forFingerprintID: leftID, in: map),
                    representativeName(forFingerprintID: rightID, in: map)
                ]
                .compactMap { sanitizedSpokenLabel($0).nilIfBlank }
                groups.append(
                    SemanticRouteVisualAliasGroup(
                        id: "\(leftID)__\(rightID)",
                        fingerprintIds: [leftID, rightID],
                        representativeNames: Array(Set(names)).sorted(),
                        similarity: Double(similarity)
                    )
                )
            }
        }

        return groups
    }

    /// Best-known capture position for each visual fingerprint: keyframe pose,
    /// or the anchor node position for landmark samples. Fingerprints without
    /// a resolvable position stay eligible for aliasing (conservative).
    private static func fingerprintCapturePositions(in map: SemanticRouteMap) -> [String: SemanticRoutePoint] {
        var positions: [String: SemanticRoutePoint] = [:]
        for keyframe in map.keyframes ?? [] {
            if let fingerprintID = keyframe.visualFingerprintId {
                positions[fingerprintID] = keyframe.pose
            }
        }
        let nodesByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        for landmark in map.landmarks {
            guard let node = nodesByID[landmark.nodeID] else { continue }
            for fingerprintID in landmark.visualFingerprintIds ?? [] where positions[fingerprintID] == nil {
                positions[fingerprintID] = node.point
            }
        }
        return positions
    }

    /// Capture heading per fingerprint. Only keyframes record one; landmark
    /// samples have no heading and stay eligible for every alias pair.
    private static func fingerprintCaptureHeadings(in map: SemanticRouteMap) -> [String: Double] {
        var headings: [String: Double] = [:]
        for keyframe in map.keyframes ?? [] {
            if let fingerprintID = keyframe.visualFingerprintId,
               let heading = keyframe.headingDegrees {
                headings[fingerprintID] = heading
            }
        }
        return headings
    }

    private static func representativeName(forFingerprintID fingerprintID: String, in map: SemanticRouteMap) -> String? {
        if let keyframe = map.keyframes?.first(where: { $0.visualFingerprintId == fingerprintID }) {
            if let edgeID = keyframe.segmentID,
               let edge = map.edges.first(where: { $0.id == edgeID }),
               let from = map.nodes.first(where: { $0.id == edge.fromNodeID }),
               let to = map.nodes.first(where: { $0.id == edge.toNodeID }) {
                return "\(from.name) to \(to.name)"
            }
            return String(format: "keyframe %.1fm", keyframe.distanceFromSegmentStart)
        }
        if let landmark = map.landmarks.first(where: { ($0.visualFingerprintIds ?? []).contains(fingerprintID) }) {
            return landmark.name
        }
        return nil
    }

    private static func captureQuality(for map: SemanticRouteMap, aliasGroups: [SemanticRouteVisualAliasGroup]) -> SemanticRouteCaptureQuality {
        let keyframeCount = map.keyframes?.count ?? 0
        let visualSampleCount = map.visualFingerprints?.count ?? 0
        let routeDistance = map.edges.reduce(0) { $0 + $1.distanceMeters }
        let averageSpacing = keyframeCount > 1 ? routeDistance / Double(max(keyframeCount - 1, 1)) : nil
        let aliasedIDs = Set(aliasGroups.flatMap(\.fingerprintIds))
        let minimumVisualSamples = min(6, max(2, map.edges.count + 1))
        let hasMinimumSpatialEvidence = map.nodes.contains { $0.kind == .entrance } &&
            map.nodes.contains { $0.kind == .destination } &&
            !map.edges.isEmpty &&
            routeDistance >= 0.75
        let hasMinimumVisualEvidence = visualSampleCount >= minimumVisualSamples && keyframeCount >= max(2, map.edges.count)

        var warnings: [String] = []
        if !hasMinimumSpatialEvidence {
            warnings.append("Capture a start, destination, and measured route segment.")
        }
        if keyframeCount < max(2, map.edges.count) {
            warnings.append("Walk the route while mapping so visual keyframes are sampled.")
        }
        if visualSampleCount < minimumVisualSamples {
            warnings.append("Add more visual samples from multiple viewpoints.")
        }
        if let averageSpacing, averageSpacing > 1.4 {
            warnings.append("Keyframes are sparse; walk more slowly or rescan the route.")
        }
        if aliasedIDs.count > max(1, visualSampleCount / 3) {
            warnings.append("Distant parts of the route look identical; add a distinctive landmark near each.")
        }
        let overlaps = overlappingCorridorCount(in: map)
        if overlaps > 0 {
            warnings.append("The route passes through \(overlaps) spot\(overlaps == 1 ? "" : "s") twice heading different ways; guidance can pick the wrong direction there.")
        }

        return SemanticRouteCaptureQuality(
            keyframeCount: keyframeCount,
            visualSampleCount: visualSampleCount,
            aliasedVisualSampleCount: aliasedIDs.count,
            routeDistanceMeters: routeDistance,
            averageKeyframeSpacingMeters: averageSpacing,
            hasMinimumSpatialEvidence: hasMinimumSpatialEvidence,
            hasMinimumVisualEvidence: hasMinimumVisualEvidence,
            warnings: warnings,
            overlappingCorridorCount: overlaps
        )
    }

    /// Roughly the AR pose error near a turn: closer than this and a pose that
    /// errs toward the foreign edge will snap to it.
    private static let overlappingCorridorProximityMeters = 1.0
    /// Below this the two edges lead the same way, so picking the wrong one
    /// costs the user nothing.
    private static let overlappingCorridorBearingDegrees = 60.0

    /// Counts nodes that sit within `overlappingCorridorProximityMeters` of an
    /// edge they are not an endpoint of, where that edge heads a materially
    /// different way than the node's own.
    ///
    /// Proximity alone over-reports: a corridor with a slight kink puts every
    /// node near its neighbour's edge, and snapping to the wrong one of two
    /// near-parallel edges leads to the same place anyway. The bearing test is
    /// what isolates real trouble — the route crossing or doubling back
    /// through somewhere it has already been. On the captured floor that
    /// misrouted a walk, this flags the five genuine overlaps (including the
    /// turn node sitting 0.25 m off an edge running 96° away, which is where
    /// start resolution latched onto the wrong corridor) and correctly ignores
    /// four benign kinks.
    private static func overlappingCorridorCount(in map: SemanticRouteMap) -> Int {
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        var count = 0
        for node in map.nodes {
            // The direction the user actually travels through this node.
            // Destinations have no outgoing edge, so fall back to arrival.
            let ownBearing = map.edges.first(where: { $0.fromNodeID == node.id })?.bearingDegrees
                ?? map.edges.first(where: { $0.toNodeID == node.id })?.bearingDegrees
            guard let ownBearing else { continue }
            for edge in map.edges {
                guard edge.fromNodeID != node.id, edge.toNodeID != node.id,
                      let from = nodeByID[edge.fromNodeID], let to = nodeByID[edge.toNodeID] else { continue }
                let projection = project(node.point, from: from.point, to: to.point, distance: edge.distanceMeters)
                guard projection.crossTrackMeters <= overlappingCorridorProximityMeters else { continue }
                let divergence = abs(SemanticRouteMath.signedAngleDifference(ownBearing, edge.bearingDegrees))
                if divergence > overlappingCorridorBearingDegrees {
                    count += 1
                }
            }
        }
        return count
    }

    /// Route-frame axis convention where y = -(ARKit z), making bearings
    /// increase on physical right turns. See SemanticRouteMap.axisConvention.
    static let northUpAxisConvention = 2

    /// Legacy ar_world_xz maps stored raw ARKit z as route-y — a left-handed
    /// ground frame in which every geometric left/right cue and the exported
    /// top-down plot came out mirrored. Flip them once into the compass-like
    /// frame: negate stored y and remap stored angles via θ' = 180° - θ
    /// (because atan2(a, -b) = 180° - atan2(a, b)). User-marked turn hints
    /// and landmark sides are physical ground truth and stay untouched.
    private static func migratedToNorthUpAxes(_ map: SemanticRouteMap) -> SemanticRouteMap {
        guard map.coordinateSpace == "ar_world_xz",
              (map.axisConvention ?? 1) < northUpAxisConvention else { return map }
        func flippedAngle(_ degrees: Double) -> Double {
            SemanticRouteMath.normalizedDegrees(180 - degrees)
        }
        var migrated = map
        migrated.nodes = map.nodes.map { node in
            var copy = node
            copy.point.y = -copy.point.y
            copy.headingDegrees = copy.headingDegrees.map(flippedAngle)
            return copy
        }
        migrated.keyframes = map.keyframes?.map { keyframe in
            var copy = keyframe
            copy.pose.y = -copy.pose.y
            copy.headingDegrees = copy.headingDegrees.map(flippedAngle)
            return copy
        }
        migrated.edges = map.edges.map { edge in
            var copy = edge
            copy.bearingDegrees = flippedAngle(edge.bearingDegrees)
            copy.reverseBearingDegrees = flippedAngle(edge.reverseBearingDegrees)
            return copy
        }
        migrated.axisConvention = northUpAxisConvention
        return migrated
    }

    private static func sanitizedMap(_ map: SemanticRouteMap) -> SemanticRouteMap {
        var cleaned = map
        let storedFingerprints = map.visualFingerprints ?? [:]
        cleaned.name = sanitizedSpokenLabel(map.name, fallback: "AR Route")
        cleaned.nodes = map.nodes.map { node in
            var copy = node
            copy.name = sanitizedSpokenLabel(node.name, fallback: node.kind.displayName)
            copy.aliases = aliases(for: copy.name)
            copy.poiAnchorId = sanitizedSpokenLabel(copy.poiAnchorId ?? "").nilIfBlank
            copy.reachingObjectName = copy.kind == .destination
                ? sanitizedSpokenLabel(copy.reachingObjectName ?? "").nilIfBlank
                : nil
            return copy
        }
        cleaned.edges = map.edges.map { edge in
            var copy = edge
            copy.leftContext = sanitizedSpokenLabel(edge.leftContext ?? "").nilIfBlank
            copy.rightContext = sanitizedSpokenLabel(edge.rightContext ?? "").nilIfBlank
            copy.spokenContext = sanitizedSpokenLabel(edge.spokenContext ?? "").nilIfBlank
            return copy
        }
        cleaned.keyframes = map.keyframes?.map { keyframe in
            var copy = keyframe
            if let fingerprintID = copy.visualFingerprintId,
               storedFingerprints[fingerprintID] == nil {
                copy.visualFingerprintId = nil
            }
            return copy
        }
        cleaned.landmarks = map.landmarks.compactMap { landmark in
            let name = sanitizedSpokenLabel(landmark.name)
            guard !name.isEmpty else { return nil }
            var copy = landmark
            copy.name = name
            copy.aliases = aliases(for: name)
            copy.context = sanitizedSpokenLabel(landmark.context ?? "").nilIfBlank
            copy.visualFingerprintIds = (landmark.visualFingerprintIds ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && storedFingerprints[$0] != nil }
            if copy.visualFingerprintIds?.isEmpty == true {
                copy.visualFingerprintIds = nil
            }
            return copy
        }
        let referencedFingerprintIDs = Set(
            (cleaned.keyframes ?? []).compactMap(\.visualFingerprintId)
            + cleaned.landmarks.flatMap { $0.visualFingerprintIds ?? [] }
        )
        let referencedFingerprints = Dictionary(uniqueKeysWithValues: referencedFingerprintIDs.compactMap { id in
            storedFingerprints[id].map { (id, $0) }
        })
        cleaned.visualFingerprints = referencedFingerprints.isEmpty ? nil : referencedFingerprints
        let aliasGroups = visualAliasGroups(in: cleaned)
        cleaned.visualAliasGroups = aliasGroups.isEmpty ? nil : aliasGroups
        cleaned.captureQuality = captureQuality(for: cleaned, aliasGroups: aliasGroups)
        cleaned.visualSamplesVersion = 1
        return cleaned
    }

    private static func sanitizedSpokenLabel(_ raw: String?, fallback: String = "") -> String {
        guard let raw else { return fallback }
        let initial = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !initial.isEmpty else { return fallback }

        if let extracted = extractJSONLabel(from: initial) {
            return sanitizedSpokenLabel(extracted, fallback: fallback)
        }

        let badLiteral = initial.lowercased()
        if ["{}", "[]", "null", "nil", "none", "unknown"].contains(badLiteral) {
            return fallback
        }

        let punctuationToSpace = CharacterSet(charactersIn: "{}[]<>\"`\\|")
        var cleaned = initial
            .components(separatedBy: punctuationToSpace)
            .joined(separator: " ")
            .replacingOccurrences(of: "_", with: " ")
        cleaned = cleaned
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .,;:-"))

        if cleaned.isEmpty { return fallback }
        if cleaned.count <= 72 { return cleaned }

        let words = cleaned.split(separator: " ")
        var limited = ""
        for word in words {
            let candidate = limited.isEmpty ? String(word) : "\(limited) \(word)"
            guard candidate.count <= 72 else { break }
            limited = candidate
        }
        return limited.isEmpty ? String(cleaned.prefix(72)) : limited
    }

    private static func extractJSONLabel(from raw: String) -> String? {
        guard (raw.hasPrefix("{") && raw.hasSuffix("}")) || (raw.hasPrefix("[") && raw.hasSuffix("]")),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let dictionary = object as? [String: Any] {
            for key in ["name", "label", "target", "object", "poi", "title", "text"] {
                if let value = dictionary[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return value
                }
            }
        }

        if let array = object as? [Any] {
            return array.compactMap { $0 as? String }.first
        }

        return nil
    }

    private static func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        return formatter.string(from: Date())
    }
}

#if DEBUG
extension SemanticRouteNavigator {
    func replaceMapsForTesting(_ maps: [SemanticRouteMap], activeMapID: String? = nil) {
        stopNavigation(resetInstruction: false)
        let cleaned = maps.map(Self.sanitizedMap)
        self.maps = cleaned
        activeMap = activeMapID.flatMap { id in cleaned.first { $0.id == id } } ?? cleaned.first
        activeMapDraft = nil
        phase = activeMap == nil ? .idle : .ready
        targetName = ""
        currentInstruction = activeMap == nil ? "Capture or load a semantic map." : "Semantic map ready."
        if let activeMap {
            refreshCaptureMetrics(for: activeMap)
        }
        rebuildRAGContext()
    }

    func setRouteProgressForTesting(
        stepIndex: Int,
        progressMeters: Double,
        markRecentAdvance: Bool = false
    ) {
        guard stepIndex >= 0, stepIndex < routeSteps.count else { return }
        currentStepIndex = stepIndex
        let step = routeSteps[stepIndex]
        segmentProgressMeters = min(max(progressMeters, 0), step.edge.distanceMeters)
        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        if phase != .navigating {
            phase = .navigating
        }
        if markRecentAdvance {
            lastRouteAdvanceAt = Date()
        }
        resetRouteCorrectionGuards()
        rebuildRAGContext()
    }

    /// Discards heading history so the next settle check passes — the test
    /// equivalent of the user finishing a sweep and holding still.
    func settleHeadingForTesting() {
        recentHeadingSamples.removeAll()
    }

    func expireRecoveryHoldForTesting() {
        recoveryStartedAt = Date().addingTimeInterval(-(recoveryHoldSeconds + 0.1))
    }

    func expireGuidanceIntroProtectionForTesting() {
        guidanceIntroProtectedUntil = nil
    }

    /// Backdates the course-correction persistence window, so a test can reach
    /// the cue without holding a drift for two real seconds. Returns false when
    /// no drift is being tracked, which is itself the assertion some tests want.
    @discardableResult
    func expireCourseCorrectionHoldForTesting() -> Bool {
        guard courseCorrectionSince != nil else { return false }
        courseCorrectionSince = Date().addingTimeInterval(-(courseCorrectionHoldSeconds + 0.1))
        return true
    }

    /// Backdates the overshoot hold, so a test can reach the "you have passed
    /// it" cue without walking past the destination for a real second and a
    /// half. Returns false when no overshoot is being tracked, which is itself
    /// the assertion the control test wants.
    @discardableResult
    func expireDestinationOvershootHoldForTesting() -> Bool {
        guard destinationOvershootStartedAt != nil else { return false }
        destinationOvershootStartedAt = Date()
            .addingTimeInterval(-(destinationOvershootHoldSeconds + 0.1))
        return true
    }

    /// Backdates the spoken-cue pacing window just past the approach-cue floor,
    /// so a test can reach the next countdown cue without waiting two real
    /// seconds — and without reaching the twenty-second quiet backstop, which
    /// would speak a cue of its own and mask what is being asserted.
    /// Ages the post-turn wait past `postTurnLegCueMaxWaitSeconds` so a test
    /// can assert the timeout releases the walk instruction without sleeping.
    func expirePostTurnLegCueWaitForTesting() {
        guard pendingPostTurnLegCueArmedAt != nil else { return }
        pendingPostTurnLegCueArmedAt = Date().addingTimeInterval(-postTurnLegCueMaxWaitSeconds - 1)
    }

    func expireCuePacingWindowForTesting() {
        lastRoutineCueAt = Date().addingTimeInterval(-(approachCueMinimumSpacingSeconds + 0.1))
    }

    func forceStillnessRepromptWindowForTesting() {
        stillnessStartedAt = Date().addingTimeInterval(-(stillnessRepromptAfterSeconds + 1))
        lastStillnessRepromptAt = nil
    }

    /// Whether the keyframe heading gate is armed. Armed, it filters keyframes
    /// against the live heading; that is only sound while a visual match has
    /// confirmed the heading.
    var headingGateArmedForTesting: Bool { didCorroborateHeadingVisually }

    /// The state after a visual match has landed, without needing camera frames.
    func armHeadingGateForTesting() {
        didCorroborateHeadingVisually = true
    }

    /// Which step each saved image is attributed to, without needing a camera
    /// frame to score it.
    func visualCandidateAttributionForTesting() -> [(fingerprintID: String, stepIndex: Int)] {
        guard let map = activeMap, let fingerprints = map.visualFingerprints else { return [] }
        return visualRouteCandidates(in: map, fingerprints: fingerprints)
            .map { (fingerprintID: $0.fingerprintID, stepIndex: $0.stepIndex) }
    }
}
#endif

private enum SemanticRouteMath {
    static func normalizedDegrees(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }

    static func signedAngleDifference(_ lhs: Double, _ rhs: Double) -> Double {
        var diff = normalizedDegrees(lhs) - normalizedDegrees(rhs)
        while diff > 180 { diff -= 360 }
        while diff < -180 { diff += 360 }
        return diff
    }
}

// MARK: - Map Debug Report Export

extension SemanticRouteNavigator {

    /// Writes a self-contained HTML debug report (top-down route plot, capture
    /// quality, alias pairs, and the camera frames behind every visual sample)
    /// for the active map and returns its file URL for the share sheet.
    func exportDebugReportURL() -> URL? {
        guard let map = activeMapDraft ?? activeMap ?? maps.first else { return nil }
        let html = Self.debugReportHTML(for: map)
        guard let data = html.data(using: .utf8) else { return nil }

        let safeName = map.name
            .replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        let fileName = "\(safeName.isEmpty ? "route-map" : safeName)-report.html"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    func pruneFrameThumbnails() {
        var referenced = Set<String>()
        for map in maps + [activeMap, activeMapDraft].compactMap({ $0 }) {
            if let keys = map.visualFingerprints?.keys {
                referenced.formUnion(keys)
            }
        }
        SemanticRouteFrameStore.pruneThumbnails(keeping: referenced)
    }

    /// Per-segment count of how many segments hold a keyframe shot facing the
    /// way you walk it, and how many hold one facing the way you walk it back.
    /// The live matcher gates keyframes on heading, so a segment with no
    /// reverse keyframe contributes nothing to a destination → start journey —
    /// this is the readout that says whether an enrichment walk landed.
    private static func directionCoverage(
        for map: SemanticRouteMap,
        keyframes: [SemanticRouteKeyframe]
    ) -> (forward: Int, reverse: Int, total: Int) {
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        var forward = 0
        var reverse = 0

        for edge in map.edges {
            guard let from = nodeByID[edge.fromNodeID], let to = nodeByID[edge.toNodeID] else { continue }
            let onSegment = keyframes.filter { keyframe in
                guard keyframe.headingDegrees != nil else { return false }
                let projection = project(keyframe.pose, from: from.point, to: to.point, distance: edge.distanceMeters)
                return projection.crossTrackMeters <= 1.5 &&
                    projection.alongTrackMeters >= -0.5 &&
                    projection.alongTrackMeters <= edge.distanceMeters + 0.5
            }
            func sees(_ bearing: Double) -> Bool {
                onSegment.contains { keyframe in
                    guard let heading = keyframe.headingDegrees else { return false }
                    return abs(SemanticRouteMath.signedAngleDifference(heading, bearing)) <= visualMatchHeadingGateDegrees
                }
            }
            if sees(edge.bearingDegrees) { forward += 1 }
            if sees(edge.reverseBearingDegrees) { reverse += 1 }
        }

        return (forward, reverse, map.edges.count)
    }

    private static func debugReportHTML(for map: SemanticRouteMap) -> String {
        let quality = map.captureQuality
        let aliasGroups = map.visualAliasGroups ?? visualAliasGroups(in: map)
        let aliasedIDs = Set(aliasGroups.flatMap(\.fingerprintIds))
        let keyframes = (map.keyframes ?? []).sorted { $0.capturedAt < $1.capturedAt }
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        var html = """
        <!DOCTYPE html>
        <html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(htmlEscape(map.name)) — Route Map Report</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px/1.5 -apple-system, system-ui, sans-serif; margin: 0 auto; max-width: 900px; padding: 16px; }
          h1 { font-size: 22px; } h2 { font-size: 17px; margin-top: 28px; }
          .badges span { display: inline-block; border-radius: 6px; padding: 2px 10px; margin: 2px 6px 2px 0; font-size: 13px; background: rgba(120,120,128,0.16); }
          .badges .ok { background: rgba(52,199,89,0.22); } .badges .bad { background: rgba(255,59,48,0.25); }
          .warn { color: #d64545; font-weight: 600; }
          svg { width: 100%; height: auto; background: rgba(120,120,128,0.08); border-radius: 12px; }
          .frames { display: grid; grid-template-columns: repeat(auto-fill, minmax(150px, 1fr)); gap: 12px; }
          .frame { border: 1px solid rgba(120,120,128,0.3); border-radius: 10px; overflow: hidden; font-size: 12px; }
          .frame.aliased { border-color: #d64545; box-shadow: 0 0 0 1px #d64545; }
          .frame img { width: 100%; display: block; }
          .frame .meta { padding: 6px 8px; }
          .frame .tag { font-weight: 700; color: #d64545; }
          table { border-collapse: collapse; width: 100%; font-size: 13px; }
          td, th { border: 1px solid rgba(120,120,128,0.3); padding: 4px 8px; text-align: left; }
          details pre { overflow-x: auto; font-size: 11px; background: rgba(120,120,128,0.1); padding: 10px; border-radius: 8px; }
          .missing { display:flex; align-items:center; justify-content:center; aspect-ratio: 3/4; color: #888; background: rgba(120,120,128,0.12); }
        </style></head><body>
        <h1>\(htmlEscape(map.name))</h1>
        <p>Created \(dateFormatter.string(from: map.createdAt)) · Updated \(dateFormatter.string(from: map.updatedAt)) · Coordinate space: \(htmlEscape(map.coordinateSpace)) (axes v\(map.axisConvention ?? 1))</p>
        """

        if let quality {
            html += "<div class=\"badges\">"
            html += "<span class=\"\(quality.isSufficientForGuidance ? "ok" : "bad")\">\(quality.isSufficientForGuidance ? "Save gate: PASS" : "Save gate: BLOCKED")</span>"
            html += "<span>\(quality.keyframeCount) keyframes</span>"
            html += "<span>\(quality.visualSampleCount) visual samples</span>"
            html += "<span class=\"\(quality.aliasedVisualSampleCount > 0 ? "bad" : "ok")\">\(quality.aliasedVisualSampleCount) aliased</span>"
            // Recomputed when absent so reports on maps saved before the check
            // still show it, rather than silently reading as clean.
            let overlaps = quality.overlappingCorridorCount ?? overlappingCorridorCount(in: map)
            html += "<span class=\"\(overlaps > 0 ? "bad" : "ok")\">\(overlaps) corridor overlap\(overlaps == 1 ? "" : "s")</span>"
            html += String(format: "<span>%.1fm route</span>", quality.routeDistanceMeters)
            if let spacing = quality.averageKeyframeSpacingMeters {
                html += String(format: "<span>%.2fm keyframe spacing</span>", spacing)
            }
            html += "</div>"
            if !quality.warnings.isEmpty {
                html += "<ul>" + quality.warnings.map { "<li class=\"warn\">\(htmlEscape($0))</li>" }.joined() + "</ul>"
            }
        }

        let coverage = directionCoverage(for: map, keyframes: keyframes)
        html += "<div class=\"badges\">"
        html += "<span class=\"\(coverage.forward == coverage.total ? "ok" : "bad")\">Forward coverage: \(coverage.forward)/\(coverage.total) segments</span>"
        html += "<span class=\"\(coverage.reverse == coverage.total ? "ok" : "bad")\">Reverse coverage: \(coverage.reverse)/\(coverage.total) segments</span>"
        html += "</div>"
        if coverage.reverse < coverage.total {
            html += "<ul><li class=\"warn\">Guidance from a destination back toward the start will run without visual matching on the uncovered segments. Load this AR map, relocalize, and run Map → Improve (Walk It Back).</li></ul>"
        }

        html += "<h2>Top-down route</h2>" + svgRoutePlot(for: map, aliasGroups: aliasGroups)

        // Keyframes are counted per direction, by heading against the segment.
        // The old single "Keyframes" column both double-counted (a keyframe
        // carrying `segmentID` is usually also listed in `edge.keyframeIds`)
        // and omitted enrichment keyframes entirely, since those carry no
        // segmentID — so a successful walk-back left the table unchanged.
        html += "<h2>Route structure</h2><table><tr><th>Segment</th><th>Distance</th><th>Bearing</th><th>Forward keyframes</th><th>Reverse keyframes</th></tr>"
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        for edge in map.edges {
            let from = nodeByID[edge.fromNodeID]
            let to = nodeByID[edge.toNodeID]
            var forward = 0
            var reverse = 0
            if let from, let to {
                for keyframe in keyframes {
                    guard let heading = keyframe.headingDegrees else { continue }
                    let projection = project(keyframe.pose, from: from.point, to: to.point, distance: edge.distanceMeters)
                    guard projection.crossTrackMeters <= 1.5,
                          projection.alongTrackMeters >= -0.5,
                          projection.alongTrackMeters <= edge.distanceMeters + 0.5 else { continue }
                    if abs(SemanticRouteMath.signedAngleDifference(heading, edge.bearingDegrees)) <= visualMatchHeadingGateDegrees {
                        forward += 1
                    }
                    if abs(SemanticRouteMath.signedAngleDifference(heading, edge.reverseBearingDegrees)) <= visualMatchHeadingGateDegrees {
                        reverse += 1
                    }
                }
            }
            html += String(
                format: "<tr><td>%@ → %@</td><td>%.1fm</td><td>%.0f°</td><td>%d</td><td class=\"%@\">%d</td></tr>",
                htmlEscape(from?.name ?? "?"), htmlEscape(to?.name ?? "?"),
                edge.distanceMeters, edge.bearingDegrees,
                forward, reverse == 0 ? "warn" : "", reverse
            )
        }
        html += "</table>"

        if !aliasGroups.isEmpty {
            html += "<h2>Perceptual alias pairs (distant places that look alike)</h2><table><tr><th>Places</th><th>Similarity</th></tr>"
            for group in aliasGroups.sorted(by: { $0.similarity > $1.similarity }) {
                let names = group.representativeNames.isEmpty
                    ? group.fingerprintIds.map { String($0.prefix(8)) }
                    : group.representativeNames
                html += String(
                    format: "<tr><td>%@</td><td>%.0f%%</td></tr>",
                    htmlEscape(names.joined(separator: " ↔ ")), group.similarity * 100
                )
            }
            html += "</table>"
        }

        html += "<h2>Captured frames (\(keyframes.count) keyframes)</h2><div class=\"frames\">"
        for (index, keyframe) in keyframes.enumerated() {
            let fingerprintID = keyframe.visualFingerprintId
            let isAliased = fingerprintID.map { aliasedIDs.contains($0) } ?? false
            html += "<div class=\"frame\(isAliased ? " aliased" : "")\">"
            if let fingerprintID, let data = SemanticRouteFrameStore.thumbnailData(for: fingerprintID) {
                html += "<img src=\"data:image/jpeg;base64,\(data.base64EncodedString())\" alt=\"keyframe \(index)\">"
            } else {
                html += "<div class=\"missing\">no frame stored</div>"
            }
            html += String(
                format: "<div class=\"meta\">#%d · pose (%.1f, %.1f)%@%@%@</div>",
                index + 1, keyframe.pose.x, keyframe.pose.y,
                keyframe.headingDegrees.map { String(format: " · %.0f°", $0) } ?? "",
                String(format: " · %.1fm into segment", keyframe.distanceFromSegmentStart),
                isAliased ? " · <span class=\"tag\">ALIASED</span>" : ""
            )
            html += "</div>"
        }
        html += "</div>"

        let landmarkSamples = map.landmarks.flatMap { landmark in
            (landmark.visualFingerprintIds ?? []).map { (landmark.name, $0) }
        }
        if !landmarkSamples.isEmpty {
            html += "<h2>Landmark frames</h2><div class=\"frames\">"
            for (name, fingerprintID) in landmarkSamples {
                let isAliased = aliasedIDs.contains(fingerprintID)
                html += "<div class=\"frame\(isAliased ? " aliased" : "")\">"
                if let data = SemanticRouteFrameStore.thumbnailData(for: fingerprintID) {
                    html += "<img src=\"data:image/jpeg;base64,\(data.base64EncodedString())\" alt=\"\(htmlEscape(name))\">"
                } else {
                    html += "<div class=\"missing\">no frame stored</div>"
                }
                html += "<div class=\"meta\">\(htmlEscape(name))\(isAliased ? " · <span class=\"tag\">ALIASED</span>" : "")</div></div>"
            }
            html += "</div>"
        }

        var strippedMap = map
        strippedMap.visualFingerprints = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let jsonData = try? encoder.encode(strippedMap),
           let json = String(data: jsonData, encoding: .utf8) {
            html += "<h2>Raw map JSON</h2><details><summary>Show JSON (fingerprint vectors stripped)</summary><pre>\(htmlEscape(json))</pre></details>"
        }

        html += "</body></html>"
        return html
    }

    private static func svgRoutePlot(for map: SemanticRouteMap, aliasGroups: [SemanticRouteVisualAliasGroup]) -> String {
        var points = map.nodes.map(\.point)
        points += (map.keyframes ?? []).map(\.pose)
        guard !points.isEmpty else { return "<p>No spatial data captured.</p>" }

        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let pad = 46.0
        let innerWidth = 720.0
        let scale = (innerWidth - pad * 2) / max(max(maxX - minX, maxY - minY), 1.0)
        let width = (maxX - minX) * scale + pad * 2
        let height = (maxY - minY) * scale + pad * 2

        func sx(_ point: SemanticRoutePoint) -> Double { (point.x - minX) * scale + pad }
        func sy(_ point: SemanticRoutePoint) -> Double { height - ((point.y - minY) * scale + pad) }

        var svg = String(format: "<svg viewBox=\"0 0 %.0f %.0f\" xmlns=\"http://www.w3.org/2000/svg\">", width, height)

        let nodesByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        for edge in map.edges {
            guard let from = nodesByID[edge.fromNodeID], let to = nodesByID[edge.toNodeID] else { continue }
            svg += String(
                format: "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#6d9ee8\" stroke-width=\"3\"/>",
                sx(from.point), sy(from.point), sx(to.point), sy(to.point)
            )
            svg += String(
                format: "<text x=\"%.1f\" y=\"%.1f\" font-size=\"10\" fill=\"#888\">%.1fm</text>",
                (sx(from.point) + sx(to.point)) / 2 + 4, (sy(from.point) + sy(to.point)) / 2 - 4, edge.distanceMeters
            )
        }

        let capturePositions = fingerprintCapturePositions(in: map)
        for group in aliasGroups {
            let positions = group.fingerprintIds.compactMap { capturePositions[$0] }
            guard positions.count >= 2 else { continue }
            svg += String(
                format: "<line x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\" stroke=\"#d64545\" stroke-width=\"1.5\" stroke-dasharray=\"5 4\"/>",
                sx(positions[0]), sy(positions[0]), sx(positions[1]), sy(positions[1])
            )
        }

        for keyframe in map.keyframes ?? [] {
            let aliased = keyframe.visualFingerprintId.map { id in
                aliasGroups.contains { $0.fingerprintIds.contains(id) }
            } ?? false
            svg += String(
                format: "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"3.5\" fill=\"%@\"/>",
                sx(keyframe.pose), sy(keyframe.pose), aliased ? "#d64545" : "#4a90d9"
            )
        }

        for node in map.nodes {
            let color: String
            switch node.kind {
            case .entrance: color = "#34c759"
            case .destination: color = "#ff3b30"
            case .intersection: color = "#ff9500"
            default: color = "#8e8e93"
            }
            svg += String(
                format: "<circle cx=\"%.1f\" cy=\"%.1f\" r=\"7\" fill=\"%@\" stroke=\"white\" stroke-width=\"2\"/>",
                sx(node.point), sy(node.point), color
            )
            svg += String(
                format: "<text x=\"%.1f\" y=\"%.1f\" font-size=\"12\" font-weight=\"600\" fill=\"currentColor\">%@</text>",
                sx(node.point) + 10, sy(node.point) + 4, htmlEscape(node.name)
            )
        }

        svg += "</svg>"
        svg += "<p style=\"font-size:12px;color:#888\">Green = start · Red = destination · Orange = turn · Blue dots = visual keyframes · Red dots/dashed lines = aliased pairs</p>"
        return svg
    }

    private static func htmlEscape(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

private final class SemanticRouteMapStore {
    private let fileName = "semantic_route_maps.json"

    func load() -> [SemanticRouteMap] {
        let url = storeURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([SemanticRouteMap].self, from: data)) ?? []
    }

    func save(_ maps: [SemanticRouteMap]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(maps) else { return }
        let url = storeURL()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic])
    }

    private func storeURL() -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return directory
            .appendingPathComponent("SemanticRouteMaps", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Persists small JPEG thumbnails of the frames behind each visual
/// fingerprint so a saved map can be inspected instead of trusted blindly.
/// Files live in Documents/SemanticRouteMaps/frames/<fingerprintID>.jpg.
enum SemanticRouteFrameStore {
    private static let ciContext = CIContext(options: [.cacheIntermediates: false])
    private static let thumbnailMaxDimension: CGFloat = 320

    static func framesDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents
            .appendingPathComponent("SemanticRouteMaps", isDirectory: true)
            .appendingPathComponent("frames", isDirectory: true)
    }

    static func thumbnailURL(for fingerprintID: String) -> URL {
        framesDirectory().appendingPathComponent("\(fingerprintID).jpg")
    }

    static func thumbnailData(for fingerprintID: String) -> Data? {
        try? Data(contentsOf: thumbnailURL(for: fingerprintID))
    }

    static func saveThumbnail(from pixelBuffer: CVPixelBuffer, fingerprintID: String) {
        // AR capturedImage is landscape sensor orientation; rotate to portrait
        // so the exported report matches what the mapper saw on screen.
        let image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scale = min(thumbnailMaxDimension / extent.width, thumbnailMaxDimension / extent.height, 1.0)
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let jpeg = ciContext.jpegRepresentation(
            of: scaled,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.6]
        ) else { return }

        let directory = framesDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? jpeg.write(to: thumbnailURL(for: fingerprintID), options: [.atomic])
    }

    /// Deletes thumbnails whose fingerprints are no longer referenced by any
    /// stored map, keeping the frames directory bounded.
    static func pruneThumbnails(keeping fingerprintIDs: Set<String>) {
        let directory = framesDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "jpg" {
            let id = file.deletingPathExtension().lastPathComponent
            if !fingerprintIDs.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
