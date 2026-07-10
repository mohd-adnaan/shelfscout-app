import SwiftUI
import UIKit

struct SemanticNavigationPanel: View {
    @ObservedObject var navigator: SemanticRouteNavigator
    @Binding var mapName: String

    let arStatusText: String
    let activeARMapName: String?
    let closestPOI: String?
    let savedARMaps: [ARStoredMapSummary]
    let selectedARMapID: String?
    let canUseARPose: Bool
    let isARSessionActive: Bool
    let isSavingARMap: Bool
    let selectARMap: (String?) -> Void
    let startARMapping: () -> Void
    let loadARMap: () -> Void
    let deleteARMap: () -> Void
    let saveARMap: () -> Void
    let stopARSession: () -> Void
    let beginWalkthrough: (String) -> Void
    let captureStart: (String) -> Void
    let captureTurn: (SemanticTurnHint) -> Void
    let captureLandmark: (String, SemanticRouteSide, String, Bool) -> Void
    let captureReachingObject: (String) -> Void
    let saveWalkthrough: () -> Void
    let startNavigation: (String, Bool, Bool) -> Void
    let snapToRoute: () -> Void
    let startReachingHandoff: () -> Void

    @State private var mode: RoutePanelMode = .map
    @State private var startName = ""
    @State private var landmarkName = ""
    @State private var destinationName = ""
    @State private var landmarkNote = ""
    @State private var reachingObjectName = ""
    @State private var selectedSide: SemanticRouteSide = .left
    @State private var targetName = ""
    @State private var showsSavedMapLoader = false
    @State private var showsLandmarkForm = false
    @State private var showsReview = false
    @State private var speakLandmarks = true
    @State private var errorRecoveryEnabled = true
    @State private var routeIDPendingDeletion: String?
    @State private var showsDeleteRouteConfirm = false

    var body: some View {
        VStack(spacing: 14) {
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 38, height: 5)
                .padding(.top, 2)

            Picker("Route mode", selection: $mode) {
                Label("Map", systemImage: "map").tag(RoutePanelMode.map)
                Label("Guide", systemImage: "figure.walk").tag(RoutePanelMode.guide)
            }
            .pickerStyle(.segmented)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    if mode == .map {
                        mapFlow
                    } else {
                        guideFlow
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: navigator.phase == .mapping ? 500 : 360)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 10)
        .onAppear {
            syncStartName()
            syncTargetName()
        }
        .onChange(of: closestPOI) { _ in syncStartName() }
        .onChange(of: navigator.availableTargets) { _ in syncTargetName() }
        .onChange(of: navigator.phase) { phase in
            if phase == .navigating || phase == .recovering || phase == .arrived {
                mode = .guide
            }
        }
        .alert("Delete route?", isPresented: $showsDeleteRouteConfirm) {
            Button("Cancel", role: .cancel) {
                routeIDPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                if let routeIDPendingDeletion {
                    navigator.deleteMap(id: routeIDPendingDeletion)
                    syncTargetName()
                }
                routeIDPendingDeletion = nil
            }
        } message: {
            Text("This removes the saved semantic route, turns, landmarks, and guidance graph. The AR map file is not deleted.")
        }
    }

    private var mapFlow: some View {
        VStack(alignment: .leading, spacing: 16) {
            flowHeader(
                title: navigator.phase == .mapping ? navigator.mappingStageTitle : "Map a Route",
                subtitle: mapSubtitle
            )

            if navigator.phase == .mapping {
                activeMapFlow
            } else {
                startMapFlow
            }
        }
    }

    private var startMapFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusLine

            TextField("Route name", text: $mapName)
                .routeTextField()

            Button {
                beginWalkthrough(mapName)
                syncStartName(force: true)
            } label: {
                Label(isARSessionActive ? "Start Route From Here" : "Start Mapping", systemImage: "figure.walk")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            if !isARSessionActive && !savedARMaps.isEmpty {
                DisclosureGroup("Use a saved AR map", isExpanded: $showsSavedMapLoader) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Saved AR map", selection: selectedMapBinding) {
                            ForEach(savedARMaps) { map in
                                Text(mapLabel(for: map)).tag(map.id)
                            }
                        }
                        .pickerStyle(.menu)

                        HStack(spacing: 10) {
                            Button {
                                loadARMap()
                            } label: {
                                Label("Load AR Map", systemImage: "location.viewfinder")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)

                            Button(role: .destructive) {
                                deleteARMap()
                            } label: {
                                Image(systemName: "trash")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                            .disabled(selectedARMapID == nil && savedARMaps.isEmpty)
                            .accessibilityLabel("Delete selected AR map")
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var activeMapFlow: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusLine

            if navigator.capturedPointCount == 0 {
                pointAForm
            } else {
                walkingControls
                landmarkDisclosure
                destinationForm
                routeReview
                saveControls
            }
        }
    }

    private var pointAForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let closestPOI, !closestPOI.isEmpty {
                Label("Detected start: \(closestPOI)", systemImage: "location.viewfinder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Start name", text: $startName)
                .routeTextField()

            Button {
                captureStart(startName)
                if startName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    startName = closestPOI ?? "Start"
                }
            } label: {
                Label("Mark Start", systemImage: "mappin.and.ellipse")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canUseARPose)
        }
    }

    private var walkingControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Walk to the next turn or the final target.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if navigator.currentSegmentDraftMeters > 0 {
                Text("Distance from last point: \(meters(navigator.currentSegmentDraftMeters))")
                    .font(.headline.weight(.semibold))
            }

            HStack(spacing: 10) {
                turnButton(.left, title: "Left", systemImage: "arrow.turn.up.left")
                turnButton(.right, title: "Right", systemImage: "arrow.turn.up.right")
            }

            HStack(spacing: 10) {
                turnButton(.cornerLeft, title: "Left Corner", systemImage: "arrow.up.left")
                turnButton(.cornerRight, title: "Right Corner", systemImage: "arrow.up.right")
            }

            turnButton(.straight, title: "Straight", systemImage: "arrow.up")
        }
    }

    private var landmarkDisclosure: some View {
        DisclosureGroup("Add object or shelf", isExpanded: $showsLandmarkForm) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Name", text: $landmarkName)
                    .routeTextField()

                HStack(spacing: 10) {
                    Picker("Side", selection: $selectedSide) {
                        ForEach(SemanticRouteSide.allCases) { side in
                            Text(side.displayName).tag(side)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Add") {
                        captureLandmark(landmarkName, selectedSide, landmarkNote, false)
                        landmarkName = ""
                        landmarkNote = ""
                        showsLandmarkForm = false
                    }
                    .buttonStyle(.bordered)
                    .disabled(landmarkName.trimmedRouteText.isEmpty || !canUseARPose)
                }

                TextField("Optional note", text: $landmarkNote)
                    .routeTextField()
            }
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var destinationForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Destination name", text: $destinationName)
                .routeTextField()

            Button {
                captureLandmark(destinationName, selectedSide, landmarkNote, true)
                if targetName.isEmpty {
                    targetName = destinationName
                }
            } label: {
                Label("Set Destination", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(destinationName.trimmedRouteText.isEmpty || !canUseARPose)

            if navigator.capturedDestinationCount > 0 {
                reachingObjectForm
            }
        }
    }

    private var reachingObjectForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let linked = navigator.capturedReachingObjectSummary {
                Label("Reaching object: \(linked.object) → \(linked.destination)", systemImage: "hand.point.up.left")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
            }

            Text("Optional last-meter reaching: aim the camera straight at the object to grab at \(navigator.latestCapturedDestinationName ?? "the destination"), then pin it. After navigation arrives, reaching guidance targets this object.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                TextField("Reaching object (e.g. kettle)", text: $reachingObjectName)
                    .routeTextField()

                Button {
                    captureReachingObject(reachingObjectName)
                    reachingObjectName = ""
                } label: {
                    Label("Pin", systemImage: "hand.point.up.left")
                }
                .buttonStyle(.borderedProminent)
                .disabled(reachingObjectName.trimmedRouteText.isEmpty || !canUseARPose)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var routeReview: some View {
        DisclosureGroup("Review route", isExpanded: $showsReview) {
            VStack(alignment: .leading, spacing: 8) {
                let lines = navigator.routeReviewLines
                if lines.isEmpty {
                    Text("Mark the start, turns, and destination first.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline.weight(.semibold))
    }

    private var saveControls: some View {
        VStack(spacing: 10) {
            Button {
                saveWalkthrough()
            } label: {
                Label(isSavingARMap ? "Saving" : "Save Route", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!navigator.canSaveCapturedMap || isSavingARMap)

            if let error = navigator.saveCapturedMapError, !isSavingARMap {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                Button("Discard") {
                    navigator.discardCapture()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("Stop AR") {
                    stopARSession()
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }

            exportMapReportButton
        }
    }

    private var exportMapReportButton: some View {
        Button {
            exportMapReport()
        } label: {
            Label("Export Map Report", systemImage: "square.and.arrow.up")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(navigator.activeMap == nil && navigator.maps.isEmpty)
        .accessibilityHint("Shares an HTML report with the route plot and the camera frames captured while mapping.")
    }

    private func exportMapReport() {
        guard let url = navigator.exportDebugReportURL() else { return }
        guard let scene = UIApplication.shared.connectedScenes
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

    private var guideFlow: some View {
        VStack(alignment: .leading, spacing: 16) {
            flowHeader(title: "Guide", subtitle: guideSubtitle)
            guidanceMessage

            if navigator.maps.isEmpty || navigator.availableTargets.isEmpty {
                unavailableGuideState
            } else {
                routeSelectionMenu
                deleteSelectedRouteButton
                destinationSelectionMenu

                Toggle(isOn: $speakLandmarks) {
                    Label("Speak landmarks", systemImage: "speaker.wave.2")
                }
                .font(.subheadline.weight(.semibold))

                Toggle(isOn: $errorRecoveryEnabled) {
                    Label("Error recovery", systemImage: "exclamationmark.triangle")
                }
                .font(.subheadline.weight(.semibold))

                if !isARSessionActive && !savedARMaps.isEmpty {
                    Button {
                        loadARMap()
                    } label: {
                        Label("Load AR Map", systemImage: "location.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                HStack(spacing: 10) {
                    Button {
                        startNavigation(targetName, speakLandmarks, errorRecoveryEnabled)
                    } label: {
                        Label("Start Guidance", systemImage: "figure.walk")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(targetName.trimmedRouteText.isEmpty || !canUseARPose || navigator.phase == .mapping)

                    Button {
                        snapToRoute()
                    } label: {
                        Image(systemName: "location")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canUseARPose)
                    .accessibilityLabel("Recenter on route")
                }

                if navigator.phase == .arrived,
                   let reachingObject = navigator.reachingObjectName(forTarget: navigator.targetName) {
                    Button {
                        startReachingHandoff()
                    } label: {
                        Label("Reach \(reachingObject)", systemImage: "hand.point.up.left")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                if navigator.phase == .navigating || navigator.phase == .recovering || navigator.phase == .arrived {
                    Button("Stop Guidance") {
                        navigator.stopNavigation()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }

                exportMapReportButton
            }
        }
    }

    private var routeSelectionMenu: some View {
        Menu {
            ForEach(navigator.maps) { map in
                Button(routeLabel(for: map)) {
                    navigator.useMap(id: map.id)
                    syncTargetName()
                }
            }
        } label: {
            let value = navigator.activeMap.map { routeLabel(for: $0) } ?? "Choose route"
            menuRow(title: "Route", value: value, systemImage: "map")
        }
    }

    private var deleteSelectedRouteButton: some View {
        Button(role: .destructive) {
            routeIDPendingDeletion = navigator.activeMap?.id
            showsDeleteRouteConfirm = true
        } label: {
            Label("Delete Selected Route", systemImage: "trash")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(navigator.activeMap == nil || navigator.phase == .mapping || navigator.phase == .navigating || navigator.phase == .recovering)
    }

    private var destinationSelectionMenu: some View {
        Menu {
            ForEach(navigator.availableTargets, id: \.self) { target in
                Button(target) {
                    targetName = target
                }
            }
        } label: {
            menuRow(title: "Destination", value: targetName.isEmpty ? "Choose target" : targetName, systemImage: "scope")
        }
    }

    private var unavailableGuideState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No saved route yet.")
                .font(.headline)
            Text("Use Map to capture Point A, turns, and a destination first.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Open Map") {
                mode = .map
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var guidanceMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(navigator.currentInstruction)
                .font(.headline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)

            if let recoveryReason = navigator.recoveryReason {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recovery needed", systemImage: "exclamationmark.triangle.fill")
                        .font(.headline.weight(.semibold))
                    Text(recoveryReason)
                        .font(.subheadline)
                    Text("Hold position and pan the phone slowly left and right. If guidance stays stuck, tap recenter.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func menuRow(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            Label(arStatusText, systemImage: canUseARPose ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(canUseARPose ? .green : .secondary)
            if let activeARMapName {
                Text(activeARMapName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.subheadline.weight(.semibold))
    }

    private var mapSubtitle: String {
        if navigator.phase == .mapping {
            return navigator.currentInstruction
        }
        if isARSessionActive {
            return "AR is ready. Start a route from your current position."
        }
        return "Walk the route once. The app measures distance and saves turns."
    }

    private var guideSubtitle: String {
        if canUseARPose {
            return "Choose a saved route and destination."
        }
        return "Load or start the matching AR map before guidance."
    }

    private func flowHeader(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func turnButton(_ hint: SemanticTurnHint, title: String, systemImage: String) -> some View {
        Button {
            captureTurn(hint)
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!canUseARPose)
    }

    private var selectedMapBinding: Binding<String> {
        Binding(
            get: { selectedARMapID ?? savedARMaps.first?.id ?? "" },
            set: { selectARMap($0.isEmpty ? nil : $0) }
        )
    }

    private var selectedRouteBinding: Binding<String> {
        Binding(
            get: { navigator.activeMap?.id ?? navigator.maps.first?.id ?? "" },
            set: { id in
                guard !id.isEmpty else { return }
                navigator.useMap(id: id)
                syncTargetName()
            }
        )
    }

    private func syncStartName(force: Bool = false) {
        guard force || startName.trimmedRouteText.isEmpty else { return }
        startName = closestPOI ?? ""
    }

    private func syncTargetName() {
        if targetName.isEmpty, let first = navigator.availableTargets.first {
            targetName = first
        } else if !navigator.availableTargets.isEmpty, !navigator.availableTargets.contains(targetName) {
            targetName = navigator.availableTargets.first ?? ""
        }
    }

    private func mapLabel(for map: ARStoredMapSummary) -> String {
        let suffix = map.poiCount == 1 ? "1 POI" : "\(map.poiCount) POIs"
        return "\(map.name) (\(suffix))"
    }

    private func routeLabel(for map: SemanticRouteMap) -> String {
        let targetCount = map.targetNames.count
        let suffix = targetCount == 1 ? "1 target" : "\(targetCount) targets"
        return "\(map.name) (\(suffix))"
    }

    private func meters(_ value: Double) -> String {
        value < 10 ? String(format: "%.1fm", value) : String(format: "%.0fm", value)
    }
}

private enum RoutePanelMode {
    case map
    case guide
}

private extension String {
    var trimmedRouteText: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension View {
    func routeTextField() -> some View {
        self
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .textFieldStyle(.roundedBorder)
    }
}
