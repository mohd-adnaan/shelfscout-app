import Foundation
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

enum SemanticTurnHint: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case straight
    case corner

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .straight: return "Straight"
        case .corner: return "Corner"
        }
    }

    var nodeName: String {
        switch self {
        case .left: return "Left turn"
        case .right: return "Right turn"
        case .straight: return "Straight point"
        case .corner: return "Corner"
        }
    }

    var spokenInstruction: String {
        switch self {
        case .left: return "turn left"
        case .right: return "turn right"
        case .straight: return "continue straight"
        case .corner: return "turn at the corner"
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
    var arWorldMapId: String?
    var startNodeId: String?
    var destinationNodeIds: [String]?
    var nodes: [SemanticRouteNode]
    var edges: [SemanticRouteEdge]
    var landmarks: [SemanticRouteLandmark]
    var keyframes: [SemanticRouteKeyframe]?
    var source: String?
    var notes: String?

    var targetNames: [String] {
        let destinationIDs = Set(destinationNodeIds ?? nodes.filter { $0.kind == .destination }.map(\.id))
        let nodeNames = nodes
            .filter { $0.kind == .destination || destinationIDs.contains($0.id) }
            .map(\.name)
        let landmarkNames = landmarks
            .filter { $0.kind == .destinationContext || $0.priority >= 20 }
            .map(\.name)
        return Array(Set(nodeNames + landmarkNames)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
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
    private var guidanceIntroProtectedUntil: Date?
    private var shouldSpeakLandmarks = true
    private var shouldEnableErrorRecovery = true

    private let arrivalThresholdMeters = 0.45
    private let turnAnnouncementThresholdMeters = 1.0
    private let crossTrackRecoveryThreshold = 1.65
    private let recoverySnapThreshold = 1.15
    private let headingRecoveryThreshold = 105.0
    private let recoveryHoldSeconds: TimeInterval = 2.0
    private let recoveryCueCooldownSeconds: TimeInterval = 8.0
    private let guidanceIntroProtectionSeconds: TimeInterval = 4.0
    private let autoSampleDistanceMeters = 0.60
    private let autoSampleTurnDegrees = 24.0
    private let autoSampleTurnMinimumDistance = 0.25
    private let targetNodeSnapDistance = 0.35
    private let manualNodeSnapDistance = 0.28
    private let routeStartEdgeSnapThreshold = 1.6

    private struct NavigationStart {
        var nodePath: [String]
        var initialProgressMeters: Double
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

    func loadMaps() {
        let loaded = store.load()
        let cleaned = loaded.map(Self.sanitizedMap)
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

    @discardableResult
    func captureStart(
        named requestedName: String,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState
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
            poiAnchorId: name
        )
    }

    @discardableResult
    func captureNode(
        named requestedName: String,
        kind: SemanticRouteNodeKind,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState
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
        let node = SemanticRouteNode(
            id: UUID().uuidString,
            name: trimmed,
            point: point,
            headingDegrees: arHeading ?? imuState.bearing,
            kind: kind,
            turnHint: nil,
            aliases: Self.aliases(for: trimmed),
            capturedAt: Date(),
            poiAnchorId: kind == .entrance || kind == .destination ? trimmed : nil
        )

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
            workingMap.edges.append(edge)
        }

        workingMap.nodes.append(node)
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
        imuState: IMUState
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
            poiAnchorId: nil
        )
    }

    @discardableResult
    func captureTurn(
        _ hint: SemanticTurnHint,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState
    ) -> Bool {
        let turnCount = (activeMapDraft ?? activeMap)?.nodes.filter { $0.kind == .intersection }.count ?? 0
        return insertManualNode(
            named: "\(hint.nodeName) \(turnCount + 1)",
            kind: .intersection,
            turnHint: hint,
            arPosition: arPosition,
            arHeading: arHeading,
            imuState: imuState,
            poiAnchorId: nil
        )
    }

    private func insertManualNode(
        named name: String,
        kind: SemanticRouteNodeKind,
        turnHint: SemanticTurnHint?,
        arPosition: simd_float3?,
        arHeading: Double?,
        imuState: IMUState,
        poiAnchorId: String?
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
            activeMapDraft = workingMap
            activeMap = workingMap
            lastAutoSampledPoint = workingMap.nodes[previousIndex].point
            lastAutoSampledHeading = heading
            lastAutoSampledAt = Date()
            currentSegmentDraftMeters = 0
            refreshCaptureMetrics(for: workingMap)
            currentInstruction = kind == .intersection
                ? "Marked \(name). Continue walking after the turn."
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
            workingMap.edges.append(edge)
        }

        workingMap.nodes.append(node)
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
            ? "Marked \(name). Continue walking after the turn."
            : kind == .entrance
                ? "Point A captured. Walk toward the first turn or destination."
                : kind == .destination
                    ? "Destination \(name) captured. Review and save the route."
                    : "Captured route point \(name)."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .regular)
        rebuildRAGContext()
        return true
    }

    @discardableResult
    func captureLandmark(
        named requestedName: String,
        side: SemanticRouteSide,
        context: String,
        arPosition: simd_float3?,
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
            visualFingerprintIds: [trimmed]
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
        upsertMap(cleaned, persist: true)
        activeMap = cleaned
        activeMapDraft = nil
        phase = .ready
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
        errorRecovery: Bool = true
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
        guard let targetNode = resolveTarget(trimmed, in: map) else {
            currentInstruction = "\(trimmed) is not in this semantic map."
            speechCue = SemanticSpeechCue(text: "\(trimmed) is not in this semantic map.", priority: .priority)
            return false
        }
        guard let start = resolveNavigationStart(
            in: map,
            targetNodeID: targetNode.id,
            arPosition: arPosition,
            imuState: imuState
        ) else {
            currentInstruction = "Could not resolve a start point."
            return false
        }

        let path = start.nodePath
        guard path.count >= 2 else {
            phase = .arrived
            targetName = trimmed
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

        targetName = trimmed
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
        guidanceIntroProtectedUntil = Date().addingTimeInterval(guidanceIntroProtectionSeconds)
        recoveryReason = nil
        phase = .navigating
        updateInstruction(forceSpeech: false)
        let startName = Self.sanitizedSpokenLabel(steps.first?.from.name, fallback: "your current location")
        let firstInstruction = currentInstruction
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
        lastAnnouncedRemainingMeter = nil
        lastAnnouncedLandmarkID = nil
        announcedLandmarkIDs.removeAll()
        recoveryStartedAt = nil
        lastRecoveryCueAt = nil
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

    func update(imuState: IMUState, arPosition: simd_float3?, arHeading: Double?, arLocalized: Bool) {
        if phase == .mapping {
            updatePassiveObservation(imuState: imuState, arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            autoSampleWalkthrough(arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            return
        }

        guard phase == .navigating || phase == .recovering else {
            lastIMUStepCount = imuState.stepCount
            lastIMUPosition = imuState.position
            updatePassiveObservation(imuState: imuState, arPosition: arPosition, arHeading: arHeading, arLocalized: arLocalized)
            return
        }
        guard let step = activeStep else { return }

        let pdrDelta = pdrDistanceDelta(from: imuState)
        let expectedHeading = step.edge.bearingDegrees
        let liveHeading = arHeading ?? imuState.bearing
        let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, expectedHeading))
        let progressScale = max(0, cos(min(headingError, 90) * .pi / 180.0))
        let gatedDelta = headingError > 65 ? pdrDelta * 0.2 : pdrDelta * progressScale
        segmentProgressMeters += max(0, gatedDelta)

        var crossTrackError: Double?
        var observationConfidence = 0.58
        if let arPoint = Self.routePoint(from: arPosition),
           activeMap?.coordinateSpace == "ar_world_xz" {
            let projection = Self.project(arPoint, onto: step)
            crossTrackError = projection.crossTrackMeters
            if arLocalized && projection.crossTrackMeters <= crossTrackRecoveryThreshold {
                segmentProgressMeters = min(max(projection.alongTrackMeters, 0), step.edge.distanceMeters)
                observationConfidence = 0.86 - min(projection.crossTrackMeters / 4.0, 0.35)
            } else if arLocalized {
                observationConfidence = 0.48
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
            crossTrackError: crossTrackError
        )

        if shouldEnableErrorRecovery {
            updateRecoveryIfNeeded(
                headingError: headingError,
                crossTrackError: crossTrackError,
                isMoving: imuState.isMoving,
                arLocalized: arLocalized,
                pose: Self.routePoint(from: arPosition),
                liveHeading: liveHeading
            )
        }

        if phase == .recovering {
            rebuildRAGContext()
            return
        }

        if segmentRemainingMeters <= arrivalThresholdMeters {
            advanceStepOrArrive()
        } else {
            updateInstruction(forceSpeech: false)
        }
        rebuildRAGContext()
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
            crossTrackError: nil
        )
    }

    private func autoSampleWalkthrough(arPosition: simd_float3?, arHeading: Double?, arLocalized: Bool) {
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

        let keyframe = SemanticRouteKeyframe(
            id: UUID().uuidString,
            segmentID: nil,
            pose: pose,
            headingDegrees: heading,
            distanceFromSegmentStart: currentSegmentDraftMeters,
            visualFingerprintId: nil,
            trackingQuality: arLocalized ? "ar_world_tracking" : "pdr",
            capturedAt: now
        )
        var keyframes = workingMap.keyframes ?? []
        keyframes.append(keyframe)
        workingMap.keyframes = Array(keyframes.suffix(120))
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
            mappingQualityText = capturedPointCount < 2
                ? "Need Point A and destination"
                : String(format: "%d route points, %.1fm", capturedPointCount, capturedDistanceMeters)
        } else {
            mappingQualityText = String(format: "%d points, %.1fm", capturedPointCount, capturedDistanceMeters)
        }
    }

    private func pdrDistanceDelta(from imuState: IMUState) -> Double {
        defer {
            lastIMUStepCount = imuState.stepCount
            lastIMUPosition = imuState.position
        }

        if let lastStep = lastIMUStepCount {
            let stepDelta = max(0, imuState.stepCount - lastStep)
            if stepDelta > 0 {
                return Double(stepDelta) * max(imuState.currentStepLength, 0.35)
            }
        }

        guard let previous = lastIMUPosition else { return 0 }
        let delta = hypot(imuState.position.x - previous.x, imuState.position.y - previous.y)
        return delta.isFinite ? min(max(delta, 0), 1.2) : 0
    }

    private func updateRecoveryIfNeeded(
        headingError: Double,
        crossTrackError: Double?,
        isMoving: Bool,
        arLocalized: Bool,
        pose: SemanticRoutePoint?,
        liveHeading: Double
    ) {
        let crossTrackBad = arLocalized && (crossTrackError ?? 0) > crossTrackRecoveryThreshold
        let awayFromDecisionPoint = segmentProgressMeters > 1.2 && segmentRemainingMeters > 1.2
        let headingBad = arLocalized && isMoving && awayFromDecisionPoint && headingError > headingRecoveryThreshold
        let lowConfidenceBad = isMoving && confidence < 0.34
        let localizationBad = !arLocalized && isMoving && segmentProgressMeters > 0.8

        guard crossTrackBad || headingBad || lowConfidenceBad || localizationBad else {
            recoveryStartedAt = nil
            if phase == .recovering {
                let sinceRecovery = lastRecoveredAt?.timeIntervalSinceNow ?? -10
                if arLocalized || sinceRecovery < -1.0 {
                    phase = .navigating
                    recoveryReason = nil
                    recoveryStartedAt = nil
                    lastRecoveredAt = Date()
                    updateInstruction(forceSpeech: false)
                    currentInstruction = "Recovered on the route. Resume walking."
                    speechCue = SemanticSpeechCue(text: currentInstruction, priority: .priority)
                }
            }
            return
        }

        if let snap = bestRecoverySnap(pose: pose, liveHeading: liveHeading),
           shouldAcceptRecoverySnap(snap, crossTrackBad: crossTrackBad, headingBad: headingBad) {
            applyRecoverySnap(snap)
            return
        }

        if let lastRecoveryCueAt,
           Date().timeIntervalSince(lastRecoveryCueAt) < recoveryCueCooldownSeconds,
           phase == .recovering {
            return
        }

        if recoveryStartedAt == nil {
            recoveryStartedAt = Date()
            return
        }

        guard Date().timeIntervalSince(recoveryStartedAt ?? Date()) >= recoveryHoldSeconds else { return }

        phase = .recovering
        if crossTrackBad {
            recoveryReason = String(format: "You appear %.1fm away from the mapped route.", crossTrackError ?? 0)
        } else if headingBad {
            recoveryReason = String(format: "Heading is %.0f degrees away from the route.", headingError)
        } else if localizationBad {
            recoveryReason = "AR localization is weak while you are moving."
        } else {
            recoveryReason = "Route confidence is low."
        }
        let hint = expectedRecoveryLandmarkHint() ?? activeStep.map {
            "the route from \(Self.sanitizedSpokenLabel($0.from.name, fallback: "the last point")) to \(Self.sanitizedSpokenLabel($0.to.name, fallback: "the next point"))"
        } ?? "the mapped route"
        currentInstruction = "Pause. Slowly scan left and right toward \(hint). I will resume when the route matches."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
        lastRecoveryCueAt = Date()
    }

    private struct RecoverySnapCandidate {
        let stepIndex: Int
        let progressMeters: Double
        let crossTrackMeters: Double
        let headingError: Double
        let score: Double
        let context: String
    }

    private func bestRecoverySnap(pose: SemanticRoutePoint?, liveHeading: Double) -> RecoverySnapCandidate? {
        guard let pose, !routeSteps.isEmpty else { return nil }
        return routeSteps.enumerated().compactMap { pair -> RecoverySnapCandidate? in
            let index = pair.offset
            let step = pair.element
            let projection = Self.project(pose, onto: step)
            let headingError = abs(SemanticRouteMath.signedAngleDifference(liveHeading, step.edge.bearingDegrees))
            let keyframeDistance = nearestKeyframeDistance(on: step, to: pose)
            let evidenceBonus = keyframeDistance.map { max(0, 0.45 - min($0 / 4.0, 0.45)) } ?? 0
            let indexPenalty = Double(abs(index - currentStepIndex)) * 0.22
            let headingPenalty = min(headingError / 120.0, 1.0) * 0.42
            let score = projection.crossTrackMeters + indexPenalty + headingPenalty - evidenceBonus
            return RecoverySnapCandidate(
                stepIndex: index,
                progressMeters: projection.alongTrackMeters,
                crossTrackMeters: projection.crossTrackMeters,
                headingError: headingError,
                score: score,
                context: recoveryContext(on: step, progressMeters: projection.alongTrackMeters)
            )
        }
        .min { $0.score < $1.score }
    }

    private func shouldAcceptRecoverySnap(
        _ candidate: RecoverySnapCandidate,
        crossTrackBad: Bool,
        headingBad: Bool
    ) -> Bool {
        if headingBad && !crossTrackBad {
            return candidate.crossTrackMeters <= 0.75 && candidate.headingError <= 75
        }
        return candidate.crossTrackMeters <= recoverySnapThreshold || candidate.score <= 1.25
    }

    private func applyRecoverySnap(_ candidate: RecoverySnapCandidate) {
        guard candidate.stepIndex >= 0, candidate.stepIndex < routeSteps.count else { return }
        let step = routeSteps[candidate.stepIndex]
        currentStepIndex = candidate.stepIndex
        segmentProgressMeters = min(max(candidate.progressMeters, 0), step.edge.distanceMeters)
        segmentRemainingMeters = max(0, step.edge.distanceMeters - segmentProgressMeters)
        lastAnnouncedRemainingMeter = nil
        recoveryStartedAt = nil
        recoveryReason = nil
        lastRecoveredAt = Date()
        guidanceIntroProtectedUntil = nil
        phase = .navigating
        updateInstruction(forceSpeech: false)
        let resumeInstruction = currentInstruction
        currentInstruction = "Recovered \(candidate.context). \(resumeInstruction)"
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
        rebuildRAGContext()
    }

    private func advanceStepOrArrive() {
        guard currentStepIndex < routeSteps.count - 1 else {
            phase = .arrived
            segmentProgressMeters = activeStep?.edge.distanceMeters ?? segmentProgressMeters
            segmentRemainingMeters = 0
            totalRemainingMeters = 0
            currentInstruction = "Arrived at \(targetName). Start object search and reaching mode."
            speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
            rebuildRAGContext()
            return
        }

        let current = routeSteps[currentStepIndex]
        let next = routeSteps[currentStepIndex + 1]
        let turn = Self.turnInstruction(at: current.to, from: current.edge.bearingDegrees, to: next.edge.bearingDegrees)
        currentStepIndex += 1
        segmentProgressMeters = 0
        segmentRemainingMeters = next.edge.distanceMeters
        lastAnnouncedRemainingMeter = nil
        lastAnnouncedLandmarkID = nil
        announcedLandmarkIDs.removeAll()
        let destinationName = Self.sanitizedSpokenLabel(next.to.name, fallback: "the next point")
        currentInstruction = "\(turn). Then walk \(Self.formatMeters(next.edge.distanceMeters)) toward \(destinationName)."
        speechCue = SemanticSpeechCue(text: currentInstruction, priority: .critical)
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

        let context = Self.sanitizedSpokenLabel(
            step.edge.spokenContext,
            fallback: "toward \(Self.sanitizedSpokenLabel(step.to.name, fallback: "the next point"))"
        )
        if segmentRemainingMeters <= turnAnnouncementThresholdMeters, currentStepIndex < routeSteps.count - 1 {
            let next = routeSteps[currentStepIndex + 1]
            let turn = Self.turnInstruction(at: step.to, from: step.edge.bearingDegrees, to: next.edge.bearingDegrees)
            currentInstruction = "In \(Self.formatMeters(segmentRemainingMeters)), \(turn)."
        } else {
            let landmarkContext = shouldSpeakLandmarks ? nextLandmarkPhrase(on: step, after: segmentProgressMeters) : nil
            if let landmarkContext {
                currentInstruction = "Walk \(Self.formatMeters(segmentRemainingMeters)) \(context), passing \(landmarkContext)."
            } else {
                currentInstruction = "Walk \(Self.formatMeters(segmentRemainingMeters)) \(context)."
            }
        }

        let bucket = Int(ceil(segmentRemainingMeters))
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
                cue = "One meter. \(Self.turnInstruction(at: step.to, from: step.edge.bearingDegrees, to: next.edge.bearingDegrees))."
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
            routeRemainingMeters: totalRemainingMeters,
            currentSegment: segment,
            nearbyLandmarks: nearby,
            recoveryReason: recoveryReason,
            hardRules: [
                "Do not invent distances, turns, targets, hazards, or landmarks.",
                "Only verbalize the provided deterministic route state.",
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
        if landmark.edgeID == baseEdgeID, let offset = landmark.offsetMeters {
            if landmark.kind != .destinationContext,
               landmark.nodeID == step.to.id,
               offset >= step.edge.distanceMeters - 1.2 {
                return nil
            }
            return reversed ? step.edge.distanceMeters - offset : offset
        }
        if landmark.nodeID == step.from.id {
            return min(0.8, step.edge.distanceMeters)
        }
        if landmark.kind == .destinationContext, landmark.nodeID == step.to.id {
            return max(0, step.edge.distanceMeters - 0.8)
        }
        return nil
    }

    private func resolveTarget(_ target: String, in map: SemanticRouteMap) -> SemanticRouteNode? {
        if let landmark = map.landmarks.first(where: { Self.matches($0.name, target) || $0.aliases.contains(where: { Self.matches($0, target) }) }),
           let node = map.nodes.first(where: { $0.id == landmark.nodeID }) {
            return node
        }
        return map.nodes.first { node in
            Self.matches(node.name, target) || node.aliases.contains { Self.matches($0, target) }
        }
    }

    private func resolveNavigationStart(
        in map: SemanticRouteMap,
        targetNodeID: String,
        arPosition: simd_float3?,
        imuState: IMUState
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
                let cost = max(0, edgeMatch.edge.distanceMeters - edgeMatch.alongTrackMeters)
                    + pathCost(for: forwardTail, in: map)
                options.append((path, progress, cost))
            }

            let reverseTail = shortestPath(in: map, from: edgeMatch.edge.fromNodeID, to: targetNodeID)
            if !reverseTail.isEmpty {
                let path = [edgeMatch.edge.toNodeID] + reverseTail
                let progress = max(0, edgeMatch.edge.distanceMeters - edgeMatch.alongTrackMeters)
                let cost = max(0, edgeMatch.alongTrackMeters) + pathCost(for: reverseTail, in: map)
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
        return SemanticRoutePoint(x: Double(arPosition.x), y: Double(arPosition.z))
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

    private static func turnInstruction(from currentBearing: Double, to nextBearing: Double) -> String {
        let diff = SemanticRouteMath.signedAngleDifference(nextBearing, currentBearing)
        let magnitude = abs(diff)
        if magnitude < 18 { return "continue straight" }
        if magnitude < 45 { return diff > 0 ? "take a slight right" : "take a slight left" }
        if magnitude < 135 { return diff > 0 ? "turn right" : "turn left" }
        return "turn around"
    }

    private static func turnInstruction(at node: SemanticRouteNode, from currentBearing: Double, to nextBearing: Double) -> String {
        node.turnHint?.spokenInstruction ?? turnInstruction(from: currentBearing, to: nextBearing)
    }

    private static func formatMeters(_ meters: Double) -> String {
        if meters < 1 {
            return String(format: "%.1f meters", meters)
        }
        return String(format: "%.0f meters", meters)
    }

    private static func aliases(for name: String) -> [String] {
        let lower = sanitizedSpokenLabel(name).lowercased()
        guard !lower.isEmpty else { return [] }
        var aliases: Set<String> = [lower]
        aliases.insert(lower.replacingOccurrences(of: "_", with: " "))
        aliases.insert(lower.replacingOccurrences(of: "-", with: " "))
        if lower.hasSuffix("s") {
            aliases.insert(String(lower.dropLast()))
        } else {
            aliases.insert("\(lower)s")
        }
        return Array(aliases).sorted()
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        sanitizedSpokenLabel(lhs).localizedCaseInsensitiveCompare(
            sanitizedSpokenLabel(rhs)
        ) == .orderedSame
    }

    private static func sanitizedMap(_ map: SemanticRouteMap) -> SemanticRouteMap {
        var cleaned = map
        cleaned.name = sanitizedSpokenLabel(map.name, fallback: "AR Route")
        cleaned.nodes = map.nodes.map { node in
            var copy = node
            copy.name = sanitizedSpokenLabel(node.name, fallback: node.kind.displayName)
            copy.aliases = aliases(for: copy.name)
            copy.poiAnchorId = sanitizedSpokenLabel(copy.poiAnchorId ?? "").nilIfBlank
            return copy
        }
        cleaned.edges = map.edges.map { edge in
            var copy = edge
            copy.leftContext = sanitizedSpokenLabel(edge.leftContext ?? "").nilIfBlank
            copy.rightContext = sanitizedSpokenLabel(edge.rightContext ?? "").nilIfBlank
            copy.spokenContext = sanitizedSpokenLabel(edge.spokenContext ?? "").nilIfBlank
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
                .map { sanitizedSpokenLabel($0) }
                .filter { !$0.isEmpty }
            if copy.visualFingerprintIds?.isEmpty == true {
                copy.visualFingerprintIds = nil
            }
            return copy
        }
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
