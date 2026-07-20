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

    var spokenInstruction: String {
        switch self {
        case .left: return "turn left"
        case .right: return "turn right"
        case .straight: return "continue straight"
        case .corner: return "follow the corner"
        case .cornerLeft: return "take a slight left at the corner"
        case .cornerRight: return "take a slight right at the corner"
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
    case ready
    case navigating
    case recovering
    case arrived

    var displayName: String {
        switch self {
        case .idle: return "No semantic map"
        case .mapping: return "Mapping route"
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

struct SemanticRouteStep: Identifiable, Equatable {
    var id: String { edge.id }
    let edge: SemanticRouteEdge
    let from: SemanticRouteNode
    let to: SemanticRouteNode
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
    @Published private(set) var ragContextJSON: String = "{}"
    @Published private(set) var capturedPointCount: Int = 0
    @Published private(set) var capturedTurnCount: Int = 0
    @Published private(set) var capturedLandmarkCount: Int = 0
    @Published private(set) var capturedDestinationCount: Int = 0
    @Published private(set) var capturedDistanceMeters: Double = 0
    @Published private(set) var currentSegmentDraftMeters: Double = 0
    @Published private(set) var mappingQualityText: String = "Not mapping"
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
    private var lastAnnouncedRemainingMeter: Int?
    private var lastAnnouncedLandmarkID: String?
    private var announcedLandmarkIDs: Set<String> = []
    private var recoveryStartedAt: Date?
    private var lastRecoveredAt: Date?
    private var lastRecoveryCueAt: Date?
    private var lastRecoveryCueKey: String?
    private var beliefIssueStartedAt: Date?
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
    private var lastRouteUpdatePDRDelta: Double = 0
    private var lastPDRDeltaWasCapped = false
    private var lastHeadingAlignmentCueAt: Date?
    private var lastHeadingAlignmentCueKey: String?
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
    private var stillnessStartedAt: Date?
    private var lastStillnessRepromptAt: Date?
    private var pendingAlignmentResumeCue = false
    private var didRebuildRouteThisUpdate = false
    private var turnPhrasing: SemanticTurnPhrasing = .leftRight

    private let arrivalThresholdMeters = 0.55
    private let destinationProximityMeters = 0.75
    private let turnAnnouncementThresholdMeters = 0.75
    private let crossTrackRecoveryThreshold = 1.35
    private let recoverySnapThreshold = 1.15
    private let headingRecoveryThreshold = 95.0
    private let recoveryHoldSeconds: TimeInterval = 0.6
    private let recoveryCueCooldownSeconds: TimeInterval = 5.0
    private let beliefHoldGraceSeconds: TimeInterval = 1.25
    private let beliefHoldRepeatSeconds: TimeInterval = 7.0
    /// After this long in a belief hold, stop asking the user to pan and
    /// actively snap back onto the best-matching route position.
    private let beliefRelocalizeAfterSeconds: TimeInterval = 5.0
    /// After this long, rebuild the whole route from the live pose instead of
    /// looping the same recovery cue.
    private let beliefRebuildAfterSeconds: TimeInterval = 12.0
    private let routeRebuildRetrySeconds: TimeInterval = 4.0
    private let postRecoveryAlignmentWindowSeconds: TimeInterval = 6.0
    /// AR must disagree with a dead-reckoned step completion by more than
    /// this before the advance is blocked.
    private let arStepCompletionSlackMeters = 1.0
    private let destinationJustAheadMeters = 1.6
    private let trackingLimitedPrefixCooldownSeconds: TimeInterval = 10.0
    private let guidanceIntroProtectionSeconds: TimeInterval = 4.0
    private let autoSampleDistanceMeters = 0.60
    private let autoSampleTurnDegrees = 24.0
    private let autoSampleTurnMinimumDistance = 0.25
    private let targetNodeSnapDistance = 0.35
    private let manualNodeSnapDistance = 0.28
    private let routeStartEdgeSnapThreshold = 1.6
    private let visualRouteMatchInterval: TimeInterval = 0.45
    private let visualRouteMinimumConfidence = 0.68
    private let visualRouteSnapConfidence = 0.88
    private let visualRouteArrivalConfidence = 0.76
    private let visualRouteAmbiguousGap = 0.20
    private let visualRouteAdvanceCooldownSeconds: TimeInterval = 1.4
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
    private let routeAlignmentCueCooldownSeconds: TimeInterval = 1.4
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
    /// New nodes landing this close to an already-mapped node get a
    /// connector edge — crossings become routable junctions.
    private let junctionSnapRadiusMeters = 0.9

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

        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .regular)
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
        mappingQualityText = "Mark Point A"
        stopNavigation(resetInstruction: false)
        phase = .mapping
        currentInstruction = "Mark Point A. Use the detected POI if it is correct, or type a start label."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
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
        refreshCaptureMetrics(for: existing)
        phase = .mapping
        mappingQualityText = "Extending \(existing.name)"
        currentInstruction = "Extending \(existing.name). Walk near the mapped route and mark points; new paths connect to the nearest mapped point."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
        rebuildRAGContext()
        return true
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
        speechCue = SemanticSpeechCue(text: "Captured \(trimmed).", priority: .regular)
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
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
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
            workingMap.nodes[previousIndex].name = name
            workingMap.nodes[previousIndex].kind = kind
            workingMap.nodes[previousIndex].turnHint = turnHint
            workingMap.nodes[previousIndex].headingDegrees = heading
            workingMap.nodes[previousIndex].aliases = Self.aliases(for: name)
            workingMap.nodes[previousIndex].poiAnchorId = poiAnchorId
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
            currentInstruction = kind == .intersection
                ? "Marked \(name). Continue walking after the \(turnHint?.isCorner == true ? "corner" : "turn")."
                : "Updated route point \(name)."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .regular)
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
                speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
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
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .regular)
        rebuildRAGContext()
        return true
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
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .regular)
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
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
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
        speechCue = SemanticSpeechCue(
            text: "Reaching object \(trimmed) linked to \(destinationNode.name). After arrival, reaching guidance will target it.",
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
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
            return false
        }
        map.updatedAt = Date()
        let cleaned = Self.sanitizedMap(map)
        if let quality = cleaned.captureQuality,
           !quality.isSufficientForGuidance {
            currentInstruction = quality.warnings.first ?? "Add more visual route evidence before saving."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
            activeMapDraft = cleaned
            activeMap = cleaned
            refreshCaptureMetrics(for: cleaned)
            rebuildRAGContext()
            return false
        }
        upsertMap(cleaned, persist: true)
        activeMap = cleaned
        activeMapDraft = nil
        phase = .ready
        pruneFrameThumbnails()
        refreshCaptureMetrics(for: cleaned)
        currentInstruction = "Saved local map: \(capturedPointCount) points, \(Self.formatMeters(capturedDistanceMeters))."
        speechCue = SemanticSpeechCue(text: "Local navigation map saved.", priority: .regular)
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
            currentInstruction = "Load the matching AR map for this route before guiding."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
            return false
        }
        if map.coordinateSpace == "ar_world_xz", arPosition == nil {
            currentInstruction = "Load or start the AR map first so I can localize on the captured route."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
            return false
        }
        guard let resolved = resolveTargetDetailed(trimmed, in: map) else {
            currentInstruction = "\(trimmed) is not in this semantic map."
            speechCue = SemanticSpeechCue(text: "\(trimmed) is not in this semantic map.", priority: .priority)
            return false
        }
        let targetNode = resolved.node
        // A fuzzy resolution ("serial" → cereal) adopts the mapped label so
        // every later announcement speaks the real destination name.
        let spokenTarget = resolved.isExact ? trimmed : Self.sanitizedSpokenLabel(targetNode.name, fallback: trimmed)
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
                currentInstruction = "I can't confirm you are at \(targetNode.name) yet. Walk a few steps along the route and ask again."
                speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
                return false
            }
            phase = .arrived
            targetName = spokenTarget
            currentInstruction = "You are already at \(targetNode.name)."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
            rebuildRAGContext()
            return true
        }

        let steps = buildSteps(for: path, in: map)
        guard !steps.isEmpty else {
            currentInstruction = "No walkable route to \(trimmed)."
            return false
        }

        targetName = spokenTarget
        routeSteps = steps
        currentStepIndex = 0
        segmentProgressMeters = min(max(start.initialProgressMeters, 0), steps.first?.edge.distanceMeters ?? 0)
        lastIMUStepCount = imuState.stepCount
        lastIMUPosition = imuState.position
        lastAnnouncedRemainingMeter = nil
        lastAnnouncedLandmarkID = nil
        announcedLandmarkIDs.removeAll()
        shouldSpeakLandmarks = speakLandmarks
        shouldEnableErrorRecovery = errorRecovery
        recoveryStartedAt = nil
        lastRecoveredAt = nil
        lastRecoveryCueAt = nil
        beliefIssueStartedAt = nil
        lastTrackingLimitedPrefixAt = nil
        lastVisualRouteMatchAt = 0
        lastVisualRouteMatch = nil
        arrivalVisualHoldStartedAt = nil
        lastRouteAdvanceAt = nil
        lastPDRDeltaWasCapped = false
        lastHeadingAlignmentCueAt = nil
        lastHeadingAlignmentCueKey = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        lastRouteRebuildAttemptAt = nil
        stillnessStartedAt = nil
        lastStillnessRepromptAt = nil
        pendingAlignmentResumeCue = false
        resetRouteCorrectionGuards()
        resetRouteBelief(status: .initializing)
        guidanceIntroProtectedUntil = Date().addingTimeInterval(guidanceIntroProtectionSeconds)
        recoveryReason = nil
        phase = .navigating
        updateInstruction(forceSpeech: false)
        let startName = Self.sanitizedSpokenLabel(steps.first?.from.name, fallback: "your current location")
        var firstInstruction = currentInstruction
        if let headingCue = initialHeadingAlignmentInstruction(
            on: steps[0],
            liveHeading: arHeading ?? imuState.bearing
        ) {
            firstInstruction = "\(headingCue) Then \(firstInstruction.lowercased())"
        }
        currentInstruction = "Starting at \(startName). \(firstInstruction)"
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
        rebuildRAGContext()
        return true
    }

    func stopNavigation(resetInstruction: Bool = true) {
        routeSteps.removeAll()
        currentStepIndex = 0
        segmentProgressMeters = 0
        segmentRemainingMeters = 0
        totalRemainingMeters = 0
        confidence = 0
        currentSegmentDraftMeters = 0
        recoveryReason = nil
        lastIMUStepCount = nil
        lastIMUPosition = nil
        lastPDRDeltaWasCapped = false
        lastAnnouncedRemainingMeter = nil
        lastAnnouncedLandmarkID = nil
        announcedLandmarkIDs.removeAll()
        recoveryStartedAt = nil
        lastRecoveryCueAt = nil
        beliefIssueStartedAt = nil
        lastTrackingLimitedPrefixAt = nil
        lastVisualRouteMatchAt = 0
        lastVisualRouteMatch = nil
        arrivalVisualHoldStartedAt = nil
        lastRouteAdvanceAt = nil
        lastHeadingAlignmentCueAt = nil
        lastHeadingAlignmentCueKey = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        lastRouteRebuildAttemptAt = nil
        stillnessStartedAt = nil
        lastStillnessRepromptAt = nil
        pendingAlignmentResumeCue = false
        resetRouteCorrectionGuards()
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
        arHeading: Double?,
        arLocalized: Bool,
        capturedImage: CVPixelBuffer? = nil
    ) {
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

        guard phase == .navigating || phase == .recovering else {
            lastIMUStepCount = imuState.stepCount
            lastIMUPosition = imuState.position
            updatePassiveObservation(imuState: imuState, arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            return
        }
        guard let step = activeStep else { return }

        let visualMatch = currentVisualRouteMatch(
            capturedImage: capturedImage,
            timestamp: Date().timeIntervalSinceReferenceDate
        )
        let pdrDelta = pdrDistanceDelta(from: imuState)
        lastRouteUpdatePDRDelta = pdrDelta
        let expectedHeading = step.edge.bearingDegrees
        let liveHeading = arHeading ?? imuState.bearing
        let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, expectedHeading))
        let previousSegmentProgressMeters = segmentProgressMeters
        let progressScale = max(0, cos(min(headingError, 90) * .pi / 180.0))
        let gatedDelta = headingError > 65 ? pdrDelta * 0.2 : pdrDelta * progressScale
        segmentProgressMeters += max(0, gatedDelta)
        recordRouteEvidence(
            stepIndex: currentStepIndex,
            progressMeters: segmentProgressMeters,
            confidence: lastPDRDeltaWasCapped ? 0.36 : (imuState.isMoving ? 0.54 : 0.44),
            uncertaintyMeters: pdrUncertaintyMeters(imuState: imuState, pdrDelta: pdrDelta, headingError: headingError),
            source: "pdr_prediction",
            summary: lastPDRDeltaWasCapped ? "PDR capped" : "PDR"
        )

        var crossTrackError: Double?
        var routeProjection: RouteProjection?
        var observationConfidence = 0.58
        let arPoint = Self.routePoint(from: arPosition)
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        if let arPoint,
           activeMap?.coordinateSpace == "ar_world_xz" {
            let projection = Self.projectDetailed(arPoint, onto: step)
            routeProjection = projection
            crossTrackError = projection.crossTrackMeters
            if arLocalized {
                lastARNodeDistanceMeters = arPoint.distance(to: step.to.point)
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

        segmentProgressMeters = min(segmentProgressMeters, step.edge.distanceMeters)
        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
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
            headingError: headingError
        ) {
            rebuildRAGContext()
            return
        }

        if pendingAlignmentResumeCue, headingError <= routeStartAlignmentThresholdDegrees, phase == .navigating {
            // The corrective turn just completed. Without an explicit "walk"
            // resumption the user stands still waiting for permission to
            // move — the pilot heard only turn cues after pausing.
            pendingAlignmentResumeCue = false
            updateInstruction(forceSpeech: false)
            currentInstruction = "Good. \(currentInstruction)"
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
            // Claim this meter bucket so the routine countdown can't clobber
            // the resume cue later in the same tick.
            lastAnnouncedRemainingMeter = Int(ceil(segmentRemainingMeters))
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

        // ── Turn/node proximity check ────────────────────────────────
        // If AR pose is close to the next node, advance the step even
        // if PDR progress is lagging due to heading gating after a turn.
        if let arPoint = Self.routePoint(from: arPosition),
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

    private func updatePassiveObservation(imuState: IMUState, arPosition: simd_float3?, arHeading: Double?, arLocalized: Bool) {
        let pose = Self.routePoint(from: arPosition) ?? SemanticRoutePoint(x: imuState.position.x, y: imuState.position.y)
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
        map.keyframes = Array(keyframes.suffix(120))
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
            let bucket = Int((evidence.progressMeters / routeBeliefBucketMeters).rounded())
            let key = "\(evidence.stepIndex):\(bucket)"
            var accumulator = accumulators[key] ?? Accumulator()
            accumulator.weightedProgress += evidence.progressMeters * max(evidence.confidence, 0.05)
            accumulator.confidenceSum += evidence.confidence
            accumulator.uncertaintySum += evidence.uncertaintyMeters
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

        guard routeLocalizationStatus == .ambiguous || routeLocalizationStatus == .lost else {
            beliefIssueStartedAt = nil
            if phase == .recovering, routeBeliefState.isInstructionSafe {
                exitRecovery(announce: true)
            }
            return false
        }

        let now = Date()
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
            applyRecoverySnap(snap, announce: true)
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
        var instruction = routeLocalizationStatus == .lost
            ? "Route lost. Stop and slowly look around."
            : "Hold on. Pan the phone slowly."
        // On repeats, add something actionable instead of the same sentence:
        // point the camera at a mapped landmark so visual matching can lock.
        if !cueChanged, let hint = expectedRecoveryLandmarkHint() {
            instruction += " Look for \(hint)."
        }
        currentInstruction = instruction

        if cueChanged || cueAge >= beliefHoldRepeatSeconds {
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
            lastRecoveryCueAt = now
            lastRecoveryCueKey = key
        }
        return true
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
        let steps = buildSteps(for: start.nodePath, in: map)
        guard let firstStep = steps.first else { return false }

        routeSteps = steps
        currentStepIndex = 0
        segmentProgressMeters = min(max(start.initialProgressMeters, 0), firstStep.edge.distanceMeters)
        segmentRemainingMeters = max(0, firstStep.edge.distanceMeters - segmentProgressMeters)
        lastAnnouncedRemainingMeter = nil
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
        currentInstruction = "Route realigned from your position. \(currentInstruction)"
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
        rebuildRAGContext()
        return true
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
        let tailSteps = buildSteps(for: best.path, in: map)
        routeSteps = [SemanticRouteStep(edge: rejoinEdge, from: hereNode, to: best.node)] + tailSteps
        currentStepIndex = 0
        segmentProgressMeters = 0
        segmentRemainingMeters = rejoinEdge.distanceMeters
        lastAnnouncedRemainingMeter = nil
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
        resetRouteCorrectionGuards()
        resetRouteBelief(status: .initializing)
        phase = .navigating
        didRebuildRouteThisUpdate = true

        let turn = Self.relativeTurnCommand(from: liveHeading, to: rejoinEdge.bearingDegrees, style: turnPhrasing)
        let nodeName = Self.sanitizedSpokenLabel(best.node.name, fallback: "the route")
        let walkText = "Walk \(Self.formatMeters(rejoinEdge.distanceMeters)) to \(nodeName)."
        currentInstruction = turn.key == "straight"
            ? "Off route. \(walkText)"
            : "Off route. \(turn.text) Then walk \(Self.formatMeters(rejoinEdge.distanceMeters)) to \(nodeName)."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
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
        lastRecoveryCueKey = nil
        lastRecoveredAt = Date()
        // Re-sync progress from the trusted AR projection before speaking the
        // next instruction: dead reckoning drifted during the hold, and
        // resuming from its stale progress produces wrong guidance.
        if let arRemaining = lastTrustedARRemainingMeters, let step = activeStep {
            segmentProgressMeters = min(
                max(step.edge.distanceMeters - arRemaining, 0),
                step.edge.distanceMeters
            )
            segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        }
        updateInstruction(forceSpeech: false)
        if announce, hadSpokenCue {
            currentInstruction = "Back on route. \(currentInstruction)"
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
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

    private func initialHeadingAlignmentInstruction(
        on step: SemanticRouteStep,
        liveHeading: Double
    ) -> String? {
        let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, step.edge.bearingDegrees))
        guard headingError >= routeStartAlignmentThresholdDegrees else { return nil }
        return Self.routeAlignmentInstruction(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing)
    }

    private func issueHeadingAlignmentCueIfNeeded(
        on step: SemanticRouteStep,
        liveHeading: Double,
        headingError: Double
    ) -> Bool {
        // Alignment nudges are corrective guidance. With error recovery
        // disabled the user asked for turn-by-turn only — no "turn around"
        // interjections, even when the heading disagrees with the route.
        guard shouldEnableErrorRecovery else { return false }
        guard phase == .navigating else { return false }
        guard headingError >= routeTurnAlignmentThresholdDegrees else { return false }

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

        let instruction = Self.routeAlignmentInstruction(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing)
        let key = "align_\(Self.relativeTurnCommand(from: liveHeading, to: step.edge.bearingDegrees, style: turnPhrasing).key)_\(currentStepIndex)"
        let now = Date()
        let cueChanged = key != lastHeadingAlignmentCueKey
        let cueAge = lastHeadingAlignmentCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        currentInstruction = instruction
        confidence = min(confidence, 0.48)
        recoveryReason = nil
        guidanceIntroProtectedUntil = nil

        if cueChanged || cueAge >= routeAlignmentCueCooldownSeconds {
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
            lastHeadingAlignmentCueAt = now
            lastHeadingAlignmentCueKey = key
            // Once the user finishes this turn, follow up with an explicit
            // "walk" resumption instead of going silent.
            pendingAlignmentResumeCue = true
        }
        return true
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
        min(destinationProximityMeters, max(0.24, step.edge.distanceMeters * 0.30))
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

    private func destinationAlongTrackArrivalWindowMeters(for step: SemanticRouteStep) -> Double {
        min(1.10, max(0.45, step.edge.distanceMeters * 0.35))
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
            applyRecoverySnap(snap, announce: phase == .recovering)
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
        let cueChanged = cue.key != lastRecoveryCueKey
        let cueAge = lastRecoveryCueAt.map { now.timeIntervalSince($0) } ?? .greatestFiniteMagnitude

        phase = .recovering
        recoveryReason = cue.reason

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

        guard cueChanged || cueAge >= recoveryCueCooldownSeconds else {
            return
        }

        currentInstruction = cue.instruction
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
        lastRecoveryCueAt = now
        lastRecoveryCueKey = cue.key
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
            return RecoveryCueDecision(
                instruction: "Wrong direction.",
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
                let routeBearing = pose.bearingDegrees(to: routeProjection.nearestPoint)
                let command = Self.relativeRecoveryCommand(from: liveHeading, to: routeBearing, style: turnPhrasing)
                let context = recoveryContext(on: step, progressMeters: routeProjection.alongTrackMeters)
                return RecoveryCueDecision(
                    instruction: Self.compactRecoveryInstruction(command, meters: observedCrossTrack),
                    reason: "Off route \(Self.formatShortMeters(observedCrossTrack)), \(context).",
                    key: "off_route_\(command.key)"
                )
            }
            return RecoveryCueDecision(
                instruction: "Off route.",
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
                instruction: "Scan slowly.",
                reason: "AR localization weak.",
                key: "localization"
            )
        }

        return RecoveryCueDecision(
            instruction: "Slow down.",
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

    private func applyRecoverySnap(_ candidate: RecoverySnapCandidate, announce: Bool) {
        guard candidate.stepIndex >= 0, candidate.stepIndex < routeSteps.count else { return }
        let step = routeSteps[candidate.stepIndex]
        currentStepIndex = candidate.stepIndex
        segmentProgressMeters = min(max(candidate.progressMeters, 0), step.edge.distanceMeters)
        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        lastAnnouncedRemainingMeter = nil
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
        updateInstruction(forceSpeech: false)
        if announce {
            currentInstruction = "Guidance realigned. Continue."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
        }
        rebuildRAGContext()
    }

    private func advanceStepOrArrive() {
        lastRouteAdvanceAt = Date()
        resetRouteCorrectionGuards()
        guard currentStepIndex < routeSteps.count - 1 else {
            phase = .arrived
            resetRouteBelief(status: .locked)
            segmentProgressMeters = activeStep?.edge.distanceMeters ?? segmentProgressMeters
            segmentRemainingMeters = 0
            totalRemainingMeters = 0
            recoveryReason = nil
            beliefIssueStartedAt = nil
            arrivalVisualHoldStartedAt = nil
            if let reachingObject = reachingObjectName(forTarget: targetName) {
                currentInstruction = "Arrived at \(targetName). Switching to reaching guidance for \(reachingObject)."
            } else {
                currentInstruction = "Arrived at \(targetName)."
            }
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
            rebuildRAGContext()
            return
        }

        let current = routeSteps[currentStepIndex]
        let next = routeSteps[currentStepIndex + 1]
        let turn = turnInstruction(at: current.to, from: current.edge.bearingDegrees, to: next.edge.bearingDegrees)
        let decisionLandmarkCue = shouldSpeakLandmarks
            ? nearbyLandmarkCue(on: current, after: max(segmentProgressMeters, current.edge.distanceMeters - 0.75))
            : nil
        currentStepIndex += 1
        resetRouteBelief(status: .initializing)
        segmentProgressMeters = 0
        segmentRemainingMeters = next.edge.distanceMeters
        lastAnnouncedRemainingMeter = nil
        lastAnnouncedLandmarkID = nil
        recoveryStartedAt = nil
        recoveryReason = nil
        beliefIssueStartedAt = nil
        arrivalVisualHoldStartedAt = nil
        lastARNodeDistanceMeters = nil
        lastTrustedARRemainingMeters = nil
        pendingAlignmentResumeCue = false
        stillnessStartedAt = nil
        lastStillnessRepromptAt = nil
        if phase == .recovering { phase = .navigating }
        let nextContext: String
        if let hint = next.to.turnHint, hint.isCorner {
            nextContext = "toward the corner"
        } else if next.to.turnHint != nil {
            nextContext = "toward the next turn"
        } else {
            nextContext = "toward \(Self.sanitizedSpokenLabel(next.to.name, fallback: "the next point"))"
        }
        let landmarkPrefix: String
        if let decisionLandmarkCue,
           !announcedLandmarkIDs.contains(decisionLandmarkCue.id) {
            announcedLandmarkIDs.insert(decisionLandmarkCue.id)
            lastAnnouncedLandmarkID = decisionLandmarkCue.id
            landmarkPrefix = "\(decisionLandmarkCue.phrase) "
        } else {
            landmarkPrefix = ""
        }
        currentInstruction = "\(landmarkPrefix)\(Self.sentenceCased(turn)). Walk \(Self.formatMeters(next.edge.distanceMeters)), \(nextContext)."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
    }

    /// Uppercases only the first letter — String.capitalized would title-case
    /// every word of multi-word instructions ("Take A Slight Left…").
    private static func sentenceCased(_ raw: String) -> String {
        guard let first = raw.first else { return raw }
        return first.uppercased() + raw.dropFirst()
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
        // model overshoots.
        let cueRemainingMeters = lastARNodeDistanceMeters.map { max(segmentRemainingMeters, $0) }
            ?? segmentRemainingMeters

        // Use turn direction for intersection nodes, destination name for destinations
        let context: String
        if let hint = step.to.turnHint, hint.isCorner {
            context = "toward the corner"
        } else if step.to.turnHint != nil {
            context = "toward the next turn"
        } else {
            context = "toward \(Self.sanitizedSpokenLabel(step.to.name, fallback: "the next point"))"
        }
        if cueRemainingMeters <= turnAnnouncementThresholdMeters, currentStepIndex < routeSteps.count - 1 {
            let next = routeSteps[currentStepIndex + 1]
            let turn = turnInstruction(at: step.to, from: step.edge.bearingDegrees, to: next.edge.bearingDegrees)
            if cueRemainingMeters <= 0.75 {
                currentInstruction = step.to.turnHint?.isCorner == true
                    ? "\(Self.sentenceCased(turn))."
                    : "At the turn, \(turn)."
            } else {
                currentInstruction = "In \(Self.formatMeters(cueRemainingMeters)), \(turn)."
            }
        } else if currentStepIndex >= routeSteps.count - 1,
                  (lastARNodeDistanceMeters ?? cueRemainingMeters) <= destinationJustAheadMeters {
            // Final approach: "keep walking X meters" reads as being lost when
            // the target is within arm's-plus reach.
            currentInstruction = "\(Self.sanitizedSpokenLabel(targetName, fallback: "The destination")) is just ahead."
        } else {
            let landmarkContext = shouldSpeakLandmarks ? nextLandmarkPhrase(on: step, after: segmentProgressMeters) : nil
            if let landmarkContext {
                currentInstruction = "Walk \(Self.formatMeters(cueRemainingMeters)), \(context). Passing \(landmarkContext)."
            } else {
                currentInstruction = "Walk \(Self.formatMeters(cueRemainingMeters)), \(context)."
            }
        }

        let pastIntroProtection = guidanceIntroProtectedUntil.map { Date() >= $0 } ?? true
        if confidence < 0.45, pastIntroProtection {
            // Say it once per stretch of weak tracking, not on every meter cue.
            let now = Date()
            let prefixAge = lastTrackingLimitedPrefixAt.map { now.timeIntervalSince($0) }
                ?? .greatestFiniteMagnitude
            if prefixAge >= trackingLimitedPrefixCooldownSeconds {
                currentInstruction = "Tracking limited, walk slowly. " + currentInstruction
                lastTrackingLimitedPrefixAt = now
            }
        }

        let bucket = Int(ceil(cueRemainingMeters))
        let routineSpeechAllowed = forceSpeech || guidanceIntroProtectedUntil.map { Date() >= $0 } ?? true
        guard routineSpeechAllowed else { return }

        if forceSpeech {
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
            lastAnnouncedRemainingMeter = bucket
        } else if shouldSpeakLandmarks,
                  let landmarkCue = nearbyLandmarkCue(on: step, after: segmentProgressMeters),
                  !announcedLandmarkIDs.contains(landmarkCue.id) {
            lastAnnouncedLandmarkID = landmarkCue.id
            announcedLandmarkIDs.insert(landmarkCue.id)
            speechCue = SemanticSpeechCue(text: landmarkCue.phrase, priority: .priority)
        } else if bucket != lastAnnouncedRemainingMeter && bucket <= 8 && bucket >= 1 {
            lastAnnouncedRemainingMeter = bucket
            let cue: String
            if bucket == 1, currentStepIndex < routeSteps.count - 1 {
                let next = routeSteps[currentStepIndex + 1]
                cue = "One meter. \(turnInstruction(at: step.to, from: step.edge.bearingDegrees, to: next.edge.bearingDegrees))."
            } else if bucket == 1 {
                cue = "One meter to \(targetName)."
            } else {
                cue = "\(bucket) meters."
            }
            speechCue = SemanticSpeechCue(text: cue, priority: .priority)
        }
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
            return (ahead, "\(name) \(Self.sidePhrase(side)) in \(Self.formatMeters(ahead))")
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
                return (ahead, landmark.id, "\(name) \(Self.sidePhrase(side)) in \(Self.formatMeters(ahead)).")
            }
            return (abs(ahead), landmark.id, "Passing \(name) \(Self.sidePhrase(side)).")
        }
        .min { $0.ahead < $1.ahead }
        .map { ($0.id, $0.phrase) }
    }

    private func expectedRecoveryLandmarkHint() -> String? {
        guard let step = activeStep else { return nil }
        if let landmark = nearbyLandmarkCue(on: step, after: max(0, segmentProgressMeters - 1.0)) {
            return landmark.phrase.replacingOccurrences(of: ".", with: "")
        }
        return nextLandmarkPhrase(on: step, after: max(0, segmentProgressMeters - 1.0))
    }

    private func currentVisualRouteMatch(
        capturedImage: CVPixelBuffer?,
        timestamp: TimeInterval
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

        let matches = visualRouteCandidates(in: map, fingerprints: fingerprints)
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
            let sameRoutePlace = second.stepIndex == best.stepIndex &&
                abs(second.progressMeters - best.progressMeters) <= 1.5
            guard sameRoutePlace else {
                lastVisualRouteMatch = nil
                return nil
            }
        }

        lastVisualRouteMatch = best
        return best
    }

    private func keyframeProgressMeters(
        for keyframe: SemanticRouteKeyframe,
        on step: SemanticRouteStep,
        baseEdgeID: String,
        keyframeIDs: Set<String>,
        reversed: Bool
    ) -> Double? {
        if keyframe.segmentID == baseEdgeID || keyframeIDs.contains(keyframe.id) {
            return reversed
                ? max(0, step.edge.distanceMeters - keyframe.distanceFromSegmentStart)
                : min(max(keyframe.distanceFromSegmentStart, 0), step.edge.distanceMeters)
        }

        let projection = Self.project(keyframe.pose, onto: step)
        let nearFrom = keyframe.pose.distance(to: step.from.point) <= 0.75
        let nearTo = keyframe.pose.distance(to: step.to.point) <= 0.95
        let nearSegment = projection.crossTrackMeters <= 0.85 &&
            projection.alongTrackMeters >= -0.5 &&
            projection.alongTrackMeters <= step.edge.distanceMeters + 0.5

        guard nearFrom || nearTo || nearSegment else { return nil }

        if nearTo { return step.edge.distanceMeters }
        if nearFrom { return 0 }
        return min(max(projection.alongTrackMeters, 0), step.edge.distanceMeters)
    }

    private func visualRouteCandidates(
        in map: SemanticRouteMap,
        fingerprints: [String: ARVisualFingerprint]
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
                guard let progress = keyframeProgressMeters(
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
                        progressMeters: progress,
                        fingerprint: fingerprint,
                        fingerprintID: fingerprintID,
                        keyframeID: keyframe.id,
                        landmarkID: nil,
                        landmarkName: nil,
                        cue: nil
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
                            cue: cue
                        )
                    )
                }
            }
        }

        return candidates
    }

    private func visualConfidence(from similarity: Float) -> Double {
        let confidence = (Double(similarity) - 0.62) / 0.26
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
        speechCue = SemanticSpeechCue(text: cue, priority: .priority)
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
            currentInstruction = "Near \(targetName). Look toward the target to confirm arrival."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
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
        return nil
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

        if let edgeMatch = nearestEdge(in: map, to: pose),
           edgeMatch.crossTrackMeters <= routeStartEdgeSnapThreshold {
            var options: [(path: [String], progress: Double, cost: Double)] = []

            let forwardTail = shortestPath(in: map, from: edgeMatch.edge.toNodeID, to: targetNodeID)
            if !forwardTail.isEmpty {
                let path = [edgeMatch.edge.fromNodeID] + forwardTail
                let progress = edgeMatch.alongTrackMeters
                let headingPenalty = routeStartHeadingPenalty(
                    liveHeading: headingDegrees,
                    routeBearing: edgeMatch.edge.bearingDegrees
                )
                let cost = max(0, edgeMatch.edge.distanceMeters - edgeMatch.alongTrackMeters)
                    + pathCost(for: forwardTail, in: map)
                    + headingPenalty
                options.append((path, progress, cost))
            }

            let reverseTail = shortestPath(in: map, from: edgeMatch.edge.fromNodeID, to: targetNodeID)
            if !reverseTail.isEmpty {
                let path = [edgeMatch.edge.toNodeID] + reverseTail
                let progress = max(0, edgeMatch.edge.distanceMeters - edgeMatch.alongTrackMeters)
                let headingPenalty = routeStartHeadingPenalty(
                    liveHeading: headingDegrees,
                    routeBearing: SemanticRouteMath.normalizedDegrees(edgeMatch.edge.bearingDegrees + 180)
                )
                let cost = max(0, edgeMatch.alongTrackMeters) + pathCost(for: reverseTail, in: map)
                    + headingPenalty
                options.append((path, progress, cost))
            }

            if let best = options.min(by: { $0.cost < $1.cost }) {
                return NavigationStart(nodePath: best.path, initialProgressMeters: best.progress)
            }
        }

        if let pose, let nearest = nearestNode(in: map, to: pose) {
            let path = shortestPath(in: map, from: nearest.id, to: targetNodeID)
            if !path.isEmpty {
                return NavigationStart(nodePath: path, initialProgressMeters: 0)
            }
        }

        let fallbackPath = shortestPath(in: map, from: map.nodes.first?.id ?? "", to: targetNodeID)
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

    private func nearestEdge(in map: SemanticRouteMap, to pose: SemanticRoutePoint?) -> (edge: SemanticRouteEdge, alongTrackMeters: Double, crossTrackMeters: Double)? {
        guard let pose else { return nil }
        let nodeByID = Dictionary(uniqueKeysWithValues: map.nodes.map { ($0.id, $0) })
        return map.edges.compactMap { edge -> (edge: SemanticRouteEdge, alongTrackMeters: Double, crossTrackMeters: Double)? in
            guard let from = nodeByID[edge.fromNodeID], let to = nodeByID[edge.toNodeID] else { return nil }
            let projection = Self.project(pose, from: from.point, to: to.point, distance: edge.distanceMeters)
            return (edge, projection.alongTrackMeters, projection.crossTrackMeters)
        }
        .min { $0.crossTrackMeters < $1.crossTrackMeters }
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

    private static func attachPendingEvidence(
        to edge: inout SemanticRouteEdge,
        in map: inout SemanticRouteMap,
        fromNodeID: String
    ) {
        var landmarkIds = edge.landmarkIds ?? []
        for index in map.landmarks.indices {
            guard map.landmarks[index].edgeID == nil,
                  map.landmarks[index].nodeID == fromNodeID else {
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
        case .left: return "on your left"
        case .right: return "on your right"
        case .center: return "near the center"
        case .ahead: return "ahead"
        case .behind: return "behind you"
        }
    }

    private static func relativeRecoveryCommand(
        from heading: Double,
        to targetBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> (text: String, key: String) {
        let diff = SemanticRouteMath.signedAngleDifference(targetBearing, heading)
        let magnitude = abs(diff)
        if magnitude < 25 { return ("Forward", "forward") }
        if style == .clockFace {
            let hour = clockHour(forSignedDegrees: diff)
            return ("Head to \(hour) o'clock", "clock_\(hour)")
        }
        if magnitude < 75 { return diff > 0 ? ("Step right", "right") : ("Step left", "left") }
        if magnitude < 135 { return diff > 0 ? ("Turn right", "turn_right") : ("Turn left", "turn_left") }
        return ("Turn around", "turn_around")
    }

    private static func compactRecoveryInstruction(_ command: (text: String, key: String), meters: Double) -> String {
        let carriesDistance = command.key == "left" || command.key == "right" ||
            command.key == "forward" || command.key.hasPrefix("clock_")
        guard meters >= 1.5, carriesDistance else {
            return "\(command.text)."
        }
        return "\(command.text), \(formatShortMeters(meters))."
    }

    /// Signed heading offset → clock hour: +90° is 3 o'clock, −90° is 9,
    /// ±180° is 6. Callers handle the near-straight band before calling.
    private static func clockHour(forSignedDegrees diff: Double) -> Int {
        var hour = Int((diff / 30.0).rounded())
        while hour <= 0 { hour += 12 }
        while hour > 12 { hour -= 12 }
        return hour
    }

    private static func relativeTurnCommand(
        from heading: Double,
        to targetBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> (text: String, key: String) {
        let diff = SemanticRouteMath.signedAngleDifference(targetBearing, heading)
        let magnitude = abs(diff)
        if magnitude < 25 { return ("Go straight.", "straight") }
        if style == .clockFace {
            let hour = clockHour(forSignedDegrees: diff)
            return ("Turn to \(hour) o'clock.", "clock_\(hour)")
        }
        // A "sharp" band keeps a 130° aisle-end turn from being spoken the
        // same as a gentle 50° one — under-specified turns walked the pilot
        // users into shelves.
        if magnitude < 110 { return diff > 0 ? ("Turn right.", "right") : ("Turn left.", "left") }
        if magnitude < 150 { return diff > 0 ? ("Turn sharp right.", "sharp_right") : ("Turn sharp left.", "sharp_left") }
        return ("Turn around.", "around")
    }

    private static func routeAlignmentInstruction(
        from heading: Double,
        to targetBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> String {
        let command = relativeTurnCommand(from: heading, to: targetBearing, style: style)
        switch command.key {
        case "straight":
            return "Face the route."
        case "around":
            return "Turn around to face the route."
        default:
            let text = command.text.hasSuffix(".") ? String(command.text.dropLast()) : command.text
            return "\(text) to face the route."
        }
    }

    private static func turnInstruction(
        from currentBearing: Double,
        to nextBearing: Double,
        style: SemanticTurnPhrasing = .leftRight
    ) -> String {
        let diff = SemanticRouteMath.signedAngleDifference(nextBearing, currentBearing)
        let magnitude = abs(diff)
        if magnitude < 18 { return "continue straight" }
        if style == .clockFace {
            return "turn to \(clockHour(forSignedDegrees: diff)) o'clock"
        }
        if magnitude < 45 { return diff > 0 ? "take a slight right" : "take a slight left" }
        if magnitude < 110 { return diff > 0 ? "turn right" : "turn left" }
        if magnitude < 150 { return diff > 0 ? "turn sharp right" : "turn sharp left" }
        return "turn around"
    }

    private func turnInstruction(at node: SemanticRouteNode, from currentBearing: Double, to nextBearing: Double) -> String {
        // Corners keep their dedicated phrasing in every mode; recorded
        // left/right hints lose to computed geometry in clock-face mode
        // because the hint carries no magnitude.
        if let hint = node.turnHint, turnPhrasing == .leftRight || hint.isCorner {
            return hint.spokenInstruction
        }
        return Self.turnInstruction(from: currentBearing, to: nextBearing, style: turnPhrasing)
    }

    private static func formatMeters(_ meters: Double) -> String {
        let clamped = max(0, meters)
        if clamped < 1 {
            return "less than one meter"
        }
        if clamped < 1.5 {
            return "about 1 meter"
        }
        return "\(Int(round(clamped))) meters"
    }

    private static func formatShortMeters(_ meters: Double) -> String {
        let clamped = max(0, meters)
        if clamped < 1.5 {
            return "1 meter"
        }
        return "\(Int(round(clamped))) meters"
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

    private static func normalizedLookupKey(_ raw: String) -> String {
        let tokens = sanitizedSpokenLabel(raw)
            .lowercased()
            .replacingOccurrences(of: "doorknob", with: "door knob")
            .replacingOccurrences(of: "doorhandle", with: "door handle")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        let lookupNoise = Set(["room", "rm", "suite", "office"])
        let withoutArticles = tokens.drop { ["the", "a", "an"].contains($0) }
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

        return SemanticRouteCaptureQuality(
            keyframeCount: keyframeCount,
            visualSampleCount: visualSampleCount,
            aliasedVisualSampleCount: aliasedIDs.count,
            routeDistanceMeters: routeDistance,
            averageKeyframeSpacingMeters: averageSpacing,
            hasMinimumSpatialEvidence: hasMinimumSpatialEvidence,
            hasMinimumVisualEvidence: hasMinimumVisualEvidence,
            warnings: warnings
        )
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

    func expireRecoveryHoldForTesting() {
        recoveryStartedAt = Date().addingTimeInterval(-(recoveryHoldSeconds + 0.1))
    }

    func expireGuidanceIntroProtectionForTesting() {
        guidanceIntroProtectedUntil = nil
    }

    func forceStillnessRepromptWindowForTesting() {
        stillnessStartedAt = Date().addingTimeInterval(-(stillnessRepromptAfterSeconds + 1))
        lastStillnessRepromptAt = nil
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
            html += String(format: "<span>%.1fm route</span>", quality.routeDistanceMeters)
            if let spacing = quality.averageKeyframeSpacingMeters {
                html += String(format: "<span>%.2fm keyframe spacing</span>", spacing)
            }
            html += "</div>"
            if !quality.warnings.isEmpty {
                html += "<ul>" + quality.warnings.map { "<li class=\"warn\">\(htmlEscape($0))</li>" }.joined() + "</ul>"
            }
        }

        html += "<h2>Top-down route</h2>" + svgRoutePlot(for: map, aliasGroups: aliasGroups)

        html += "<h2>Route structure</h2><table><tr><th>Segment</th><th>Distance</th><th>Bearing</th><th>Keyframes</th></tr>"
        let keyframesByEdge = Dictionary(grouping: keyframes) { $0.segmentID ?? "" }
        for edge in map.edges {
            let from = map.nodes.first { $0.id == edge.fromNodeID }?.name ?? "?"
            let to = map.nodes.first { $0.id == edge.toNodeID }?.name ?? "?"
            let attached = (keyframesByEdge[edge.id]?.count ?? 0) + (edge.keyframeIds?.count ?? 0)
            html += String(
                format: "<tr><td>%@ → %@</td><td>%.1fm</td><td>%.0f°</td><td>%d</td></tr>",
                htmlEscape(from), htmlEscape(to), edge.distanceMeters, edge.bearingDegrees, attached
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
