import Foundation
import CoreGraphics
import CoreImage
import Vision
@preconcurrency import ARKit

enum ARMappingSessionMode {
    case idle
    case mapping
    case relocalizing
}

final class ARMappingManager: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {
    @Published var isMapping = false
    @Published var mappingStatus: ARFrame.WorldMappingStatus = .notAvailable
    @Published var savedMapURL: URL?
    @Published var isRelocalizing = false
    @Published var isLocalized = false
    @Published var isSavingMap = false
    @Published var sessionMode: ARMappingSessionMode = .idle
    @Published var savedMaps: [ARStoredMapSummary] = []
    @Published var selectedMapID: String?
    @Published var activeMapID: String?
    @Published var activeMapName: String?
    @Published var currentPositionText: String = ""
    @Published var statusMessage: String?
    @Published var closestPOI: String?
    @Published var poiMatchStatusText: String?
    @Published var anchorsList: [String] = []
    @Published var mapPOIs: [String: simd_float3] = [:]
    @Published var mapFeaturePoints: [simd_float3] = []
    @Published var mapFeaturePointCount: Int = 0
    @Published var cameraMapPosition: simd_float3?
    @Published var cameraMapForward: simd_float3?
    @Published var arHeadingDegrees: Double?
    @Published var poiInspectionList: [ARMapPOIInspection] = []
    @Published var localizationCandidates: [ARLocalizationCandidate] = []
    /// Bumped when the already-localized pose jumps by more than
    /// `postLocalizationJumpMeters` shortly after localization — ARKit
    /// finishing its real world-map alignment after a premature `.normal`.
    /// Observers must re-resolve anything derived from the earlier pose.
    ///
    /// Rate-limited by `localizationCorrectionCooldownSeconds` rather than
    /// capped at one bump. ARKit refines its alignment several times over the
    /// first seconds, and bumping on every refinement re-resolved the route —
    /// and so the spoken turn — several times in a row while the user was being
    /// oriented. But the old once-per-relocalization cap was worse: it meant a
    /// realignment arriving after the first one was silently ignored, and the
    /// route stayed locked to a frame ARKit had already abandoned.
    ///
    /// ⚠️ Both position AND yaw feed this. A yaw-only realignment is the case
    /// that matters most and the one a distance check cannot see at all: when
    /// the journey begins at the route's first node, the un-relocalized session
    /// origin sits on top of that node, so the correction is a pure rotation
    /// with a ~0 m position delta. See `detectWorldFrameYawShift`.
    @Published private(set) var localizationRevision = 0
    private var lastLocalizationCorrectionAt: Date?
    /// Per-POI count of saved feature points within `poiRelocalizationRadiusMeters`,
    /// measured at the last save. These POIs (route start + destinations) are the
    /// spots a journey begins from; a low count predicts the cold-start "pan
    /// around then time out" relocalization stall there. Keyframe coverage in the
    /// route report does NOT measure this — that is a different layer.
    @Published private(set) var poiRelocalizationCounts: [String: Int] = [:]
    /// Pinned POIs whose feature density fell below the gate at the last save.
    /// Non-empty ⇒ the last plain `saveMap()` was blocked; `saveMap(force: true)`
    /// overrides.
    @Published private(set) var weakRelocalizationPOIs: [String] = []
    /// Place the camera visually recognizes while ARKit is still relocalizing.
    /// Image-fingerprint matching is pose-independent, so it can name where the
    /// user is standing seconds before the world map matches — that is what the
    /// waiting user hears instead of a blind "keep panning".
    @Published private(set) var recognizedPlaceName: String?

    /// The AR session this manager drives.
    ///
    /// A `var` because the return leg of a journey ADOPTS a session instead of
    /// running one: reaching hands its live, already-relocalized session back
    /// when it finishes, and `loadMapAndRelocalize` takes ownership of that
    /// object rather than resetting tracking on a fresh one. See
    /// `adoptOfferedLiveSession(forMapID:)`.
    private(set) var session = ARSession()
    /// True while another owner (the reaching session) is driving this session.
    /// Teardown must not pause it then — the point of the handoff is that
    /// reaching inherits tracking that is *already* relocalized.
    private(set) var isSessionHandedOff = false
    /// Bumped every time `session` is replaced, so the SwiftUI container knows
    /// to re-point the `ARSCNView` and the coaching overlay at the new object.
    /// `session` itself cannot be `@Published`: it is read from the session
    /// delegate queue on every frame.
    @Published private(set) var sessionRevision = 0
    private let sessionDelegateQueue = DispatchQueue(label: "placefinder.arkit.mapping.session", qos: .userInitiated)
    private let poiRecordsQueue = DispatchQueue(label: "placefinder.arkit.mapping.poi-records", attributes: .concurrent)
    private let imuMotionQueue = DispatchQueue(label: "placefinder.arkit.mapping.imu-motion", attributes: .concurrent)
    private let mapStore = ARMapStore()
    private let frameFingerprinter = ARFrameFingerprinter()
    private var poiAnchorsByName: [String: ARAnchor] = [:]
    private var poiRecords: [POIRecord] = []
    private var activeMapMetadata: ARStoredMapMetadata?
    private var latestIMUMotion: ARIMUMotionState?
    private var motionReference: ARIMUMotionReference?
    private var lastUpdateTime: TimeInterval = 0
    private var lastVisualMatchTime: TimeInterval = 0
    private var lastVisualMatchResult: VisualPOIMatchResult?
    private var lastVisualMatchCandidates: [VisualPOIMatch]?
    private var poseEvidenceWindow: [PoseEvidenceFrame] = []
    private var pendingStableMatchName: String?
    private var pendingStableMatchCount = 0
    private var pendingStableMatchStartTime: TimeInterval = 0
    private let frameUpdateInterval: TimeInterval = 0.15
    private let visualMatchInterval: TimeInterval = 0.45
    private let nearbySnapDistance: Float = 0.55
    private let maxPOIRecognitionDistance: Float = 24.0
    private let verticalTolerance: Float = 2.0
    private let minimumPOIMatchConfidence: Float = 0.58
    private let ambiguousScoreGap: Float = 0.20
    private let visualAgreementConfidence: Float = 0.72
    private let visualAmbiguousConfidenceGap: Float = 0.20
    private let visualPoseRequiredConfidence: Float = 0.88
    private let visualPoseConfirmationDistance: Float = 1.35
    private let visualOverrideConfidence: Float = 0.94
    private let visualDisagreementMaxDistance: Float = 1.6
    private let stableMatchRequiredFrames = 5
    private let stableMatchRequiredDuration: TimeInterval = 1.2
    private let stableMatchMinimumConfidence: Float = 0.82
    private let poseBeliefWindowDuration: TimeInterval = 2.8
    private let poseBeliefMinimumSupportRatio: Float = 0.55
    private let poseBeliefMinimumMargin: Float = 0.16
    private let poseBeliefMinimumAcceptanceConfidence: Float = 0.84
    private let poseBeliefMaximumCandidates = 6
    private let maxInspectableFeaturePoints = 1800
    /// Radius around a pinned POI within which saved feature points count toward
    /// cold-start relocalizability.
    private let poiRelocalizationRadiusMeters: Float = 1.6
    /// Minimum saved feature points within that radius for a POI to be treated as
    /// reliably relocalizable. A rushed pass-through (e.g. the last 0.6 m into a
    /// destination) banks far fewer than a deliberate turn-in-place anchor, so a
    /// POI below this floor is the one that stalls on "pan around" later.
    /// Conservative on purpose — measured counts surface in the inspector so the
    /// floor can be tuned against real maps.
    private let minPOIRelocalizationFeatures = 45
    /// How far a candidate pose may sit from a POI the camera is confidently
    /// recognizing before the pose is treated as being in the wrong frame.
    private let visualPoseContradictionDistance: Float = 12.0
    /// How far off-axis a visually recognized POI may sit before the believed
    /// frame is judged rotated. Visual matching already requires the POI to be
    /// within the camera's cone, so anything beyond a generous margin means the
    /// pose's yaw disagrees with what the lens is actually looking at.
    private let visualBearingContradictionDegrees: Double = 55.0
    /// Below this range the bearing to a POI swings wildly for a small position
    /// error, so the angular test says nothing useful.
    private let visualBearingMinimumDistanceMeters: Float = 1.5
    /// How far the relocalized AR heading may sit from the device compass
    /// before the frame is judged unaligned. Generous, because indoor compass
    /// readings are noisy — this is meant to catch the tens-of-degrees frame
    /// error a `.gravity` session carries, not to police a few degrees of
    /// magnetometer drift. The field failure was 63°.
    private let imuMotionMinimumSteps = 2
    private let imuMotionMinimumDistance: Float = 0.8
    private let imuMotionDirectionMinimumDistance: Float = 1.15
    private let imuMotionDirectionToleranceDegrees: Double = 48
    /// ARKit can report `.normal` tracking briefly BEFORE it has truly aligned
    /// to the loaded world map; trusting the first `.normal` published a
    /// session-origin pose (≈ the route start) and started guidance from the
    /// wrong place. `.normal` must now hold this long — with a settled pose —
    /// before isLocalized flips.
    private let relocalizationConfirmationSeconds: TimeInterval = 0.9
    /// worldMappingStatus normally reaches .mapped/.extending once the loaded
    /// map is matched; a feature-poor corridor can lag, so a longer stable
    /// window promotes without it rather than blocking forever.
    private let relocalizationStatusFallbackSeconds: TimeInterval = 2.7
    private let postLocalizationJumpMeters: Float = 1.5
    /// How much the AR↔device yaw offset may move across the settle window and
    /// still count as a frame ARKit has finished aligning.
    ///
    /// Sized above the noise floor, not at it: the AR heading and the device
    /// yaw are sampled by different subsystems at different instants, so a fast
    /// relocalization pan injects apparent offset spread from timing skew alone
    /// (90°/s against a 30 ms skew is ~3°). Held frames in the cims trace sat
    /// under 3.5° per second; the swing that should have been caught was 10–13°
    /// and the post-promotion shift was 38°.
    private let relocalizationYawSettleDegrees: Double = 8.0
    /// Escape hatch. A user standing still because the frame will not settle is
    /// worse than a frame that may be rotated — the visual keyframe headings
    /// correct that in flight now (`SemanticRouteNavigator`'s map-frame yaw
    /// bias), and there is no recovery at all from never starting.
    private let relocalizationYawSettleMaxWaitSeconds: TimeInterval = 12.0
    /// The offset has to be observed over at least this long before it can be
    /// called settled. Must stay under `WorldFrameYawWatch.windowSeconds`.
    private let relocalizationYawSettleWindowSeconds: TimeInterval = 1.0
    /// Minimum gap between two published corrections, so ARKit's burst of
    /// refinements in the first seconds cannot re-resolve the route repeatedly
    /// while the user is being oriented.
    private let localizationCorrectionCooldownSeconds: TimeInterval = 6.0
    /// True once the lean relocalization config has been swapped back to the
    /// full mapping config for this session.
    private var didUpgradeSessionFidelity = false
    /// When the fidelity re-run happened, so a transient tracking blip caused by
    /// the configuration change is not mistaken for lost tracking.
    /// How many named POI anchors the loaded map is expected to restore. Set on
    /// load, before the session runs, and read on the session queue; zero means
    /// the map carries no anchors and cannot supply relocalization proof.
    private var expectedRestoredPOICount = 0
    /// Identifiers of named anchors THIS session added (POI pins). They are
    /// indistinguishable from map-restored anchors by name alone, so the
    /// relocalization proof has to exclude them explicitly.
    private var locallyCreatedAnchorIDs: Set<UUID> = []
    private var lastTracedFrameAt: Date?
    private var lastTracedVetoReason: String?
    private var fidelityUpgradeAt: Date?
    private let fidelityUpgradeSettleSeconds: TimeInterval = 2.0
    private var relocalizationNormalSince: Date?
    /// When the yaw-settling veto first blocked a promotion, so the escape
    /// hatch can measure how long the user has been held up by it.
    private var yawSettleVetoSince: Date?
    /// True once that escape hatch has fired for this relocalization attempt.
    private var yawSettleVetoExpired = false
    private var preLocalizationPosition: simd_float3?
    private var previousPublishedPosition: simd_float3?
    private var localizedAt: Date?
    /// Frame rotation that was detected but whose correction the publish
    /// cooldown swallowed. Held rather than dropped: `WorldFrameYawWatch` has
    /// already re-baselined onto the corrected frame by the time the cooldown
    /// is consulted, so a dropped detection is a rotation nothing will ever
    /// report again — the route simply stays locked to the abandoned bearing.
    private var pendingFrameYawRotationDegrees: Double = 0
    /// Hysteresis state for the pitch threshold in `headingReading`.
    private var usingTiltFallbackHeading = false
    private var worldFrameYawWatch = WorldFrameYawWatch()
    
    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = sessionDelegateQueue
        refreshSavedMaps()
    }
    
    func startCameraFeed() {
        // Kept for compatibility with older call sites. The AR session is intentionally idle
        // until the user explicitly starts mapping or relocalization.
        stopMapping()
    }

    func updateIMUMotion(_ imuState: IMUState) {
        let motion = ARIMUMotionState(
            position: SIMD2<Double>(imuState.position.x, imuState.position.y),
            bearing: imuState.position.bearing,
            stepCount: imuState.stepCount,
            isMoving: imuState.isMoving,
            updatedAt: Date(),
            deviceYawDegrees: imuState.deviceYawDegrees
        )

        imuMotionQueue.async(flags: .barrier) {
            self.latestIMUMotion = motion
        }
    }
    
    func startMapping() {
        guard ARWorldTrackingConfiguration.isSupported else {
            statusMessage = "AR world tracking is not supported on this device."
            return
        }

        // A fresh capture defines its own frame; there is no map to prove
        // alignment against.
        expectedRestoredPOICount = 0
        locallyCreatedAnchorIDs.removeAll()
        reclaimSessionAfterHandoff()
        let config = makeWorldTrackingConfiguration()
        // The capture frame's yaw origin. A map recorded under one alignment
        // and relocalized under another is the first thing to rule out when
        // left/right cues mirror, so both ends are on the record.
        NavigationTrace.shared.log("ar.mappingStarted", [
            "worldAlignment": config.worldAlignment == .gravity ? "gravity" : "gravityAndHeading"
        ])
        lastTracedVetoReason = nil
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        // A fresh capture already runs the full config, so the on-demand
        // upgrade in `addPOIAnchor` has nothing to do — and must not re-run the
        // session mid-capture to discover that.
        didUpgradeSessionFidelity = true
        lastUpdateTime = 0
        isMapping = true
        isRelocalizing = false
        isLocalized = false
        relocalizationNormalSince = nil
        preLocalizationPosition = nil
        previousPublishedPosition = nil
        localizedAt = nil
        resetWorldFrameYawWatch()
        sessionMode = .mapping
        mappingStatus = .notAvailable
        activeMapMetadata = nil
        activeMapID = nil
        activeMapName = nil
        currentPositionText = ""
        closestPOI = nil
        poiMatchStatusText = nil
        anchorsList.removeAll()
        mapPOIs.removeAll()
        mapFeaturePoints.removeAll()
        mapFeaturePointCount = 0
        cameraMapPosition = nil
        cameraMapForward = nil
        arHeadingDegrees = nil
        poiInspectionList.removeAll()
        poiAnchorsByName.removeAll()
        replacePOIRecords(with: [])
        lastVisualMatchTime = 0
        lastVisualMatchResult = nil
        lastVisualMatchCandidates = nil
        poseEvidenceWindow.removeAll()
        localizationCandidates.removeAll()
        resetStableMatch()
        resetMotionReference()
        statusMessage = nil
    }
    
    func stopMapping() {
        // A handed-off session belongs to reaching now. Pausing it here would
        // undo the whole handoff: the JS arrival path tears this screen down
        // (handleDisappear → stopMapping) in the seconds between the offer and
        // reaching claiming it, and a paused session delivers no frames.
        if isSessionHandedOff {
            NSLog("🗺️ [ARMapping] stopMapping while session is handed off — leaving the session running for reaching")
        } else {
            session.pause()
        }
        isMapping = false
        isRelocalizing = false
        isLocalized = false
        isSavingMap = false
        relocalizationNormalSince = nil
        preLocalizationPosition = nil
        previousPublishedPosition = nil
        localizedAt = nil
        resetWorldFrameYawWatch()
        sessionMode = .idle
        mappingStatus = .notAvailable
        currentPositionText = ""
        closestPOI = nil
        poiMatchStatusText = nil
        cameraMapPosition = nil
        cameraMapForward = nil
        arHeadingDegrees = nil
        lastVisualMatchTime = 0
        lastVisualMatchResult = nil
        lastVisualMatchCandidates = nil
        poseEvidenceWindow.removeAll()
        localizationCandidates.removeAll()
        resetStableMatch()
        resetMotionReference()
    }

    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Live session handoff (navigation → reaching)
    // ═══════════════════════════════════════════════════════════════════════

    /// Hands the live, already-relocalized session to the reaching flow.
    ///
    /// Reaching used to start a COLD session (`initialWorldMap` +
    /// `.resetTracking`) at arrival, which asked the user to relocalize the
    /// whole world map a SECOND time — standing at a shelf, barely moving,
    /// with an 18 s budget. Relocalization at journey start only succeeds
    /// because the user deliberately turns a full circle there; at the
    /// destination it stalls, so the box never got placed and reaching timed
    /// out with "point toward the mapped shelf" on repeat.
    ///
    /// Inheriting the session removes that second relocalization entirely: the
    /// map frame is already established, the POI ARAnchors are already
    /// restored, and a POI coordinate read out of `mapPOIs` is *already* valid
    /// in the frame reaching is about to render.
    ///
    /// The session is NOT paused and its config is NOT re-run — see
    /// `upgradeSessionToFullFidelity` for why re-running a relocalized session
    /// is off the table. Returns nil when there is nothing worth inheriting,
    /// and the caller falls back to the old cold start.
    func detachLiveSessionForHandoff(reason: String) -> ARSession? {
        guard session.configuration != nil, sessionMode != .idle else {
            NSLog("🗺️ [ARMapping] No live session to hand off (%@) — mode=%@", reason, "\(sessionMode)")
            return nil
        }
        // A session that never localized carries no map frame, so its poses
        // mean nothing to a map-frame POI coordinate. A fresh capture session
        // IS the map frame, so it qualifies too.
        guard isLocalized || isMapping else {
            NSLog("🗺️ [ARMapping] Live session not localized — cold reaching start (%@)", reason)
            return nil
        }

        NavigationTrace.shared.log("ar.sessionHandoff", [
            "reason": reason,
            "isLocalized": isLocalized,
            "isMapping": isMapping,
            "mapID": activeMapID ?? NSNull()
        ])
        NSLog("🗺️ [ARMapping] 🤝 Handing live session to reaching (%@) — localized=%@ map=%@",
              reason, isLocalized ? "YES" : "NO", activeMapName ?? "none")

        isSessionHandedOff = true
        // Stop consuming frames on our side; reaching installs its own
        // delegate. Without this the manager keeps publishing pose updates
        // into a screen that is being torn down.
        session.delegate = nil

        // Same published-state reset as stopMapping, minus the pause.
        isMapping = false
        isRelocalizing = false
        isLocalized = false
        isSavingMap = false
        relocalizationNormalSince = nil
        preLocalizationPosition = nil
        previousPublishedPosition = nil
        localizedAt = nil
        resetWorldFrameYawWatch()
        sessionMode = .idle
        mappingStatus = .notAvailable
        currentPositionText = ""
        closestPOI = nil
        poiMatchStatusText = nil
        cameraMapPosition = nil
        cameraMapForward = nil
        arHeadingDegrees = nil
        lastVisualMatchTime = 0
        lastVisualMatchResult = nil
        lastVisualMatchCandidates = nil
        poseEvidenceWindow.removeAll()
        localizationCandidates.removeAll()
        resetStableMatch()
        resetMotionReference()

        return session
    }

    /// Takes back a live session reaching finished with, instead of relocalizing.
    ///
    /// The one-way handoff was a known, measured cost: every leg after a
    /// reaching arrival cold-loaded the ARWorldMap and relocalized again, at
    /// 4.6–11.4 s across the 11 Aug 2026 pilot traces and 36.7 / 39.1 s in the
    /// 25 Aug lab test — long enough that the automation gave up 0.85 s and
    /// 2.8 s before ARKit actually landed, so the return route was never built
    /// at all. This is the other end of `detachLiveSessionForHandoff`: the same
    /// ARSession object, still tracking in the same map frame, comes back.
    ///
    /// ⚠️ The session is NOT re-run. `run()` on a relocalized session reverts
    /// the world-frame yaw within ~0.2 s (see `upgradeSessionToFullFidelity`),
    /// which would move every map-frame coordinate sideways by r·θ and defeat
    /// the whole point of keeping it. It keeps the lean relocalization config
    /// navigation started it with, and `didUpgradeSessionFidelity` is latched
    /// so nothing re-runs it later either.
    ///
    /// Promotion still goes through the normal confirmation path rather than
    /// being asserted here: `hasRestoredMapAnchors` is recomputed from
    /// `frame.anchors` on every frame (NOT accumulated from `session(_:didAdd:)`,
    /// which would never re-fire for anchors an adopted session already holds),
    /// so the map's named anchors satisfy the alignment proof immediately and
    /// the hold clock is the only thing left to run — about a second.
    ///
    /// Returns false when there is nothing to adopt, and the caller cold-starts.
    private func adoptOfferedLiveSession(forMapID mapID: String) -> Bool {
        guard let adopted = ARLiveSessionHandoff.shared.claim(mapID: mapID) else { return false }
        guard adopted.configuration != nil, let frame = adopted.currentFrame else {
            // Offered but dead: it was paused, or never delivered a frame.
            // Cold-starting is the correct fallback, but this session has no
            // owner left, so stop it rather than leaving it on the camera.
            NSLog("🗺️ [ARMapping] Offered session has no live frame — cold relocalization instead")
            adopted.pause()
            return false
        }

        if session !== adopted {
            // Our own session has never run on a freshly presented screen, so
            // this is normally a no-op — but a manager that had one going must
            // not leave it holding the camera next to the adopted one.
            session.delegate = nil
            session.pause()
            session = adopted
            sessionRevision &+= 1
        }
        adopted.delegate = self
        adopted.delegateQueue = sessionDelegateQueue
        isSessionHandedOff = false
        // Reaching ran whatever configuration navigation handed it, which is
        // already the lean relocalization config. Latching this keeps
        // `addPOIAnchor`'s on-demand upgrade from re-running the session.
        didUpgradeSessionFidelity = true
        fidelityUpgradeAt = nil

        // ⚠️ The confirmation window has to be seeded by hand here.
        //
        // `relocalizationNormalSince` — the clock `confirmRelocalizationIfStable`
        // guards on, and the ONLY thing that opens it — is set from
        // `cameraDidChangeTrackingState`. Installing a delegate does not replay
        // that callback, and an adopted session is ALREADY `.normal`: the change
        // it would be waiting for happened minutes ago and will never happen
        // again. Without this the screen relocalizes forever against a session
        // that is already relocalized — a worse hang than the cold path it
        // replaces, because nothing would ever end it but the total budget.
        //
        // Tracking that is merely `.limited` needs no seed: ARKit will report
        // the transition to `.normal` itself and the usual path takes over.
        let isTrackingNormally: Bool
        if case .normal = frame.camera.trackingState { isTrackingNormally = true }
        else { isTrackingNormally = false }
        if isTrackingNormally {
            relocalizationNormalSince = Date()
            preLocalizationPosition = nil
        }

        NavigationTrace.shared.log("ar.sessionAdopted", [
            "mapID": mapID,
            "mapName": activeMapName ?? NSNull(),
            "expectedRestoredPOIs": expectedRestoredPOICount,
            "anchorsInFrame": frame.anchors.count,
            "namedAnchorsInFrame": frame.anchors.filter { $0.name?.isEmpty == false }.count,
            "trackingNormal": isTrackingNormally,
            "worldMappingStatus": Self.describe(frame.worldMappingStatus)
        ])
        NSLog("🗺️ [ARMapping] 🤝 Adopted the live session back from reaching — no relocalization needed")
        statusMessage = "Continuing on the live map."
        return true
    }

    /// Takes the session back before a mapping/relocalization run. Both entry
    /// points re-run it with `.resetTracking`, so whatever reaching left behind
    /// is discarded — only the delegate has to be re-installed, because the
    /// handoff cleared it.
    private func reclaimSessionAfterHandoff() {
        guard isSessionHandedOff else { return }
        isSessionHandedOff = false
        session.delegate = self
        session.delegateQueue = sessionDelegateQueue
        NSLog("🗺️ [ARMapping] Reclaimed the AR session after a reaching handoff")
    }

    func saveMap(named requestedName: String? = nil) {
        isSavingMap = true
        let existingMetadata = activeMapMetadata
        let resolvedName = normalizedMapName(requestedName, fallback: existingMetadata?.name)
        let recordsSnapshot = currentPOIRecords()

        session.getCurrentWorldMap { worldMap, error in
            guard let map = worldMap else {
                DispatchQueue.main.async {
                    self.isSavingMap = false
                    self.statusMessage = error?.localizedDescription ?? "Could not read the current AR map."
                }
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let loadedPOIs = self.deduplicatedPOIs(self.extractPOIs(from: map))
                    let featureSnapshot = self.sampledFeaturePoints(from: map.rawFeaturePoints)

                    // Relocalization advisory (NEVER blocks the save): journeys
                    // start at these POIs and ARKit cold-relocalizes best where the
                    // feature cloud is dense, so a thin endpoint is flagged for
                    // re-anchoring — but the ARWorldMap is always written. Blocking
                    // here once orphaned the map: the semantic layer saves first in
                    // saveSemanticWalkthrough, so a blocked save left a perfect route
                    // report sitting on a map that had no world map to relocalize.
                    let relocalizationCounts = self.poiFeatureDensity(
                        pois: loadedPOIs.map { (name: $0.name, position: $0.position) },
                        cloud: map.rawFeaturePoints
                    )
                    let weak = relocalizationCounts
                        .filter { $0.value < self.minPOIRelocalizationFeatures }
                        .keys.sorted()

                    let recordsByName = Dictionary(uniqueKeysWithValues: recordsSnapshot.map { ($0.name, $0) })
                    let storedPOIs = loadedPOIs.map { poi in
                        ARStoredPOI(
                            name: poi.name,
                            position: ARCodableVector3(poi.position),
                            visualFingerprint: recordsByName[poi.name]?.visualFingerprints.first,
                            visualFingerprints: recordsByName[poi.name]?.visualFingerprints,
                            motionFingerprint: recordsByName[poi.name]?.motionFingerprint,
                            placement: recordsByName[poi.name]?.placement
                        )
                    }
                    let metadata = try self.mapStore.save(
                        worldMap: map,
                        name: resolvedName,
                        replacing: existingMetadata,
                        pois: storedPOIs
                    )
                    
                    DispatchQueue.main.async {
                        self.isSavingMap = false
                        self.savedMapURL = self.mapStore.worldMapURL(for: metadata)
                        self.activeMapMetadata = metadata
                        self.activeMapID = metadata.id
                        self.activeMapName = metadata.name
                        self.selectedMapID = metadata.id
                        self.mapFeaturePoints = featureSnapshot.points
                        self.mapFeaturePointCount = featureSnapshot.totalCount
                        self.poiRelocalizationCounts = relocalizationCounts
                        self.weakRelocalizationPOIs = weak
                        self.refreshPOIInspectionList()
                        self.refreshSavedMaps()
                        let weakNote = weak.isEmpty
                            ? ""
                            : " \(self.listPhrase(weak)) weakly anchored — re-anchor for reliable relocalization from there."
                        self.statusMessage = "Saved \(metadata.name) with \(metadata.pois.count) POIs.\(weakNote)"
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isSavingMap = false
                        self.statusMessage = "Failed to save map: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    func loadMapAndRelocalize(mapID requestedMapID: String? = nil) {
        guard ARWorldTrackingConfiguration.isSupported else {
            statusMessage = "AR world tracking is not supported on this device."
            return
        }

        let mapID = requestedMapID ?? selectedMapID ?? savedMaps.first?.id
        guard let mapID else {
            statusMessage = "No saved maps found."
            return
        }

        statusMessage = "Loading saved map..."
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loadedMap = try self.mapStore.load(id: mapID)
                let map = loadedMap.worldMap
                let metadata = loadedMap.metadata
                let metadataByName = Dictionary(uniqueKeysWithValues: metadata.pois.map { ($0.name, $0) })
                let loadedPOIs = self.deduplicatedPOIs(self.extractPOIs(from: map))
                let featureSnapshot = self.sampledFeaturePoints(from: map.rawFeaturePoints)
                let records = loadedPOIs.map { poi in
                    POIRecord(
                        name: poi.name,
                        position: poi.position,
                        visualFingerprints: metadataByName[poi.name]?.allVisualFingerprints ?? [],
                        motionFingerprint: metadataByName[poi.name]?.motionFingerprint,
                        placement: metadataByName[poi.name]?.placement
                    )
                }

                DispatchQueue.main.async {
                    self.anchorsList = loadedPOIs.map(\.name)
                    self.mapPOIs = Dictionary(uniqueKeysWithValues: loadedPOIs.map { ($0.name, $0.position) })
                    self.poiAnchorsByName = Dictionary(uniqueKeysWithValues: loadedPOIs.map { ($0.name, $0.anchor) })
                    self.replacePOIRecords(with: records)
                    self.mapFeaturePoints = featureSnapshot.points
                    self.mapFeaturePointCount = featureSnapshot.totalCount
                    self.refreshPOIInspectionList()
                    self.activeMapMetadata = metadata
                    self.activeMapID = metadata.id
                    self.activeMapName = metadata.name
                    self.selectedMapID = metadata.id
                    self.isRelocalizing = true
                    self.isMapping = false
                    self.isLocalized = false
                    self.relocalizationNormalSince = nil
                    self.yawSettleVetoSince = nil
                    self.yawSettleVetoExpired = false
                    self.preLocalizationPosition = nil
                    self.previousPublishedPosition = nil
                    self.localizedAt = nil
                    self.resetWorldFrameYawWatch()
                    self.sessionMode = .relocalizing
                    self.mappingStatus = .notAvailable
                    self.currentPositionText = ""
                    self.closestPOI = nil
                    self.poiMatchStatusText = nil
                    self.lastUpdateTime = 0
                    self.lastVisualMatchTime = 0
                    self.lastVisualMatchResult = nil
                    self.lastVisualMatchCandidates = nil
                    self.poseEvidenceWindow.removeAll()
                    self.localizationCandidates.removeAll()
                    self.resetStableMatch()
                    self.resetMotionReference()
                    self.statusMessage = loadedPOIs.isEmpty
                        ? "Map loaded. No POIs are pinned yet."
                        : "Map loaded with \(loadedPOIs.count) POIs."

                    self.didUpgradeSessionFidelity = false
                    self.expectedRestoredPOICount = loadedPOIs.count
                    // Reloading resets the session, so nothing we pinned before
                    // survives; every named anchor from here is the map's.
                    self.locallyCreatedAnchorIDs.removeAll()
                    self.lastTracedVetoReason = nil
                    self.reclaimSessionAfterHandoff()

                    // The return leg of a journey. Reaching gave its live,
                    // already-relocalized session back when it finished, so the
                    // map frame this screen needs is established already and the
                    // 27–39 s cold relocalization below is pure waste — that is
                    // the wait the 25 Aug 2026 lab test spent standing at 421
                    // being coached to turn a full circle. Adopting returns
                    // early: everything above (POIs, metadata, published state)
                    // has already been applied and is what the adopted frame is
                    // read against.
                    if self.adoptOfferedLiveSession(forMapID: metadata.id) { return }

                    let config = self.makeWorldTrackingConfiguration(initialWorldMap: map, lightweight: true)
                    NavigationTrace.shared.log("ar.mapLoaded", [
                        "mapID": metadata.id,
                        "mapName": metadata.name,
                        "poiCount": loadedPOIs.count,
                        "poiNames": loadedPOIs.map(\.name),
                        "featurePoints": featureSnapshot.totalCount,
                        "worldAlignment": config.worldAlignment == .gravity ? "gravity" : "gravityAndHeading"
                    ])
                    self.session.run(config, options: [.resetTracking, .removeExistingAnchors])
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusMessage = "Could not load map: \(error.localizedDescription)"
                }
            }
        }
    }

    func refreshSavedMaps() {
        let maps = mapStore.loadSummaries()
        savedMaps = maps
        if selectedMapID == nil || maps.contains(where: { $0.id == selectedMapID }) == false {
            selectedMapID = maps.first?.id
        }
    }

    func deleteMap(id: String) {
        do {
            try mapStore.delete(id: id)
            if activeMapMetadata?.id == id {
                activeMapMetadata = nil
                activeMapID = nil
                activeMapName = nil
                anchorsList.removeAll()
                mapPOIs.removeAll()
                mapFeaturePoints.removeAll()
                mapFeaturePointCount = 0
                cameraMapPosition = nil
                cameraMapForward = nil
                arHeadingDegrees = nil
                localizationCandidates.removeAll()
                poseEvidenceWindow.removeAll()
                poiAnchorsByName.removeAll()
                replacePOIRecords(with: [])
                poiInspectionList.removeAll()
            }
            if selectedMapID == id {
                selectedMapID = nil
            }
            refreshSavedMaps()
            statusMessage = "Map deleted."
        } catch {
            statusMessage = "Could not delete map: \(error.localizedDescription)"
        }
    }

    func suggestedMapName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return "Map \(formatter.string(from: Date()))"
    }
    
    @discardableResult
    func addPOIAnchor(name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        guard isMapping || isLocalized else {
            statusMessage = "Start mapping or relocalize before pinning a POI."
            return false
        }
        guard let currentFrame = session.currentFrame else {
            statusMessage = "Camera pose is not ready yet."
            return false
        }
        // Pinning is the one thing that needs LiDAR depth and plane raycasts,
        // and a relocalized session runs the lightweight config that has
        // neither. Ask for them here — the authoring flow, where the user is
        // looking at the result and the map is about to be re-saved — and
        // never automatically after relocalizing, where the same call reverts
        // the map alignment under a blind user's route. THIS pin still uses
        // the fallback cascade in `surfacePOITransform`; the next one gets
        // depth. See `upgradeSessionToFullFidelity`.
        upgradeSessionToFullFidelity()
        let visualFingerprint = frameFingerprinter.makeFingerprint(from: currentFrame.capturedImage)

        if let existingAnchor = poiAnchorsByName[trimmedName] {
            session.remove(anchor: existingAnchor)
        }

        // Pin the anchor on the OBJECT the camera is aimed at, not at the
        // camera's own pose. A camera-pose anchor is wherever the user was
        // standing — offset from the real target by their whole reach
        // distance, which poisons spatial-target reaching later.
        let placed = surfacePOITransform(from: currentFrame)
        let anchor = ARAnchor(name: trimmedName, transform: placed.transform)
        session.add(anchor: anchor)
        // Ours, not the map's — must never count as relocalization proof.
        locallyCreatedAnchorIDs.insert(anchor.identifier)

        let anchorPos = simd_make_float3(placed.transform.columns.3.x, placed.transform.columns.3.y, placed.transform.columns.3.z)

        if !anchorsList.contains(trimmedName) {
            anchorsList.append(trimmedName)
        }
        mapPOIs[trimmedName] = anchorPos
        poiAnchorsByName[trimmedName] = anchor
        upsertPOIRecord(
            name: trimmedName,
            position: anchorPos,
            visualFingerprint: visualFingerprint,
            motionFingerprint: currentMotionFingerprint(),
            preservesExistingSamples: true,
            placement: placed.placement.rawValue
        )
        refreshPOIInspectionList()
        let cameraPos = simd_make_float3(
            currentFrame.camera.transform.columns.3.x,
            currentFrame.camera.transform.columns.3.y,
            currentFrame.camera.transform.columns.3.z
        )
        let pinDistance = simd_distance(cameraPos, anchorPos)
        NSLog("📍 [ARMapping] Pinned POI %@ via %@ at (%.2f, %.2f, %.2f), %.2fm from camera",
              trimmedName, placed.placement.rawValue, anchorPos.x, anchorPos.y, anchorPos.z, pinDistance)
        switch placed.placement {
        case .cameraPose:
            statusMessage = "Pinned \(trimmedName) at your position. Aim the camera at it and re-pin for surface accuracy."
        default:
            // Raycast error grows with range; a far pin can land a meter or
            // more past the object (e.g. through glass behind it).
            if pinDistance > 2.0 {
                statusMessage = String(
                    format: "Pinned %@ %.1fm away. For reaching accuracy, step within arm's reach and re-pin.",
                    trimmedName, pinDistance
                )
            } else {
                statusMessage = visualFingerprint == nil
                    ? "Pinned \(trimmedName) on the surface. Visual sample was not ready."
                    : "Pinned \(trimmedName) on the surface with visual sample."
            }
        }
        return true
    }

    /// How a stored POI anchor's position was derived. Surface placements sit
    /// on the target itself; `cameraPose` is the legacy fallback (the user's
    /// standing pose), which reaching treats as approximate.
    enum POIPlacement: String {
        case lidarSurface = "lidar_surface"
        case raycastSurface = "raycast_surface"
        case featurePointSurface = "feature_point_surface"
        case cameraPose = "camera_pose"
    }

    private func surfacePOITransform(from frame: ARFrame) -> (transform: simd_float4x4, placement: POIPlacement) {
        let camT = frame.camera.transform
        let camPos = simd_make_float3(camT.columns.3)
        let forward = -simd_normalize(simd_make_float3(camT.columns.2))

        func transform(at depth: Float) -> simd_float4x4 {
            var pinned = camT
            let position = camPos + forward * depth
            pinned.columns.3 = simd_float4(position.x, position.y, position.z, 1)
            return pinned
        }

        // 1. LiDAR metric depth at the frame center (Pro devices).
        if let lidarDepth = centerSceneDepth(from: frame), lidarDepth >= 0.15, lidarDepth <= 5.0 {
            return (transform(at: lidarDepth), .lidarSurface)
        }

        // 2. ARKit plane raycast along the camera-forward ray.
        for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
            let query = ARRaycastQuery(origin: camPos, direction: forward, allowing: target, alignment: .any)
            if let hit = session.raycast(query).first {
                let hitPos = simd_make_float3(hit.worldTransform.columns.3)
                let depth = simd_length(hitPos - camPos)
                if depth >= 0.15, depth <= 5.0 {
                    return (transform(at: depth), .raycastSurface)
                }
            }
        }

        // 3. Median feature-point distance in a narrow cone around the ray.
        if let cloud = frame.rawFeaturePoints {
            var dists: [Float] = []
            dists.reserveCapacity(min(cloud.points.count, 64))
            for point in cloud.points {
                let toPoint = point - camPos
                let d = simd_length(toPoint)
                guard d > 0.15, d < 5.0 else { continue }
                if simd_dot(toPoint / d, forward) > 0.95 {
                    dists.append(d)
                }
            }
            if dists.count >= 6 {
                dists.sort()
                let n = dists.count
                let median = n % 2 == 0 ? (dists[n / 2 - 1] + dists[n / 2]) / 2 : dists[n / 2]
                let iqr = dists[3 * n / 4] - dists[n / 4]
                if iqr < 0.25 {
                    return (transform(at: median), .featurePointSurface)
                }
            }
        }

        // 4. Legacy fallback: the camera pose itself.
        return (camT, .cameraPose)
    }

    private func centerSceneDepth(from frame: ARFrame) -> Float? {
        guard let sceneDepth = frame.sceneDepth else { return nil }
        let depthMap = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        // Median of a 5x5 center window rejects single-pixel LiDAR noise.
        var samples: [Float] = []
        samples.reserveCapacity(25)
        for dy in -2...2 {
            let y = height / 2 + dy
            guard y >= 0, y < height else { continue }
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for dx in -2...2 {
                let x = width / 2 + dx
                guard x >= 0, x < width else { continue }
                let value = row[x]
                if value.isFinite, value > 0 {
                    samples.append(value)
                }
            }
        }
        guard samples.count >= 5 else { return nil }
        samples.sort()
        return samples[samples.count / 2]
    }

    @discardableResult
    func addVisualSample(name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        guard isMapping || isLocalized else {
            statusMessage = "Start mapping or relocalize before sampling a POI."
            return false
        }
        guard mapPOIs[trimmedName] != nil else {
            statusMessage = "Pin \(trimmedName) before adding samples."
            return false
        }
        guard let frame = session.currentFrame,
              let visualFingerprint = frameFingerprinter.makeFingerprint(from: frame.capturedImage) else {
            statusMessage = "Visual sample was not ready."
            return false
        }

        appendVisualSample(
            name: trimmedName,
            visualFingerprint: visualFingerprint,
            motionFingerprint: currentMotionFingerprint()
        )
        refreshPOIInspectionList()
        let sampleCount = currentPOIRecords().first(where: { $0.name == trimmedName })?.visualFingerprints.count ?? 0
        statusMessage = "Added visual sample \(sampleCount) for \(trimmedName)."
        return true
    }

    @discardableResult
    func retakeVisualSample(name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        guard isMapping || isLocalized else {
            statusMessage = "Start mapping or relocalize before retaking a sample."
            return false
        }
        guard let poiPosition = mapPOIs[trimmedName] else {
            statusMessage = "Pin \(trimmedName) before retaking samples."
            return false
        }
        guard let frame = session.currentFrame,
              let visualFingerprint = frameFingerprinter.makeFingerprint(from: frame.capturedImage) else {
            statusMessage = "Visual sample was not ready."
            return false
        }

        upsertPOIRecord(
            name: trimmedName,
            position: poiPosition,
            visualFingerprint: visualFingerprint,
            motionFingerprint: currentMotionFingerprint(),
            preservesExistingSamples: false
        )
        refreshPOIInspectionList()
        statusMessage = "Retook visual sample for \(trimmedName)."
        return true
    }

    @discardableResult
    func deletePOI(named name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return false }
        guard mapPOIs[trimmedName] != nil || poiAnchorsByName[trimmedName] != nil else {
            statusMessage = "\(trimmedName) is not pinned on this map."
            return false
        }

        if let anchor = poiAnchorsByName[trimmedName] {
            session.remove(anchor: anchor)
        }

        poiAnchorsByName.removeValue(forKey: trimmedName)
        mapPOIs.removeValue(forKey: trimmedName)
        anchorsList.removeAll { $0 == trimmedName }
        removePOIRecord(name: trimmedName)
        resetMotionReference()

        if closestPOI == trimmedName {
            closestPOI = nil
        }
        if selectedMapID != nil {
            statusMessage = "Deleted \(trimmedName). Save the map to persist it."
        } else {
            statusMessage = "Deleted \(trimmedName)."
        }
        refreshPOIInspectionList()
        return true
    }

    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let currentTime = frame.timestamp
        if currentTime - lastUpdateTime < frameUpdateInterval { return }
        lastUpdateTime = currentTime
        
        let mappingStatus = frame.worldMappingStatus
        let transform = frame.camera.transform
        let yaw = frame.camera.eulerAngles.y * 180 / .pi
        let cameraPosition = simd_make_float3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let cameraForward = simd_make_float3(-transform.columns.2.x, -transform.columns.2.y, -transform.columns.2.z)
        // Up vector too: it is the heading reference whenever the phone is
        // pitched far enough that forward goes near-vertical.
        let cameraUp = simd_make_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)
        let headingReading = self.headingReading(for: cameraForward, cameraUp: cameraUp)
        let arHeading = headingReading?.degrees
        let headingUsedTiltFallback = headingReading?.usedTiltFallback ?? false
        let displayHeading = arHeading ?? Double(yaw)
        let liveFeatureSnapshot = isMapping ? sampledFeaturePoints(from: frame.rawFeaturePoints) : nil
        let poiMatchResult = bestPOIMatch(
            cameraTransform: transform,
            capturedImage: frame.capturedImage,
            timestamp: currentTime
        )
        // Read on the session queue, where visualPOIMatches just wrote it. This
        // is the pose-independent half of the match, so it stays meaningful
        // while the world-map pose is still garbage.
        let visuallyRecognizedPlace = lastVisualMatchResult?.match?.name

        // Proof that a named anchor in this frame came from the LOADED MAP
        // rather than from us.
        //
        // ⚠️ "any named anchor" is not that proof, which is how this check came
        // to pass while gating nothing: `addPOIAnchor` puts named anchors into
        // the very same session, so the flag flipped true the instant the user
        // pinned their first POI — during a fresh capture, with no map loaded at
        // all (see the 2026-07-27 trace: node pinned at t=12.7, flag true at
        // t=13.2). A pose still in ARKit's own session frame then read as
        // map-aligned, and under `.gravity` that frame's yaw is arbitrary —
        // the "Localized, route locked, now turn 100° into a desk" failure.
        // Only anchors this session did not create can testify.
        let hasRestoredMapAnchors = frame.anchors.contains { anchor in
            anchor.name?.isEmpty == false && !locallyCreatedAnchorIDs.contains(anchor.identifier)
        }


        let x = transform.columns.3.x
        let z = transform.columns.3.z

        DispatchQueue.main.async {
            // Before the promotion gate, not after: the gate's yaw-settling
            // veto reads the window this call feeds, and judging the frame on
            // evidence that stops one frame short of the decision is how a
            // still-swinging frame got promoted.
            self.detectWorldFrameYawShift(
                arHeading: arHeading,
                usedTiltFallback: headingUsedTiltFallback
            )
            self.confirmRelocalizationIfStable(
                cameraPosition: cameraPosition,
                cameraForward: cameraForward,
                arHeading: arHeading,
                mappingStatus: mappingStatus,
                hasRestoredMapAnchors: hasRestoredMapAnchors
            )
            self.detectPostLocalizationJump(cameraPosition: cameraPosition)
            self.mappingStatus = mappingStatus
            self.cameraMapPosition = cameraPosition
            self.cameraMapForward = cameraForward
            self.arHeadingDegrees = arHeading
            if let liveFeatureSnapshot {
                self.mapFeaturePoints = liveFeatureSnapshot.points
                self.mapFeaturePointCount = liveFeatureSnapshot.totalCount
            }
            self.localizationCandidates = poiMatchResult.candidates
            self.recognizedPlaceName = self.isLocalized ? nil : visuallyRecognizedPlace


            if self.isLocalized {
                if let match = poiMatchResult.match {
                    self.closestPOI = match.name
                    self.poiMatchStatusText = poiMatchResult.statusText
                        ?? String(format: "Confidence %.0f%%", match.confidence * 100)
                    self.currentPositionText = String(
                        format: "X %.1f  Z %.1f  HDG %.0f°\nPOI %@  %.1fm  %.0f°",
                        x,
                        z,
                        displayHeading,
                        match.name,
                        match.distance,
                        match.angleDegrees
                    )
                } else if poiMatchResult.isAmbiguous {
                    self.closestPOI = nil
                    self.poiMatchStatusText = poiMatchResult.statusText ?? "Ambiguous view"
                    self.currentPositionText = String(
                        format: "X %.1f  Z %.1f  HDG %.0f°\n%@",
                        x,
                        z,
                        displayHeading,
                        poiMatchResult.statusText ?? "Align camera with one named POI"
                    )
                } else {
                    self.closestPOI = nil
                    self.poiMatchStatusText = poiMatchResult.statusText
                    self.currentPositionText = String(
                        format: "X %.1f  Z %.1f  HDG %.0f°\n%@",
                        x,
                        z,
                        displayHeading,
                        poiMatchResult.statusText ?? "No POI in view"
                    )
                }
            } else if self.isMapping {
                self.currentPositionText = String(format: "X %.1f  Z %.1f  HDG %.0f°", x, z, displayHeading)
                self.poiMatchStatusText = nil
            } else {
                self.currentPositionText = ""
                self.poiMatchStatusText = nil
            }

            self.traceARFrame(
                position: cameraPosition,
                heading: arHeading,
                usedTiltFallback: headingUsedTiltFallback,
                mappingStatus: mappingStatus,
                hasRestoredMapAnchors: hasRestoredMapAnchors,
                visuallyRecognizedPlace: visuallyRecognizedPlace
            )
        }
    }

    /// The raw AR frame the route layer is fed, at ~4 Hz. Whether the pose is
    /// in the saved map's frame or the session's own is exactly what the trace
    /// has to be able to settle, so this records the alignment evidence
    /// (restored anchors, mapping status) beside the pose itself.
    private func traceARFrame(
        position: simd_float3,
        heading: Double?,
        usedTiltFallback: Bool,
        mappingStatus: ARFrame.WorldMappingStatus,
        hasRestoredMapAnchors: Bool,
        visuallyRecognizedPlace: String?
    ) {
        let now = Date()
        guard lastTracedFrameAt.map({ now.timeIntervalSince($0) >= 0.25 }) ?? true else { return }
        lastTracedFrameAt = now
        // The AR yaw beside the ARKit-independent device yaw, every sample. A
        // frame that rotates under a stationary user is only visible as the
        // divergence between these two columns, and reading the AR heading alone
        // (all the trace used to carry) cannot tell that apart from a user
        // turning — which is why three sessions of traces did not settle it.
        let deviceYaw = currentIMUMotion()?.deviceYawDegrees
        NavigationTrace.shared.tick("ar.frame", [
            "x": Double(position.x),
            "z": Double(position.z),
            "routeY": -Double(position.z),
            "headingDeg": heading ?? NSNull(),
            "deviceYawDeg": deviceYaw ?? NSNull(),
            "headingTiltFallback": usedTiltFallback,
            "frameYawDriftDeg": {
                guard let heading, let deviceYaw else { return NSNull() as Any }
                return worldFrameYawWatch.frameYawDrift(
                    arHeading: heading,
                    deviceYaw: deviceYaw
                ) ?? NSNull()
            }(),
            "mappingStatus": Self.describe(mappingStatus),
            "isLocalized": isLocalized,
            "isRelocalizing": isRelocalizing,
            "isMapping": isMapping,
            "hasRestoredMapAnchors": hasRestoredMapAnchors,
            "expectedRestoredPOIs": expectedRestoredPOICount,
            "closestPOI": closestPOI ?? NSNull(),
            "visuallyRecognized": visuallyRecognizedPlace ?? NSNull(),
            "activeMapID": activeMapID ?? NSNull()
        ])
    }

    /// Why a `.normal` frame was not promoted to "localized". Logged once per
    /// distinct reason so a 30-second search does not bury the rest of the
    /// trace, but re-logged whenever the reason changes.
    private func traceRelocalizationVeto(_ reason: String, detail: [String: Any]) {
        guard lastTracedVetoReason != reason else { return }
        lastTracedVetoReason = reason
        var fields = detail
        fields["reason"] = reason
        fields["activeMapID"] = activeMapID ?? NSNull()
        NavigationTrace.shared.log("ar.relocalizeVeto", fields)
    }

    private static func describe(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: return "notAvailable"
        case .limited: return "limited"
        case .extending: return "extending"
        case .mapped: return "mapped"
        @unknown default: return "unknown"
        }
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            if self.isRelocalizing {
                switch camera.trackingState {
                case .normal:
                    // Do NOT flip isLocalized on the first `.normal`: ARKit can
                    // report it before the loaded map is truly aligned, and the
                    // camera pose is then still session-origin-relative. Open a
                    // confirmation window; the frame handler promotes once the
                    // pose has held steady (confirmRelocalizationIfStable).
                    if !self.isLocalized, self.relocalizationNormalSince == nil {
                        self.relocalizationNormalSince = Date()
                        self.preLocalizationPosition = nil
                        self.statusMessage = "Matching the saved map..."
                    }
                default:
                    self.relocalizationNormalSince = nil
                    self.yawSettleVetoSince = nil
                    self.yawSettleVetoExpired = false
                    self.preLocalizationPosition = nil
                    // Re-running the session to restore plane/mesh fidelity can
                    // blip tracking for a frame or two. That is a configuration
                    // change, not a lost map, so it must not tear down a
                    // relocalization the user just spent time earning.
                    let isFidelitySettling = self.fidelityUpgradeAt.map {
                        Date().timeIntervalSince($0) < self.fidelityUpgradeSettleSeconds
                    } ?? false
                    // Tracking genuinely dropped: the yaw baseline belongs to a
                    // frame that may not survive the recovery, so it must not be
                    // carried across and reported as a shift afterwards. The
                    // next promotion sets a new one.
                    //
                    // ⚠️ Not on a fidelity blip. The same `isFidelitySettling`
                    // window already protects `isLocalized` here — but the
                    // baseline was being wiped unconditionally, so the one event
                    // most likely to move the frame (our own `session.run()`)
                    // was also the event that blinded the watch to it. That is
                    // the cims trace: 38° of rotation, `frameYawDriftDeg`
                    // reporting 2.9°, and a route left pointing into a wall.
                    if !isFidelitySettling {
                        self.worldFrameYawWatch.acceptAlignment(arHeading: nil, deviceYaw: nil)
                        NavigationTrace.shared.log("ar.yawBaselineDropped", [
                            "trackingState": "\(camera.trackingState)",
                            "wasLocalized": self.isLocalized
                        ])
                    }
                    if self.isLocalized, !isFidelitySettling {
                        self.isLocalized = false
                        self.closestPOI = nil
                        self.poiMatchStatusText = nil
                        self.statusMessage = "Tracking limited. Hold the camera steady."
                    }
                }
            }
        }
    }

    /// Runs on every throttled frame while a confirmation window is open.
    /// Promotes to isLocalized only after `.normal` has held long enough with
    /// a settled pose; a pose jump inside the window means alignment happened
    /// mid-window, so the clock restarts to let the corrected pose stand.
    private func confirmRelocalizationIfStable(
        cameraPosition: simd_float3,
        cameraForward: simd_float3,
        arHeading: Double?,
        mappingStatus: ARFrame.WorldMappingStatus,
        hasRestoredMapAnchors: Bool
    ) {
        guard isRelocalizing, !isLocalized, let normalSince = relocalizationNormalSince else { return }

        // ── Map-alignment proof ─────────────────────────────────────────────
        // Without this, `.normal` tracking alone promotes ARKit's OWN session
        // frame as if it were the map frame. The distance-based visual veto
        // cannot catch that when the journey starts at the route's first node,
        // because the session origin sits right on top of it — position looks
        // perfect while heading is arbitrary (`.gravity` yaw is relative to
        // wherever the session started, not the map's north-aligned capture
        // frame). That is the "Localized, but turn around" failure: right place,
        // heading 180° out. Restored named anchors only exist once ARKit has
        // genuinely matched the map, so they are the proof that the frame — and
        // therefore every bearing derived from it — is real.
        // ── Compass corroboration ───────────────────────────────────────────
        // The decisive check, because the anchor proof below cannot be trusted:
        // ARKit adds a loaded map's named anchors at `run()` time, BEFORE
        // relocalization lands, so their presence proves nothing (field trace:
        // "LOCALIZED after 0.9s [ANCHOR-PROVEN]" on a 7332-feature map, with the
        // frame 63° out).
        //
        // Maps are captured under `.gravityAndHeading`, so their bearings are
        // compass-referenced. Relocalization must reproduce that frame — so a
        // genuinely aligned AR heading agrees with the device compass. When it
        // does not, ARKit is still tracking in its own `.gravity` frame whose
        // yaw is arbitrary, and every bearing derived from it is wrong. The
        // field trace is unambiguous: compass 303.0° vs route 298.1° (agree),
        // ARKit 1.2° (63° out) — and guidance turned the user 63° off a
        // corridor they were already facing correctly.
        // ⚠️ REMOVED: a "compass corroboration" veto that compared `arHeading`
        // against `latestIMUMotion.bearing`. That premise was false —
        // `IMUSensorManager` has no magnetometer at all; its bearing is a
        // gyro-integrated value SEEDED from this very AR heading
        // (`seedIMUBearingIfNeeded` → `setInitialBearing`). It compared ARKit
        // against a drifted copy of ARKit, so it could never validate the map
        // frame. Kept as a note so the idea is not re-invented.

        if expectedRestoredPOICount > 0, !hasRestoredMapAnchors {
            relocalizationNormalSince = Date()
            let waiting = "Matching the saved map. Keep the camera up and turn slowly."
            if statusMessage != waiting { statusMessage = waiting }
            traceRelocalizationVeto("no_restored_map_anchors", detail: [
                "expectedRestoredPOIs": expectedRestoredPOICount
            ])
            return
        }
        if expectedRestoredPOICount == 0 {
            // No named anchors in the saved map means the anchor proof above
            // cannot run, so `.normal` tracking alone is allowed to promote a
            // pose that may still be in ARKit's own session frame. Worth
            // knowing before blaming the route graph for mirrored cues.
            traceRelocalizationVeto("anchor_proof_unavailable", detail: [
                "expectedRestoredPOIs": 0
            ])
        }

        if let previous = preLocalizationPosition,
           simd_distance(previous, cameraPosition) > postLocalizationJumpMeters {
            relocalizationNormalSince = Date()
            preLocalizationPosition = cameraPosition
            traceRelocalizationVeto("pose_still_jumping", detail: [
                "jumpM": Double(simd_distance(previous, cameraPosition))
            ])
            return
        }
        preLocalizationPosition = cameraPosition

        // ── Yaw-settling veto ───────────────────────────────────────────────
        // The position check above cannot see the failure that actually
        // happens. ARKit's relocalization refines over several seconds, and a
        // refinement is largely a ROTATION about a point the user is standing
        // on: position moves by centimetres while the world yaw — the quantity
        // every bearing, every turn word and the whole overlay derive from —
        // swings by tens of degrees.
        //
        // The 2026-07-30 cims trace: the AR↔device yaw offset moved through
        // −21° … −34° over the three seconds before promotion and the pose
        // read as rock steady the whole time. It was promoted mid-swing, the
        // route was locked to that instant's frame, and 0.34 s later the frame
        // moved another 38°. Requiring the offset to hold still is the only
        // way to promote a frame ARKit has actually finished with.
        let yawSpread = worldFrameYawWatch.offsetSpreadDegrees(
            minimumSeconds: relocalizationYawSettleWindowSeconds
        )
        if let yawSpread, yawSpread <= relocalizationYawSettleDegrees {
            // Settled: forget how long the last unsettled spell ran, so a
            // second one later gets its own full patience rather than
            // inheriting a clock that has already run out.
            yawSettleVetoSince = nil
        } else if let yawSpread, !yawSettleVetoExpired {
            let vetoSince = yawSettleVetoSince ?? Date()
            yawSettleVetoSince = vetoSince
            let waitedSeconds = Date().timeIntervalSince(vetoSince)
            if waitedSeconds < relocalizationYawSettleMaxWaitSeconds {
                relocalizationNormalSince = Date()
                let waiting = "Matching the saved map. Hold the camera steady."
                if statusMessage != waiting { statusMessage = waiting }
                traceRelocalizationVeto("frame_yaw_still_settling", detail: [
                    "offsetSpreadDeg": yawSpread,
                    "allowedDeg": relocalizationYawSettleDegrees,
                    "waitedSeconds": waitedSeconds
                ])
                return
            }
            // Latched, not re-armed. The veto resets `relocalizationNormalSince`
            // on every frame it blocks, so a timeout that merely stopped
            // vetoing for one frame would be undone by the next: the hold clock
            // would never reach the confirmation window and the user would wait
            // forever. Giving up has to stay given up until something resets
            // the relocalization.
            yawSettleVetoExpired = true
            NavigationTrace.shared.log("ar.yawSettleTimeout", [
                "offsetSpreadDeg": yawSpread,
                "allowedDeg": relocalizationYawSettleDegrees,
                "waitedSeconds": waitedSeconds
            ])
        }

        // ── Wrong-frame veto ────────────────────────────────────────────────
        // `.normal` tracking does NOT prove ARKit matched the saved map: while
        // relocalization has not landed, ARKit keeps tracking in its OWN session
        // frame whose origin is wherever the session started. Promoting that pose
        // is exactly the "wrong initial localization" failure — the user gets
        // placed near the route beginning no matter where they really are, so the
        // first cue is "turn around" while the real route runs straight ahead.
        // The visual fingerprint match is pose-INDEPENDENT, so it can veto a pose
        // that lands far from the place the camera is actually looking at. Keep
        // searching instead of starting guidance from a frame known to be wrong.
        if let contradiction = visualEvidenceContradiction(
            for: cameraPosition,
            cameraForward: cameraForward
        ) {
            relocalizationNormalSince = Date()
            if statusMessage != contradiction {
                statusMessage = contradiction
            }
            traceRelocalizationVeto("visual_evidence_contradiction", detail: [
                "message": contradiction
            ])
            return
        }

        let heldSeconds = Date().timeIntervalSince(normalSince)
        let statusConfirms = mappingStatus == .mapped || mappingStatus == .extending
        let promoted = statusConfirms
            ? heldSeconds >= relocalizationConfirmationSeconds
            : heldSeconds >= relocalizationStatusFallbackSeconds
        guard promoted else { return }

        relocalizationNormalSince = nil
        yawSettleVetoSince = nil
        yawSettleVetoExpired = false
        preLocalizationPosition = nil
        cameraMapPosition = cameraPosition
        cameraMapForward = cameraForward
        arHeadingDegrees = arHeading
        previousPublishedPosition = cameraPosition
        localizedAt = Date()
        lastLocalizationCorrectionAt = nil
        // Baseline the frame-rotation watch from the yaw we are about to hand
        // guidance. Everything after this is measured against it, so if this
        // promotion turns out to be premature the realignment shows up as a
        // divergence instead of vanishing into a route locked at the wrong angle.
        let deviceYawAtPromotion = currentIMUMotion()?.deviceYawDegrees
        worldFrameYawWatch.acceptAlignment(
            arHeading: arHeading,
            deviceYaw: deviceYawAtPromotion
        )
        isLocalized = true
        statusMessage = "Localized against saved map."
        lastTracedVetoReason = nil
        NavigationTrace.shared.log("ar.localized", [
            "heldSeconds": heldSeconds,
            "mappingStatus": Self.describe(mappingStatus),
            "statusConfirms": statusConfirms,
            // ⚠️ NOT proof of anything. ARKit inserts a loaded map's named
            // anchors at `run()` time, before relocalization, so this is true
            // from the first frame. Named to stop the trace reader (and the
            // analyzer, which printed "[ANCHOR-PROVEN]") from treating a
            // restored-anchor count as evidence the frame is aligned.
            "restoredAnchorsPresent": expectedRestoredPOICount > 0 && hasRestoredMapAnchors,
            "expectedRestoredPOIs": expectedRestoredPOICount,
            // What the frame was doing when it was accepted. A promotion with a
            // null spread means the watch had no window to judge with, not that
            // the frame was steady.
            "yawOffsetSpreadDeg": yawSpread ?? NSNull(),
            "deviceYawDeg": deviceYawAtPromotion ?? NSNull(),
            "x": Double(cameraPosition.x),
            "z": Double(cameraPosition.z),
            "routeY": -Double(cameraPosition.z),
            "headingDeg": arHeading ?? NSNull(),
            "activeMapID": activeMapID ?? NSNull(),
            "activeMapName": activeMapName ?? NSNull()
        ])
        // ⚠️ NOTHING re-runs the session here. See
        // `upgradeSessionToFullFidelity` for why relocalizing no longer
        // triggers a fidelity upgrade at all.
    }

    /// A large pose jump shortly after localization is ARKit correcting a
    /// premature alignment. The published pose is already correct; bump the
    /// revision so guidance built on the stale pose re-resolves itself.
    private func detectPostLocalizationJump(cameraPosition: simd_float3) {
        guard isRelocalizing, isLocalized else {
            previousPublishedPosition = cameraPosition
            return
        }
        defer { previousPublishedPosition = cameraPosition }
        guard let previous = previousPublishedPosition,
              simd_distance(previous, cameraPosition) > postLocalizationJumpMeters else {
            return
        }
        let jump = Double(simd_distance(previous, cameraPosition))
        guard publishLocalizationCorrection(reason: "pose_jump") else { return }
        NavigationTrace.shared.log("ar.poseJump", [
            "jumpM": jump,
            "sinceLocalizedS": localizedAt.map { Date().timeIntervalSince($0) } ?? NSNull(),
            "fromX": Double(previous.x),
            "fromRouteY": -Double(previous.z),
            "toX": Double(cameraPosition.x),
            "toRouteY": -Double(cameraPosition.z),
            "revision": localizationRevision
        ])
    }

    /// Detects ARKit re-orienting the world frame under a pose we already
    /// published — the failure mode no position check can see.
    ///
    /// ## Why this is needed at all
    ///
    /// A journey usually starts at the route's first node, which is also where
    /// the mapping walk started, which is where the saved map's ORIGIN is. Until
    /// relocalization lands, ARKit tracks in its own `.gravity` frame whose
    /// origin is where this session started — the same spot. So the pose reads
    /// as sitting exactly on the first node (the 2026-07-29 IGA trace snapped it
    /// to the right edge at 0.25 m cross-track) while the yaw is arbitrary. When
    /// ARKit then aligns for real, the correction is a pure ROTATION about a
    /// point the user is standing on: position barely moves, so
    /// `detectPostLocalizationJump` sees nothing, `localizationRevision` never
    /// bumps, and the route stays locked to a bearing ARKit has abandoned. That
    /// is what reaches the user as the route running off behind them.
    ///
    /// ## How it separates "the user turned" from "the frame turned"
    ///
    /// `IMUState.deviceYawDegrees` comes from `CMDeviceMotion.attitude` under
    /// `.xArbitraryZVertical`: gravity-referenced, pitch-immune, and — decisively
    /// — never seeded from ARKit. So over any short window
    ///
    ///     Δ(AR yaw) − Δ(device yaw) ≈ rotation of the AR world FRAME
    ///
    /// because whatever the user did with the phone appears in both terms and
    /// cancels. A user spinning 180° moves both by 180° and reads as zero; a
    /// stationary user whose AR heading walks 140° reads as 140°.
    ///
    /// ⚠️ This is the mechanism commit c718e3f deleted. That commit was right
    /// that comparing `arHeading` against `IMUState.bearing` cannot do
    /// COMPASS corroboration (there is no magnetometer, and `bearing` is seeded
    /// from the AR heading), and right to remove it from the promotion gate. But
    /// the differential signal it was accidentally computing was real, and
    /// deleting it left nothing at all watching the frame. This restores the
    /// signal on a reference that is genuinely independent, and uses it for what
    /// it can actually prove: rotation, not absolute direction.
    /// Delegates the decision to `WorldFrameYawWatch` (pure, unit-tested) and
    /// keeps only the I/O here: reading the sensors, rate-limiting, tracing.
    private func detectWorldFrameYawShift(arHeading: Double?, usedTiltFallback: Bool) {
        guard isRelocalizing, let arHeading,
              let deviceYaw = currentIMUMotion()?.deviceYawDegrees else {
            worldFrameYawWatch.clearWindow()
            return
        }
        let previousConvention = worldFrameYawWatch.signConvention
        // Observed from the first relocalizing frame, acted on only once there
        // is an accepted alignment to correct. Two things need the pre-promotion
        // samples: the yaw-settling veto in `confirmRelocalizationIfStable`, and
        // the sign convention — whose votes need a real turn, which is exactly
        // what the user is doing during the relocalization pan and almost never
        // does afterwards.
        let detection = worldFrameYawWatch.ingest(
            at: Date(),
            arHeading: arHeading,
            deviceYaw: deviceYaw,
            usedTiltFallback: usedTiltFallback,
            acting: isLocalized
        )
        if worldFrameYawWatch.signConvention != previousConvention {
            NavigationTrace.shared.log("ar.yawSignCalibrated", [
                "convention": worldFrameYawWatch.signConvention == .subtract ? "subtract" : "add",
                "votes": worldFrameYawWatch.signVotes,
                "cumulativeDetectorEnabled": worldFrameYawWatch.signConvention == .subtract
            ])
        }
        // A rotation the cooldown swallowed earlier still has to reach the route
        // layer; retry it as soon as the cooldown allows.
        if detection == nil,
           pendingFrameYawRotationDegrees != 0,
           publishLocalizationCorrection(reason: "frame_yaw_shift_deferred") {
            NavigationTrace.shared.log("ar.frameYawShift", [
                "detector": "deferred",
                "frameRotationDeg": pendingFrameYawRotationDegrees,
                "arHeadingDeg": arHeading,
                "deviceYawDeg": deviceYaw,
                "published": true,
                "sinceLocalizedS": localizedAt.map { Date().timeIntervalSince($0) } ?? NSNull(),
                "revision": localizationRevision
            ])
            pendingFrameYawRotationDegrees = 0
        }
        guard let detection else { return }
        // ⚠️ Log BEFORE consulting the cooldown, and bank the rotation when the
        // cooldown refuses. `ingest` has already re-baselined onto the corrected
        // frame, so a detection dropped here is gone for good: it will never be
        // re-detected, nothing is logged, and the route stays locked to a
        // bearing ARKit abandoned. The old `guard publish… else { return }` did
        // exactly that.
        let published = publishLocalizationCorrection(reason: "frame_yaw_shift")
        if !published {
            pendingFrameYawRotationDegrees = WorldFrameYawWatch.signedDegrees(
                pendingFrameYawRotationDegrees + detection.rotationDegrees
            )
        }
        NavigationTrace.shared.log("ar.frameYawShift", [
            "detector": detection.detector.rawValue,
            "frameRotationDeg": detection.rotationDegrees,
            "arDeltaDeg": detection.arDeltaDegrees,
            "deviceDeltaDeg": detection.deviceDeltaDegrees,
            "arHeadingDeg": arHeading,
            "deviceYawDeg": deviceYaw,
            "heldSeconds": detection.heldSeconds,
            "published": published,
            "pendingRotationDeg": pendingFrameYawRotationDegrees,
            "sinceLocalizedS": localizedAt.map { Date().timeIntervalSince($0) } ?? NSNull(),
            "revision": localizationRevision
        ])
    }

    /// Publishes one alignment correction, rate-limited. Returns false when the
    /// cooldown swallowed it, so callers can skip their trace too.
    private func publishLocalizationCorrection(reason: String) -> Bool {
        let now = Date()
        if let last = lastLocalizationCorrectionAt,
           now.timeIntervalSince(last) < localizationCorrectionCooldownSeconds {
            return false
        }
        lastLocalizationCorrectionAt = now
        localizationRevision += 1
        statusMessage = "Map alignment corrected."
        return true
    }

    private func resetWorldFrameYawWatch() {
        worldFrameYawWatch.reset()
        lastLocalizationCorrectionAt = nil
        pendingFrameYawRotationDegrees = 0
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        DispatchQueue.main.async {
            self.statusMessage = error.localizedDescription
            self.isMapping = false
            self.isRelocalizing = false
            self.isLocalized = false
            self.sessionMode = .idle
            self.closestPOI = nil
            self.poiMatchStatusText = nil
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async {
            self.statusMessage = "AR session interrupted."
            self.isLocalized = false
            self.relocalizationNormalSince = nil
            self.preLocalizationPosition = nil
            self.resetWorldFrameYawWatch()
            self.closestPOI = nil
            self.poiMatchStatusText = nil
        }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async {
            if self.sessionMode != .idle {
                self.statusMessage = "Restart the AR session to recover tracking."
            }
        }
    }
    
    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0]
    }

    /// `lightweight` strips everything ARKit does NOT need in order to match the
    /// saved feature cloud: scene mesh reconstruction, plane detection and scene
    /// depth all run per frame and compete with relocalization for the same CPU/
    /// GPU budget, which is why a large store map could sit on "pan around" for
    /// tens of seconds. A relocalizing session therefore stays lean for its
    /// whole life; only pinning a POI asks for the mapping features back, via
    /// `upgradeSessionToFullFidelity()`, because that re-run costs the map
    /// alignment.
    private func makeWorldTrackingConfiguration(
        initialWorldMap: ARWorldMap? = nil,
        lightweight: Bool = false
    ) -> ARWorldTrackingConfiguration {
        let config = ARWorldTrackingConfiguration()
        config.initialWorldMap = initialWorldMap
        // Relocalizing to a saved map must use .gravity: with .gravityAndHeading
        // ARKit keeps pulling the world yaw toward TODAY's compass reading,
        // which fights the feature-matched map frame. Indoors (metal shelving)
        // the compass is routinely 5–30° off, so the whole route graph rotates
        // around the user — start poses land on the wrong part of the route,
        // every left/right cue mirrors, and relocalization can stall entirely
        // because tracking never settles. The saved map frame is already
        // heading-aligned from capture time. (Same rule as the reaching
        // session — see Reachingviewcontroller+ar.swift startAR.)
        config.worldAlignment = initialWorldMap != nil ? .gravity : .gravityAndHeading
        config.environmentTexturing = .none
        config.isLightEstimationEnabled = false
        config.providesAudioData = false
        config.frameSemantics = []
        if lightweight {
            config.planeDetection = []
        } else {
            config.planeDetection = [.horizontal, .vertical]
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                config.frameSemantics.insert(.sceneDepth)
            }
            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                config.sceneReconstruction = .mesh
            }
        }
        applyEfficientVideoFormat(to: config)
        return config
    }

    /// Re-enables plane detection, scene depth and mesh on an already
    /// relocalized session, so a POI pinned from here lands on the object the
    /// camera is aimed at (LiDAR depth / plane raycast) instead of on the
    /// user's own standing pose.
    ///
    /// ## ⚠️ Never call this during guidance
    ///
    /// It re-runs the session, and re-running the session destroys the
    /// relocalized map alignment. Two field traces say so with the same
    /// signature — the world yaw snaps back to ARKit's own session frame within
    /// ~0.2 s of the `run()`, position untouched, so it is a pure rotation that
    /// no position check can see:
    ///
    ///   2026-07-30 cims   run() at promotion (t=18.51) → frame reverted +38° at 18.85
    ///   2026-07-30 ECSE   run() deferred to t≈7.4      → frame reverted +29° at  7.54
    ///
    /// In both the route was locked to the pre-`run()` frame and the overlay
    /// swung off through a wall — which is exactly what the user sees. The
    /// second trace also lost tracking outright (`notAvailable`, isLocalized
    /// false) 3.5 s later, with mesh and depth newly running on a loaded map.
    ///
    /// `run(config)` without reset options is documented to keep tracking
    /// state, so this is inference from timing rather than from Apple's
    /// contract — but two traces, one signature, and no other event at those
    /// instants. The upgrade buys depth-accurate pinning, which only the
    /// authoring flow needs; guidance never pins anything, so the trade is not
    /// close. Now requested explicitly by `addPOIAnchor`, never automatically
    /// after relocalizing.
    ///
    /// Runs WITHOUT reset options and pins `worldAlignment` to the relocalized
    /// session's `.gravity`, because changing alignment mid-session would move
    /// the world origin out from under the route frame.
    private func upgradeSessionToFullFidelity() {
        guard !didUpgradeSessionFidelity else { return }
        didUpgradeSessionFidelity = true
        fidelityUpgradeAt = Date()
        NavigationTrace.shared.log("ar.fidelityUpgrade", [
            "isLocalized": isLocalized,
            "isMapping": isMapping,
            "sinceLocalizedS": localizedAt.map { Date().timeIntervalSince($0) } ?? NSNull()
        ])
        let config = makeWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        session.run(config)
    }

    private func applyEfficientVideoFormat(to config: ARWorldTrackingConfiguration) {
        let thirtyFPSFormats = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter { $0.framesPerSecond <= 30 }

        guard !thirtyFPSFormats.isEmpty else {
            return
        }

        let minimumPixels: CGFloat = 1280 * 720
        let viableFormats = thirtyFPSFormats.filter { pixelCount(for: $0) >= minimumPixels }
        let formatPool = viableFormats.isEmpty ? thirtyFPSFormats : viableFormats

        guard let format = formatPool.min(by: { pixelCount(for: $0) < pixelCount(for: $1) }) else { return }
        config.videoFormat = format
    }

    private func pixelCount(for format: ARConfiguration.VideoFormat) -> CGFloat {
        format.imageResolution.width * format.imageResolution.height
    }

    private func extractPOIs(from map: ARWorldMap) -> [(name: String, position: simd_float3, anchor: ARAnchor)] {
        map.anchors.compactMap { anchor in
            guard type(of: anchor) == ARAnchor.self,
                  let name = anchor.name,
                  !name.isEmpty else {
                return nil
            }

            let position = simd_make_float3(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            return (name: name, position: position, anchor: anchor)
        }
    }

    private func deduplicatedPOIs(_ pois: [(name: String, position: simd_float3, anchor: ARAnchor)]) -> [(name: String, position: simd_float3, anchor: ARAnchor)] {
        var latestByName: [String: (position: simd_float3, anchor: ARAnchor)] = [:]
        var orderedNames: [String] = []

        for poi in pois {
            if latestByName[poi.name] == nil {
                orderedNames.append(poi.name)
            }
            latestByName[poi.name] = (poi.position, poi.anchor)
        }

        return orderedNames.compactMap { name in
            guard let poi = latestByName[name] else { return nil }
            return (name: name, position: poi.position, anchor: poi.anchor)
        }
    }

    private struct POIRecord {
        let name: String
        let position: simd_float3
        let visualFingerprints: [ARVisualFingerprint]
        let motionFingerprint: ARPOIMotionFingerprint?
        var placement: String? = nil
    }

    private struct ARIMUMotionState {
        let position: SIMD2<Double>
        let bearing: Double
        let stepCount: Int
        let isMoving: Bool
        let updatedAt: Date
        /// ARKit-independent device yaw; see `detectWorldFrameYawShift`. Not to
        /// be confused with `bearing`, which is seeded from the AR heading and
        /// therefore cannot testify about the AR frame.
        let deviceYawDegrees: Double?
    }

    private struct ARIMUMotionReference {
        let poiName: String
        let poiPosition: simd_float3
        let imuPosition: SIMD2<Double>
        let stepCount: Int
        let updatedAt: Date
    }

    private struct POIMatch {
        let name: String
        let distance: Float
        let angleDegrees: Float
        let confidence: Float
        let score: Float
        let visualConfidence: Float?

        init(
            name: String,
            distance: Float,
            angleDegrees: Float,
            confidence: Float,
            score: Float,
            visualConfidence: Float? = nil
        ) {
            self.name = name
            self.distance = distance
            self.angleDegrees = angleDegrees
            self.confidence = confidence
            self.score = score
            self.visualConfidence = visualConfidence
        }
    }

    private struct POIMatchResult {
        let match: POIMatch?
        let isAmbiguous: Bool
        let statusText: String?
        let candidates: [ARLocalizationCandidate]

        init(
            match: POIMatch?,
            isAmbiguous: Bool,
            statusText: String? = nil,
            candidates: [ARLocalizationCandidate] = []
        ) {
            self.match = match
            self.isAmbiguous = isAmbiguous
            self.statusText = statusText
            self.candidates = candidates
        }
    }

    private struct VisualPOIMatch {
        let name: String
        let confidence: Float
        let score: Float
    }

    private struct VisualPOIMatchResult {
        let match: VisualPOIMatch?
        let isAmbiguous: Bool
        let statusText: String?
    }

    private struct PoseEvidence {
        let name: String
        let confidence: Float
        let spatialConfidence: Float?
        let visualConfidence: Float?
        let distance: Float
        let angleDegrees: Float
        let position: simd_float3
    }

    private struct PoseEvidenceFrame {
        let timestamp: TimeInterval
        let candidates: [PoseEvidence]
    }

    private struct PoseBeliefCandidate {
        let evidence: PoseEvidence
        let confidence: Float
        let supportRatio: Float
        let visualSupportRatio: Float
    }

    private func replacePOIRecords(with records: [POIRecord]) {
        poiRecordsQueue.sync(flags: .barrier) {
            self.poiRecords = records
        }
    }

    private func currentPOIRecords() -> [POIRecord] {
        poiRecordsQueue.sync {
            poiRecords
        }
    }

    private func upsertPOIRecord(
        name: String,
        position: simd_float3,
        visualFingerprint: ARVisualFingerprint?,
        motionFingerprint: ARPOIMotionFingerprint?,
        preservesExistingSamples: Bool,
        placement: String? = nil
    ) {
        poiRecordsQueue.sync(flags: .barrier) {
            let existingRecord = self.poiRecords.first(where: { $0.name == name })
            let existingSamples = preservesExistingSamples
                ? existingRecord?.visualFingerprints ?? []
                : []
            var samples = existingSamples
            if let visualFingerprint {
                samples.append(visualFingerprint)
            }
            samples = Array(samples.suffix(6))
            self.poiRecords.removeAll { $0.name == name }
            self.poiRecords.append(
                POIRecord(
                    name: name,
                    position: position,
                    visualFingerprints: samples,
                    motionFingerprint: motionFingerprint ?? existingRecord?.motionFingerprint,
                    placement: placement ?? existingRecord?.placement
                )
            )
        }
    }

    private func appendVisualSample(
        name: String,
        visualFingerprint: ARVisualFingerprint,
        motionFingerprint: ARPOIMotionFingerprint?
    ) {
        poiRecordsQueue.sync(flags: .barrier) {
            guard let index = self.poiRecords.firstIndex(where: { $0.name == name }) else { return }
            var samples = self.poiRecords[index].visualFingerprints
            samples.append(visualFingerprint)
            samples = Array(samples.suffix(6))
            let existing = self.poiRecords[index]
            self.poiRecords[index] = POIRecord(
                name: existing.name,
                position: existing.position,
                visualFingerprints: samples,
                motionFingerprint: motionFingerprint ?? existing.motionFingerprint,
                placement: existing.placement
            )
        }
    }

    private func removePOIRecord(name: String) {
        poiRecordsQueue.sync(flags: .barrier) {
            self.poiRecords.removeAll { $0.name == name }
        }
    }

    private func refreshPOIInspectionList() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.refreshPOIInspectionList()
            }
            return
        }

        let records = currentPOIRecords()
        let sampleCounts = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.visualFingerprints.count) })
        let recordPositions = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0.position) })
        let names = Set(anchorsList)
            .union(mapPOIs.keys)
            .union(records.map(\.name))

        poiInspectionList = names
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                guard let position = mapPOIs[name] ?? recordPositions[name] else { return nil }
                return ARMapPOIInspection(
                    name: name,
                    position: position,
                    visualSampleCount: sampleCounts[name] ?? 0,
                    hasAnchor: poiAnchorsByName[name] != nil
                )
            }
    }

    private func sampledFeaturePoints(from pointCloud: ARPointCloud?) -> (points: [simd_float3], totalCount: Int) {
        guard let pointCloud else { return ([], 0) }

        let allPoints = Array(pointCloud.points)
        let totalCount = allPoints.count
        guard totalCount > maxInspectableFeaturePoints else {
            return (allPoints, totalCount)
        }

        let sampleStride = max(1, totalCount / maxInspectableFeaturePoints)
        var sampledPoints: [simd_float3] = []
        sampledPoints.reserveCapacity(maxInspectableFeaturePoints)

        var index = 0
        while index < totalCount && sampledPoints.count < maxInspectableFeaturePoints {
            sampledPoints.append(allPoints[index])
            index += sampleStride
        }

        return (sampledPoints, totalCount)
    }

    /// Non-nil when the candidate relocalized pose disagrees with the place the
    /// camera is visually recognizing right now. Gated on the HIGH visual
    /// confidence bar (`visualPoseRequiredConfidence`) and a deliberately
    /// generous distance so this only vetoes gross frame errors — the tens of
    /// metres kind that come from tracking in the session frame instead of the
    /// map frame — never ordinary pose noise near the right place.
    private func visualEvidenceContradiction(for cameraPosition: simd_float3) -> String? {
        visualEvidenceContradiction(for: cameraPosition, cameraForward: nil)
    }

    /// Rejects a candidate pose that disagrees with what the camera can see.
    ///
    /// Two independent disagreements, because the frame can be wrong in two
    /// ways. POSITION: the camera confidently recognizes a place the believed
    /// pose sits far away from. BEARING: the camera recognizes a place but the
    /// believed frame says that place is off to one side, when recognizing it
    /// at all means the camera is pointed at it. The bearing test is the one
    /// that catches a pure yaw error — position right, heading 100° out — which
    /// is invisible to a distance check and is precisely the failure that
    /// reaches the user as "Localized" followed by a turn into a desk.
    private func visualEvidenceContradiction(
        for cameraPosition: simd_float3,
        cameraForward: simd_float3?
    ) -> String? {
        guard let seen = lastVisualMatchResult?.match,
              seen.confidence >= visualPoseRequiredConfidence,
              let record = currentPOIRecords().first(where: { $0.name == seen.name }) else {
            return nil
        }
        let distance = simd_distance(cameraPosition, record.position)
        if distance > visualPoseContradictionDistance {
            return String(
                format: "Camera sees %@ but the map pose is %.0fm away — still matching.",
                seen.name,
                distance
            )
        }

        // Close enough to compare directions. Recognizing the place visually
        // means it is in front of the lens, so the believed frame must agree.
        guard let cameraForward,
              distance >= visualBearingMinimumDistanceMeters else {
            return nil
        }
        let toPOI = record.position - cameraPosition
        let toPOIFlat = simd_float3(toPOI.x, 0, toPOI.z)
        let forwardFlat = simd_float3(cameraForward.x, 0, cameraForward.z)
        guard simd_length(toPOIFlat) > 0.001, simd_length(forwardFlat) > 0.001 else { return nil }
        let cosine = simd_dot(simd_normalize(toPOIFlat), simd_normalize(forwardFlat))
        let offAxisDegrees = Double(acos(max(-1, min(1, cosine))) * 180 / .pi)
        guard offAxisDegrees > visualBearingContradictionDegrees else { return nil }
        return String(
            format: "Camera sees %@ but the map frame puts it %.0f° off to the side — still matching.",
            seen.name,
            offAxisDegrees
        )
    }

    /// Counts saved feature points within `poiRelocalizationRadiusMeters` of each
    /// pinned POI — the cold-start relocalizability proxy the keyframe report
    /// cannot see. Runs over the full cloud (not the render-sampled subset) for an
    /// honest count; called once per save on a background queue.
    private func poiFeatureDensity(
        pois: [(name: String, position: simd_float3)],
        cloud: ARPointCloud?
    ) -> [String: Int] {
        guard let cloud, !pois.isEmpty else { return [:] }
        let points = cloud.points
        let radiusSquared = poiRelocalizationRadiusMeters * poiRelocalizationRadiusMeters
        var counts: [String: Int] = [:]
        for poi in pois {
            var nearby = 0
            for point in points where simd_distance_squared(point, poi.position) <= radiusSquared {
                nearby += 1
            }
            counts[poi.name] = max(counts[poi.name] ?? 0, nearby)
        }
        return counts
    }

    /// "A", "A and B", "A, B, and C".
    private func listPhrase(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + ", and " + names[names.count - 1]
        }
    }

    private func currentIMUMotion() -> ARIMUMotionState? {
        imuMotionQueue.sync {
            latestIMUMotion
        }
    }

    private func currentMotionReference() -> ARIMUMotionReference? {
        imuMotionQueue.sync {
            motionReference
        }
    }

    private func resetMotionReference() {
        imuMotionQueue.async(flags: .barrier) {
            self.motionReference = nil
        }
    }

    private func currentMotionFingerprint() -> ARPOIMotionFingerprint? {
        guard let motion = currentIMUMotion() else { return nil }
        return ARPOIMotionFingerprint(
            imuX: motion.position.x,
            imuY: motion.position.y,
            bearing: motion.bearing,
            stepCount: motion.stepCount,
            createdAt: motion.updatedAt
        )
    }

    private func recordMotionReferenceIfNeeded(for match: POIMatch, records: [POIRecord]) {
        guard let motion = currentIMUMotion() else { return }
        let poiPosition = position(for: match, in: records)

        imuMotionQueue.async(flags: .barrier) {
            if self.motionReference?.poiName == match.name {
                return
            }

            self.motionReference = ARIMUMotionReference(
                poiName: match.name,
                poiPosition: poiPosition,
                imuPosition: motion.position,
                stepCount: motion.stepCount,
                updatedAt: motion.updatedAt
            )
        }
    }

    private func finalizedStableResult(_ result: POIMatchResult, records: [POIRecord]) -> POIMatchResult {
        if let match = result.match {
            recordMotionReferenceIfNeeded(for: match, records: records)
        }
        return result
    }

    private func motionCheckedResult(from result: POIMatchResult, records: [POIRecord]) -> POIMatchResult {
        guard let match = result.match,
              let motion = currentIMUMotion(),
              let reference = currentMotionReference() else {
            return result
        }

        let stepsSinceReference = motion.stepCount - reference.stepCount
        guard stepsSinceReference >= imuMotionMinimumSteps else { return result }

        let imuDelta = motion.position - reference.imuPosition
        let imuDistance = Float(simd_length(imuDelta))
        guard imuDistance >= imuMotionMinimumDistance else { return result }

        let candidatePosition = position(for: match, in: records)
        let arDelta = SIMD2<Double>(
            Double(candidatePosition.x - reference.poiPosition.x),
            Double(candidatePosition.z - reference.poiPosition.z)
        )
        let candidateDistance = Float(simd_length(arDelta))
        let tolerance = imuMotionTolerance(forDistance: imuDistance)
        let mismatch = abs(candidateDistance - imuDistance)
        let directionMismatch = motionDirectionMismatchDegrees(imuDelta: imuDelta, arDelta: arDelta)
        let directionDisagrees = directionMismatch.map { $0 > imuMotionDirectionToleranceDegrees } ?? false

        guard mismatch > tolerance || directionDisagrees else {
            let statusText = result.statusText.map { "\($0) + IMU ok" } ?? "IMU ok"
            return POIMatchResult(
                match: match,
                isAmbiguous: result.isAmbiguous,
                statusText: statusText,
                candidates: result.candidates
            )
        }

        let excess = max(0, mismatch - tolerance)
        let directionPenalty: Float
        if let directionMismatch, directionDisagrees {
            directionPenalty = min(0.24, Float((directionMismatch - imuMotionDirectionToleranceDegrees) / 90) * 0.24)
        } else {
            directionPenalty = 0
        }
        let confidencePenalty = min(0.52, excess * 0.13 + directionPenalty)
        let adjustedConfidence = max(0, match.confidence - confidencePenalty)
        let directionText = directionMismatch.map { String(format: ", %.0f° off", $0) } ?? ""
        let motionText = String(format: "IMU disagrees: walked %.1fm%@ from %@", imuDistance, directionText, reference.poiName)

        if match.visualConfidence != nil || adjustedConfidence < stableMatchMinimumConfidence {
            resetStableMatch()
            return POIMatchResult(
                match: nil,
                isAmbiguous: false,
                statusText: motionText,
                candidates: result.candidates
            )
        }

        let adjustedMatch = POIMatch(
            name: match.name,
            distance: match.distance,
            angleDegrees: match.angleDegrees,
            confidence: adjustedConfidence,
            score: 1 - adjustedConfidence,
            visualConfidence: match.visualConfidence
        )
        return POIMatchResult(
            match: adjustedMatch,
            isAmbiguous: result.isAmbiguous,
            statusText: String(format: "IMU caution %@ %.0f%%", match.name, adjustedConfidence * 100),
            candidates: result.candidates
        )
    }

    private func imuMotionTolerance(forDistance distance: Float) -> Float {
        max(1.15, min(4.0, 0.65 + distance * 0.35))
    }

    private func motionDirectionMismatchDegrees(imuDelta: SIMD2<Double>, arDelta: SIMD2<Double>) -> Double? {
        guard simd_length(imuDelta) >= Double(imuMotionDirectionMinimumDistance),
              simd_length(arDelta) >= Double(imuMotionDirectionMinimumDistance) else {
            return nil
        }

        let imuDirection = simd_normalize(imuDelta)
        let arDirection = simd_normalize(arDelta)
        let dot = max(-1, min(1, simd_dot(imuDirection, arDirection)))
        return acos(dot) * 180 / Double.pi
    }

    private func bestPOIMatch(
        cameraTransform: simd_float4x4,
        capturedImage: CVPixelBuffer,
        timestamp: TimeInterval
    ) -> POIMatchResult {
        let records = currentPOIRecords()
        guard !records.isEmpty else {
            resetStableMatch()
            poseEvidenceWindow.removeAll()
            return POIMatchResult(match: nil, isAmbiguous: false)
        }

        let spatialCandidates = spatialPOIMatches(cameraTransform: cameraTransform, records: records)
        let hasVisualSamples = records.contains { !$0.visualFingerprints.isEmpty }
        let visualCandidates = hasVisualSamples
            ? visualPOIMatches(capturedImage: capturedImage, records: records, timestamp: timestamp)
            : nil
        let evidence = poseEvidence(
            spatialCandidates: spatialCandidates,
            visualCandidates: visualCandidates ?? [],
            requiresVisualEvidence: hasVisualSamples,
            cameraTransform: cameraTransform,
            records: records
        )

        let beliefResult = temporalPoseBeliefResult(
            from: evidence,
            timestamp: timestamp,
            requiresVisualEvidence: hasVisualSamples,
            visualWasAvailable: visualCandidates != nil
        )
        let motionResult = motionCheckedResult(from: beliefResult, records: records)
        return finalizedStableResult(motionResult, records: records)
    }

    private func spatialPOIMatches(cameraTransform: simd_float4x4, records: [POIRecord]) -> [POIMatch] {
        guard !records.isEmpty else { return [] }

        let cameraPosition = simd_make_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        let cameraForward = horizontalNormalized(
            simd_make_float3(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
        )

        guard simd_length(cameraForward) > 0 else {
            return []
        }

        var candidates: [POIMatch] = []

        for poi in records {
            let offset = poi.position - cameraPosition
            let distance = simd_length(offset)

            if distance <= nearbySnapDistance {
                candidates.append(POIMatch(name: poi.name, distance: distance, angleDegrees: 0, confidence: 1, score: distance * 0.12))
                continue
            }

            let horizontalOffset = simd_make_float3(offset.x, 0, offset.z)
            let horizontalDistance = simd_length(horizontalOffset)
            guard horizontalDistance > 0.05,
                  horizontalDistance <= maxPOIRecognitionDistance,
                  abs(offset.y) <= verticalTolerance else {
                continue
            }

            let directionToPOI = horizontalOffset / horizontalDistance
            let dot = max(-1, min(1, simd_dot(cameraForward, directionToPOI)))
            let angleDegrees = acos(dot) * 180 / Float.pi
            let coneDegrees = coneLimit(forDistance: horizontalDistance)
            guard angleDegrees <= coneDegrees else { continue }

            let crossTrackError = horizontalDistance * sin(angleDegrees * Float.pi / 180)
            let lateralTolerance = lateralTolerance(forDistance: horizontalDistance)
            guard crossTrackError <= lateralTolerance else { continue }

            let angleScore = angleDegrees / coneDegrees
            let lateralScore = crossTrackError / lateralTolerance
            let distanceScore = min(horizontalDistance / maxPOIRecognitionDistance, 1)
            let score = lateralScore * 0.56 + angleScore * 0.32 + distanceScore * 0.12
            let confidence = max(0, min(1, 1 - score))
            guard confidence >= minimumPOIMatchConfidence else { continue }

            candidates.append(POIMatch(name: poi.name, distance: distance, angleDegrees: angleDegrees, confidence: confidence, score: score))
        }

        return candidates
            .sorted { $0.score < $1.score }
            .prefix(poseBeliefMaximumCandidates)
            .map { $0 }
    }

    private func bestSpatialPOIMatch(cameraTransform: simd_float4x4, records: [POIRecord]) -> POIMatchResult {
        let sortedCandidates = spatialPOIMatches(cameraTransform: cameraTransform, records: records)
        guard let bestMatch = sortedCandidates.first else {
            return POIMatchResult(match: nil, isAmbiguous: false)
        }

        if let secondMatch = sortedCandidates.dropFirst().first,
           bestMatch.distance > nearbySnapDistance,
           secondMatch.score - bestMatch.score < ambiguousScoreGap,
           simd_distance(position(for: bestMatch, in: records), position(for: secondMatch, in: records)) > nearbySnapDistance {
            return POIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: "AR ambiguous: \(bestMatch.name) / \(secondMatch.name)"
            )
        }

        return POIMatchResult(match: bestMatch, isAmbiguous: false)
    }

    private func bestVisualPOIMatch(
        capturedImage: CVPixelBuffer,
        records: [POIRecord],
        timestamp: TimeInterval
    ) -> VisualPOIMatchResult? {
        guard let candidates = visualPOIMatches(capturedImage: capturedImage, records: records, timestamp: timestamp) else {
            return nil
        }

        return visualMatchResult(from: candidates)
    }

    private func visualPOIMatches(
        capturedImage: CVPixelBuffer,
        records: [POIRecord],
        timestamp: TimeInterval
    ) -> [VisualPOIMatch]? {
        let visualRecords = records.filter { !$0.visualFingerprints.isEmpty }
        guard !visualRecords.isEmpty else { return nil }

        if timestamp - lastVisualMatchTime < visualMatchInterval {
            return lastVisualMatchCandidates
        }

        lastVisualMatchTime = timestamp

        guard let currentFingerprint = frameFingerprinter.makeFingerprint(from: capturedImage) else {
            lastVisualMatchCandidates = nil
            lastVisualMatchResult = nil
            return nil
        }

        let candidates = visualRecords.compactMap { record -> VisualPOIMatch? in
            let bestSimilarity = record.visualFingerprints
                .map { frameFingerprinter.similarity(currentFingerprint, $0) }
                .max() ?? 0
            let confidence = max(0, min(1, (bestSimilarity - 0.62) / 0.26))
            guard confidence >= visualAgreementConfidence else { return nil }
            return VisualPOIMatch(name: record.name, confidence: confidence, score: 1 - confidence)
        }
        .sorted { $0.score < $1.score }
        .prefix(poseBeliefMaximumCandidates)
        .map { $0 }

        lastVisualMatchCandidates = candidates
        lastVisualMatchResult = visualMatchResult(from: candidates)
        return candidates
    }

    private func visualMatchResult(from candidates: [VisualPOIMatch]) -> VisualPOIMatchResult {
        guard let bestMatch = candidates.first else {
            return VisualPOIMatchResult(match: nil, isAmbiguous: false, statusText: "Visual weak")
        }

        if let secondMatch = candidates.dropFirst().first,
           bestMatch.confidence - secondMatch.confidence < visualAmbiguousConfidenceGap {
            return VisualPOIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: "Visual ambiguous: \(bestMatch.name) / \(secondMatch.name)"
            )
        }

        return VisualPOIMatchResult(
            match: bestMatch,
            isAmbiguous: false,
            statusText: String(format: "Visual %.0f%%", bestMatch.confidence * 100)
        )
    }

    private func poseEvidence(
        spatialCandidates: [POIMatch],
        visualCandidates: [VisualPOIMatch],
        requiresVisualEvidence: Bool,
        cameraTransform: simd_float4x4,
        records: [POIRecord]
    ) -> [PoseEvidence] {
        let spatialByName = Dictionary(uniqueKeysWithValues: spatialCandidates.map { ($0.name, $0) })
        let visualByName = Dictionary(uniqueKeysWithValues: visualCandidates.map { ($0.name, $0) })
        let recordsByName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
        let candidateNames = Set(spatialByName.keys).union(visualByName.keys)

        let cameraPosition = simd_make_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )

        return candidateNames.compactMap { name -> PoseEvidence? in
            guard let record = recordsByName[name] else { return nil }

            let spatial = spatialByName[name]
            let visual = visualByName[name]
            let distance = spatial?.distance ?? simd_distance(cameraPosition, record.position)
            let angle = spatial?.angleDegrees ?? angleToPOI(cameraTransform: cameraTransform, poiPosition: record.position)

            let confidence: Float
            if requiresVisualEvidence {
                if let spatial, let visual {
                    confidence = min(0.99, spatial.confidence * 0.52 + visual.confidence * 0.48 + 0.06)
                } else if let visual {
                    let poseCloseness = max(0, 1 - min(distance / visualDisagreementMaxDistance, 1))
                    let closePose = visual.confidence >= visualPoseRequiredConfidence
                        && distance <= visualDisagreementMaxDistance
                    confidence = closePose
                        ? min(0.90, visual.confidence * 0.72 + poseCloseness * 0.18)
                        : min(0.64, visual.confidence * 0.66)
                } else if let spatial {
                    confidence = min(0.68, spatial.confidence * 0.72)
                } else {
                    return nil
                }
            } else if let spatial {
                confidence = spatial.confidence
            } else {
                return nil
            }

            guard confidence >= 0.50 else { return nil }
            return PoseEvidence(
                name: name,
                confidence: confidence,
                spatialConfidence: spatial?.confidence,
                visualConfidence: visual?.confidence,
                distance: distance,
                angleDegrees: angle,
                position: record.position
            )
        }
        .sorted { $0.confidence > $1.confidence }
        .prefix(poseBeliefMaximumCandidates)
        .map { $0 }
    }

    private func temporalPoseBeliefResult(
        from evidence: [PoseEvidence],
        timestamp: TimeInterval,
        requiresVisualEvidence: Bool,
        visualWasAvailable: Bool
    ) -> POIMatchResult {
        poseEvidenceWindow.append(PoseEvidenceFrame(timestamp: timestamp, candidates: evidence))
        let oldestAllowed = timestamp - poseBeliefWindowDuration
        poseEvidenceWindow.removeAll { $0.timestamp < oldestAllowed }

        let scoredCandidates = temporalPoseCandidates()
        let summaries = scoredCandidates.map { candidate in
            ARLocalizationCandidate(
                name: candidate.evidence.name,
                confidence: candidate.confidence,
                supportRatio: candidate.supportRatio,
                distance: candidate.evidence.distance,
                angleDegrees: candidate.evidence.angleDegrees,
                hasVisualEvidence: candidate.visualSupportRatio > 0,
                pose: candidate.evidence.position
            )
        }

        guard let best = scoredCandidates.first else {
            let status = requiresVisualEvidence && visualWasAvailable ? "Visual weak" : "Need visual confirmation"
            return POIMatchResult(match: nil, isAmbiguous: false, statusText: status, candidates: summaries)
        }

        let windowDuration = (poseEvidenceWindow.last?.timestamp ?? timestamp) - (poseEvidenceWindow.first?.timestamp ?? timestamp)
        guard poseEvidenceWindow.count >= stableMatchRequiredFrames,
              windowDuration >= stableMatchRequiredDuration else {
            return POIMatchResult(
                match: nil,
                isAmbiguous: false,
                statusText: "Collecting pose evidence \(poseEvidenceWindow.count)/\(stableMatchRequiredFrames)",
                candidates: summaries
            )
        }

        if let second = scoredCandidates.dropFirst().first,
           best.confidence - second.confidence < poseBeliefMinimumMargin {
            resetStableMatch()
            return POIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: String(format: "Pose ambiguous: %@ / %@ (gap %.0f%%)", best.evidence.name, second.evidence.name, (best.confidence - second.confidence) * 100),
                candidates: summaries
            )
        }

        guard best.confidence >= poseBeliefMinimumAcceptanceConfidence,
              best.supportRatio >= poseBeliefMinimumSupportRatio else {
            resetStableMatch()
            return POIMatchResult(
                match: nil,
                isAmbiguous: false,
                statusText: String(format: "Pose weak %@ %.0f%%", best.evidence.name, best.confidence * 100),
                candidates: summaries
            )
        }

        if requiresVisualEvidence, best.visualSupportRatio <= 0 {
            resetStableMatch()
            return POIMatchResult(
                match: nil,
                isAmbiguous: false,
                statusText: "Need visual confirmation for \(best.evidence.name)",
                candidates: summaries
            )
        }

        let match = POIMatch(
            name: best.evidence.name,
            distance: best.evidence.distance,
            angleDegrees: best.evidence.angleDegrees,
            confidence: best.confidence,
            score: 1 - best.confidence,
            visualConfidence: best.evidence.visualConfidence
        )

        return POIMatchResult(
            match: match,
            isAmbiguous: false,
            statusText: String(format: "Pose locked %@ %.0f%%", best.evidence.name, best.confidence * 100),
            candidates: summaries
        )
    }

    private func temporalPoseCandidates() -> [PoseBeliefCandidate] {
        guard !poseEvidenceWindow.isEmpty else { return [] }

        struct Accumulator {
            var evidence: PoseEvidence
            var confidenceSum: Float
            var supportCount: Int
            var visualSupportCount: Int
            var latestTimestamp: TimeInterval
        }

        var accumulators: [String: Accumulator] = [:]
        for frame in poseEvidenceWindow {
            for evidence in frame.candidates {
                if var accumulator = accumulators[evidence.name] {
                    accumulator.confidenceSum += evidence.confidence
                    accumulator.supportCount += 1
                    if evidence.visualConfidence != nil {
                        accumulator.visualSupportCount += 1
                    }
                    if frame.timestamp >= accumulator.latestTimestamp {
                        accumulator.evidence = evidence
                        accumulator.latestTimestamp = frame.timestamp
                    }
                    accumulators[evidence.name] = accumulator
                } else {
                    accumulators[evidence.name] = Accumulator(
                        evidence: evidence,
                        confidenceSum: evidence.confidence,
                        supportCount: 1,
                        visualSupportCount: evidence.visualConfidence == nil ? 0 : 1,
                        latestTimestamp: frame.timestamp
                    )
                }
            }
        }

        let frameCount = max(1, poseEvidenceWindow.count)
        return accumulators.values.map { accumulator in
            let supportRatio = Float(accumulator.supportCount) / Float(frameCount)
            let visualSupportRatio = Float(accumulator.visualSupportCount) / Float(max(1, accumulator.supportCount))
            let meanConfidence = accumulator.confidenceSum / Float(accumulator.supportCount)
            let confidence = min(1, meanConfidence * 0.72 + supportRatio * 0.22 + visualSupportRatio * 0.06)
            return PoseBeliefCandidate(
                evidence: accumulator.evidence,
                confidence: confidence,
                supportRatio: supportRatio,
                visualSupportRatio: visualSupportRatio
            )
        }
        .sorted { $0.confidence > $1.confidence }
        .prefix(poseBeliefMaximumCandidates)
        .map { $0 }
    }

    private func fuse(
        spatialResult: POIMatchResult,
        visualResult: VisualPOIMatchResult,
        cameraTransform: simd_float4x4,
        records: [POIRecord]
    ) -> POIMatchResult {
        if visualResult.isAmbiguous {
            return POIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: visualResult.statusText ?? "Visual ambiguous"
            )
        }

        guard let visualMatch = visualResult.match else {
            resetStableMatch()
            let visualStatus = visualResult.statusText ?? "Visual weak"
            let statusText: String
            let isAmbiguous: Bool

            if let spatialMatch = spatialResult.match {
                statusText = "\(visualStatus) for \(spatialMatch.name)"
                isAmbiguous = false
            } else if spatialResult.isAmbiguous {
                statusText = spatialResult.statusText ?? visualStatus
                isAmbiguous = true
            } else {
                statusText = visualStatus
                isAmbiguous = false
            }

            return POIMatchResult(
                match: nil,
                isAmbiguous: isAmbiguous,
                statusText: statusText
            )
        }

        if let spatialMatch = spatialResult.match {
            if spatialMatch.name == visualMatch.name {
                let fusedConfidence = min(
                    1,
                    spatialMatch.confidence * 0.58 + visualMatch.confidence * 0.42 + 0.08
                )
                let match = POIMatch(
                    name: spatialMatch.name,
                    distance: spatialMatch.distance,
                    angleDegrees: spatialMatch.angleDegrees,
                    confidence: fusedConfidence,
                    score: 1 - fusedConfidence,
                    visualConfidence: visualMatch.confidence
                )
                return POIMatchResult(
                    match: match,
                    isAmbiguous: false,
                    statusText: String(format: "AR+visual %.0f%%", fusedConfidence * 100)
                )
            }

            if let visualRecord = records.first(where: { $0.name == visualMatch.name }),
               let visualOverrideMatch = visualOverrideMatch(
                for: visualMatch,
                record: visualRecord,
                cameraTransform: cameraTransform
               ) {
                return POIMatchResult(
                    match: visualOverrideMatch,
                    isAmbiguous: false,
                    statusText: String(format: "Visual chose %@ %.0f%%", visualOverrideMatch.name, visualOverrideMatch.confidence * 100)
                )
            }

            resetStableMatch()
            return POIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: "AR/visual conflict: \(spatialMatch.name) / \(visualMatch.name)"
            )
        }

        guard let visualRecord = records.first(where: { $0.name == visualMatch.name }) else {
            return POIMatchResult(match: nil, isAmbiguous: false, statusText: visualResult.statusText)
        }

        let cameraPosition = simd_make_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let poseDistance = simd_distance(cameraPosition, visualRecord.position)

        if visualMatch.confidence >= visualPoseRequiredConfidence,
           poseDistance <= visualPoseConfirmationDistance {
            let angle = angleToPOI(cameraTransform: cameraTransform, poiPosition: visualRecord.position)
            let confidence = min(0.96, visualMatch.confidence * 0.72 + (1 - poseDistance / visualPoseConfirmationDistance) * 0.24)
            let match = POIMatch(
                name: visualMatch.name,
                distance: poseDistance,
                angleDegrees: angle,
                confidence: confidence,
                score: 1 - confidence,
                visualConfidence: visualMatch.confidence
            )
            return POIMatchResult(
                match: match,
                isAmbiguous: false,
                statusText: String(format: "Visual+pose %.0f%%", confidence * 100)
            )
        }

        if spatialResult.isAmbiguous {
            return POIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: spatialResult.statusText ?? "AR ambiguous near \(visualMatch.name)"
            )
        }

        if visualMatch.confidence >= visualAgreementConfidence {
            return POIMatchResult(
                match: nil,
                isAmbiguous: true,
                statusText: "Visual saw \(visualMatch.name), pose not aligned"
            )
        }

        return POIMatchResult(match: nil, isAmbiguous: false, statusText: visualResult.statusText)
    }

    private func stableResult(
        from result: POIMatchResult,
        timestamp: TimeInterval,
        acceptedPrefix: String,
        waitingPrefix: String
    ) -> POIMatchResult {
        guard let match = result.match else {
            resetStableMatch()
            return result
        }

        guard !result.isAmbiguous, match.confidence >= stableMatchMinimumConfidence else {
            resetStableMatch()
            return POIMatchResult(
                match: nil,
                isAmbiguous: result.isAmbiguous,
                statusText: String(format: "Evidence weak %@ %.0f%%", match.name, match.confidence * 100)
            )
        }

        if pendingStableMatchName == match.name {
            pendingStableMatchCount += 1
        } else {
            pendingStableMatchName = match.name
            pendingStableMatchCount = 1
            pendingStableMatchStartTime = timestamp
        }

        let elapsed = timestamp - pendingStableMatchStartTime
        guard pendingStableMatchCount >= stableMatchRequiredFrames,
              elapsed >= stableMatchRequiredDuration else {
            return POIMatchResult(
                match: nil,
                isAmbiguous: false,
                statusText: "\(waitingPrefix) \(match.name) \(pendingStableMatchCount)/\(stableMatchRequiredFrames)"
            )
        }

        let statusText = result.statusText
            .map { "\(acceptedPrefix) \($0)" }
            ?? String(format: "\(acceptedPrefix) %.0f%%", match.confidence * 100)
        return POIMatchResult(match: match, isAmbiguous: false, statusText: statusText)
    }

    private func resetStableMatch() {
        pendingStableMatchName = nil
        pendingStableMatchCount = 0
        pendingStableMatchStartTime = 0
    }

    private func horizontalNormalized(_ vector: simd_float3) -> simd_float3 {
        let horizontal = simd_make_float3(vector.x, 0, vector.z)
        let length = simd_length(horizontal)
        guard length > 0 else { return simd_make_float3(0, 0, 0) }
        return horizontal / length
    }

    /// A heading reading plus how it was derived. The provenance matters because
    /// the two derivations do not agree to the degree when the phone is rolled,
    /// so a switch between them looks like a real turn — and the world-frame
    /// yaw-shift detector must not read that as ARKit realigning the map.
    private struct ARHeadingReading {
        let degrees: Double
        /// True when the pitch was steep enough that the camera's UP vector,
        /// not its forward vector, supplied the horizontal reference.
        let usedTiltFallback: Bool
    }

    private func headingReading(
        for cameraForward: simd_float3,
        cameraUp: simd_float3? = nil
    ) -> ARHeadingReading? {
        // Must match SemanticRouteNavigator's route frame (y = -z): 0° is the
        // session's initial facing (-Z) and heading increases on physical
        // RIGHT turns. Using raw +z flips the handedness and mirrors every
        // geometric left/right cue.
        //
        // ⚠️ Tilt robustness. Taking the heading from the forward vector alone
        // fails as the phone pitches: looking down at the screen (or up) drives
        // the forward vector toward vertical, its horizontal component collapses
        // to noise, and `atan2` of that noise swings tens of degrees. The old
        // `> 0.001` guard let all of it through — a field trace recorded the
        // heading moving 46° → 39° → 357° → 3° while the user stood still with
        // `progress` pinned at 0.00 m, which reads to the user as the route
        // "drifting off to the left or right" seconds after it appeared
        // correctly. Past ~70° of pitch the camera's UP vector is the reliable
        // horizontal reference: looking down it points the way you face,
        // looking up it points behind you.
        // ⚠️ Hysteresis, not a single threshold. A bare `< 0.34` cutoff flaps
        // between the two references whenever the pitch hovers near it, and
        // because forward-derived and up-derived headings only coincide at zero
        // roll, each flap injects a step change into the heading. That is
        // indistinguishable from the world frame rotating, so it would both
        // mislead the user and trip the yaw-shift detector. Enter the fallback
        // below 0.30 (≈73° pitch), leave it only above 0.40 (≈66°).
        var horizontal = SIMD2<Double>(Double(cameraForward.x), -Double(cameraForward.z))
        let forwardHorizontalLength = simd_length(horizontal)
        let fallbackEnterLength = 0.30
        let fallbackExitLength = 0.40
        let wantsFallback = usingTiltFallbackHeading
            ? forwardHorizontalLength < fallbackExitLength
            : forwardHorizontalLength < fallbackEnterLength
        var usedTiltFallback = false
        if wantsFallback, let cameraUp {
            let upHorizontal = SIMD2<Double>(Double(cameraUp.x), -Double(cameraUp.z))
            if simd_length(upHorizontal) > 0.34 {
                horizontal = cameraForward.y < 0 ? upHorizontal : -upHorizontal
                usedTiltFallback = true
            }
        }
        usingTiltFallbackHeading = usedTiltFallback
        // Still degenerate (phone flat on a table): no trustworthy heading.
        guard simd_length(horizontal) > 0.2 else { return nil }
        return ARHeadingReading(
            degrees: normalizedDegrees(atan2(horizontal.x, horizontal.y) * 180 / Double.pi),
            usedTiltFallback: usedTiltFallback
        )
    }

    private func normalizedDegrees(_ degrees: Double) -> Double {
        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized < 0 { normalized += 360 }
        return normalized
    }

    private func coneLimit(forDistance distance: Float) -> Float {
        max(8, min(32, 36 - distance * 1.35))
    }

    private func lateralTolerance(forDistance distance: Float) -> Float {
        max(0.45, min(1.65, 0.28 + distance * 0.09))
    }

    private func position(for match: POIMatch, in records: [POIRecord]) -> simd_float3 {
        records.first(where: { $0.name == match.name })?.position ?? simd_make_float3(0, 0, 0)
    }

    private func visualOverrideMatch(
        for visualMatch: VisualPOIMatch,
        record: POIRecord,
        cameraTransform: simd_float4x4
    ) -> POIMatch? {
        let cameraPosition = simd_make_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let poseDistance = simd_distance(cameraPosition, record.position)
        let closePoseMatch = visualMatch.confidence >= visualPoseRequiredConfidence
            && poseDistance <= visualPoseConfirmationDistance
        let strongVisualOverride = visualMatch.confidence >= visualOverrideConfidence
            && poseDistance <= visualDisagreementMaxDistance

        guard closePoseMatch || strongVisualOverride else { return nil }

        let distanceLimit = closePoseMatch ? visualPoseConfirmationDistance : visualDisagreementMaxDistance
        let poseCloseness = max(0, 1 - min(poseDistance / distanceLimit, 1))
        let confidence = min(0.97, visualMatch.confidence * 0.78 + poseCloseness * 0.18)

        return POIMatch(
            name: visualMatch.name,
            distance: poseDistance,
            angleDegrees: angleToPOI(cameraTransform: cameraTransform, poiPosition: record.position),
            confidence: confidence,
            score: 1 - confidence,
            visualConfidence: visualMatch.confidence
        )
    }

    private func angleToPOI(cameraTransform: simd_float4x4, poiPosition: simd_float3) -> Float {
        let cameraPosition = simd_make_float3(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let cameraForward = horizontalNormalized(
            simd_make_float3(
                -cameraTransform.columns.2.x,
                -cameraTransform.columns.2.y,
                -cameraTransform.columns.2.z
            )
        )
        let offset = poiPosition - cameraPosition
        let horizontalOffset = simd_make_float3(offset.x, 0, offset.z)
        let horizontalDistance = simd_length(horizontalOffset)
        guard horizontalDistance > 0.05, simd_length(cameraForward) > 0 else { return 0 }

        let directionToPOI = horizontalOffset / horizontalDistance
        let dot = max(-1, min(1, simd_dot(cameraForward, directionToPOI)))
        return acos(dot) * 180 / Float.pi
    }

    private func normalizedMapName(_ requestedName: String?, fallback: String?) -> String {
        let trimmed = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
        if let fallback, !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fallback
        }
        return suggestedMapName()
    }
}

struct ARMapPOIInspection: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let position: simd_float3
    let visualSampleCount: Int
    let hasAnchor: Bool
}

struct ARLocalizationCandidate: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let confidence: Float
    let supportRatio: Float
    let distance: Float
    let angleDegrees: Float
    let hasVisualEvidence: Bool
    let pose: simd_float3
}

struct ARStoredMapSummary: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var poiCount: Int
}

struct ARCodableVector3: Codable, Equatable {
    var x: Float
    var y: Float
    var z: Float

    init(_ vector: simd_float3) {
        x = vector.x
        y = vector.y
        z = vector.z
    }

    var simdValue: simd_float3 {
        simd_make_float3(x, y, z)
    }
}

struct ARVisualFingerprint: Codable, Equatable {
    let dimension: Int
    let luma: [Float]
    let colorMean: [Float]
    let averageHash: UInt64
    let featurePrintData: Data?
    let createdAt: Date?
}

struct ARPOIMotionFingerprint: Codable, Equatable {
    let imuX: Double
    let imuY: Double
    let bearing: Double
    let stepCount: Int
    let createdAt: Date?
}

struct ARStoredPOI: Codable, Equatable {
    var name: String
    var position: ARCodableVector3
    var visualFingerprint: ARVisualFingerprint? = nil
    var visualFingerprints: [ARVisualFingerprint]? = nil
    var motionFingerprint: ARPOIMotionFingerprint? = nil
    /// ARMappingManager.POIPlacement raw value. nil = legacy camera-pose pin.
    var placement: String? = nil

    var isSurfacePlacement: Bool {
        guard let placement else { return false }
        return placement != ARMappingManager.POIPlacement.cameraPose.rawValue
    }

    var allVisualFingerprints: [ARVisualFingerprint] {
        if let visualFingerprints, !visualFingerprints.isEmpty {
            return visualFingerprints
        }
        return visualFingerprint.map { [$0] } ?? []
    }
}

struct ARStoredMapMetadata: Codable, Equatable {
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var worldMapFileName: String
    var pois: [ARStoredPOI]
}

final class ARMapStore {
    private static let legacyMapID = "legacy-building-map"
    private let fileManager = FileManager.default
    private let metadataExtension = "json"
    private let worldMapExtension = "arexperience"

    func loadSummaries() -> [ARStoredMapSummary] {
        var summaries: [ARStoredMapSummary] = []

        if let directory = try? mapsDirectory() {
            let metadataURLs = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []

            summaries = metadataURLs
                .filter { $0.pathExtension == metadataExtension }
                .compactMap { url in
                    guard let metadata = try? loadMetadata(from: url) else { return nil }
                    return ARStoredMapSummary(
                        id: metadata.id,
                        name: metadata.name,
                        createdAt: metadata.createdAt,
                        updatedAt: metadata.updatedAt,
                        poiCount: metadata.pois.count
                    )
                }
        }

        if fileManager.fileExists(atPath: legacyWorldMapURL.path),
           summaries.contains(where: { $0.id == Self.legacyMapID }) == false {
            let dates = fileDates(for: legacyWorldMapURL)
            summaries.append(
                ARStoredMapSummary(
                    id: Self.legacyMapID,
                    name: "Building Map",
                    createdAt: dates.createdAt,
                    updatedAt: dates.updatedAt,
                    poiCount: legacyPOICount()
                )
            )
        }

        return summaries.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(
        worldMap: ARWorldMap,
        name: String,
        replacing existingMetadata: ARStoredMapMetadata?,
        pois: [ARStoredPOI]
    ) throws -> ARStoredMapMetadata {
        let directory = try mapsDirectory()
        let canReplace = existingMetadata?.id != Self.legacyMapID
        let id = canReplace ? (existingMetadata?.id ?? UUID().uuidString) : UUID().uuidString
        let createdAt = canReplace ? (existingMetadata?.createdAt ?? Date()) : Date()
        let fileName = canReplace ? (existingMetadata?.worldMapFileName ?? "\(id).\(worldMapExtension)") : "\(id).\(worldMapExtension)"
        let mapURL = directory.appendingPathComponent(fileName)
        let metadataURL = directory.appendingPathComponent("\(id).\(metadataExtension)")

        let mapData = try NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true)
        try mapData.write(to: mapURL, options: .atomic)

        let metadata = ARStoredMapMetadata(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: Date(),
            worldMapFileName: fileName,
            pois: pois.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        )

        let metadataData = try JSONEncoder.arMapEncoder.encode(metadata)
        try metadataData.write(to: metadataURL, options: .atomic)
        return metadata
    }

    func load(id: String) throws -> (worldMap: ARWorldMap, metadata: ARStoredMapMetadata) {
        if id == Self.legacyMapID {
            let worldMap = try loadWorldMap(from: legacyWorldMapURL)
            let dates = fileDates(for: legacyWorldMapURL)
            let pois = pois(from: worldMap).map { poi in
                ARStoredPOI(name: poi.name, position: ARCodableVector3(poi.position), visualFingerprint: nil)
            }
            let metadata = ARStoredMapMetadata(
                id: Self.legacyMapID,
                name: "Building Map",
                createdAt: dates.createdAt,
                updatedAt: dates.updatedAt,
                worldMapFileName: legacyWorldMapURL.lastPathComponent,
                pois: pois
            )
            return (worldMap, metadata)
        }

        let directory = try mapsDirectory()
        let metadataURL = directory.appendingPathComponent("\(id).\(metadataExtension)")
        let metadata = try loadMetadata(from: metadataURL)
        let worldMap = try loadWorldMap(from: directory.appendingPathComponent(metadata.worldMapFileName))
        return (worldMap, metadata)
    }

    func delete(id: String) throws {
        if id == Self.legacyMapID {
            if fileManager.fileExists(atPath: legacyWorldMapURL.path) {
                try fileManager.removeItem(at: legacyWorldMapURL)
            }
            return
        }

        let directory = try mapsDirectory()
        let metadataURL = directory.appendingPathComponent("\(id).\(metadataExtension)")

        if let metadata = try? loadMetadata(from: metadataURL) {
            let mapURL = directory.appendingPathComponent(metadata.worldMapFileName)
            if fileManager.fileExists(atPath: mapURL.path) {
                try fileManager.removeItem(at: mapURL)
            }
        }

        if fileManager.fileExists(atPath: metadataURL.path) {
            try fileManager.removeItem(at: metadataURL)
        }
    }

    func worldMapURL(for metadata: ARStoredMapMetadata) -> URL {
        if metadata.id == Self.legacyMapID {
            return legacyWorldMapURL
        }
        return (try? mapsDirectory())?.appendingPathComponent(metadata.worldMapFileName)
            ?? documentsDirectory.appendingPathComponent(metadata.worldMapFileName)
    }

    private func mapsDirectory() throws -> URL {
        let directory = documentsDirectory.appendingPathComponent("ARMaps", isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) == false {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private var documentsDirectory: URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var legacyWorldMapURL: URL {
        documentsDirectory.appendingPathComponent("BuildingMap.arexperience")
    }

    private func loadMetadata(from url: URL) throws -> ARStoredMapMetadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder.arMapDecoder.decode(ARStoredMapMetadata.self, from: data)
    }

    private func loadWorldMap(from url: URL) throws -> ARWorldMap {
        let data = try Data(contentsOf: url)
        guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return worldMap
    }

    private func legacyPOICount() -> Int {
        guard let worldMap = try? loadWorldMap(from: legacyWorldMapURL) else { return 0 }
        return pois(from: worldMap).count
    }

    private func pois(from worldMap: ARWorldMap) -> [(name: String, position: simd_float3)] {
        worldMap.anchors.compactMap { anchor in
            guard type(of: anchor) == ARAnchor.self,
                  let name = anchor.name,
                  !name.isEmpty else {
                return nil
            }

            let position = simd_make_float3(
                anchor.transform.columns.3.x,
                anchor.transform.columns.3.y,
                anchor.transform.columns.3.z
            )
            return (name: name, position: position)
        }
    }

    private func fileDates(for url: URL) -> (createdAt: Date, updatedAt: Date) {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        let createdAt = attributes?[.creationDate] as? Date
        let updatedAt = attributes?[.modificationDate] as? Date
        let fallback = updatedAt ?? createdAt ?? Date()
        return (createdAt ?? fallback, updatedAt ?? fallback)
    }
}

final class ARFrameFingerprinter {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let dimension = 16
    private let hashDimension = 8

    func makeFingerprint(from pixelBuffer: CVPixelBuffer) -> ARVisualFingerprint? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        let cropSide = min(extent.width, extent.height) * 0.82
        let cropRect = CGRect(
            x: extent.midX - cropSide / 2,
            y: extent.midY - cropSide / 2,
            width: cropSide,
            height: cropSide
        ).integral

        let normalized = image
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        let scale = CGFloat(dimension) / cropSide
        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let bounds = CGRect(x: 0, y: 0, width: dimension, height: dimension)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let rowBytes = dimension * 4
        var pixels = [UInt8](repeating: 0, count: dimension * dimension * 4)

        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            context.render(
                scaled,
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
        }

        var luma: [Float] = []
        luma.reserveCapacity(dimension * dimension)
        var colorMean = [Float](repeating: 0, count: 3)

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Float(pixels[index]) / 255
            let g = Float(pixels[index + 1]) / 255
            let b = Float(pixels[index + 2]) / 255
            luma.append(0.299 * r + 0.587 * g + 0.114 * b)
            colorMean[0] += r
            colorMean[1] += g
            colorMean[2] += b
        }

        let pixelCount = Float(dimension * dimension)
        colorMean = colorMean.map { $0 / pixelCount }

        return ARVisualFingerprint(
            dimension: dimension,
            luma: luma,
            colorMean: colorMean,
            averageHash: averageHash(from: luma),
            featurePrintData: makeFeaturePrintData(from: normalized, cropSide: cropSide),
            createdAt: Date()
        )
    }

    func similarity(_ lhs: ARVisualFingerprint, _ rhs: ARVisualFingerprint) -> Float {
        similarity(
            lhs, rhs,
            lhsObservation: featurePrintObservation(from: lhs.featurePrintData),
            rhsObservation: featurePrintObservation(from: rhs.featurePrintData)
        )
    }

    /// Variant that accepts pre-unarchived feature prints so O(n²) sweeps
    /// (alias-group detection) don't unarchive each print once per pair.
    func similarity(
        _ lhs: ARVisualFingerprint,
        _ rhs: ARVisualFingerprint,
        lhsObservation: VNFeaturePrintObservation?,
        rhsObservation: VNFeaturePrintObservation?
    ) -> Float {
        guard lhs.dimension == rhs.dimension,
              lhs.luma.count == rhs.luma.count,
              lhs.colorMean.count == rhs.colorMean.count else {
            return 0
        }

        let lumaScore = normalizedCorrelation(lhs.luma, rhs.luma)
        let hashScore = averageHashSimilarity(lhs.averageHash, rhs.averageHash)
        let colorScore = colorSimilarity(lhs.colorMean, rhs.colorMean)
        let fallbackScore = max(0, min(1, lumaScore * 0.64 + hashScore * 0.24 + colorScore * 0.12))

        guard let featureScore = featurePrintSimilarity(lhsObservation, rhsObservation) else {
            return fallbackScore
        }

        return max(0, min(1, featureScore * 0.82 + fallbackScore * 0.18))
    }

    func featurePrintObservation(for fingerprint: ARVisualFingerprint) -> VNFeaturePrintObservation? {
        featurePrintObservation(from: fingerprint.featurePrintData)
    }

    private func makeFeaturePrintData(from image: CIImage, cropSide: CGFloat) -> Data? {
        let bounds = CGRect(x: 0, y: 0, width: cropSide, height: cropSide)
        guard let cgImage = context.createCGImage(image, from: bounds) else { return nil }

        let request = VNGenerateImageFeaturePrintRequest()
        // Pin revision 1: on iOS 17+ the request silently defaults to revision 2,
        // whose distances are ~20x smaller than revision 1. Every downstream
        // similarity constant (exp(-d/13), alias threshold 0.82) is calibrated
        // for revision 1 — unpinned, nearly every frame pair scores "similar",
        // aliasing floods, and map saving is permanently blocked.
        request.revision = VNGenerateImageFeaturePrintRequestRevision1
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
            return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
        } catch {
            return nil
        }
    }

    private func featurePrintSimilarity(
        _ lhsObservation: VNFeaturePrintObservation?,
        _ rhsObservation: VNFeaturePrintObservation?
    ) -> Float? {
        guard let lhsObservation, let rhsObservation else {
            return nil
        }

        var distance: Float = 0
        do {
            try lhsObservation.computeDistance(&distance, to: rhsObservation)
            // Distance scale differs per feature-print revision. New prints are
            // pinned to revision 1 (2048 elements, distances ~0–40). Prints
            // stored before pinning may be revision 2 (768 elements, distances
            // ~0–1.5); comparing across revisions throws and falls back below.
            let isRevision2Pair = lhsObservation.elementCount == 768 && rhsObservation.elementCount == 768
            let scale = isRevision2Pair ? 0.5 : 13.0
            let score = Foundation.exp(-Double(distance) / scale)
            return Float(max(0, min(1, score)))
        } catch {
            return nil
        }
    }

    private func featurePrintObservation(from data: Data?) -> VNFeaturePrintObservation? {
        guard let data else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    private func normalizedCorrelation(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }

        let count = Float(lhs.count)
        let meanL = lhs.reduce(0, +) / count
        let meanR = rhs.reduce(0, +) / count

        var numerator: Float = 0
        var varianceL: Float = 0
        var varianceR: Float = 0

        for index in lhs.indices {
            let left = lhs[index] - meanL
            let right = rhs[index] - meanR
            numerator += left * right
            varianceL += left * left
            varianceR += right * right
        }

        let denominator = sqrt(varianceL * varianceR)
        guard denominator > 0.0001 else { return 0 }
        let correlation = max(-1, min(1, numerator / denominator))
        return (correlation + 1) / 2
    }

    private func averageHash(from luma: [Float]) -> UInt64 {
        guard luma.count == dimension * dimension else { return 0 }

        let blockSize = dimension / hashDimension
        var cells: [Float] = []
        cells.reserveCapacity(hashDimension * hashDimension)

        for y in 0..<hashDimension {
            for x in 0..<hashDimension {
                var sum: Float = 0
                for blockY in 0..<blockSize {
                    for blockX in 0..<blockSize {
                        let sourceX = x * blockSize + blockX
                        let sourceY = y * blockSize + blockY
                        sum += luma[sourceY * dimension + sourceX]
                    }
                }
                cells.append(sum / Float(blockSize * blockSize))
            }
        }

        let mean = cells.reduce(0, +) / Float(cells.count)
        var hash: UInt64 = 0
        for (index, value) in cells.enumerated() where value >= mean {
            hash |= UInt64(1) << UInt64(index)
        }
        return hash
    }

    private func averageHashSimilarity(_ lhs: UInt64, _ rhs: UInt64) -> Float {
        let difference = (lhs ^ rhs).nonzeroBitCount
        return 1 - Float(difference) / 64
    }

    private func colorSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        let averageDelta = zip(lhs, rhs).map { abs($0 - $1) }.reduce(0, +) / Float(lhs.count)
        return max(0, 1 - averageDelta * 1.8)
    }
}

/// Decides whether ARKit has re-oriented the world frame under a pose already
/// handed to guidance — the failure no position check can see.
///
/// ## The failure this exists for
///
/// A journey usually starts at the route's first node, which is where the mapping
/// walk started, which is where the saved map's ORIGIN is. Until relocalization
/// lands, ARKit tracks in its own `.gravity` frame whose origin is where THIS
/// session started — the same spot. So the pose reads as sitting exactly on the
/// first node (the 2026-07-29 IGA trace snapped it to the right edge at 0.25 m
/// cross-track) while the yaw is arbitrary. When ARKit then aligns for real, the
/// correction is a pure ROTATION about a point the user is standing on: position
/// barely moves, so a distance check sees nothing, `localizationRevision` never
/// bumps, and the route stays locked to a bearing ARKit has abandoned. That is
/// what reaches the user as the route running off behind them.
///
/// ## Separating "the user turned" from "the frame turned"
///
/// `IMUState.deviceYawDegrees` comes from `CMDeviceMotion.attitude` under
/// `.xArbitraryZVertical`: gravity-referenced, pitch-immune, and — decisively —
/// never seeded from ARKit. Over any window,
///
///     Δ(AR yaw) − Δ(device yaw) ≈ rotation of the AR world FRAME
///
/// because whatever the user did with the phone appears in both terms and
/// cancels. A user spinning 180° moves both by 180° and reads as zero; a
/// stationary user whose AR heading walks 140° reads as 140°.
///
/// ⚠️ This is the mechanism commit c718e3f deleted. That commit was right that
/// comparing `arHeading` against `IMUState.bearing` cannot do COMPASS
/// corroboration (there is no magnetometer anywhere in this app, and `bearing`
/// is gyro-integrated from a seed taken off the AR heading), and right to remove
/// it from the promotion gate. But the differential signal it was accidentally
/// computing was real, and deleting it left nothing at all watching the frame.
/// This restores the signal on a genuinely independent reference and uses it for
/// what it can prove: rotation, not absolute direction.
///
/// Extracted from `ARMappingManager` as a pure value type so the scenarios that
/// matter — the IGA failure, the same failure while the user pans, an ordinary
/// turn, an inverted sign convention, a tilt-reference switch — are covered by
/// tests rather than by a trip to a grocery store.
struct WorldFrameYawWatch {
    enum Detector: String {
        /// The device was held still while the AR yaw stepped. Sign-independent.
        case stillDevice = "still_device"
        /// Cumulative divergence since the accepted alignment. Needs the sign
        /// convention established first.
        case cumulative
    }

    /// Whether the AR heading and the device yaw increase in the same direction.
    /// Measured, never assumed — see `voteOnSignConvention`.
    enum SignConvention { case unknown, subtract, add }

    struct Detection {
        let detector: Detector
        let rotationDegrees: Double
        let arDeltaDegrees: Double
        let deviceDeltaDegrees: Double
        let heldSeconds: TimeInterval
    }

    // ── Tunables ────────────────────────────────────────────────────────────
    /// How far the AR yaw must move, against a still device, to count.
    /// Comfortably above what `CMDeviceMotion.attitude` drifts over the hold
    /// window and far below the errors seen in the field (IGA: ~140°).
    var shiftDegrees = 12.0
    /// How much the DEVICE may have turned across the window and still count as
    /// held still. Above this the window proves nothing either way and is simply
    /// not acted on; the next quiet moment catches the same shift.
    var stillnessDegrees = 8.0
    /// A shift must persist this long. One frame of disagreement is noise.
    var holdSeconds: TimeInterval = 0.6
    /// Span of the rolling history — long enough to bracket a step change
    /// against a pre-jump reading, short enough that a deliberate turn cannot
    /// fit inside it under the stillness cap.
    var windowSeconds: TimeInterval = 1.6
    /// Bar for the cumulative detector, higher than the still-device one because
    /// it accumulates over the whole journey and so must clear the yaw drift
    /// `CMDeviceMotion.attitude` picks up over minutes without a magnetometer.
    var cumulativeDegrees = 25.0
    /// A turn must be at least this big to vote on the sign convention.
    var signVoteDegrees = 20.0
    var signVotesRequired = 3

    // ── State ───────────────────────────────────────────────────────────────
    private var samples: [(at: Date, arHeading: Double, deviceYaw: Double, usedTiltFallback: Bool)] = []
    /// The AR↔device yaw offset at the alignment guidance was actually built
    /// on. Set ONLY by `acceptAlignment`.
    ///
    /// ⚠️ It used to be auto-seeded by `ingest` whenever it was nil, and that
    /// single line is why the 2026-07-30 cims trace reported "peak drift 4.4°"
    /// for a 38° rotation: a tracking blip cleared the baseline, the next
    /// sample — taken AFTER the frame had already turned — became the new one,
    /// and every drift reading from then on was measured from the wrong frame.
    /// A missing baseline must read as "unknown", never as "no drift".
    private var acceptedReference: (arHeading: Double, deviceYaw: Double)?
    private(set) var signConvention: SignConvention = .unknown
    private(set) var signVotes = 0

    /// Wipes everything, including the measured sign convention. For a new AR
    /// session: the convention is really a property of the OS and device, but
    /// re-measuring costs nothing and stops one bad session poisoning the next.
    mutating func reset() {
        samples.removeAll()
        acceptedReference = nil
        signConvention = .unknown
        signVotes = 0
    }

    /// Drops the rolling window but keeps the alignment baseline and the
    /// measured convention. For a gap in readings, where consecutive samples
    /// would otherwise be differenced across the gap.
    mutating func clearWindow() {
        samples.removeAll()
    }

    /// Anchors the cumulative detector: everything after this is measured
    /// against the frame guidance was actually built on.
    ///
    /// ⚠️ Deliberately does NOT drop the rolling window. Clearing it here made
    /// the first 0.6 s after promotion — the likeliest moment for ARKit to
    /// finish realigning, and the moment guidance has just locked the route —
    /// the one interval the still-device detector structurally could not see:
    /// its hold needs a sample older than the jump, and that sample had just
    /// been deleted. The cims trace's 38° shift landed 0.34 s after promotion
    /// and went unreported for exactly that reason. Pre-promotion samples are
    /// honest observations of the same frame; keeping them is what lets the
    /// detector bracket a jump that straddles the promotion.
    mutating func acceptAlignment(arHeading: Double?, deviceYaw: Double?) {
        if let arHeading, let deviceYaw {
            acceptedReference = (arHeading: arHeading, deviceYaw: deviceYaw)
        } else {
            acceptedReference = nil
        }
    }

    /// How far the frame has rotated since the accepted alignment. Diagnostic
    /// only — nothing acts on it, so a wrong sign convention here is visible in
    /// the trace rather than harmful. Nil until an alignment has been accepted.
    func frameYawDrift(arHeading: Double, deviceYaw: Double) -> Double? {
        guard let acceptedReference else { return nil }
        let arDrift = Self.signedDegrees(arHeading - acceptedReference.arHeading)
        let deviceDrift = Self.signedDegrees(deviceYaw - acceptedReference.deviceYaw)
        return Self.signedDegrees(arDrift - deviceDrift)
    }

    /// Peak-to-peak movement of the AR↔device yaw offset across the rolling
    /// window — i.e. how much the world FRAME has been turning under the user,
    /// with everything the user did with the phone cancelled out. Nil until the
    /// window spans `minimumSeconds`, so "not enough evidence" is distinct from
    /// "settled".
    ///
    /// This is what the relocalization promotion gate was missing. A frame
    /// rotating about a standing user moves the position by ~0 m, so the
    /// position-jump veto reports a perfectly settled pose while the only
    /// quantity every bearing depends on is still swinging.
    func offsetSpreadDegrees(minimumSeconds: TimeInterval) -> Double? {
        guard let oldest = samples.first,
              let newest = samples.last,
              newest.at.timeIntervalSince(oldest.at) >= minimumSeconds else {
            return nil
        }
        // Measured as signed deltas from the first offset rather than on the
        // raw values, so a window straddling 0°/360° does not read as a 360°
        // swing.
        let datum = Self.signedDegrees(oldest.arHeading - oldest.deviceYaw)
        let deltas = samples.map {
            Self.signedDegrees(Self.signedDegrees($0.arHeading - $0.deviceYaw) - datum)
        }
        guard let low = deltas.min(), let high = deltas.max() else { return nil }
        return high - low
    }

    /// - Parameter acting: when false the sample is recorded and the sign
    ///   convention still votes on it, but no detection is returned. Used while
    ///   relocalization is still in progress: there is no accepted alignment to
    ///   correct yet, but the pan the user is doing right then is the best
    ///   sign-convention material in the whole session — and gating ingestion
    ///   on `isLocalized` is why `signConvention` never left `.unknown` in the
    ///   field, which left the cumulative detector permanently disabled.
    @discardableResult
    mutating func ingest(
        at now: Date,
        arHeading: Double,
        deviceYaw: Double,
        usedTiltFallback: Bool,
        acting: Bool = true
    ) -> Detection? {
        // The forward-vector and up-vector heading derivations do not agree
        // under roll, so a switch between them is a step change that is NOT the
        // frame moving. Drop the history rather than read the switch as one.
        if let last = samples.last, last.usedTiltFallback != usedTiltFallback {
            samples.removeAll()
        }
        samples.append((at: now, arHeading: arHeading, deviceYaw: deviceYaw, usedTiltFallback: usedTiltFallback))
        samples.removeAll { $0.at < now.addingTimeInterval(-windowSeconds) }

        guard let oldest = samples.first,
              now.timeIntervalSince(oldest.at) >= holdSeconds else {
            return nil
        }
        let arStep = Self.signedDegrees(arHeading - oldest.arHeading)
        let deviceStep = Self.signedDegrees(deviceYaw - oldest.deviceYaw)
        let heldSeconds = now.timeIntervalSince(oldest.at)
        voteOnSignConvention(arStep: arStep, deviceStep: deviceStep)
        guard acting else { return nil }

        // ── Detector 1: still device, moving AR yaw ─────────────────────────
        // The device term enters only as a magnitude, so this cannot be broken
        // by getting the rotational sense backwards. It is also the exact
        // signature of the observed failure.
        if abs(deviceStep) <= stillnessDegrees, abs(arStep) > shiftDegrees {
            return accept(
                detector: .stillDevice,
                rotation: Self.signedDegrees(arStep - deviceStep),
                arDelta: arStep,
                deviceDelta: deviceStep,
                heldSeconds: heldSeconds,
                arHeading: arHeading,
                deviceYaw: deviceYaw
            )
        }

        // ── Detector 2: cumulative, since the accepted alignment ────────────
        // Detector 1 only fires if a quiet window happens to bracket the jump,
        // and often none does: the moment the frame rotates, guidance starts
        // telling the user to turn, they pan, and every window from then on has
        // both readings already past the step. The IGA session did exactly this
        // — "Turn sharp left" at t=4.21, then 81 cues deferred as
        // `heading_sweeping`. The cumulative difference does not care when the
        // rotation happened, so it closes that gap.
        guard signConvention == .subtract,
              let cumulative = frameYawDrift(arHeading: arHeading, deviceYaw: deviceYaw),
              abs(cumulative) > cumulativeDegrees,
              let acceptedReference else {
            return nil
        }
        return accept(
            detector: .cumulative,
            rotation: cumulative,
            arDelta: Self.signedDegrees(arHeading - acceptedReference.arHeading),
            deviceDelta: Self.signedDegrees(deviceYaw - acceptedReference.deviceYaw),
            heldSeconds: heldSeconds,
            arHeading: arHeading,
            deviceYaw: deviceYaw
        )
    }

    /// Re-baselines onto the corrected frame before returning, so one rotation
    /// is never reported twice.
    private mutating func accept(
        detector: Detector,
        rotation: Double,
        arDelta: Double,
        deviceDelta: Double,
        heldSeconds: TimeInterval,
        arHeading: Double,
        deviceYaw: Double
    ) -> Detection {
        samples.removeAll()
        acceptedReference = (arHeading: arHeading, deviceYaw: deviceYaw)
        return Detection(
            detector: detector,
            rotationDegrees: rotation,
            arDeltaDegrees: arDelta,
            deviceDeltaDegrees: deviceDelta,
            heldSeconds: heldSeconds
        )
    }

    /// Establishes from measurement whether the AR heading and the device yaw
    /// increase in the same direction, so the cumulative detector can subtract
    /// them without depending on a hand-reasoned sign.
    ///
    /// While the frame is stable, a window in which the user genuinely turned
    /// has `arStep ≈ deviceStep` if the conventions agree and `arStep ≈ −deviceStep`
    /// if they are opposed. Which pairing cancels is therefore a direct read of
    /// the convention.
    ///
    /// If the votes come back `.add`, the negation in
    /// `IMUSensorManager.processAttitude` is wrong for this OS/device: the
    /// cumulative detector stays disabled and the trace says so — rather than
    /// the subtraction silently becoming an addition, doubling every turn the
    /// user makes and re-resolving the route on each one. A silent sign error
    /// producing constant false corrections would be a worse failure than the
    /// one being fixed, which is why this is measured and not reasoned.
    private mutating func voteOnSignConvention(arStep: Double, deviceStep: Double) {
        guard signConvention == .unknown, abs(deviceStep) >= signVoteDegrees else { return }
        let subtracted = abs(Self.signedDegrees(arStep - deviceStep))
        let added = abs(Self.signedDegrees(arStep + deviceStep))
        // A window where neither pairing cancels is one where the frame was
        // itself moving; it says nothing about the convention.
        guard min(subtracted, added) <= stillnessDegrees else { return }
        signVotes += subtracted < added ? 1 : -1
        guard abs(signVotes) >= signVotesRequired else { return }
        signConvention = signVotes > 0 ? .subtract : .add
    }

    /// Wraps a degree difference into (-180, 180].
    static func signedDegrees(_ degrees: Double) -> Double {
        var delta = degrees.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Live session handoff holder
// ═══════════════════════════════════════════════════════════════════════════

/// Carries a live, relocalized ARSession across the gap between navigation
/// ending and reaching starting.
///
/// The native (route-manager) arrival hands the session straight to
/// `ReachingModule.launchSpatialTargetReaching`. The automated arrival cannot:
/// it resolves to JS, JS speaks the "switching to reaching" line, and only
/// then calls back down through the bridge — several seconds later, with the
/// navigation screen already dismissed. This holder keeps the session alive
/// (and, crucially, unpaused) across that gap, then hands it to whichever
/// reaching launch shows up first.
///
/// If nobody claims it, the session is paused and released, so a dropped
/// handoff can never leave the camera running behind the user's back.
final class ARLiveSessionHandoff: @unchecked Sendable {
    static let shared = ARLiveSessionHandoff()

    private let lock = NSLock()
    private var heldSession: ARSession?
    private var heldMapID: String?
    private var expiry: DispatchWorkItem?
    /// Which map each session currently out on loan belongs to.
    ///
    /// Whoever finishes with a borrowed session has to say which map it is for
    /// when offering it back, and the reaching screen has no reason to carry a
    /// map *id* through its own call chain (it only knows the name). Recording
    /// it at loan time lets `offerBack` supply it instead.
    private var loanedMapIDs: [ObjectIdentifier: String] = [:]

    /// Long enough for the JS round trip (arrival → announcement → bridge call
    /// → up to 3.6 s of modal-presentation retries), short enough that a
    /// dropped handoff releases the camera promptly.
    static let arrivalHoldSeconds: TimeInterval = 25

    /// The return leg's budget: reaching finishes, the user hears the result,
    /// thinks, and only then asks for somewhere else. That gap is human-paced,
    /// not machine-paced, so it is far longer than the arrival handoff's — and
    /// the session holds the camera the whole time, which is why it is bounded
    /// at all. JS releases it explicitly (`stopNavigation`) the moment it needs
    /// the camera back, so this is only the backstop for a user who walks away.
    static let returnHoldSeconds: TimeInterval = 120

    private init() {}

    func offer(session: ARSession, mapID: String?, holdSeconds: TimeInterval = ARLiveSessionHandoff.arrivalHoldSeconds) {
        lock.lock()
        expiry?.cancel()
        heldSession = session
        heldMapID = mapID?.trimmingCharacters(in: .whitespacesAndNewlines)
        loanedMapIDs.removeValue(forKey: ObjectIdentifier(session))
        let work = DispatchWorkItem { [weak self] in self?.expire() }
        expiry = work
        lock.unlock()
        NSLog("🤝 [SessionHandoff] Live session offered for map %@ — held for %.0fs",
              mapID ?? "unknown", holdSeconds)
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
    }

    /// Records that `session` was handed to another owner directly, without
    /// going through `offer`/`claim` — the manual arrival path passes it as a
    /// call argument. Only so that owner can hand it back by `offerBack`.
    func noteLoan(session: ARSession, mapID: String?) {
        let trimmed = mapID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        lock.lock()
        loanedMapIDs[ObjectIdentifier(session)] = trimmed
        lock.unlock()
    }

    /// Hands a borrowed session back for the next navigation leg to adopt.
    ///
    /// Returns false when this session was never on loan from here, which is
    /// the caller's signal to pause it as it always did — a session nobody can
    /// identify a map for is one no navigation leg could safely adopt.
    @discardableResult
    func offerBack(session: ARSession, holdSeconds: TimeInterval = ARLiveSessionHandoff.returnHoldSeconds) -> Bool {
        lock.lock()
        let mapID = loanedMapIDs.removeValue(forKey: ObjectIdentifier(session))
        lock.unlock()
        guard let mapID else {
            NSLog("🤝 [SessionHandoff] Session offered back but was never loaned from here — not holding it")
            return false
        }
        offer(session: session, mapID: mapID, holdSeconds: holdSeconds)
        return true
    }

    /// Takes the offered session, if one is waiting and it belongs to the map
    /// the caller is reaching in. A map mismatch is left alone rather than
    /// claimed: a session relocalized to a different map would place the box
    /// from coordinates that mean nothing in its frame.
    func claim(mapID: String?) -> ARSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = heldSession else { return nil }
        let wanted = mapID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let held = heldMapID ?? ""
        if !wanted.isEmpty, !held.isEmpty, wanted != held {
            NSLog("🤝 [SessionHandoff] Offered session is for map %@, reaching wants %@ — not claiming",
                  held, wanted)
            return nil
        }
        expiry?.cancel()
        expiry = nil
        heldSession = nil
        heldMapID = nil
        // Remember which map it is for, so the claimant can offer it back
        // without carrying the id through its own call chain.
        if !held.isEmpty {
            loanedMapIDs[ObjectIdentifier(session)] = held
        } else if !wanted.isEmpty {
            loanedMapIDs[ObjectIdentifier(session)] = wanted
        }
        NSLog("🤝 [SessionHandoff] ✅ Live navigation session claimed")
        return session
    }

    /// Drops the offer. `pauseSession: true` releases the camera — used when
    /// nobody is going to claim it.
    func discard(pauseSession: Bool) {
        lock.lock()
        expiry?.cancel()
        expiry = nil
        let session = heldSession
        heldSession = nil
        heldMapID = nil
        lock.unlock()
        guard let session else { return }
        NSLog("🤝 [SessionHandoff] Offer discarded (pause=%@)", pauseSession ? "YES" : "NO")
        if pauseSession {
            DispatchQueue.main.async { session.pause() }
        }
    }

    private func expire() {
        NSLog("🤝 [SessionHandoff] ⏳ Nobody claimed the live session — pausing it")
        discard(pauseSession: true)
    }
}

private extension JSONEncoder {
    static var arMapEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var arMapDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
