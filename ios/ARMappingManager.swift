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
    
    let session = ARSession()
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
    private let imuMotionMinimumSteps = 2
    private let imuMotionMinimumDistance: Float = 0.8
    private let imuMotionDirectionMinimumDistance: Float = 1.15
    private let imuMotionDirectionToleranceDegrees: Double = 48
    
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
            updatedAt: Date()
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

        let config = makeWorldTrackingConfiguration()
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
        lastUpdateTime = 0
        isMapping = true
        isRelocalizing = false
        isLocalized = false
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
        session.pause()
        isMapping = false
        isRelocalizing = false
        isLocalized = false
        isSavingMap = false
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
                        self.refreshPOIInspectionList()
                        self.refreshSavedMaps()
                        self.statusMessage = "Saved \(metadata.name) with \(metadata.pois.count) POIs."
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

                    let config = self.makeWorldTrackingConfiguration(initialWorldMap: map)
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
        let arHeading = headingDegrees(for: cameraForward)
        let displayHeading = arHeading ?? Double(yaw)
        let liveFeatureSnapshot = isMapping ? sampledFeaturePoints(from: frame.rawFeaturePoints) : nil
        let poiMatchResult = bestPOIMatch(
            cameraTransform: transform,
            capturedImage: frame.capturedImage,
            timestamp: currentTime
        )
        
        let x = transform.columns.3.x
        let z = transform.columns.3.z

        DispatchQueue.main.async {
            self.mappingStatus = mappingStatus
            self.cameraMapPosition = cameraPosition
            self.cameraMapForward = cameraForward
            self.arHeadingDegrees = arHeading
            if let liveFeatureSnapshot {
                self.mapFeaturePoints = liveFeatureSnapshot.points
                self.mapFeaturePointCount = liveFeatureSnapshot.totalCount
            }
            self.localizationCandidates = poiMatchResult.candidates
            
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
        }
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        DispatchQueue.main.async {
            if self.isRelocalizing {
                switch camera.trackingState {
                case .normal:
                    if !self.isLocalized {
                        // Publish a post-relocalization pose BEFORE isLocalized:
                        // the published cameraMapPosition is frame-throttled and
                        // can still hold the pre-relocalization pose (≈ session
                        // origin ≈ route start). Observers react to isLocalized
                        // immediately and would start guidance from that stale
                        // point instead of where the user actually stands.
                        if let frame = self.session.currentFrame {
                            let transform = frame.camera.transform
                            let position = simd_make_float3(
                                transform.columns.3.x,
                                transform.columns.3.y,
                                transform.columns.3.z
                            )
                            let forward = simd_make_float3(
                                -transform.columns.2.x,
                                -transform.columns.2.y,
                                -transform.columns.2.z
                            )
                            self.cameraMapPosition = position
                            self.cameraMapForward = forward
                            self.arHeadingDegrees = self.headingDegrees(for: forward)
                        }
                        self.isLocalized = true
                        self.statusMessage = "Localized against saved map."
                    }
                default:
                    if self.isLocalized {
                        self.isLocalized = false
                        self.closestPOI = nil
                        self.poiMatchStatusText = nil
                        self.statusMessage = "Tracking limited. Hold the camera steady."
                    }
                }
            }
        }
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

    private func makeWorldTrackingConfiguration(initialWorldMap: ARWorldMap? = nil) -> ARWorldTrackingConfiguration {
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
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .none
        config.isLightEstimationEnabled = false
        config.providesAudioData = false
        config.frameSemantics = []
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics.insert(.sceneDepth)
        }
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        applyEfficientVideoFormat(to: config)
        return config
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

    private func headingDegrees(for cameraForward: simd_float3) -> Double? {
        // Must match SemanticRouteNavigator's route frame (y = -z): 0° is the
        // session's initial facing (-Z) and heading increases on physical
        // RIGHT turns. Using raw +z flips the handedness and mirrors every
        // geometric left/right cue.
        let horizontal = SIMD2<Double>(Double(cameraForward.x), -Double(cameraForward.z))
        guard simd_length(horizontal) > 0.001 else { return nil }
        return normalizedDegrees(atan2(horizontal.x, horizontal.y) * 180 / Double.pi)
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
