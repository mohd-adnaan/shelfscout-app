import SwiftUI
import ARKit
import SceneKit
import UIKit

struct ARViewContainer: UIViewRepresentable {
    var session: ARSession
    /// Changes when the manager swaps its `ARSession` object — which it does on
    /// the return leg, adopting the live session reaching handed back instead of
    /// relocalizing a fresh one. `session` is captured at `makeUIView`, so
    /// without re-pointing here the view would render a session nobody drives.
    var sessionRevision: Int
    var isSessionActive: Bool
    var showsCoaching: Bool
    /// AR-world positions of the remaining route polyline. Non-empty while
    /// guidance runs on an AR-frame map: the container draws gamified chevrons
    /// along it so a sighted developer can verify, against the real store,
    /// that the route the guidance believes in is the route being spoken.
    var routeOverlayPoints: [SIMD3<Float>] = []
    /// Why the polyline is what it is ("route", or the guard that emptied it).
    /// Traced on change so a field report of "no arrows" pinpoints the guard.
    var routeOverlayContext: String = ""

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView(frame: .zero)
        arView.session = session
        arView.debugOptions = []
        arView.preferredFramesPerSecond = 30
        arView.antialiasingMode = .none
        arView.rendersContinuously = false
        arView.autoenablesDefaultLighting = false
        arView.automaticallyUpdatesLighting = false
        arView.backgroundColor = .black
        context.coordinator.attachCoachingOverlay(to: arView, session: session)
        context.coordinator.attachRouteOverlay(to: arView)
        context.coordinator.update(showsCoaching: showsCoaching && isSessionActive)
        applyRouteOverlay(via: context.coordinator)
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        uiView.debugOptions = []
        if uiView.session !== session {
            uiView.session = session
            context.coordinator.repointCoachingOverlay(to: session)
        }
        context.coordinator.update(showsCoaching: showsCoaching && isSessionActive)
        applyRouteOverlay(via: context.coordinator)
    }

    private func applyRouteOverlay(via coordinator: Coordinator) {
        coordinator.updateRouteOverlay(
            points: isSessionActive ? routeOverlayPoints : [],
            context: isSessionActive ? routeOverlayContext : "session_idle"
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private let coachingOverlay = ARCoachingOverlayView()
        private let routeOverlayRoot = SCNNode()
        private var lastOverlaySignature = ""

        func attachCoachingOverlay(to arView: ARSCNView, session: ARSession) {
            coachingOverlay.session = session
            coachingOverlay.goal = .tracking
            coachingOverlay.activatesAutomatically = false
            coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
            coachingOverlay.isHidden = true
            // It is a full-screen view with no controls of ours on it, and it
            // is visible exactly while the map is being searched for — the
            // stretch a participant is most likely to want out of. Letting it
            // eat touches would make the screen's exit stop working there.
            coachingOverlay.isUserInteractionEnabled = false

            arView.addSubview(coachingOverlay)
            NSLayoutConstraint.activate([
                coachingOverlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                coachingOverlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                coachingOverlay.topAnchor.constraint(equalTo: arView.topAnchor),
                coachingOverlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
            ])
        }

        /// Follows an adopted session. The overlay holds its own reference and
        /// would otherwise keep coaching against the session that was replaced.
        func repointCoachingOverlay(to session: ARSession) {
            coachingOverlay.session = session
        }

        func update(showsCoaching: Bool) {
            coachingOverlay.isHidden = !showsCoaching
            coachingOverlay.activatesAutomatically = showsCoaching
            if !showsCoaching {
                coachingOverlay.setActive(false, animated: true)
            }
        }

        func attachRouteOverlay(to arView: ARSCNView) {
            routeOverlayRoot.name = "routeArrowOverlay"
            if routeOverlayRoot.parent == nil {
                arView.scene.rootNode.addChildNode(routeOverlayRoot)
            }
        }

        /// Where the active leg's floor trail starts, in metres ahead of the
        /// user. The first stretch of a leg is under their feet: at a 1.35 m
        /// camera height a marker 0.35 m ahead sits 75° below the horizon and
        /// one at 1.85 m sits 36° below, while the AR view only sees about 30°
        /// below centre — and the bottom of the screen is behind the guidance
        /// panel besides. A trail that starts at the toes is a trail nobody
        /// ever sees, which is exactly how this overlay first shipped.
        private static let activeLegTrailStartMeters: Float = 1.6

        /// Rebuilds the chevron trail when the route meaningfully changes.
        /// The signature quantizes to half-metre buckets so per-tick progress
        /// noise and camera-height bobbing do not thrash the scene graph.
        func updateRouteOverlay(points: [SIMD3<Float>], context: String) {
            let signature = points
                .map { String(format: "%.0f,%.0f,%.0f", $0.x * 2, $0.y * 2, $0.z * 2) }
                .joined(separator: ";")
            guard signature != lastOverlaySignature else { return }
            lastOverlaySignature = signature

            routeOverlayRoot.childNodes.forEach { $0.removeFromParentNode() }
            guard points.count >= 2 else {
                // "No arrows appeared" has to be answerable from the log rather
                // than from guessing which guard emptied the polyline.
                NavigationTrace.shared.log("ar.routeOverlay", [
                    "context": context,
                    "points": points.count,
                    "markers": 0
                ])
                return
            }

            let floorY = points[0].y
            var markerCount = 0
            let chevronSpacing: Float = 0.9

            for index in 0..<(points.count - 1) {
                let from = points[index]
                let to = points[index + 1]
                let delta = to - from
                let length = simd_length(delta)
                guard length > 0.05 else { continue }
                let direction = delta / length

                var offset: Float = index == 0
                    ? Self.activeLegTrailStartMeters
                    : chevronSpacing * 0.5
                while offset < length - 0.15 {
                    routeOverlayRoot.addChildNode(Self.chevronNode(
                        at: from + direction * offset,
                        direction: direction,
                        isActiveLeg: index == 0
                    ))
                    markerCount += 1
                    offset += chevronSpacing
                }

                // One ring standing at eye height on the active leg. The floor
                // trail can fall out of frame in a narrow aisle or when the
                // phone is held level; a gate at 1.5 m sits dead centre of the
                // view, so there is always one element that proves which way
                // guidance believes the route runs.
                if index == 0, length > 0.6 {
                    let gateOffset = min(max(length * 0.6, 1.2), min(length, 2.8))
                    var gatePosition = from + direction * gateOffset
                    gatePosition.y = floorY + 1.5
                    routeOverlayRoot.addChildNode(Self.routeGateNode(
                        at: gatePosition,
                        direction: direction
                    ))
                    markerCount += 1
                }

                if index < points.count - 2 {
                    routeOverlayRoot.addChildNode(Self.turnMarkerNode(at: to, floorY: floorY))
                    markerCount += 1
                }
            }
            if let destination = points.last {
                routeOverlayRoot.addChildNode(Self.destinationBeaconNode(at: destination))
                markerCount += 1
            }

            NavigationTrace.shared.log("ar.routeOverlay", [
                "context": context,
                "points": points.count,
                "markers": markerCount,
                "firstX": points[0].x,
                "firstZ": points[0].z,
                "floorY": floorY,
                "lastX": points[points.count - 1].x,
                "lastZ": points[points.count - 1].z
            ])
        }

        /// A flat arrowhead on the floor pointing along the walking direction.
        /// The active leg is bright green; upcoming legs are dimmer teal so
        /// the next action reads at a glance.
        private static func chevronNode(
            at position: SIMD3<Float>,
            direction: SIMD3<Float>,
            isActiveLeg: Bool
        ) -> SCNNode {
            let pyramid = SCNPyramid(width: 0.28, height: 0.38, length: 0.05)
            let color = isActiveLeg ? UIColor.systemGreen : UIColor.systemTeal
            let material = SCNMaterial()
            material.diffuse.contents = color.withAlphaComponent(isActiveLeg ? 0.95 : 0.55)
            material.emission.contents = color
            material.lightingModel = .constant
            material.isDoubleSided = true
            material.writesToDepthBuffer = false
            pyramid.materials = [material]
            let node = SCNNode(geometry: pyramid)
            node.simdPosition = position
            node.renderingOrder = 100
            node.simdOrientation = Self.floorArrowOrientation(direction: direction)
            return node
        }

        /// Lays a pyramid flat on the floor with its apex along `direction`.
        ///
        /// `simd_quatf(from:to:)` returns the MINIMAL rotation between two
        /// vectors, which leaves the roll about the resulting axis
        /// unconstrained. Taking the pyramid's apex (+y) onto a horizontal
        /// travel direction therefore also takes its 0.28 m base width onto the
        /// vertical and leaves the 0.05 m thickness horizontal: every chevron
        /// rendered as a thin blade standing on edge, seen almost end-on from
        /// behind. That is the "distorted arrows" in the 2026-08-11 pilot
        /// screenshot — the trail was drawn as a row of slivers rather than
        /// arrowheads. Build the basis explicitly instead, so the geometry's own
        /// axes land where the comment always claimed: width across the aisle,
        /// apex along travel, thickness on the vertical.
        private static func floorArrowOrientation(direction: SIMD3<Float>) -> simd_quatf {
            let horizontal = SIMD3<Float>(direction.x, 0, direction.z)
            guard simd_length(horizontal) > 1e-4 else {
                // A purely vertical leg cannot happen (every overlay point
                // shares one floor height), but a degenerate basis would put
                // NaNs in the scene graph, so fall back to unrotated.
                return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
            }
            let forward = simd_normalize(horizontal)
            let up = SIMD3<Float>(0, 1, 0)
            let right = simd_normalize(simd_cross(forward, up))
            // Columns are where the geometry's own x/y/z end up. SCNPyramid
            // spans `width` on x, `height` (apex) on y and `length` on z.
            return simd_quatf(simd_float3x3(columns: (right, forward, up)))
        }

        /// A checkpoint ring standing across the active leg at eye height.
        private static func routeGateNode(
            at position: SIMD3<Float>,
            direction: SIMD3<Float>
        ) -> SCNNode {
            let torus = SCNTorus(ringRadius: 0.40, pipeRadius: 0.045)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemGreen.withAlphaComponent(0.85)
            material.emission.contents = UIColor.systemGreen
            material.lightingModel = .constant
            material.writesToDepthBuffer = false
            torus.materials = [material]
            let node = SCNNode(geometry: torus)
            node.simdPosition = position
            node.renderingOrder = 100
            // A torus's axis is +y and its ring lies in the xz plane; steering
            // +y onto the travel direction stands the ring up across the leg,
            // so the user walks through it.
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(direction))
            return node
        }

        /// A pillar, not a marble: a turn eight metres away has to read from
        /// standing height, and anything lying on the floor at that distance is
        /// a couple of pixels tall.
        private static func turnMarkerNode(at position: SIMD3<Float>, floorY: Float) -> SCNNode {
            let cylinder = SCNCylinder(radius: 0.05, height: 1.6)
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemOrange.withAlphaComponent(0.75)
            material.emission.contents = UIColor.systemOrange
            material.lightingModel = .constant
            material.writesToDepthBuffer = false
            cylinder.materials = [material]
            let node = SCNNode(geometry: cylinder)
            node.simdPosition = SIMD3<Float>(position.x, floorY + 0.8, position.z)
            node.renderingOrder = 100
            return node
        }

        private static func destinationBeaconNode(at position: SIMD3<Float>) -> SCNNode {
            let beacon = SCNNode()
            beacon.simdPosition = position
            beacon.renderingOrder = 100

            let cylinder = SCNCylinder(radius: 0.04, height: 2.0)
            let cylinderMaterial = SCNMaterial()
            cylinderMaterial.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.55)
            cylinderMaterial.emission.contents = UIColor.systemRed
            cylinderMaterial.lightingModel = .constant
            cylinderMaterial.writesToDepthBuffer = false
            cylinder.materials = [cylinderMaterial]
            let pole = SCNNode(geometry: cylinder)
            pole.simdPosition = SIMD3<Float>(0, 1.0, 0)
            beacon.addChildNode(pole)

            let sphere = SCNSphere(radius: 0.14)
            let sphereMaterial = SCNMaterial()
            sphereMaterial.diffuse.contents = UIColor.systemRed
            sphereMaterial.emission.contents = UIColor.systemRed
            sphereMaterial.lightingModel = .constant
            sphereMaterial.writesToDepthBuffer = false
            sphere.materials = [sphereMaterial]
            let cap = SCNNode(geometry: sphere)
            cap.simdPosition = SIMD3<Float>(0, 2.0, 0)
            beacon.addChildNode(cap)

            return beacon
        }
    }
}

struct ARMappingView: View {
    @EnvironmentObject private var sensorManager: IMUSensorManager
    @EnvironmentObject private var ttsManager: TTSManager
    @StateObject private var mappingManager = ARMappingManager()
    @StateObject private var semanticNavigator = SemanticRouteNavigator()
    @ObservedObject private var navigationSession = ARKitNavigationSession.shared
    @Binding private var sourceSelection: String
    private let launchTargetName: String?
    private let launchRouteMapId: String?
    private let launchRouteMapName: String?
    private let launchSpeakLandmarks: Bool
    private let launchErrorRecovery: Bool
    private let launchClockFaceDirections: Bool
    private let launchVoiceOverEnabled: Bool
    private let onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)?
    /// Manual exit from an automated guidance run. Wired to the same handler as
    /// the toolbar's Done button so the whole screen can end the session.
    private let onExitRequested: (() -> Void)?
    @State private var newPOIName: String = ""
    @State private var mapName: String = ""
    @State private var showsMapInspector: Bool = false
    @State private var didSeedIMUBearing: Bool = false
    @State private var lastSpokenSemanticCueText: String?
    @State private var lastSpokenSemanticCueAt: Date?
    @State private var didAttemptAutomatedRouteSelection: Bool = false
    @State private var didStartAutomatedGuidance: Bool = false
    @State private var didResolveAutomation: Bool = false
    @State private var didTriggerReachingHandoff: Bool = false
    /// True once the user has tapped out of an automated run. The arrival wait
    /// is the one thing that can still be in flight when they do, and resolving
    /// an arrival into a screen they have already left is at best pointless.
    @State private var didRequestGuidanceExit: Bool = false
    /// True once the arrival resolution is waiting on the arrival announcement.
    /// The phase can be republished while that wait is in flight, and a second
    /// waiter would resolve the automation the moment the first one did.
    @State private var didScheduleArrivalResolve: Bool = false
    @State private var automatedRelocalizationStartedAt: Date?
    @State private var lastRelocalizationVoiceCueAt: Date?
    @State private var relocalizationVoiceCueCount: Int = 0
    /// True once the "still looking" checkpoint has been spoken for this
    /// attempt. Said once, not on repeat: past it the escalating coaching cues
    /// are the ones carrying the search, and a status line repeating over them
    /// would only crowd out the instruction the user can act on.
    @State private var didReportSlowRelocalization: Bool = false
    /// When this mounted screen first started searching for the saved map.
    /// Unlike `automatedRelocalizationStartedAt` it survives a retarget, so it
    /// bounds the total warm search rather than one attempt.
    @State private var relocalizationSearchStartedAt: Date?
    /// AR world map whose async load has been requested but not yet reflected
    /// in `mappingManager.activeMapID`.
    @State private var requestedARMapLoadID: String?

    /// The destination this app run last confirmed the user reached.
    ///
    /// Static for the same reason `hasCoachedRelocalization` is: a journey hops
    /// from leg to leg through separate mounts of this screen, and what the
    /// previous mount PROVED about where the user is standing is still true in
    /// the next one. Used only to say so out loud while the next leg relocalizes
    /// — never to assume a pose. Cleared the moment guidance starts, because
    /// from then on the user is walking away from it.
    private static var lastConfirmedPlaceName: String?
    /// When that arrival was confirmed. "You are at 421" is a safe thing to say
    /// a minute after arriving there and a wrong thing to say an hour later,
    /// after the phone has been in a pocket — the app has no way to know the
    /// user did not walk off. Past `lastConfirmedPlaceMaxAgeSeconds` the claim
    /// is dropped and the ordinary coaching cue speaks instead.
    private static var lastConfirmedPlaceAt: Date?
    private static let lastConfirmedPlaceMaxAgeSeconds: TimeInterval = 600

    /// The place the user is standing in, if the app still has grounds to say so.
    private static var freshConfirmedPlaceName: String? {
        guard let name = lastConfirmedPlaceName, let at = lastConfirmedPlaceAt else { return nil }
        guard Date().timeIntervalSince(at) <= lastConfirmedPlaceMaxAgeSeconds else { return nil }
        return name
    }

    /// Whether the full posture-and-pan coaching has been spoken already in
    /// this app run.
    ///
    /// Static on purpose: a multi-destination map hops from target to target
    /// through separate mounts of this screen, and the user does not need to
    /// be taught how to hold the phone again at every hop — they were told at
    /// the first one and they are still holding it the same way. Subsequent
    /// relocalizations open on the short form, and only if the search is
    /// actually running long; the fast ones now finish in silence.
    private static var hasCoachedRelocalization = false

    /// Longest the automated arrival waits for "Arrived at X" to be spoken
    /// before handing off anyway. Comfortably past the longest arrival line in
    /// either language at the slowest speech rate, so it is a failure bound
    /// rather than a normal cut-off.
    private let arrivalSpeechMaxWaitSeconds: TimeInterval = 6.0

    /// The coaching overlay is visual-only; a blind user standing in silence
    /// while the map searches gets spoken guidance instead, then a hard
    /// timeout so the JS side can recover rather than waiting forever.
    private let relocalizationVoiceCueIntervalSeconds: TimeInterval = 8.0
    private let automatedRelocalizationTimeoutSeconds: TimeInterval = 35.0
    /// Total time this mounted screen may keep an unlocalized ARKit session
    /// searching across retries before it is genuinely given up on. Each
    /// individual attempt still reports back at
    /// `automatedRelocalizationTimeoutSeconds` so the user is never left in
    /// silence — this only bounds how long the session stays warm underneath.
    private let automatedRelocalizationWarmBudgetSeconds: TimeInterval = 180.0

    init(
        sourceSelection: Binding<String> = .constant(""),
        launchTargetName: String? = nil,
        launchRouteMapId: String? = nil,
        launchRouteMapName: String? = nil,
        launchSpeakLandmarks: Bool = true,
        launchErrorRecovery: Bool = true,
        launchClockFaceDirections: Bool = false,
        launchVoiceOverEnabled: Bool = UIAccessibility.isVoiceOverRunning,
        onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)? = nil,
        onExitRequested: (() -> Void)? = nil
    ) {
        _sourceSelection = sourceSelection
        self.launchTargetName = launchTargetName
        self.launchRouteMapId = launchRouteMapId
        self.launchRouteMapName = launchRouteMapName
        self.launchSpeakLandmarks = launchSpeakLandmarks
        self.launchErrorRecovery = launchErrorRecovery
        self.launchClockFaceDirections = launchClockFaceDirections
        self.launchVoiceOverEnabled = launchVoiceOverEnabled
        self.onAutomationComplete = onAutomationComplete
        self.onExitRequested = onExitRequested
    }

    var body: some View {
        routeSceneWithNavigationChrome
            .onAppear(perform: handleAppear)
            .onDisappear(perform: handleDisappear)
            .onChange(of: mappingManager.sessionMode) { _ in handleSessionModeChanged() }
            .onChange(of: mappingManager.isLocalized) { handleLocalizationChanged($0) }
            .onChange(of: mappingManager.arHeadingDegrees) { handleARHeadingChanged($0) }
            .onChange(of: mappingManager.selectedMapID) { _ in handleSelectedMapChanged() }
            .onChange(of: mappingManager.activeMapName) { handleActiveMapNameChanged($0) }
            .onChange(of: mappingManager.activeMapID) { handleActiveMapIDChanged($0) }
            .onChange(of: mappingManager.closestPOI) { handleClosestPOIChanged($0) }
            .onReceive(sensorManager.$imuState, perform: handleIMUStateChanged)
            .onChange(of: semanticNavigator.speechCue?.id) { _ in handleSpeechCueChanged() }
            .onChange(of: semanticNavigator.phase) { handleNavigationPhaseChange($0) }
            .onChange(of: mappingManager.localizationRevision) { _ in handleLocalizationRevisionChanged() }
            .onChange(of: navigationSession.retargetRevision) { _ in handleRetarget() }
    }

    /// ARKit corrected a premature alignment after guidance had already
    /// started, so the route was resolved from a stale pose. Re-resolve the
    /// whole route from the corrected pose rather than letting the user walk
    /// a path built for somewhere they were never standing.
    ///
    /// A realignment, not a restart: `startNavigation` here re-announced the
    /// journey from the top every time ARKit nudged the pose, and each
    /// re-resolve could pick a different start edge and so a different turn.
    private func handleLocalizationRevisionChanged() {
        guard semanticNavigator.phase == .navigating
                || semanticNavigator.phase == .recovering else {
            return
        }
        // ARKit has moved the world frame, so anything measured about how that
        // frame sat relative to the map describes a frame that no longer
        // exists. Drop it and let the keyframes re-measure against the new one
        // — carrying a stale bias forward would apply a correction for an error
        // that has already been corrected, and double it.
        semanticNavigator.noteARFrameRealigned()
        semanticNavigator.realignRouteToCorrectedPose(
            arPosition: mappingManager.cameraMapPosition,
            imuState: sensorManager.imuState,
            heading: semanticNavigator.mapFrameHeading(mappingManager.arHeadingDegrees)
        )
    }

    /// Next leg of a chained journey on the already-relocalized session.
    /// Only the automation state machine resets — the AR session, the loaded
    /// world map and the live pose all carry over, which is what lets this
    /// leg start without another relocalization.
    private func handleRetarget() {
        didResolveAutomation = false
        didStartAutomatedGuidance = false
        didTriggerReachingHandoff = false
        didScheduleArrivalResolve = false
        didRequestGuidanceExit = false
        automatedRelocalizationStartedAt = nil
        lastRelocalizationVoiceCueAt = nil
        relocalizationVoiceCueCount = 0
        didReportSlowRelocalization = false
        // The route map for the new target may differ from the current one,
        // so route selection re-runs; the AR world map stays loaded.
        didAttemptAutomatedRouteSelection = false
        semanticNavigator.stopNavigation(resetInstruction: false)
        // First call performs route selection and returns; the second starts
        // guidance. On a warm session isLocalized never changes, so nothing
        // else would drive the second call.
        attemptAutomatedNavigationIfNeeded()
        attemptAutomatedNavigationIfNeeded()
    }

    private var routeSceneWithNavigationChrome: some View {
        arSceneContent
            .navigationTitle(isAutomatedNavigation ? "ARKit Navigation" : "Manage ARKit Route Maps")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var arSceneContent: AnyView {
        let scene = ZStack {
            ARViewContainer(
                session: mappingManager.session,
                sessionRevision: mappingManager.sessionRevision,
                isSessionActive: mappingManager.sessionMode != .idle,
                showsCoaching: mappingManager.isMapping || (mappingManager.isRelocalizing && !mappingManager.isLocalized),
                routeOverlayPoints: routeOverlayWorldPoints,
                routeOverlayContext: routeOverlayContext
            )
            .ignoresSafeArea()

            if mappingManager.sessionMode == .idle {
                Color.black.opacity(0.82)
                    .ignoresSafeArea()
            }

            if let headingError = activeLegHeadingErrorDegrees {
                // Upper third, not centre: the manual Guide sheet reaches
                // past mid-screen, and an indicator the panel covers is an
                // indicator that does not exist in the field.
                VStack {
                    routeDirectionHUD(headingErrorDegrees: headingError)
                        .padding(.top, 84)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }

            if !isAutomatedNavigation && showsMapInspector && hasInspectionContent {
                VStack {
                    mapInspectorPanel
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                    Spacer(minLength: 0)
                }
            }

            VStack {
                Spacer(minLength: 0)
                bottomSheetContent
            }
        }

        // The route manager is a screen full of controls, so it keeps its
        // buttons. A guidance run is the opposite: the app is not listening,
        // nothing on screen is meant to be read, and until now the single way
        // out was a Done button in the far top corner — a target a blind
        // participant has no way to find. Under guidance the screen IS the
        // exit. The gesture sits on the container, so the panel's log-export
        // button (inner views win a tap) still works for the researcher, and
        // the two VoiceOver gestures are wired up because VoiceOver never
        // delivers the plain tap.
        guard isAutomatedNavigation else { return AnyView(scene) }
        return AnyView(
            scene
                .contentShape(Rectangle())
                .onTapGesture(perform: requestGuidanceExit)
                .accessibilityAction(.magicTap, requestGuidanceExit)
                .accessibilityAction(.escape, requestGuidanceExit)
        )
    }

    /// Manual end of an automated guidance run, from anywhere on the screen.
    private func requestGuidanceExit() {
        guard isAutomatedNavigation, let onExitRequested else { return }
        didRequestGuidanceExit = true
        NavigationTrace.shared.log("nav.exit.tap", [
            "target": automatedTargetName ?? launchTargetName ?? "",
            "phase": String(describing: semanticNavigator.phase)
        ])
        onExitRequested()
    }

    /// Route-frame polyline mapped into the live AR session's world frame for
    /// the chevron overlay. Route x is AR x; route y is -AR z; the floor sits
    /// a torso below the camera. Only meaningful while localized on an
    /// AR-frame map — `remainingRoutePolyline` is empty otherwise.
    ///
    /// The two frames are only interchangeable while ARKit's world yaw agrees
    /// with the map's; when it does not, writing route coordinates straight
    /// into world coordinates draws a correct route at a wrong angle — arrows
    /// heading into a wall while the corridor runs straight ahead. Hence
    /// `arFrameRoutePolyline`, which applies the measured rotation.
    private var routeOverlayWorldPoints: [SIMD3<Float>] {
        // Same pose-trust rule the navigator itself uses: a relocalized map
        // frame, or the live capture session whose frame IS the map frame.
        guard mappingManager.isLocalized || mappingManager.isMapping,
              let cameraPosition = mappingManager.cameraMapPosition else {
            return []
        }
        let floorY = cameraPosition.y - 1.35
        var points = semanticNavigator.arFrameRoutePolyline(userARPosition: cameraPosition).map {
            SIMD3<Float>(Float($0.x), floorY, Float(-$0.y))
        }
        // The polyline's first vertex is the BELIEVED position on the route, not
        // where the camera is. Those differ by the belief's cross-track and
        // along-track error — 0.39 m and 0.51 m median, 3.3 m worst case across
        // the two 2026-08-11 pilot journeys — and the trail, its 1.6 m lead-in
        // and the eye-height gate are all measured from that first vertex. A
        // metre of lateral belief error therefore swings the first chevron ~30°
        // off the aisle and stands the gate in front of the shelving, which is
        // the "arrows point into the shelf while the spoken leg is right"
        // report: guidance steers on the leg BEARING and survives the offset,
        // the overlay draws raw geometry and does not.
        //
        // Only the leading vertex is moved. Every node, turn pillar and the
        // destination beacon keep their true map positions, so the active leg is
        // drawn from the user's feet toward the node they are actually walking
        // to, and a genuine off-route offset still shows up as a diagonal first
        // segment instead of a whole trail shifted sideways.
        if !points.isEmpty {
            points[0] = SIMD3<Float>(cameraPosition.x, floorY, cameraPosition.z)
        }
        return points
    }

    /// Why the overlay is showing what it is. Logged with the rebuild so a
    /// field report of "no arrows" names the guard that emptied it instead of
    /// leaving the cause to be guessed at afterwards.
    private var routeOverlayContext: String {
        if !(mappingManager.isLocalized || mappingManager.isMapping) { return "not_localized" }
        if mappingManager.cameraMapPosition == nil { return "no_camera_pose" }
        let phase = semanticNavigator.phase
        if phase != .navigating && phase != .recovering { return "phase_\(phase.rawValue)" }
        if semanticNavigator.activeMap?.coordinateSpace != "ar_world_xz" { return "not_ar_frame_map" }
        if semanticNavigator.routeSteps.isEmpty { return "no_route_steps" }
        return "route"
    }

    /// Signed turn from where the camera points to where the active leg runs:
    /// positive means the route is to the user's right. This is the number
    /// every spoken turn is derived from, so putting it on screen makes a wrong
    /// instruction visible instead of merely audible.
    private var activeLegHeadingErrorDegrees: Double? {
        // Map frame, not AR frame: the leg bearings this is compared against
        // are the map's, and mixing the two puts the on-screen turn readout at
        // odds with the spoken one by exactly the frame rotation.
        guard let heading = semanticNavigator.mapFrameHeading(mappingManager.arHeadingDegrees) else {
            return nil
        }
        return semanticNavigator.headingErrorToActiveLeg(liveHeading: heading)
    }

    /// Screen-space direction indicator, pinned to the middle of the view.
    ///
    /// The floor chevrons answer "where does the route run" but only while the
    /// floor is in frame; this answers it unconditionally. The needle points
    /// where guidance wants the user to walk, relative to where the camera
    /// currently points — straight up means aligned — so a spoken turn that
    /// contradicts the geometry is visible the moment it is said.
    private func routeDirectionHUD(headingErrorDegrees: Double) -> some View {
        let magnitude = abs(headingErrorDegrees)
        let tint: Color = magnitude <= 20 ? .green : (magnitude <= 60 ? .yellow : .orange)
        return VStack(spacing: 6) {
            Image(systemName: "arrow.up")
                .font(.system(size: 54, weight: .heavy))
                .foregroundColor(tint)
                .rotationEffect(.degrees(headingErrorDegrees))
                .shadow(color: .black.opacity(0.6), radius: 6)
                .animation(.easeOut(duration: 0.18), value: headingErrorDegrees)

            Text("\(headingErrorDegrees >= 0 ? "R" : "L") \(Int(magnitude.rounded()))°")
                .font(.system(.subheadline, design: .monospaced).weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.55))
                .clipShape(Capsule())
        }
        .accessibilityHidden(true)
    }

    private func handleAppear() {
        sensorManager.startSensors()
        mappingManager.updateIMUMotion(sensorManager.imuState)
        mappingManager.refreshSavedMaps()
        if mapName.isEmpty {
            mapName = mappingManager.activeMapName ?? selectedSavedMap?.name ?? mappingManager.suggestedMapName()
        }
        attemptAutomatedNavigationIfNeeded()
    }

    private func handleDisappear() {
        navigationSession.isWarm = false
        navigationSession.isSearching = false
        relocalizationSearchStartedAt = nil
        mappingManager.stopMapping()
    }

    private var bottomSheetContent: AnyView {
        AnyView(
            routeBottomSheet
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        )
    }

    private func handleNavigationPhaseChange(_ phase: SemanticNavigationPhase) {
        if phase == .navigating || phase == .recovering {
            didTriggerReachingHandoff = false
            didScheduleArrivalResolve = false
        }
        guard phase == .arrived else { return }

        // Where the user is now, for the next leg to open on. `targetName` is
        // the navigator's resolved label, so it is the name the user was just
        // told they arrived at rather than whatever they said to get here.
        let arrivedAt = semanticNavigator.targetName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !arrivedAt.isEmpty {
            Self.lastConfirmedPlaceName = arrivedAt
            Self.lastConfirmedPlaceAt = Date()
        }

        if launchTargetName != nil {
            resolveAutomatedArrivalWhenSpoken()
            return
        }

        triggerManualReachingHandoffIfNeeded()
    }

    /// Hold the automation open until "Arrived at X" has actually been said.
    ///
    /// Resolving the instant the phase flips is what made arrival inaudible.
    /// The trace of the 25 Aug 2026 lab test has the arrival cue at t=228.96
    /// and the session handoff at t=228.97: this screen enqueued the sentence
    /// and was torn down 10 ms later, so the utterance was cancelled a syllable
    /// in and reaching simply began. The participant's report was that they
    /// never learned they had arrived — it "just directly shifted to reaching".
    ///
    /// The manual path has always given it a beat (`triggerManualReachingHandoff
    /// IfNeeded`); this is the same idea measured against the synthesizer
    /// instead of a guessed constant, so a long arrival line in either language
    /// gets the time it actually needs and a short one costs nothing.
    private func resolveAutomatedArrivalWhenSpoken() {
        guard didScheduleArrivalResolve == false,
              didResolveAutomation == false,
              didRequestGuidanceExit == false else { return }
        didScheduleArrivalResolve = true

        let message = semanticNavigator.currentInstruction

        // Two cases cannot be measured: VoiceOver owns the utterance and
        // reports nothing back about it, and a disabled synthesizer never
        // reports starting at all. Both estimate instead, on the same basis as
        // Announcer's queue pacing on the JS side.
        guard !launchVoiceOverEnabled, ttsManager.ttsState.isEnabled else {
            let estimate = min(
                arrivalSpeechMaxWaitSeconds,
                max(1.6, Double(message.count) * 0.055)
            )
            DispatchQueue.main.asyncAfter(deadline: .now() + estimate) {
                guard didRequestGuidanceExit == false else { return }
                resolveArrivedAutomation(message: message)
            }
            return
        }

        awaitArrivalSpeech(message: message, deadline: Date().addingTimeInterval(arrivalSpeechMaxWaitSeconds))
    }

    /// Polls the synthesizer until the arrival line has been spoken.
    ///
    /// Polling rather than sampling once: the cue is enqueued by a *different*
    /// `onChange` handler (`handleSpeechCueChanged`) on the same runloop turn as
    /// the phase change, and SwiftUI does not order the two — reading
    /// `isSpeaking` immediately can catch the moment before it starts and
    /// mistake "not yet" for "done". The deadline bounds it so a TTS failure
    /// costs a few seconds, never the arrival.
    private func awaitArrivalSpeech(message: String, deadline: Date) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard didResolveAutomation == false, didRequestGuidanceExit == false else { return }
            let state = ttsManager.ttsState
            let startedThisLine = state.lastSpokenText == message
            if (startedThisLine && !state.isSpeaking) || Date() >= deadline {
                resolveArrivedAutomation(message: message)
                return
            }
            awaitArrivalSpeech(message: message, deadline: deadline)
        }
    }

    private func resolveArrivedAutomation(message: String) {
        resolveAutomation(
            success: true,
            reason: "arrived",
            message: message,
            messageSpoken: true
        )
    }

    /// Route-manager testing flow: after a manual guidance run arrives at a
    /// destination that has a reaching object, switch into the in-device
    /// spatial-target reaching session automatically. The automated (JS
    /// driven) flow does this on the React Native side instead.
    private func triggerManualReachingHandoffIfNeeded() {
        guard !isAutomatedNavigation,
              didTriggerReachingHandoff == false,
              arrivedReachingObjectName != nil else {
            return
        }
        guard mappingManager.activeMapID != nil else {
            mappingManager.statusMessage = "Save and load the AR map to enable the reaching handoff."
            return
        }
        didTriggerReachingHandoff = true
        // Give the arrival announcement a beat before reaching takes over
        // the camera and audio session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            startReachingHandoff()
        }
    }

    private var arrivedReachingObjectName: String? {
        let target = automatedTargetName
            ?? semanticNavigator.targetName.nilIfRouteBlank
        guard let target else { return nil }
        return semanticNavigator.reachingObjectName(forTarget: target)
    }

    private func startReachingHandoff() {
        guard let objectName = arrivedReachingObjectName else { return }
        let manager = mappingManager
        let speech = ttsManager
        let mapId = manager.activeMapID
        let mapName = manager.activeMapName
        let objectPosition = reachingObjectWorldPosition(for: objectName)

        // Reaching INHERITS this session instead of starting its own. A cold
        // reaching session has to relocalize the whole world map a second
        // time, standing still at the shelf — which is where it stalled and
        // timed out without ever placing the box. The live session is already
        // relocalized, so `objectPosition` (a map-frame coordinate) is valid in
        // it immediately. Only when there is nothing to inherit do we release
        // the camera and let reaching cold-start.
        let liveSession = manager.detachLiveSessionForHandoff(reason: "manual_arrival_reaching")
        if liveSession == nil {
            manager.stopMapping()
        }

        ReachingModule.launchSpatialTargetReaching(
            targetName: objectName,
            routeMapId: mapId,
            routeMapName: mapName,
            targetWorldPosition: objectPosition,
            liveSession: liveSession,
            voiceOverEnabled: launchVoiceOverEnabled,
            onFailure: { _, message, _ in
                DispatchQueue.main.async {
                    manager.statusMessage = message
                    speech.speakPriority("Reaching could not start. \(message)")
                }
            },
            onDone: { result in
                DispatchQueue.main.async {
                    let reason = result["reason"] as? String
                    manager.statusMessage = reason == "user_confirmed"
                        ? "Reaching complete for \(objectName)."
                        : "Reaching session ended."
                }
            }
        )
    }

    private func reachingObjectWorldPosition(for objectName: String) -> simd_float3? {
        let normalizedTarget = normalizedRouteLookupKey(objectName)
        return mappingManager.mapPOIs.first(where: { name, _ in
            normalizedRouteLookupKey(name) == normalizedTarget
        })?.value
    }

    private func handleSessionModeChanged() {
        didSeedIMUBearing = false
        seedIMUBearingIfNeeded(mappingManager.arHeadingDegrees)
    }

    private func handleLocalizationChanged(_ isLocalized: Bool) {
        // A warm session is only reusable while it is actually localized;
        // losing tracking must force the next leg back through a normal
        // (re)localizing launch instead of silently retargeting a lost pose.
        navigationSession.isWarm = isLocalized && isAutomatedNavigation
        guard isLocalized else { return }
        // The search this screen was holding the session warm for succeeded.
        navigationSession.isSearching = false
        relocalizationSearchStartedAt = nil
        didSeedIMUBearing = false
        seedIMUBearingIfNeeded(mappingManager.arHeadingDegrees)
        attemptAutomatedNavigationIfNeeded()
    }

    private func handleARHeadingChanged(_ heading: Double?) {
        seedIMUBearingIfNeeded(heading)
    }

    private func handleSelectedMapChanged() {
        if let selectedSavedMap {
            mapName = selectedSavedMap.name
        }
        attemptAutomatedNavigationIfNeeded()
    }

    private func handleActiveMapNameChanged(_ newValue: String?) {
        guard let newValue,
              !newValue.isEmpty else {
            return
        }
        mapName = newValue
    }

    private func handleActiveMapIDChanged(_ newValue: String?) {
        if let newValue, newValue == requestedARMapLoadID {
            requestedARMapLoadID = nil
        }
        semanticNavigator.linkActiveRouteToARWorldMap(id: newValue)
        attemptAutomatedNavigationIfNeeded()
    }

    private func handleClosestPOIChanged(_ newValue: String?) {
        guard let newValue,
              !newValue.isEmpty,
              sourceSelection != newValue else {
            return
        }
        sourceSelection = newValue
    }

    private func handleIMUStateChanged(_ imuState: IMUState) {
        mappingManager.updateIMUMotion(imuState)
        tickAutomatedRelocalizationWatchdog()
        semanticNavigator.update(
            imuState: imuState,
            arPosition: mappingManager.cameraMapPosition,
            arHeading: mappingManager.arHeadingDegrees,
            arLocalized: mappingManager.isLocalized || mappingManager.isMapping,
            capturedImage: currentCapturedImage
        )
    }

    /// Runs on the IMU heartbeat while the automated flow waits for
    /// relocalization. Nothing else speaks in that window — the coaching
    /// overlay is a visual icon — so this narrates the wait for a blind user
    /// and resolves the automation with a failure once the wait is hopeless.
    private func tickAutomatedRelocalizationWatchdog() {
        guard isAutomatedNavigation,
              didResolveAutomation == false,
              didStartAutomatedGuidance == false,
              didAttemptAutomatedRouteSelection,
              mappingManager.sessionMode == .relocalizing,
              mappingManager.isLocalized == false else {
            automatedRelocalizationStartedAt = nil
            lastRelocalizationVoiceCueAt = nil
            relocalizationVoiceCueCount = 0
            didReportSlowRelocalization = false
            return
        }

        let now = Date()
        if relocalizationSearchStartedAt == nil {
            relocalizationSearchStartedAt = now
        }
        navigationSession.isSearching = true
        guard let startedAt = automatedRelocalizationStartedAt else {
            automatedRelocalizationStartedAt = now
            return
        }

        let searchedFor = now.timeIntervalSince(relocalizationSearchStartedAt ?? now)

        // Out of patience for real. Nothing is left to search with, so end the
        // automation and let the screen come down.
        if searchedFor >= automatedRelocalizationWarmBudgetSeconds {
            navigationSession.isSearching = false
            resolveAutomation(
                success: false,
                reason: "relocalization_failed",
                message: NavLoc.relocFailedMessage()
            )
            return
        }

        // ⚠️ This used to RESOLVE the automation here, as a failure, while
        // deliberately leaving ARKit searching — the idea being that the user
        // would ask again and retarget the warm session. Resolving latches
        // `didResolveAutomation`, and that latch is what
        // `attemptAutomatedNavigationIfNeeded` checks first, so the search we
        // had just kept alive could no longer start anything. The 25 Aug 2026
        // lab test hit exactly that, twice: the timeout fired at 35 s and ARKit
        // localized 2.8 s and 0.85 s later, both times into a screen that would
        // no longer build a route. The trace shows `ar.localized` with no
        // `nav.start` after it, and the participant standing at 421 being told
        // to turn in a full circle until they tapped out.
        //
        // So it only SPEAKS now. The session stays searching, the automation
        // stays live, and a relocalization that lands one second past the mark
        // starts the journey the way one that landed a second before it would.
        if now.timeIntervalSince(startedAt) >= automatedRelocalizationTimeoutSeconds,
           didReportSlowRelocalization == false {
            didReportSlowRelocalization = true
            announceAutomatedStatus(NavLoc.relocStillSearchingMessage())
            lastRelocalizationVoiceCueAt = now
            return
        }

        let sinceCue = lastRelocalizationVoiceCueAt.map { now.timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        guard sinceCue >= relocalizationVoiceCueIntervalSeconds else { return }
        lastRelocalizationVoiceCueAt = now
        relocalizationVoiceCueCount += 1

        // When the camera recognizes a mapped place, say so. The visual match is
        // pose-independent and lands well before ARKit's world-map match, so this
        // is the difference between "it knows where I am, keep going" and
        // standing in a store being told to pan at nothing.
        let cue: String
        if let recognized = mappingManager.recognizedPlaceName {
            cue = NavLoc.relocRecognizedPlaceCue(recognized)
        } else if relocalizationVoiceCueCount == 1,
                  let origin = Self.freshConfirmedPlaceName,
                  let destination = automatedTargetName,
                  origin.caseInsensitiveCompare(destination) != .orderedSame {
            // The app is not starting from nothing here and should not sound
            // like it is. This leg begins where the last one ended — the user
            // was told "Arrived at 421" a minute ago and has not walked away —
            // so the opening cue states that, names where they asked to go, and
            // only then asks for the pan. "Pan left and right" with no subject
            // was the participant's complaint on 25 Aug 2026: the app plainly
            // knew where they were standing and gave no sign of it.
            //
            // What it does NOT do is skip the relocalization. Knowing the place
            // is not the same as holding the map frame, and assuming the pose
            // is how a route ends up built from somewhere the user is not.
            cue = NavLoc.relocResumingFromCue(origin: origin, destination: destination)
            Self.hasCoachedRelocalization = true
        } else if Self.hasCoachedRelocalization {
            // Already coached earlier in this run. The first interval passes in
            // silence — a relocalization that resolves inside it never needed
            // narrating — and anything after it escalates straight to the cues
            // that ask for something new.
            switch relocalizationVoiceCueCount {
            case 1:
                return
            case 2:
                cue = NavLoc.relocPanBriefCue()
            case 3:
                cue = NavLoc.relocTurnFullCircleCue()
            default:
                cue = NavLoc.relocStepAndTurnCue()
            }
        } else {
            switch relocalizationVoiceCueCount {
            case 1:
                cue = NavLoc.relocLoadingCue()
                Self.hasCoachedRelocalization = true
            case 2:
                cue = NavLoc.relocTurnFullCircleCue()
            default:
                cue = NavLoc.relocStepAndTurnCue()
            }
        }
        announceAutomatedStatus(cue)
    }

    /// Speaks automation status through the same VoiceOver-aware channel as
    /// semantic cues so announcements are not doubled for screen-reader users.
    private func announceAutomatedStatus(_ text: String) {
        if launchVoiceOverEnabled {
            UIAccessibility.post(notification: .announcement, argument: text)
            return
        }
        ttsManager.speakPriority(text)
    }

    private func handleSpeechCueChanged() {
        speakSemanticCue(semanticNavigator.speechCue)
    }

    private func confirmDeleteSelectedMap() {
        guard let id = mappingManager.selectedMapID else {
            return
        }

        mappingManager.deleteMap(id: id)
        mapName = mappingManager.selectedMapID.flatMap { id in
            mappingManager.savedMaps.first(where: { $0.id == id })?.name
        } ?? mappingManager.suggestedMapName()
    }

    private func seedIMUBearingIfNeeded(_ heading: Double?) {
        guard let heading,
              mappingManager.sessionMode != .idle,
              didSeedIMUBearing == false else {
            return
        }

        sensorManager.setInitialBearing(heading)
        mappingManager.updateIMUMotion(sensorManager.imuState)
        didSeedIMUBearing = true
    }

    /// The leg currently being guided. The shared session wins over the
    /// launch value so a retargeted second leg guides to the NEW destination
    /// while the same screen and AR session stay mounted.
    private var automatedTargetName: String? {
        let live = navigationSession.activeTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !live.isEmpty { return live }
        let trimmed = launchTargetName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private var isAutomatedNavigation: Bool {
        automatedTargetName != nil
    }

    private var automatedAccent: Color {
        Color(red: 0.18, green: 0.72, blue: 0.62)
    }

    private func attemptAutomatedNavigationIfNeeded() {
        guard let target = automatedTargetName,
              didResolveAutomation == false else {
            return
        }

        if didAttemptAutomatedRouteSelection == false {
            didAttemptAutomatedRouteSelection = true
            semanticNavigator.loadMaps()

            let allMaps = semanticNavigator.maps
            guard !allMaps.isEmpty else {
                resolveAutomation(
                    success: false,
                    reason: "map_not_found",
                    message: "No saved AR route maps were found."
                )
                return
            }

            guard let route = bestAutomatedRoute(for: target, in: allMaps) else {
                resolveAutomation(
                    success: false,
                    reason: "target_not_found",
                    message: "\(target) is not in the saved AR route maps."
                )
                return
            }

            semanticNavigator.useMap(id: route.id)
            mapName = route.name

            guard let arWorldMapId = route.arWorldMapId, !arWorldMapId.isEmpty else {
                resolveAutomation(
                    success: false,
                    reason: "map_not_found",
                    routeName: route.name,
                    message: "The route \(route.name) is not linked to a saved ARWorldMap."
                )
                return
            }

            guard mappingManager.savedMaps.contains(where: { $0.id == arWorldMapId }) else {
                resolveAutomation(
                    success: false,
                    reason: "map_not_found",
                    routeName: route.name,
                    message: "The ARWorldMap for \(route.name) was not found on this device."
                )
                return
            }

            if mappingManager.selectedMapID != arWorldMapId {
                mappingManager.selectedMapID = arWorldMapId
            }
            // A retargeted leg keeps a live session, so "already relocalizing"
            // is no longer a reason to skip the load: when the new target
            // lives in a DIFFERENT world map, that map must still be loaded
            // or guidance would wait forever on a map it will never match.
            // `requestedARMapLoadID` keeps the async load from being fired
            // twice while activeMapID is still catching up.
            if mappingManager.activeMapID != arWorldMapId,
               requestedARMapLoadID != arWorldMapId {
                requestedARMapLoadID = arWorldMapId
                loadSelectedMap()
            }
            return
        }

        guard didStartAutomatedGuidance == false,
              let activeRoute = semanticNavigator.activeMap else {
            return
        }

        if let requiredARMapID = activeRoute.arWorldMapId,
           mappingManager.activeMapID != requiredARMapID {
            return
        }

        guard mappingManager.cameraMapPosition != nil,
              mappingManager.isLocalized || mappingManager.isMapping else {
            return
        }

        let didStart = semanticNavigator.startNavigation(
            to: target,
            arPosition: mappingManager.cameraMapPosition,
            imuState: sensorManager.imuState,
            activeARWorldMapID: mappingManager.activeMapID,
            speakLandmarks: launchSpeakLandmarks,
            errorRecovery: launchErrorRecovery,
            clockFaceDirections: launchClockFaceDirections,
            arHeading: mappingManager.arHeadingDegrees
        )

        if didStart {
            didStartAutomatedGuidance = true
            // They are about to walk away from it.
            Self.lastConfirmedPlaceName = nil
            Self.lastConfirmedPlaceAt = nil
        } else {
            let lower = semanticNavigator.currentInstruction.lowercased()
            let reason: String
            if lower.contains("not in this semantic map") {
                reason = "target_not_found"
            } else if lower.contains("can't confirm you are at") {
                reason = "arrival_unverified"
            } else {
                reason = "relocalization_failed"
            }
            resolveAutomation(
                success: false,
                reason: reason,
                routeName: activeRoute.name,
                message: semanticNavigator.currentInstruction
            )
        }
    }

    private func bestAutomatedRoute(for target: String, in maps: [SemanticRouteMap]) -> SemanticRouteMap? {
        let normalizedTarget = normalizedRouteLookupKey(target)

        // The pinned map is a preference, not a filter: when the requested
        // target lives in a different saved map, switch to that map instead
        // of failing the session (pilot: querying cereal with the produce
        // map selected ended guidance).
        let pinned: [SemanticRouteMap] = [
            launchRouteMapId.flatMap { id in maps.first { $0.id == id } },
            launchRouteMapName.flatMap { name in
                maps.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            }
        ].compactMap { $0 }
        let ordered = pinned + maps.filter { candidate in
            !pinned.contains { $0.id == candidate.id }
        }

        // A map where the target is a DESTINATION was captured walking toward
        // it — its keyframes face the walking direction and its start is where
        // the user is coming from. A map that merely CONTAINS the target as its
        // start node would relocalize at the far end and guide a zero-length
        // route. With directional map pairs (A→B saved separately from B→A)
        // every target exists in both maps, so this preference is what picks
        // the map that can actually guide there; `maps.first` was a coin flip.
        if let toward = ordered.first(where: { routeGuidesToward($0, normalizedTarget: normalizedTarget) }) {
            return toward
        }

        if let contains = ordered.first(where: { routeContainsTarget($0, normalizedTarget: normalizedTarget) }) {
            return contains
        }

        // Fuzzy fallback for ASR noise: "serial" must still find the map
        // holding "cereal" — and the same toward-preference applies.
        if let towardFuzzy = ordered.first(where: {
            routeGuidesTowardFuzzily($0, target: target)
        }) {
            return towardFuzzy
        }
        return ordered.first(where: { routeContainsTargetFuzzily($0, target: target) })
    }

    /// True when the target is one of this route's DESTINATIONS — a place the
    /// capture walk ended at, which is the direction the map can guide.
    private func routeGuidesToward(_ route: SemanticRouteMap, normalizedTarget: String) -> Bool {
        let destinationIDs = destinationNodeIDs(of: route)
        return route.nodes.contains { node in
            destinationIDs.contains(node.id) && (
                normalizedRouteLookupKey(node.name) == normalizedTarget ||
                node.aliases.contains { normalizedRouteLookupKey($0) == normalizedTarget }
            )
        } || route.landmarks.contains { landmark in
            destinationIDs.contains(landmark.nodeID) && (
                normalizedRouteLookupKey(landmark.name) == normalizedTarget ||
                landmark.aliases.contains { normalizedRouteLookupKey($0) == normalizedTarget }
            )
        }
    }

    private func routeGuidesTowardFuzzily(_ route: SemanticRouteMap, target: String) -> Bool {
        let destinationIDs = destinationNodeIDs(of: route)
        return route.nodes.contains { node in
            destinationIDs.contains(node.id) && (
                SemanticRouteNavigator.fuzzyMatchesSpokenTarget(node.name, target) ||
                node.aliases.contains { SemanticRouteNavigator.fuzzyMatchesSpokenTarget($0, target) }
            )
        } || route.landmarks.contains { landmark in
            destinationIDs.contains(landmark.nodeID) && (
                SemanticRouteNavigator.fuzzyMatchesSpokenTarget(landmark.name, target) ||
                landmark.aliases.contains { SemanticRouteNavigator.fuzzyMatchesSpokenTarget($0, target) }
            )
        }
    }

    private func destinationNodeIDs(of route: SemanticRouteMap) -> Set<String> {
        var ids = Set(route.nodes.filter { $0.kind == .destination }.map(\.id))
        for id in route.destinationNodeIds ?? [] {
            ids.insert(id)
        }
        return ids
    }

    private func routeContainsTargetFuzzily(_ route: SemanticRouteMap, target: String) -> Bool {
        route.nodes.contains { node in
            SemanticRouteNavigator.fuzzyMatchesSpokenTarget(node.name, target) ||
            node.aliases.contains { SemanticRouteNavigator.fuzzyMatchesSpokenTarget($0, target) }
        } ||
        route.landmarks.contains { landmark in
            SemanticRouteNavigator.fuzzyMatchesSpokenTarget(landmark.name, target) ||
            landmark.aliases.contains { SemanticRouteNavigator.fuzzyMatchesSpokenTarget($0, target) }
        }
    }

    private func routeContainsTarget(_ route: SemanticRouteMap, normalizedTarget: String) -> Bool {
        route.targetNames.contains { normalizedRouteLookupKey($0) == normalizedTarget } ||
        route.nodes.contains { node in
            normalizedRouteLookupKey(node.name) == normalizedTarget ||
            node.aliases.contains { normalizedRouteLookupKey($0) == normalizedTarget }
        } ||
        route.landmarks.contains { landmark in
            normalizedRouteLookupKey(landmark.name) == normalizedTarget ||
            landmark.aliases.contains { normalizedRouteLookupKey($0) == normalizedTarget }
        }
    }

    private func normalizedRouteLookupKey(_ raw: String) -> String {
        let tokens = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        return canonicalizedRouteLookupTokens(Array(meaningfulTokens)).joined(separator: " ")
    }

    private func canonicalizedRouteLookupTokens(_ tokens: [String]) -> [String] {
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

    private func resolveAutomation(
        success: Bool,
        reason: String,
        routeName: String? = nil,
        message: String? = nil,
        messageSpoken: Bool = false
    ) {
        guard didResolveAutomation == false else { return }
        didResolveAutomation = true
        let reachingObjectName = success && reason == "arrived"
            ? arrivedReachingObjectName
            : nil
        var result = ARKitNavigationNativeResult(
            success: success,
            reason: reason,
            targetName: automatedTargetName,
            routeMapId: mappingManager.activeMapID ?? semanticNavigator.activeMap?.arWorldMapId,
            routeName: routeName ?? semanticNavigator.activeMap?.name,
            targetWorldPosition: automatedTargetWorldPosition(),
            reachingObjectName: reachingObjectName,
            reachingObjectWorldPosition: reachingObjectName.flatMap { reachingObjectWorldPosition(for: $0) },
            message: message
        )
        // Whether the session survives this result is `ARKitNavigationModule`'s
        // call, not this screen's: it owns the JS-supplied `keepSessionAlive`
        // config and the presented-controller state that decides it.
        result.messageSpoken = messageSpoken

        // Automated arrival with a reaching object: this screen is about to be
        // torn down, JS speaks the switch-over line, and only then calls back
        // through the bridge to start reaching. Park the live, relocalized
        // session in the handoff holder so reaching inherits it across that
        // gap instead of cold-relocalizing the map at the shelf (which is what
        // stalled and timed out). Unclaimed offers pause themselves.
        if reachingObjectName != nil,
           let live = mappingManager.detachLiveSessionForHandoff(reason: "automated_arrival_reaching") {
            ARLiveSessionHandoff.shared.offer(session: live, mapID: mappingManager.activeMapID)
        }

        onAutomationComplete?(result)
    }

    private func automatedTargetWorldPosition() -> simd_float3? {
        guard let target = automatedTargetName else { return nil }
        let normalizedTarget = normalizedRouteLookupKey(target)

        if let direct = mappingManager.mapPOIs.first(where: { name, _ in
            normalizedRouteLookupKey(name) == normalizedTarget
        }) {
            return direct.value
        }

        guard let route = semanticNavigator.activeMap else { return nil }
        let nodeAliases = route.nodes
            .filter { node in
                normalizedRouteLookupKey(node.name) == normalizedTarget ||
                node.aliases.contains { normalizedRouteLookupKey($0) == normalizedTarget }
            }
            .flatMap { [$0.name] + $0.aliases }
        let landmarkAliases = route.landmarks
            .filter { landmark in
                normalizedRouteLookupKey(landmark.name) == normalizedTarget ||
                landmark.aliases.contains { normalizedRouteLookupKey($0) == normalizedTarget }
            }
            .flatMap { [$0.name] + $0.aliases }
        let aliases = nodeAliases + landmarkAliases

        for alias in aliases {
            let normalizedAlias = normalizedRouteLookupKey(alias)
            if let match = mappingManager.mapPOIs.first(where: { name, _ in
                normalizedRouteLookupKey(name) == normalizedAlias
            }) {
                return match.value
            }
        }

        return nil
    }

    private var headerHUD: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 8, height: 8)

                Text(statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsMapInspector.toggle()
                    }
                } label: {
                    Image(systemName: showsMapInspector ? "cube.transparent.fill" : "cube.transparent")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 32, height: 28)
                        .foregroundColor(.white.opacity(0.9))
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityLabel(showsMapInspector ? "Hide map inspector" : "Show map inspector")

                if let closestPOI = mappingManager.closestPOI {
                    Label(closestPOI, systemImage: "location.viewfinder")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } else if let poiMatchStatusText = mappingManager.poiMatchStatusText {
                    Text(poiMatchStatusText)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            if !mappingManager.currentPositionText.isEmpty {
                Text(mappingManager.currentPositionText)
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .foregroundColor(.white.opacity(0.82))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message = mappingManager.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.68))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let activeMapName = mappingManager.activeMapName {
                Label(activeMapName, systemImage: "folder")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.52))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if shouldShowPOIEditor {
                poiEditorStrip
            }

            if mappingManager.sessionMode == .idle {
                idleControls
            } else {
                mapNameInput
                if canPinPOI {
                    poiInput
                }
                activeControls
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.62))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var routeBottomSheet: some View {
        if isAutomatedNavigation {
            automatedNavigationPanel
        } else {
            SemanticNavigationPanel(
                navigator: semanticNavigator,
                mapName: $mapName,
                arStatusText: statusText,
                activeARMapName: mappingManager.activeMapName,
                activeARWorldMapID: mappingManager.activeMapID,
                enrichmentBlockedReason: enrichmentBlockedReason,
                closestPOI: mappingManager.closestPOI,
                savedARMaps: mappingManager.savedMaps,
                selectedARMapID: mappingManager.selectedMapID,
                canUseARPose: mappingManager.cameraMapPosition != nil && (mappingManager.isMapping || mappingManager.isLocalized),
                isARSessionActive: mappingManager.sessionMode != .idle,
                isSavingARMap: mappingManager.isSavingMap,
                selectARMap: { id in
                    mappingManager.selectedMapID = id
                },
                startARMapping: startNewMap,
                loadARMap: loadSelectedMap,
                deleteARMap: {
                    confirmDeleteSelectedMap()
                },
                saveARMap: { mappingManager.saveMap(named: mapName) },
                stopARSession: { mappingManager.stopMapping() },
                beginWalkthrough: beginSemanticWalkthrough,
                captureStart: captureSemanticStart,
                captureTurn: captureSemanticTurn,
                captureLandmark: captureSemanticLandmark,
                captureReachingObject: captureSemanticReachingObject,
                saveWalkthrough: saveSemanticWalkthrough,
                startNavigation: startSemanticNavigation,
                snapToRoute: snapSemanticNavigationToRoute,
                startReachingHandoff: startReachingHandoff,
                beginEnrichmentWalk: beginSemanticEnrichmentWalk,
                finishEnrichmentWalk: finishSemanticEnrichmentWalk,
                cancelEnrichmentWalk: { semanticNavigator.cancelEnrichmentWalk() }
            )
        }
    }

    /// Deliberately compact. This panel sits over the bottom third of the
    /// screen, which is precisely where the floor two to five metres ahead is
    /// rendered — the stretch of route the AR overlay draws. A tall panel hides
    /// the guidance it is describing, so everything here earns its height: the
    /// live instruction, one status line, and the log export the field workflow
    /// depends on. The destination and screen title live in the nav bar.
    private var automatedNavigationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "location.north.line.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(automatedAccent)

                Text(automatedTargetName ?? "Destination")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer(minLength: 0)

                Button {
                    exportSessionTrace()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.white.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .accessibilityLabel("Export session log")
                .accessibilityHint("Shares a log of this guidance run and the mapping walk behind it.")
            }

            Text(semanticNavigator.currentInstruction)
                .font(.headline.weight(.semibold))
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Label(routeAwareStatusText, systemImage: routeAwareStatusIcon)
                    .foregroundColor(routeAwareStatusTint)

                if let activeMapName = mappingManager.activeMapName ?? semanticNavigator.activeMap?.name {
                    Text(activeMapName)
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }
            .font(.caption.weight(.semibold))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.18, blue: 0.18).opacity(0.96),
                    Color(red: 0.04, green: 0.32, blue: 0.28).opacity(0.94)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(automatedAccent.opacity(0.34), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.24), radius: 20, x: 0, y: 10)
    }

    private func exportSessionTrace() {
        guard let url = NavigationTrace.shared.exportURL(),
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = top.view
        activity.popoverPresentationController?.sourceRect = CGRect(
            x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1
        )
        top.present(activity, animated: true)
    }

    private var idleControls: some View {
        VStack(spacing: 10) {
            mapNameInput

            Button(action: startNewMap) {
                Label("Start Mapping", systemImage: "map")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ARControlButtonStyle(prominence: .primary))

            savedMapControls
        }
    }

    private var mapNameInput: some View {
        TextField("Map name", text: $mapName)
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .padding(.vertical, 11)
            .padding(.horizontal, 12)
            .foregroundColor(.white)
            .background(Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.14), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var savedMapControls: some View {
        VStack(spacing: 10) {
            if mappingManager.savedMaps.isEmpty {
                Text("No saved maps")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white.opacity(0.62))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Saved map", selection: selectedMapBinding) {
                    ForEach(mappingManager.savedMaps) { map in
                        Text(mapLabel(for: map)).tag(map.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(.white)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Button(action: loadSelectedMap) {
                        Label("Load Map", systemImage: "location.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ARControlButtonStyle(prominence: .secondary))

                    Button(action: confirmDeleteSelectedMap) {
                        Label("Delete", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ARControlButtonStyle(prominence: .secondary))
                    .disabled(mappingManager.selectedMapID == nil)
                }
            }
        }
    }

    private var poiInput: some View {
        HStack(spacing: 10) {
            TextField("POI name", text: $newPOIName)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .padding(.vertical, 11)
                .padding(.horizontal, 12)
                .foregroundColor(.white)
                .background(Color.white.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button(action: pinPOI) {
                Label("Pin", systemImage: "mappin.and.ellipse")
            }
            .buttonStyle(ARControlButtonStyle(prominence: .compact))
            .disabled(trimmedPOIName.isEmpty)

            Button(action: samplePOI) {
                Label("Sample", systemImage: "camera.viewfinder")
            }
            .buttonStyle(ARControlButtonStyle(prominence: .compact))
            .disabled(!canSamplePOI)
        }
    }

    private var activeControls: some View {
        HStack(spacing: 10) {
            Button(action: { mappingManager.saveMap(named: mapName) }) {
                Label(mappingManager.isSavingMap ? "Saving" : saveButtonTitle, systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ARControlButtonStyle(prominence: .primary))
            .disabled(mappingManager.isSavingMap)

            Button(action: { mappingManager.stopMapping() }) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ARControlButtonStyle(prominence: .secondary))
        }
    }

    private var mapInspectorPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Map Inspector", systemImage: "cube.transparent")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()

                inspectorBadge("\(mappingManager.mapFeaturePointCount)", label: "points")
                inspectorBadge("\(mappingManager.poiInspectionList.count)", label: "POIs")
            }

            ARMapSceneView(
                featurePoints: mappingManager.mapFeaturePoints,
                pois: mappingManager.poiInspectionList,
                cameraPosition: mappingManager.cameraMapPosition,
                cameraForward: mappingManager.cameraMapForward,
                emphasizesFeaturePoints: mappingManager.isMapping
            )
            .frame(height: mapInspectorHeight)
            .background(Color.black.opacity(0.36))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                metricPill(title: "Span", value: mapSpanText)
                metricPill(title: "Density", value: mapDensityText)
                metricPill(title: "Samples", value: "\(totalVisualSamples)")
            }

            if !mappingManager.localizationCandidates.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(mappingManager.localizationCandidates.prefix(4)) { candidate in
                            candidatePill(candidate)
                        }
                    }
                }
            }

            if !mappingManager.poiRelocalizationCounts.isEmpty {
                anchorStatusRow
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.52))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Per-endpoint feature density behind the save-time relocalization gate.
    /// A weak (orange) POI is the one that will stall on "pan around" when a
    /// journey later starts from it — anchor it and re-save.
    private var anchorStatusRow: some View {
        let counts = mappingManager.poiRelocalizationCounts
        let weak = Set(mappingManager.weakRelocalizationPOIs)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: weak.isEmpty ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundColor(weak.isEmpty ? .green.opacity(0.85) : .orange)
                Text(weak.isEmpty
                     ? "Endpoints anchored for relocalization"
                     : "Weak anchor — stand there, turn a full circle, then re-save")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(counts.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        anchorPill(name: entry.key, count: entry.value, isWeak: weak.contains(entry.key))
                    }
                }
            }
        }
    }

    private func anchorPill(name: String, count: Int, isWeak: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
            Text("\(count) pts")
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
        }
        .foregroundColor(isWeak ? .orange : .white.opacity(0.82))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background((isWeak ? Color.orange : Color.white).opacity(isWeak ? 0.16 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func inspectorBadge(_ value: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(.caption2, design: .monospaced).weight(.bold))
            Text(label)
                .font(.caption2.weight(.medium))
        }
        .foregroundColor(.white.opacity(0.78))
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(Color.white.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metricPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundColor(.white.opacity(0.56))
                .lineLimit(1)
            Text(value)
                .font(.system(.caption2, design: .monospaced).weight(.semibold))
                .foregroundColor(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func candidatePill(_ candidate: ARLocalizationCandidate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(candidate.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if candidate.hasVisualEvidence {
                    Image(systemName: "camera.viewfinder")
                        .font(.caption2.weight(.bold))
                }
            }

            Text(String(format: "%.0f%% - %.0fm", candidate.confidence * 100, candidate.distance))
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundColor(.white.opacity(0.62))
                .lineLimit(1)
        }
        .foregroundColor(.white.opacity(0.86))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .frame(width: 126, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var poiEditorStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("POI Evidence", systemImage: "mappin.and.ellipse")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.84))

                Spacer()

                Text("\(totalVisualSamples) samples")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white.opacity(0.58))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(mappingManager.poiInspectionList) { poi in
                        poiEditorCard(for: poi)
                    }
                }
            }
        }
    }

    private func poiEditorCard(for poi: ARMapPOIInspection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(poi.name)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 6)

                Text("\(poi.visualSampleCount)x")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundColor(poi.visualSampleCount > 0 ? Color(red: 0.56, green: 0.84, blue: 0.78) : Color(red: 0.96, green: 0.72, blue: 0.46))
            }

            Text(coordinateText(for: poi.position))
                .font(.system(.caption2, design: .monospaced).weight(.medium))
                .foregroundColor(.white.opacity(0.58))
                .lineLimit(1)

            HStack(spacing: 7) {
                poiActionButton(systemImage: "scope", label: "Re-anchor \(poi.name)") {
                    reanchorPOI(poi.name)
                }
                .disabled(!canEditPOIs)

                poiActionButton(systemImage: "camera.viewfinder", label: "Retake visual sample for \(poi.name)") {
                    retakePOIFrame(poi.name)
                }
                .disabled(!canEditPOIs)

                poiActionButton(systemImage: "trash", label: "Delete \(poi.name)") {
                    mappingManager.deletePOI(named: poi.name)
                }
                .disabled(!canEditPOIs)
            }
        }
        .padding(10)
        .frame(width: 202, alignment: .leading)
        .background(Color.white.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(poi.hasAnchor ? 0.14 : 0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func poiActionButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .frame(width: 32, height: 30)
        }
        .buttonStyle(POIActionButtonStyle())
        .accessibilityLabel(label)
    }

    private func pinPOI() {
        mappingManager.addPOIAnchor(name: newPOIName)
    }

    private func samplePOI() {
        if mappingManager.addVisualSample(name: newPOIName) {
            newPOIName = ""
        }
    }

    private func reanchorPOI(_ name: String) {
        newPOIName = name
        mappingManager.addPOIAnchor(name: name)
    }

    private func retakePOIFrame(_ name: String) {
        newPOIName = name
        mappingManager.retakeVisualSample(name: name)
    }

    private func beginSemanticWalkthrough(_ requestedName: String) {
        // Relocalized into a saved map → extend that map's semantic network
        // instead of starting a parallel one-way map. One store area, one
        // map: new trails stitch onto the existing route graph.
        if mappingManager.sessionMode != .idle,
           mappingManager.isLocalized,
           let activeARMapID = mappingManager.activeMapID,
           let existingRoute = semanticNavigator.maps.first(where: { $0.arWorldMapId == activeARMapID }) {
            mapName = existingRoute.name
            semanticNavigator.beginRouteCaptureAppending(toMapID: existingRoute.id)
            return
        }

        let resolvedName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? mappingManager.suggestedMapName()
            : requestedName
        if mappingManager.sessionMode == .idle {
            mapName = resolvedName
            mappingManager.startMapping()
        }
        semanticNavigator.beginRouteCapture(named: resolvedName)
    }

    private func captureSemanticStart(_ name: String) {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? mappingManager.closestPOI ?? sourceSelection.nilIfRouteBlank ?? "Start"
            : name
        capturePOIEvidence(named: resolvedName)
        semanticNavigator.captureStart(
            named: resolvedName,
            arPosition: mappingManager.cameraMapPosition,
            arHeading: mappingManager.arHeadingDegrees,
            imuState: sensorManager.imuState,
            capturedImage: currentCapturedImage
        )
        sourceSelection = resolvedName
    }

    private func captureSemanticLandmark(_ name: String, side: SemanticRouteSide, context: String, isDestination: Bool) {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedName.isEmpty else { return }
        capturePOIEvidence(named: resolvedName)
        let didCapture = semanticNavigator.captureLandmark(
            named: name,
            side: side,
            context: context,
            arPosition: mappingManager.cameraMapPosition,
            capturedImage: currentCapturedImage,
            isDestination: isDestination
        )
        if didCapture, isDestination {
            sourceSelection = resolvedName
        }
    }

    private func captureSemanticReachingObject(_ name: String) {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolvedName.isEmpty else { return }
        // Surface-pin the object into the ARWorldMap first — spatial-target
        // reaching resolves this exact anchor by name after relocalizing.
        capturePOIEvidence(named: resolvedName)
        semanticNavigator.attachReachingObject(
            named: resolvedName,
            capturedImage: currentCapturedImage
        )
    }

    private func captureSemanticRoutePoint(_ name: String) {
        semanticNavigator.captureRoutePoint(
            named: name,
            arPosition: mappingManager.cameraMapPosition,
            arHeading: mappingManager.arHeadingDegrees,
            imuState: sensorManager.imuState,
            capturedImage: currentCapturedImage
        )
    }

    private func captureSemanticTurn(_ hint: SemanticTurnHint) {
        semanticNavigator.captureTurn(
            hint,
            arPosition: mappingManager.cameraMapPosition,
            arHeading: mappingManager.arHeadingDegrees,
            imuState: sensorManager.imuState,
            capturedImage: currentCapturedImage
        )
    }

    private func saveSemanticWalkthrough() {
        guard semanticNavigator.saveCapturedMap() else { return }

        guard mappingManager.sessionMode != .idle else { return }
        let resolvedName = semanticNavigator.activeMap?.name ?? mapName
        mapName = resolvedName
        mappingManager.saveMap(named: resolvedName)
    }

    private func startSemanticNavigation(_ target: String, speakLandmarks: Bool, errorRecovery: Bool) {
        semanticNavigator.startNavigation(
            to: target,
            arPosition: mappingManager.cameraMapPosition,
            imuState: sensorManager.imuState,
            activeARWorldMapID: mappingManager.activeMapID,
            speakLandmarks: speakLandmarks,
            errorRecovery: errorRecovery,
            clockFaceDirections: launchClockFaceDirections,
            arHeading: mappingManager.arHeadingDegrees
        )
    }

    private func snapSemanticNavigationToRoute() {
        semanticNavigator.snapToNearestGraphPose(
            arPosition: mappingManager.cameraMapPosition,
            imuState: sensorManager.imuState
        )
    }

    /// nil when an enrichment walk can begin right now, otherwise the reason
    /// it cannot — shown on the button and spoken, never swallowed.
    ///
    /// A session that just *mapped* the route needs no relocalization: it is
    /// already in the route's own frame, and that is the best moment to walk
    /// it back. Only a session that loaded a saved map has to localize first.
    private var enrichmentBlockedReason: String? {
        switch mappingManager.sessionMode {
        case .idle:
            return "Start or load this route's AR map first, then walk it back."
        case .relocalizing where !mappingManager.isLocalized:
            return "Waiting to localize against the saved map. Pan slowly across the shelves you mapped."
        case .relocalizing, .mapping:
            break
        }
        if mappingManager.cameraMapPosition == nil {
            return "Waiting for AR tracking. Move the phone slowly until tracking recovers."
        }
        return nil
    }

    private func beginSemanticEnrichmentWalk(routeID: String) {
        guard let route = semanticNavigator.maps.first(where: { $0.id == routeID }) else { return }
        if let reason = enrichmentBlockedReason {
            mappingManager.statusMessage = reason
            speakSemanticCue(SemanticSpeechCue(text: reason, priority: .priority))
            return
        }
        // Samples are poses in the loaded map's frame. Appending them to a
        // route captured in a different frame would corrupt that route.
        guard route.arWorldMapId == mappingManager.activeMapID else {
            let reason = "Load the AR map linked to \(route.name) before improving it."
            mappingManager.statusMessage = reason
            speakSemanticCue(SemanticSpeechCue(text: reason, priority: .priority))
            return
        }
        semanticNavigator.beginEnrichmentWalk(mapID: route.id)
    }

    /// Persists the enrichment pass. The ARWorldMap is re-saved from the SAME
    /// live session, so `getCurrentWorldMap` returns the original features
    /// plus everything ARKit observed while walking back — which is what makes
    /// reverse-direction relocalization work. Re-saving keeps the existing map
    /// id (ARMapStore replaces by metadata), so the route's arWorldMapId link
    /// and every pinned POI anchor survive.
    private func finishSemanticEnrichmentWalk() {
        guard semanticNavigator.finishEnrichmentWalk() else { return }
        guard mappingManager.sessionMode != .idle else { return }
        let resolvedName = mappingManager.activeMapName ?? semanticNavigator.activeMap?.name ?? mapName
        mappingManager.saveMap(named: resolvedName)
    }

    private func capturePOIEvidence(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if mappingManager.mapPOIs[trimmed] == nil {
            mappingManager.addPOIAnchor(name: trimmed)
        } else {
            _ = mappingManager.addVisualSample(name: trimmed)
        }
        newPOIName = trimmed
    }

    private var currentCapturedImage: CVPixelBuffer? {
        mappingManager.session.currentFrame?.capturedImage
    }

    private func speakSemanticCue(_ cue: SemanticSpeechCue?) {
        guard let cue else { return }
        if lastSpokenSemanticCueText == cue.text,
           let lastSpokenSemanticCueAt,
           Date().timeIntervalSince(lastSpokenSemanticCueAt) < 2.5 {
            return
        }
        lastSpokenSemanticCueText = cue.text
        lastSpokenSemanticCueAt = Date()

        if launchVoiceOverEnabled {
            UIAccessibility.post(notification: .announcement, argument: cue.text)
            return
        }

        switch cue.priority {
        case .regular:
            ttsManager.speak(cue.text)
        case .priority:
            ttsManager.speakPriority(cue.text)
        case .critical:
            ttsManager.speakCritical(cue.text)
        }
    }

    private func startNewMap() {
        if mapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mapName = mappingManager.suggestedMapName()
        }
        mappingManager.startMapping()
    }

    private func loadSelectedMap() {
        guard let selectedID = mappingManager.selectedMapID else { return }
        if let selectedSavedMap {
            mapName = selectedSavedMap.name
        }
        mappingManager.loadMapAndRelocalize(mapID: selectedID)
    }

    private var selectedMapBinding: Binding<String> {
        Binding(
            get: { mappingManager.selectedMapID ?? mappingManager.savedMaps.first?.id ?? "" },
            set: { mappingManager.selectedMapID = $0.isEmpty ? nil : $0 }
        )
    }

    private var selectedSavedMap: ARStoredMapSummary? {
        guard let id = mappingManager.selectedMapID else { return mappingManager.savedMaps.first }
        return mappingManager.savedMaps.first(where: { $0.id == id })
    }

    private func mapLabel(for map: ARStoredMapSummary) -> String {
        let suffix = map.poiCount == 1 ? "1 POI" : "\(map.poiCount) POIs"
        return "\(map.name) (\(suffix))"
    }

    private var saveButtonTitle: String {
        mappingManager.isRelocalizing ? "Save Expanded Map" : "Save Map"
    }

    private var canPinPOI: Bool {
        mappingManager.isMapping || mappingManager.isLocalized
    }

    private var canEditPOIs: Bool {
        mappingManager.isMapping || mappingManager.isLocalized
    }

    private var trimmedPOIName: String {
        newPOIName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSamplePOI: Bool {
        guard !trimmedPOIName.isEmpty else { return false }
        return mappingManager.mapPOIs[trimmedPOIName] != nil
    }

    private var hasInspectionContent: Bool {
        !mappingManager.mapFeaturePoints.isEmpty
            || !mappingManager.poiInspectionList.isEmpty
            || mappingManager.cameraMapPosition != nil
    }

    private var totalVisualSamples: Int {
        mappingManager.poiInspectionList.reduce(0) { $0 + $1.visualSampleCount }
    }

    private var mapInspectorHeight: CGFloat {
        156
    }

    private var shouldShowPOIEditor: Bool {
        mappingManager.sessionMode != .idle && !mappingManager.poiInspectionList.isEmpty
    }

    private var mapSpanText: String {
        let bounds = inspectionBounds()
        guard bounds.hasContent else { return "0.0m" }
        return String(format: "%.1fm x %.1fm", bounds.spanX, bounds.spanZ)
    }

    private var mapDensityText: String {
        let bounds = inspectionBounds()
        guard bounds.hasContent else { return "0 pts/m2" }
        let area = max(bounds.spanX * bounds.spanZ, 0.05)
        let density = Float(mappingManager.mapFeaturePointCount) / area
        if density < 10 {
            return String(format: "%.1f pts/m2", density)
        }
        return String(format: "%.0f pts/m2", density)
    }

    private func coordinateText(for position: simd_float3) -> String {
        String(format: "X %.1f  Y %.1f  Z %.1f", position.x, position.y, position.z)
    }

    private func inspectionBounds() -> ARMapSceneBounds {
        ARMapSceneBounds(
            points: mappingManager.mapFeaturePoints,
            pois: mappingManager.poiInspectionList.map(\.position),
            cameraPosition: mappingManager.cameraMapPosition
        )
    }

    private var statusTint: Color {
        if mappingManager.isLocalized {
            return Color(red: 0.56, green: 0.84, blue: 0.78)
        }
        if mappingManager.isMapping || mappingManager.isRelocalizing {
            return Color(red: 0.86, green: 0.68, blue: 0.38)
        }
        return Color.white.opacity(0.64)
    }

    private var statusText: String {
        if mappingManager.isRelocalizing {
            return mappingManager.isLocalized ? "Localized" : "Searching saved map"
        }

        if !mappingManager.isMapping {
            return "Ready"
        }

        switch mappingManager.mappingStatus {
        case .notAvailable:
            return "Starting map"
        case .limited:
            return "Scanning limited"
        case .extending:
            return "Extending map"
        case .mapped:
            return "Map quality good"
        @unknown default:
            return "Tracking"
        }
    }

    private var routeAwareStatusText: String {
        guard semanticNavigator.phase == .navigating || semanticNavigator.phase == .recovering else {
            return statusText
        }
        return "\(statusText) · \(semanticNavigator.routeLocalizationStatus.displayName)"
    }

    private var routeAwareStatusIcon: String {
        switch semanticNavigator.routeLocalizationStatus {
        case .locked:
            return mappingManager.isLocalized ? "checkmark.circle.fill" : "location.circle"
        case .ambiguous, .recovering:
            return "exclamationmark.triangle.fill"
        case .lost:
            return "viewfinder.circle"
        case .initializing:
            return "viewfinder"
        }
    }

    private var routeAwareStatusTint: Color {
        switch semanticNavigator.routeLocalizationStatus {
        case .locked:
            return automatedAccent
        case .ambiguous, .recovering, .lost:
            return Color(red: 0.98, green: 0.68, blue: 0.34)
        case .initializing:
            return mappingManager.isLocalized ? automatedAccent : Color.white.opacity(0.72)
        }
    }
}

private struct ARMapSceneBounds {
    let hasContent: Bool
    let minX: Float
    let maxX: Float
    let minY: Float
    let maxY: Float
    let minZ: Float
    let maxZ: Float

    init(points: [simd_float3], pois: [simd_float3], cameraPosition: simd_float3?) {
        var values = points + pois
        if let cameraPosition {
            values.append(cameraPosition)
        }

        guard let first = values.first else {
            hasContent = false
            minX = -0.6
            maxX = 0.6
            minY = -0.2
            maxY = 0.6
            minZ = -0.6
            maxZ = 0.6
            return
        }

        hasContent = true
        minX = values.reduce(first.x) { Swift.min($0, $1.x) }
        maxX = values.reduce(first.x) { Swift.max($0, $1.x) }
        minY = values.reduce(first.y) { Swift.min($0, $1.y) }
        maxY = values.reduce(first.y) { Swift.max($0, $1.y) }
        minZ = values.reduce(first.z) { Swift.min($0, $1.z) }
        maxZ = values.reduce(first.z) { Swift.max($0, $1.z) }
    }

    var center: simd_float3 {
        simd_make_float3((minX + maxX) * 0.5, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
    }

    var spanX: Float {
        Swift.max(maxX - minX, 0.2)
    }

    var spanY: Float {
        Swift.max(maxY - minY, 0.2)
    }

    var spanZ: Float {
        Swift.max(maxZ - minZ, 0.2)
    }

    var largestSpan: Float {
        Swift.max(spanX, Swift.max(spanY, spanZ))
    }
}

private struct ARMapSceneView: UIViewRepresentable {
    let featurePoints: [simd_float3]
    let pois: [ARMapPOIInspection]
    let cameraPosition: simd_float3?
    let cameraForward: simd_float3?
    let emphasizesFeaturePoints: Bool

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling2X
        view.autoenablesDefaultLighting = false
        view.isUserInteractionEnabled = false
        view.scene = SCNScene()
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        uiView.scene = Self.makeScene(
            featurePoints: featurePoints,
            pois: pois,
            cameraPosition: cameraPosition,
            cameraForward: cameraForward,
            emphasizesFeaturePoints: emphasizesFeaturePoints
        )
    }

    private static func makeScene(
        featurePoints: [simd_float3],
        pois: [ARMapPOIInspection],
        cameraPosition: simd_float3?,
        cameraForward: simd_float3?,
        emphasizesFeaturePoints: Bool
    ) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = UIColor.clear

        let bounds = ARMapSceneBounds(
            points: featurePoints,
            pois: pois.map(\.position),
            cameraPosition: cameraPosition
        )
        let target = SCNNode()
        target.position = vector(bounds.center)
        scene.rootNode.addChildNode(target)
        scene.rootNode.addChildNode(makeGridNode(bounds: bounds))

        if !featurePoints.isEmpty {
            scene.rootNode.addChildNode(makePointCloudNode(points: featurePoints, isEmphasized: emphasizesFeaturePoints))
        }

        for poi in pois {
            scene.rootNode.addChildNode(makePOINode(poi))
        }

        if let cameraPosition {
            scene.rootNode.addChildNode(makeCameraMarker(position: cameraPosition, forward: cameraForward))
        }

        let cameraNode = SCNNode()
        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(Swift.max(bounds.largestSpan * 1.35, 1.6))
        camera.zNear = 0.01
        camera.zFar = 500
        cameraNode.camera = camera

        let cameraDistance = Swift.max(bounds.largestSpan * 1.15, 1.7)
        let center = bounds.center
        cameraNode.position = SCNVector3(
            center.x,
            bounds.maxY + cameraDistance,
            center.z + cameraDistance * 0.62
        )
        let lookAt = SCNLookAtConstraint(target: target)
        lookAt.isGimbalLockEnabled = true
        cameraNode.constraints = [lookAt]
        scene.rootNode.addChildNode(cameraNode)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 900
        let lightNode = SCNNode()
        lightNode.light = ambientLight
        scene.rootNode.addChildNode(lightNode)

        return scene
    }

    private static func makePointCloudNode(points: [simd_float3], isEmphasized: Bool) -> SCNNode {
        let vertices = points.map(vector)
        let source = SCNGeometrySource(vertices: vertices)
        let indices = vertices.indices.map { Int32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = isEmphasized ? 6 : 4
        element.minimumPointScreenSpaceRadius = isEmphasized ? 2.2 : 1.5
        element.maximumPointScreenSpaceRadius = isEmphasized ? 7 : 5

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor(
            red: 0.47,
            green: 0.76,
            blue: 0.92,
            alpha: isEmphasized ? 0.86 : 0.72
        )
        material.writesToDepthBuffer = true
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func makeGridNode(bounds: ARMapSceneBounds) -> SCNNode {
        let padding = Swift.max(bounds.largestSpan * 0.16, 0.35)
        let step = gridStep(for: bounds.largestSpan)
        let startX = floor((bounds.minX - padding) / step) * step
        let endX = ceil((bounds.maxX + padding) / step) * step
        let startZ = floor((bounds.minZ - padding) / step) * step
        let endZ = ceil((bounds.maxZ + padding) / step) * step
        let y = bounds.minY - 0.04
        var vertices: [SCNVector3] = []

        for x in stride(from: startX, through: endX, by: step) {
            vertices.append(SCNVector3(x, y, startZ))
            vertices.append(SCNVector3(x, y, endZ))
        }

        for z in stride(from: startZ, through: endZ, by: step) {
            vertices.append(SCNVector3(startX, y, z))
            vertices.append(SCNVector3(endX, y, z))
        }

        return makeLineNode(vertices: vertices, color: UIColor.white.withAlphaComponent(0.16))
    }

    private static func gridStep(for span: Float) -> Float {
        switch span {
        case 0..<2:
            return 0.25
        case 2..<6:
            return 0.5
        default:
            return 1.0
        }
    }

    private static func makePOINode(_ poi: ARMapPOIInspection) -> SCNNode {
        let root = SCNNode()
        root.position = vector(poi.position)

        let marker = SCNSphere(radius: poi.visualSampleCount > 0 ? 0.075 : 0.065)
        let markerMaterial = SCNMaterial()
        markerMaterial.lightingModel = .constant
        markerMaterial.diffuse.contents = poi.visualSampleCount > 0
            ? UIColor(red: 0.55, green: 0.92, blue: 0.78, alpha: 0.96)
            : UIColor(red: 1.0, green: 0.68, blue: 0.34, alpha: 0.96)
        marker.firstMaterial = markerMaterial

        let markerNode = SCNNode(geometry: marker)
        root.addChildNode(markerNode)

        let text = SCNText(string: poi.name, extrusionDepth: 0.002)
        text.font = UIFont.systemFont(ofSize: 10, weight: .semibold)
        text.flatness = 0.35
        let textMaterial = SCNMaterial()
        textMaterial.lightingModel = .constant
        textMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.92)
        text.firstMaterial = textMaterial

        let textNode = SCNNode(geometry: text)
        textNode.scale = SCNVector3(0.012, 0.012, 0.012)
        textNode.position = SCNVector3(0.11, 0.05, 0)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        textNode.constraints = [billboard]
        root.addChildNode(textNode)

        return root
    }

    private static func makeCameraMarker(position: simd_float3, forward: simd_float3?) -> SCNNode {
        let root = SCNNode()
        root.position = vector(position)

        let marker = SCNSphere(radius: 0.06)
        let markerMaterial = SCNMaterial()
        markerMaterial.lightingModel = .constant
        markerMaterial.diffuse.contents = UIColor(red: 0.34, green: 0.65, blue: 1.0, alpha: 0.98)
        marker.firstMaterial = markerMaterial
        root.addChildNode(SCNNode(geometry: marker))

        if let forward, simd_length(forward) > 0.001 {
            let normalizedForward = simd_normalize(forward)
            let end = normalizedForward * 0.42
            root.addChildNode(
                makeLineNode(
                    vertices: [SCNVector3Zero, SCNVector3(end.x, end.y, end.z)],
                    color: UIColor(red: 0.42, green: 0.76, blue: 1.0, alpha: 0.95)
                )
            )
        }

        return root
    }

    private static func makeLineNode(vertices: [SCNVector3], color: UIColor) -> SCNNode {
        guard vertices.count >= 2 else { return SCNNode() }
        let source = SCNGeometrySource(vertices: vertices)
        let indices = vertices.indices.map { Int32($0) }
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        geometry.firstMaterial = material
        return SCNNode(geometry: geometry)
    }

    private static func vector(_ value: simd_float3) -> SCNVector3 {
        SCNVector3(value.x, value.y, value.z)
    }
}

private enum ARControlProminence {
    case primary
    case secondary
    case compact
}

private extension String {
    var nilIfRouteBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ARControlButtonStyle: ButtonStyle {
    var prominence: ARControlProminence

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .foregroundColor(foregroundColor)
            .padding(.vertical, verticalPadding)
            .padding(.horizontal, 12)
            .background(background(configuration: configuration))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }

    private var font: Font {
        switch prominence {
        case .compact:
            return .subheadline.weight(.semibold)
        default:
            return .callout.weight(.semibold)
        }
    }

    private var verticalPadding: CGFloat {
        prominence == .compact ? 11 : 13
    }

    private var foregroundColor: Color {
        prominence == .primary ? .black : .white
    }

    private func background(configuration: Configuration) -> some View {
        let fill: Color
        switch prominence {
        case .primary:
            fill = Color.white.opacity(configuration.isPressed ? 0.82 : 0.94)
        case .secondary:
            fill = Color.white.opacity(configuration.isPressed ? 0.16 : 0.10)
        case .compact:
            fill = Color.white.opacity(configuration.isPressed ? 0.22 : 0.14)
        }

        return RoundedRectangle(cornerRadius: 8)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(prominence == .primary ? 0 : 0.16), lineWidth: 1)
            )
    }
}

private struct POIActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.64 : 0.9))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.14), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
