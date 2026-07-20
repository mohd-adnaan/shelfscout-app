import SwiftUI
import ARKit
import SceneKit
import UIKit

struct ARViewContainer: UIViewRepresentable {
    var session: ARSession
    var isSessionActive: Bool
    var showsCoaching: Bool

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
        context.coordinator.update(showsCoaching: showsCoaching && isSessionActive)
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        uiView.debugOptions = []
        context.coordinator.update(showsCoaching: showsCoaching && isSessionActive)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    @MainActor
    final class Coordinator {
        private let coachingOverlay = ARCoachingOverlayView()

        func attachCoachingOverlay(to arView: ARSCNView, session: ARSession) {
            coachingOverlay.session = session
            coachingOverlay.goal = .tracking
            coachingOverlay.activatesAutomatically = false
            coachingOverlay.translatesAutoresizingMaskIntoConstraints = false
            coachingOverlay.isHidden = true

            arView.addSubview(coachingOverlay)
            NSLayoutConstraint.activate([
                coachingOverlay.leadingAnchor.constraint(equalTo: arView.leadingAnchor),
                coachingOverlay.trailingAnchor.constraint(equalTo: arView.trailingAnchor),
                coachingOverlay.topAnchor.constraint(equalTo: arView.topAnchor),
                coachingOverlay.bottomAnchor.constraint(equalTo: arView.bottomAnchor)
            ])
        }

        func update(showsCoaching: Bool) {
            coachingOverlay.isHidden = !showsCoaching
            coachingOverlay.activatesAutomatically = showsCoaching
            if !showsCoaching {
                coachingOverlay.setActive(false, animated: true)
            }
        }
    }
}

struct ARMappingView: View {
    @EnvironmentObject private var sensorManager: IMUSensorManager
    @EnvironmentObject private var ttsManager: TTSManager
    @StateObject private var mappingManager = ARMappingManager()
    @StateObject private var semanticNavigator = SemanticRouteNavigator()
    @Binding private var sourceSelection: String
    private let launchTargetName: String?
    private let launchRouteMapId: String?
    private let launchRouteMapName: String?
    private let launchSpeakLandmarks: Bool
    private let launchErrorRecovery: Bool
    private let launchClockFaceDirections: Bool
    private let launchVoiceOverEnabled: Bool
    private let onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)?
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
    @State private var automatedRelocalizationStartedAt: Date?
    @State private var lastRelocalizationVoiceCueAt: Date?
    @State private var relocalizationVoiceCueCount: Int = 0

    /// The coaching overlay is visual-only; a blind user standing in silence
    /// while the map searches gets spoken guidance instead, then a hard
    /// timeout so the JS side can recover rather than waiting forever.
    private let relocalizationVoiceCueIntervalSeconds: TimeInterval = 8.0
    private let automatedRelocalizationTimeoutSeconds: TimeInterval = 35.0

    init(
        sourceSelection: Binding<String> = .constant(""),
        launchTargetName: String? = nil,
        launchRouteMapId: String? = nil,
        launchRouteMapName: String? = nil,
        launchSpeakLandmarks: Bool = true,
        launchErrorRecovery: Bool = true,
        launchClockFaceDirections: Bool = false,
        launchVoiceOverEnabled: Bool = UIAccessibility.isVoiceOverRunning,
        onAutomationComplete: ((ARKitNavigationNativeResult) -> Void)? = nil
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
    }

    private var routeSceneWithNavigationChrome: some View {
        arSceneContent
            .navigationTitle(isAutomatedNavigation ? "ARKit Navigation" : "Manage ARKit Route Maps")
            .navigationBarTitleDisplayMode(.inline)
    }

    private var arSceneContent: AnyView {
        AnyView(
            ZStack {
                ARViewContainer(
                    session: mappingManager.session,
                    isSessionActive: mappingManager.sessionMode != .idle,
                    showsCoaching: mappingManager.isMapping || (mappingManager.isRelocalizing && !mappingManager.isLocalized)
                )
                .ignoresSafeArea()

                if mappingManager.sessionMode == .idle {
                    Color.black.opacity(0.82)
                        .ignoresSafeArea()
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
        )
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
        }
        guard phase == .arrived else { return }

        if launchTargetName != nil {
            resolveAutomation(
                success: true,
                reason: "arrived",
                message: semanticNavigator.currentInstruction
            )
            return
        }

        triggerManualReachingHandoffIfNeeded()
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

        // Reaching runs its own AR session; release the camera first.
        manager.stopMapping()

        ReachingModule.launchSpatialTargetReaching(
            targetName: objectName,
            routeMapId: mapId,
            routeMapName: mapName,
            targetWorldPosition: objectPosition,
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
        guard isLocalized else { return }
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
            return
        }

        let now = Date()
        guard let startedAt = automatedRelocalizationStartedAt else {
            automatedRelocalizationStartedAt = now
            return
        }

        if now.timeIntervalSince(startedAt) >= automatedRelocalizationTimeoutSeconds {
            resolveAutomation(
                success: false,
                reason: "relocalization_failed",
                message: "I could not match the saved route map from here. Walk to a spot on the mapped route, hold the phone at chest height facing the shelves, and try again."
            )
            return
        }

        let sinceCue = lastRelocalizationVoiceCueAt.map { now.timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        guard sinceCue >= relocalizationVoiceCueIntervalSeconds else { return }
        lastRelocalizationVoiceCueAt = now
        relocalizationVoiceCueCount += 1

        let cue: String
        switch relocalizationVoiceCueCount {
        case 1:
            cue = "Loading the saved route. Hold the phone at chest height and slowly pan left and right."
        case 2:
            cue = "Still matching the map. Keep panning slowly, and point the camera at the shelves ahead."
        default:
            cue = "Still searching. Take a small step forward or turn slightly, then pan slowly again."
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

    private var automatedTargetName: String? {
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
            if mappingManager.activeMapID != arWorldMapId && mappingManager.sessionMode != .relocalizing {
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
        if let launchRouteMapId,
           let byId = maps.first(where: { $0.id == launchRouteMapId }),
           routeContainsTarget(byId, normalizedTarget: normalizedTarget) {
            return byId
        }

        if let launchRouteMapName,
           let byName = maps.first(where: { $0.name.caseInsensitiveCompare(launchRouteMapName) == .orderedSame }),
           routeContainsTarget(byName, normalizedTarget: normalizedTarget) {
            return byName
        }

        if let exact = maps.first(where: { routeContainsTarget($0, normalizedTarget: normalizedTarget) }) {
            return exact
        }

        // Fuzzy fallback for ASR noise: "serial" must still find the map
        // holding "cereal".
        return maps.first(where: { routeContainsTargetFuzzily($0, target: target) })
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
        message: String? = nil
    ) {
        guard didResolveAutomation == false else { return }
        didResolveAutomation = true
        let reachingObjectName = success && reason == "arrived"
            ? arrivedReachingObjectName
            : nil
        let result = ARKitNavigationNativeResult(
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
                startReachingHandoff: startReachingHandoff
            )
        }
    }

    private var automatedNavigationPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule()
                .fill(Color.white.opacity(0.34))
                .frame(width: 38, height: 5)
                .frame(maxWidth: .infinity)

            HStack(spacing: 10) {
                Image(systemName: "location.north.line.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(automatedAccent)
                    .frame(width: 30, height: 30)
                    .background(automatedAccent.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text("ARKit Navigation")
                        .font(.title3.weight(.bold))
                        .foregroundColor(.white)
                    Text(automatedTargetName.map { "Destination: \($0)" } ?? "Destination selected")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 8) {
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
                .font(.subheadline.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(automatedAccent.opacity(0.34), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(16)
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
