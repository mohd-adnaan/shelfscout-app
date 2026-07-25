//
//  Reachingviewcontroller+placeAndHold.swift
//  shelfscout
//
//  PLACE-AND-HOLD v8 — no X-mirror. Clean placement.
//
//  The corrected photo and ARKit's capturedImage are BOTH true,
//  un-mirrored views of the same scene (the OrientationFixer only does
//  an EXIF rotation, which preserves handedness; the back camera is not
//  mirrored). The portrait→landscape mapping below is already a pure
//  rotation, so no X flip is applied — flipping would turn it into a
//  reflection and place every off-center object on the wrong side.

import ARKit
import Vision
import CoreImage

extension ReachingViewController {

  func handlePlaceAndHoldFrame(_ frame: ARFrame) -> Bool {
    guard placeAndHoldPrototype else { return false }
    if !anchorPlaced {
      if spatialTargetWorldPosition != nil {
        attemptSpatialTargetPlacement(frame)
        return true
      }
      guard placeAndHoldInitialBboxReady(frame) else { return true }
      attemptPlaceAndHold(frame)
      return true
    }
    tryDav2Refine(frame)        // parallel, non-blocking DAv2 depth correction

    // Place-and-hold owns its own refinement policy. It never uses the live
    // camera->anchor ray because that redefines the target from wherever the
    // phone is currently pointing. Depth can improve only along the original
    // bbox line of sight, then it locks.
    if !placeAndHoldDepthLocked {
      tryPlaceAndHoldLockedRayDepthRefine(frame: frame)
    }

    if spatialTargetWorldPosition != nil {
      followSpatialPOIAnchor(frame)
      refineSpatialAnchorOnApproach(frame)
      tryRefineSpatialTargetExtent(frame)
    }

    // Guidance style is the user's Settings choice and is independent of how
    // the anchor was placed, so it routes the same for a backend bbox and for
    // a map POI: with-hand walks the user in on camera bearing, then hands
    // over to Vision hand tracking inside arm's reach; hand-free stays on
    // camera bearing the whole way. Both read the same held anchor.
    if mode == .withHand {
      processARFrameWithHand(frame)
    } else {
      processARFrameHandFree(frame)
    }
    return true
  }

  /// A map POI can be off by a meter or more — the mapping-time raycast can
  /// overshoot through glass, and relocalization adds drift. Once the user is
  /// close and facing the anchor, the live camera sees the real surface:
  /// raycast toward the anchor and snap it onto actual geometry. One-shot,
  /// evidence-gated, never blocks guidance (see reaching-placement rules).
  ///
  /// Runs for BOTH pin types. Legacy camera-pose pins mark where the mapper
  /// stood, so the real surface is typically a short distance PAST the pin —
  /// inside the +0.75m accept window below. Snapping moves the "saved spot"
  /// onto the actual thing the user is facing, which is strictly better than
  /// leaving the anchor floating at the mapper's old standing pose.
  private func refineSpatialAnchorOnApproach(_ frame: ARFrame) {
    guard !spatialAnchorSnapLocked,
          anchorPlaced,
          let anchorPos = objectWorldPosition else { return }
    guard case .normal = frame.camera.trackingState else { return }

    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSpatialAnchorSnapAttemptAt >= 0.30 else { return }
    lastSpatialAnchorSnapAttemptAt = now

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let toAnchor = anchorPos - camPos
    let anchorDist = simd_length(toAnchor)
    // Only near the target — from far away the ray samples unrelated geometry.
    guard anchorDist > 0.05, anchorDist <= 2.6 else { return }

    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    let rayDir = toAnchor / anchorDist
    // Camera must be roughly facing the anchor, or the raycast hits whatever
    // wall the user is walking past.
    guard simd_dot(camFwd, rayDir) > 0.80 else { return }

    var hitPoint: simd_float3?
    for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
      let query = ARRaycastQuery(origin: camPos, direction: rayDir, allowing: target, alignment: .any)
      for hit in sceneView.session.raycast(query) {
        let hp = simd_make_float3(hit.worldTransform.columns.3)
        let d = simd_dot(hp - camPos, rayDir)
        // Accept surfaces in front of the user up to slightly past the
        // anchor: closer hits correct pin overshoot, slightly-farther hits
        // correct undershoot/drift.
        guard d > 0.15, d < anchorDist + 0.75 else { continue }
        hitPoint = hp
        break
      }
      if hitPoint != nil { break }
    }
    guard let hitPoint else { return }

    // Pin already sits on real geometry — nothing to correct.
    if simd_distance(hitPoint, anchorPos) <= 0.30 {
      spatialAnchorSnapHits.removeAll()
      return
    }

    spatialAnchorSnapHits.append(hitPoint)
    if spatialAnchorSnapHits.count > 5 {
      spatialAnchorSnapHits.removeFirst()
    }
    guard spatialAnchorSnapHits.count >= 3 else { return }

    let recent = Array(spatialAnchorSnapHits.suffix(3))
    let centroid = (recent[0] + recent[1] + recent[2]) / 3
    let spread = recent.map { simd_distance($0, centroid) }.max() ?? 0
    guard spread <= 0.12 else { return }

    // Bounded correction — a surface far from the pin is a different object.
    let correction = simd_distance(centroid, anchorPos)
    guard correction <= 1.9 else {
      spatialAnchorSnapHits.removeAll()
      return
    }

    objectWorldPosition = centroid
    anchorDepth = simd_distance(centroid, camPos)
    liveDistanceToObject = anchorDepth
    let camT = camera.transform
    let right = -simd_normalize(simd_make_float3(camT.columns.1))
    let up    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = centroid + right * objectWorldHalfW + up * objectWorldHalfH
    objectWorldCornerBL = centroid - right * objectWorldHalfW - up * objectWorldHalfH
    placeAndHoldLastDepthSource = "surface snap"
    spatialAnchorSnapLocked = true
    spatialAnchorSnapHits.removeAll()

    NSLog("◎ [SpatialTarget] 🧲 Anchor snapped to live surface — %.0fcm correction (map pin → real geometry), now %.2fm away",
          correction * 100, anchorDepth)
  }

  private func attemptSpatialTargetPlacement(_ frame: ARFrame) {
    guard let storedTarget = spatialTargetWorldPosition else { return }
    guard arFrameCount >= 5 else { return }

    let now = ProcessInfo.processInfo.systemUptime
    if spatialTargetPlacementStartedAt <= 0 {
      spatialTargetPlacementStartedAt = now
    }

    let elapsed = now - spatialTargetPlacementStartedAt
    if elapsed > spatialTargetPlacementTimeoutSec {
      NSLog("◎ [SpatialTarget] ❌ Relocalization timed out after %.1fs for %@ on map %@",
            elapsed, objectName, spatialTargetMapName ?? "unknown")
      if guidanceAudioEnabled {
        say("I could not relocalize to the saved map. Try scanning this area again, then retry.")
      }
      finishWith(success: false, reason: "spatial_relocalization_timeout")
      return
    }

    switch frame.camera.trackingState {
    case .normal:
      // Relocalization landed; restore the mapping features that were held back
      // to get here quickly (surface snap and extent refinement need them).
      upgradeToFullFidelityAfterRelocalization()
    default:
      speakSpatialTargetRelocalizationCueIfNeeded()
      if arFrameCount % 30 == 0 {
        NSLog("◎ [SpatialTarget] Waiting for ARKit relocalization before placing %@",
              objectName)
      }
      return
    }

    // ── Prefer the RESTORED map anchor over the stored coordinate ────────
    // The stored value is a snapshot of the map frame at pin time. The POI
    // was also pinned into the ARWorldMap as a named ARAnchor; after
    // relocalization ARKit restores it and keeps it registered to real
    // geometry while alignment refines. A raw coordinate goes stale with
    // every refinement — that is the "box glued to the wrong door" failure.
    var target = storedTarget
    var placementSource = "saved map POI \(spatialTargetMapName ?? "unknown map")"
    if let poiAnchor = restoredSpatialPOIAnchor(in: frame) {
      let anchorPos = simd_make_float3(poiAnchor.transform.columns.3)
      let storedDelta = simd_distance(anchorPos, storedTarget)
      spatialPOIAnchorUUID = poiAnchor.identifier
      spatialPOIAnchorLastPosition = anchorPos
      target = anchorPos
      placementSource = "restored map anchor \(poiAnchor.name ?? objectName)"
      NSLog("◎ [SpatialTarget] 🔗 Restored POI anchor '%@' at (%.2f,%.2f,%.2f) — %.0fcm from stored coordinate",
            poiAnchor.name ?? "?", anchorPos.x, anchorPos.y, anchorPos.z, storedDelta * 100)
    } else {
      if spatialTargetFirstNormalAt <= 0 {
        spatialTargetFirstNormalAt = now
      }
      if now - spatialTargetFirstNormalAt < spatialPOIAnchorGraceSec {
        if arFrameCount % 30 == 0 {
          NSLog("◎ [SpatialTarget] Tracking normal — waiting up to %.1fs for restored POI anchor '%@'",
                spatialPOIAnchorGraceSec, spatialTargetPOIName ?? objectName)
        }
        return
      }
      // Sync reference so followSpatialPOIAnchor can jump the target to the
      // anchor if it is restored later.
      spatialPOIAnchorLastPosition = storedTarget
      NSLog("◎ [SpatialTarget] ⚠️ POI anchor '%@' not restored after %.1fs of normal tracking — placing from stored coordinate",
            spatialTargetPOIName ?? objectName, spatialPOIAnchorGraceSec)
    }

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let offset = target - camPos
    let depth = simd_length(offset)
    guard depth >= 0.10 && depth <= 12.0 else {
      speakSpatialTargetRelocalizationCueIfNeeded()
      if arFrameCount % 30 == 0 {
        NSLog("◎ [SpatialTarget] Target %@ has implausible map distance %.2fm; waiting",
              objectName, depth)
      }
      return
    }

    placementRayOrigin = camPos
    placementRayDir = simd_normalize(offset)
    placementHorizScale = 1.0
    dav2RefineState = .done
    dav2RequestInFlight = false
    placeAndHoldDepthLocked = true

    // Box extents from the POI name, not a one-size-fits-all blanket.
    // (0.16, 0.20) drew a 32×40cm box over a 15cm door handle — visually
    // wrong and useless as a size signal. Surface pins sit on the object
    // itself, so the prior describes the object; legacy camera-pose pins
    // mark where the mapper STOOD, so keep a wide uncertainty box there.
    // Either way tryRefineSpatialTargetExtent replaces the prior with
    // measured extents once saliency locks onto the real object.
    let prior = spatialTargetPriorHalfExtents()
    let fixedHalfExtents: (w: Float, h: Float) = spatialTargetIsSurfacePlacement
      ? prior
      : (max(prior.w, 0.30), max(prior.h, 0.35))

    finalizePlacement(
      worldPos: target,
      depth: depth,
      camera: camera,
      horizScale: 1.0,
      source: placementSource,
      frame: frame,
      fixedHalfExtents: fixedHalfExtents
    )
    placeAndHoldDepthLocked = true

    NSLog("◎ [SpatialTarget] ✅ Map target %@ locked at (%.3f,%.3f,%.3f), distance %.2fm, placement=%@ via %@",
          objectName, target.x, target.y, target.z, depth,
          spatialTargetIsSurfacePlacement ? "surface" : "camera_pose(legacy)", placementSource)
    if !spatialTargetIsSurfacePlacement && guidanceAudioEnabled {
      // Legacy pin marks where the mapper STOOD, not the object itself.
      // Tell the user so the last half-meter is on their hands, not the box.
      say("Guiding you to the saved spot near \(objectName). It is within arm's reach from there.")
    }
  }

  /// The POI ARAnchor restored from the saved ARWorldMap, if relocalization
  /// has brought it back. Matched by identifier once seen, by name before.
  private func restoredSpatialPOIAnchor(in frame: ARFrame) -> ARAnchor? {
    if let id = spatialPOIAnchorUUID,
       let cached = frame.anchors.first(where: { $0.identifier == id }) {
      return cached
    }
    let wanted = Set(
      [spatialTargetPOIName ?? "", objectName]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        .filter { !$0.isEmpty }
    )
    guard !wanted.isEmpty else { return nil }
    return frame.anchors.first { anchor in
      guard let name = anchor.name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
        return false
      }
      return wanted.contains(name)
    }
  }

  /// Keep the target glued to the restored map anchor. ARKit moves the
  /// anchor as relocalization refines (loop closures, yaw corrections); the
  /// target must move WITH it or it drifts off the real object — this is the
  /// primary fix for the box parking a metre from the pinned doorknob.
  /// Deltas are applied on top of the current target so surface-snap and
  /// extent corrections are preserved; a large refinement re-arms both
  /// passes since their evidence was gathered against the old position.
  private func followSpatialPOIAnchor(_ frame: ARFrame) {
    guard anchorPlaced else { return }
    guard let poiAnchor = restoredSpatialPOIAnchor(in: frame),
          let lastPin = spatialPOIAnchorLastPosition else { return }
    let pos = simd_make_float3(poiAnchor.transform.columns.3)
    let delta = pos - lastPin
    let shift = simd_length(delta)
    spatialPOIAnchorUUID = poiAnchor.identifier
    guard shift > 0.015 else { return }
    spatialPOIAnchorLastPosition = pos

    if let current = objectWorldPosition {
      objectWorldPosition = current + delta
      objectWorldCornerTR += delta
      objectWorldCornerBL += delta
    }
    if shift > 0.25 {
      spatialAnchorSnapLocked = false
      spatialAnchorSnapHits.removeAll()
      extentRefineLocked = false
      extentRefineAttempts = 0
      extentCandidates.removeAll()
    }
    NSLog("◎ [SpatialTarget] 🔗 Map anchor moved %.0fcm (relocalization refinement) — target follows%@",
          shift * 100, shift > 0.25 ? "; snap/extent re-armed" : "")
  }

  private func speakSpatialTargetRelocalizationCueIfNeeded() {
    guard guidanceAudioEnabled else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - spatialTargetRelocalizationCueLastAt >= spatialTargetRelocalizationCueIntervalSec else {
      return
    }
    spatialTargetRelocalizationCueLastAt = now
    spatialTargetRelocalizationCueCount += 1
    switch spatialTargetRelocalizationCueCount {
    case 1:
      say("Finding the saved map. Move the phone slowly and point toward the mapped shelf.")
    default:
      say("Still matching the map. Keep panning slowly across the shelf in front of you.")
    }
  }

  private func placeAndHoldInitialBboxReady(_ frame: ARFrame) -> Bool {
    switch initialReseedStatus {
    case .pending:
      if arFrameCount >= initialReseedFrameWait {
        initialReseedStatus = .inFlight
        requestInitialBboxFromAR(frame: frame)
      }
      return false
    case .inFlight:
      let elapsed = ProcessInfo.processInfo.systemUptime - initialReseedStartTime
      if elapsed > initialReseedTimeoutSec {
        NSLog("🅿️ [PlaceHold] Initial reseed timed out after %.1fs — using original bbox", elapsed)
        initialReseedStatus = .failed
        detectionFrameCameraTransform = nil
      }
      return false
    case .succeeded, .failed, .skipped:
      return true
    }
  }

  private func attemptPlaceAndHold(_ frame: ARFrame) {
    let camera = frame.camera
    let framesSinceStart = arFrameCount
    if framesSinceStart < 5 { return }

    let sw = cachedSW, sh = cachedSH
    let viewSize = CGSize(width: sw, height: sh)

    // ── Bbox center — photo coords map directly, no mirror ──────────────
    let photoCenterX = (bboxNormalized[0] + bboxNormalized[2]) / 2
    let photoCenterY = (bboxNormalized[1] + bboxNormalized[3]) / 2

    // ── FOV crop correction ─────────────────────────────────────────────
    let imgRes = camera.imageResolution  // 1920×1440 landscape
    let arW = imgRes.width, arH = imgRes.height
    let arPortraitAspect = arH / arW
    let photoPortraitAspect = imageWidth / imageHeight
    let horizScale: CGFloat
    let horizOffset: CGFloat
    if photoPortraitAspect < arPortraitAspect - 0.01 {
      horizScale = photoPortraitAspect / arPortraitAspect
      horizOffset = (1.0 - horizScale) / 2.0
    } else {
      horizScale = 1.0; horizOffset = 0.0
    }

    let arNormX = photoCenterX * horizScale + horizOffset
    let arNormY = photoCenterY

    // ── Portrait → landscape pixels for intrinsics ──────────────────────
    let arPxX = arNormY * arW
    let arPxY = (1.0 - arNormX) * arH

    let intr = camera.intrinsics
    let fx = CGFloat(intr[0][0]), fy = CGFloat(intr[1][1])
    let cx = CGFloat(intr[2][0]), cy = CGFloat(intr[2][1])
    let rX = Float((arPxX - cx) / fx)
    let rY = Float((arPxY - cy) / fy)
    let rayCam = simd_normalize(simd_float3(rX, -rY, -1.0))

    let placementT = detectionFrameCameraTransform ?? camera.transform
    let poseSource = detectionFrameCameraTransform == nil ? "live pose" : "saved detection pose"
    let worldRayDir = simd_normalize(simd_make_float3(placementT * simd_float4(rayCam, 0)))
    let camPos = simd_make_float3(placementT.columns.3)

    NSLog("🅿️ [PlaceHold] photo(%.3f,%.3f)→AR(%.3f,%.3f)→px(%.0f,%.0f) ray=(%.3f,%.3f,%.3f) pose=%@",
          photoCenterX, photoCenterY, arNormX, arNormY, arPxX, arPxY,
          worldRayDir.x, worldRayDir.y, worldRayDir.z, poseSource)
    speakInitialDirection(photoCenterX: photoCenterX, photoCenterY: photoCenterY)

    // ═══════════════════════════════════════════════════════════════════════
    // PLACE IMMEDIATELY — never block on DAv2.
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Blocking placement on DAv2 was the "box shows up a minute later" bug:
    // DAv2 needs an ARKit scale anchor, and on a non-LiDAR device that anchor
    // doesn't exist until the user has walked around long enough for planes to
    // form. The old state machine held EVERY frame until then.
    //
    // Now we place NOW from the best depth available this frame (raycast →
    // backend → near default) and arm DAv2 to run IN PARALLEL. tryDav2Refine()
    // snaps the anchor to the DAv2 metric depth a frame or two later, the
    // moment DAv2 succeeds — without ever freezing the box.
    // ═══════════════════════════════════════════════════════════════════════

    var placedDepth: Float? = nil
    var placedSource = ""

    // 0. LiDAR fast-path (Pro / LiDAR devices). Read true metric depth straight
    //    from the ARKit scene depth map at the bbox center — accurate on the
    //    first frame, no plane/feature-point wait and no DAv2 needed. Non-LiDAR
    //    devices skip this (sampleLiDARDepth guards on hasLiDAR) and fall through
    //    to the existing raycast → feature-point → default ladder UNCHANGED, so
    //    behaviour on non-Pro hardware is identical to before.
    if hasLiDAR {
      let lidarScreenCenter = CGPoint(x: CGFloat(arNormX) * sw, y: CGFloat(arNormY) * sh)
      if let lidarDepth = sampleLiDARDepth(frame: frame, screenCenter: lidarScreenCenter) {
        placedDepth = lidarDepth
        placedSource = "lidar"
        lidarDepthSeeded = true
        NSLog("🅿️ [PlaceHold] 🎯 LiDAR depth: %.2fm — skipping raycast/DAv2 ladder", lidarDepth)
      }
    }

    // 1. ARKit raycast along the bbox ray — best immediate depth IF a plane
    //    already exists. Usually nothing this early; that's expected.
    //    Skipped when LiDAR already supplied metric depth.
    if placedDepth == nil {
      let targets: [(ARRaycastQuery.Target, String)] = [
        (.existingPlaneGeometry, "existingGeometry"),
        (.estimatedPlane,        "estimatedPlane"),
      ]
      for (target, label) in targets {
        let query = ARRaycastQuery(origin: camPos, direction: worldRayDir,
                                   allowing: target, alignment: .any)
        if let hit = sceneView.session.raycast(query).first {
          let hitPos = simd_make_float3(hit.worldTransform.columns.3)
          let d = simd_length(hitPos - camPos)
          if d >= 0.15 && d <= 5.0 {
            placedDepth = d; placedSource = "raycast:\(label)"; break
          }
        }
      }
    }

    // 2. Feature-point cone depth (no planes needed). Use the median distance
    //    of points near the bbox ray to avoid far-wall hits.
    if placedDepth == nil, let cloud = frame.rawFeaturePoints {
      var dists: [Float] = []
      dists.reserveCapacity(min(cloud.points.count, 64))
      let coneCos: Float = 0.94  // ~20 deg
      for p in cloud.points {
        let toP = p - camPos
        let d = simd_length(toP)
        guard d > 0.25 && d < 4.0 else { continue }
        let dot = simd_dot(toP / d, worldRayDir)
        if dot > coneCos { dists.append(d) }
      }
      if dists.count >= 6 {
        dists.sort()
        let n = dists.count
        let median = n % 2 == 0 ? (dists[n/2-1] + dists[n/2]) / 2.0 : dists[n/2]
        let q1 = dists[n/4], q3 = dists[3*n/4]
        let iqr = q3 - q1
        if iqr < 0.25 {
          placedDepth = median
          placedSource = "featurePoints"
        }
      }
    }

    // 3. Scene-distance default.
    //    ARKit continuous refinement + DAv2 correct this as planes form.
    let depth = placedDepth ?? placeAndHoldDefaultDepth
    if placedDepth == nil {
      placedSource = String(format: "default(%.1fm, refinement pending)", placeAndHoldDefaultDepth)
    }

    let worldPos = camPos + worldRayDir * depth

    // Stash the ray so a late DAv2 result can re-place along the same bearing.
    placementRayOrigin = camPos
    placementRayDir = worldRayDir
    placementHorizScale = horizScale

    finalizePlacement(worldPos: worldPos, depth: depth, camera: camera,
                      horizScale: horizScale, source: "\(placedSource), \(poseSource)", frame: frame)
    detectionFrameCameraTransform = nil

    // Arm parallel DAv2 refinement — UNLESS LiDAR already gave us true metric
    // depth this frame, in which case there is nothing to refine.
    if placedSource == "lidar" {
      dav2RefineState = .done
      NSLog("🅿️ [PlaceHold] 🎯 LiDAR metric depth used — DAv2 refinement not armed")
    } else {
      dav2RefineState = .pending
      dav2RequestInFlight = false
      dav2NoAnchorLogCount = 0
      dav2RefineDeadline = ProcessInfo.processInfo.systemUptime + dav2RefineWindowSec
      NSLog("🅿️ [PlaceHold] 🌊 DAv2 refinement armed (%.0fs window) — placement NOT blocked", dav2RefineWindowSec)
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Parallel DAv2 Depth Refinement
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Runs DAv2 metric-depth estimation IN PARALLEL with the live guidance loop,
  // after the anchor is already placed. Non-blocking: at most one inference is
  // in flight at a time, and the whole thing self-disables after the first
  // success or once the refine window expires. The box is already on screen
  // and guiding the user the entire time this runs.

  func tryDav2Refine(_ frame: ARFrame) {
    guard dav2RefineState == .pending, !dav2RequestInFlight else { return }

    if ProcessInfo.processInfo.systemUptime > dav2RefineDeadline {
      dav2RefineState = .done
      NSLog("🅿️ [PlaceHold] 🌊 DAv2 refine window expired — keeping fallback depth %.2fm", anchorDepth)
      return
    }

    // AR-portrait normalized bbox for DAv2 (crop-corrected X, same column the
    // placement ray points through).
    let hs = placementHorizScale
    let ho = (1.0 - hs) / 2.0
    let arBboxNormalized: [CGFloat] = [
      bboxNormalized[0] * hs + ho, bboxNormalized[1],
      bboxNormalized[2] * hs + ho, bboxNormalized[3]
    ]

    dav2RequestInFlight = true
    estimateMetricDepth(frame: frame, bboxARNormalized: arBboxNormalized) { [weak self] estimate in
      guard let self = self else { return }
      self.dav2RequestInFlight = false
      guard self.dav2RefineState == .pending else { return }
      if let estimate = estimate, self.applyDav2Depth(estimate) {
        self.dav2RefineState = .done
      }
      // nil → still .pending; the next frame retries until the deadline.
    }
  }

  /// Snap the already-placed anchor to a DAv2 metric depth along the stored
  /// placement ray. Runs on visionQ (estimateMetricDepth's completion queue),
  /// the same queue as frame processing — no locking needed.
  @discardableResult
  private func applyDav2Depth(_ estimate: DAv2MetricDepthEstimate) -> Bool {
    guard anchorPlaced else { return false }
    let metric = estimate.depth
    let oldDepth = anchorDepth
    guard metric > 0.20 && metric < 5.0 else {
      NSLog("🅿️ [PlaceHold] 🌊 Rejected DAv2 depth %.2fm (out of range)", metric)
      return false
    }

    let delta = abs(metric - oldDepth)
    let offBboxScaleAnchor = estimate.anchorLabel != "bbox center"
      && !estimate.anchorLabel.hasPrefix("featurePoints")
    if offBboxScaleAnchor && delta > 0.25 {
      if metric < oldDepth && estimate.ratio < 0.75 {
        NSLog("🅿️ [PlaceHold] 🌊 Holding DAv2 %.2fm from %@ (anchor=%.2fm ratio=%.3f) — off-bbox shrink from %.2fm needs ARKit vote",
              metric, estimate.anchorLabel, estimate.anchorDepth, estimate.ratio, oldDepth)
        return false
      }
      if metric > oldDepth && estimate.ratio > 1.45 {
        NSLog("🅿️ [PlaceHold] 🌊 Holding DAv2 %.2fm from %@ (anchor=%.2fm ratio=%.3f) — off-bbox expansion from %.2fm needs ARKit vote",
              metric, estimate.anchorLabel, estimate.anchorDepth, estimate.ratio, oldDepth)
        return false
      }
    }

    applyPlaceAndHoldDepth(metric, source: "DAv2")
    placeAndHoldRefinementHits.removeAll()

    NSLog("🅿️ [PlaceHold] 🌊 ✅ DAv2 refined depth %.2fm → %.2fm (Δ%.0fcm, source=%@, ratio=%.3f)",
          oldDepth, metric, delta * 100, estimate.anchorLabel, estimate.ratio)
    return true
  }

  private func tryPlaceAndHoldLockedRayDepthRefine(frame: ARFrame) {
    guard anchorPlaced else { return }
    guard simd_length(placementRayDir) > 0.5 else { return }

    var candidateDepth: Float?
    var candidateSource = ""

    // 1. ARKit planes along the original bbox ray. This is the important
    // distinction from legacy refinement: current phone aim never changes
    // the target bearing.
    for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
      let query = ARRaycastQuery(origin: placementRayOrigin, direction: placementRayDir,
                                 allowing: target, alignment: .any)
      for hit in sceneView.session.raycast(query) {
        let hp = simd_make_float3(hit.worldTransform.columns.3)
        let d = simd_dot(hp - placementRayOrigin, placementRayDir)
        guard d > 0.25 && d < 4.5 else { continue }

        if mode == .handFree && hit.targetAlignment == .horizontal {
          let belowPlacementCamera = placementRayOrigin.y - hp.y
          if belowPlacementCamera > 1.1 {
            NSLog("🅿️ [PlaceHoldRefine] Skipped floor hit %.2fm below placement camera", belowPlacementCamera)
            continue
          }
        }

        candidateDepth = d
        candidateSource = target == .existingPlaneGeometry ? "existingPlaneLockedRay" : "estimatedPlaneLockedRay"
        break
      }
      if candidateDepth != nil { break }
    }

    // 2. Feature points close to the original ray. Use a tube, not only a
    // cone, so far wall points in the same general direction do not dominate.
    if candidateDepth == nil, let cloud = frame.rawFeaturePoints {
      var dists: [Float] = []
      dists.reserveCapacity(min(cloud.points.count, 64))
      for p in cloud.points {
        let fromOrigin = p - placementRayOrigin
        let along = simd_dot(fromOrigin, placementRayDir)
        guard along > 0.25 && along < 4.5 else { continue }

        let closest = placementRayOrigin + placementRayDir * along
        let lateral = simd_length(p - closest)
        let maxLateral = max(0.06, along * 0.08)
        guard lateral <= maxLateral else { continue }

        dists.append(along)
      }

      if dists.count >= 5 {
        dists.sort()
        let n = dists.count
        let median = n % 2 == 0 ? (dists[n/2-1] + dists[n/2]) / 2.0 : dists[n/2]
        let q1 = dists[n/4], q3 = dists[3*n/4]
        let iqr = q3 - q1
        if iqr < 0.12 {
          candidateDepth = median
          candidateSource = "featurePointTube(\(dists.count))"
        }
      }
    }

    guard let depth = candidateDepth else {
      if arFrameCount % 90 == 0 {
        NSLog("🅿️ [PlaceHoldRefine] No locked-ray depth yet (%d buffered)", placeAndHoldRefinementHits.count)
      }
      return
    }

    let jump = abs(depth - anchorDepth)
    if jump > placeAndHoldRefinementHardJump {
      _ = recordPlaceAndHoldAlternateDepth(depth, source: candidateSource)
      return
    }

    let softRebaseJump = max(anchorDepth * 0.35, 0.55)
    if jump > softRebaseJump,
       recordPlaceAndHoldAlternateDepth(depth, source: candidateSource) {
      return
    }
    if jump < 0.30 {
      placeAndHoldAlternateDepthHits.removeAll()
    }

    placeAndHoldRefinementHits.append(depth)
    if placeAndHoldRefinementHits.count > placeAndHoldRefinementMaxHits {
      placeAndHoldRefinementHits.removeFirst()
    }

    NSLog("🅿️ [PlaceHoldRefine] Hit #%d: %.2fm via %@",
          placeAndHoldRefinementHits.count, depth, candidateSource)

    guard placeAndHoldRefinementHits.count >= placeAndHoldRefinementMinHits else { return }

    let sorted = placeAndHoldRefinementHits.sorted()
    let n = sorted.count
    let median = n % 2 == 0 ? (sorted[n/2-1] + sorted[n/2]) / 2.0 : sorted[n/2]
    let q1 = sorted[n/4], q3 = sorted[3*n/4]
    let iqr = q3 - q1

    guard iqr <= placeAndHoldRefinementIQR else {
      NSLog("🅿️ [PlaceHoldRefine] IQR %.2fm too wide (need %.2fm)", iqr, placeAndHoldRefinementIQR)
      return
    }

    let medianJump = abs(median - anchorDepth)
    let softJump = max(anchorDepth * 0.55, 0.45)
    if medianJump > softJump && placeAndHoldRefinementHits.count < placeAndHoldRefinementMaxHits {
      NSLog("🅿️ [PlaceHoldRefine] Median %.2fm differs %.0fcm from current %.2fm — waiting for max evidence",
            median, medianJump * 100, anchorDepth)
      return
    }

    let old = anchorDepth
    applyPlaceAndHoldDepth(median, source: "ARKit locked ray")
    placeAndHoldDepthLocked = true
    dav2RefineState = .done
    placeAndHoldRefinementHits.removeAll()

    NSLog("🅿️ [PlaceHoldRefine] ✅ DEPTH LOCKED %.2fm → %.2fm (IQR %.2fm, Δ%.0fcm)",
          old, median, iqr, abs(old - median) * 100)
  }

  @discardableResult
  private func recordPlaceAndHoldAlternateDepth(_ depth: Float, source: String) -> Bool {
    placeAndHoldAlternateDepthHits.append(depth)
    if placeAndHoldAlternateDepthHits.count > placeAndHoldAlternateDepthMaxHits {
      placeAndHoldAlternateDepthHits.removeFirst()
    }

    let count = placeAndHoldAlternateDepthHits.count
    if count <= 3 || count % 3 == 0 {
      NSLog("🅿️ [PlaceHoldRefine] Correction candidate %.2fm via %@ — collecting alternate evidence (%d/%d)",
            depth, source, count, placeAndHoldAlternateDepthMinHits)
    }

    guard count >= placeAndHoldAlternateDepthMinHits else { return false }

    let sorted = placeAndHoldAlternateDepthHits.sorted()
    let n = sorted.count
    let median = n % 2 == 0 ? (sorted[n/2-1] + sorted[n/2]) / 2.0 : sorted[n/2]
    let q1 = sorted[n/4], q3 = sorted[3*n/4]
    let iqr = q3 - q1

    guard iqr <= placeAndHoldAlternateDepthIQR else {
      NSLog("🅿️ [PlaceHoldRefine] Alternate cluster IQR %.2fm too wide (need %.2fm)",
            iqr, placeAndHoldAlternateDepthIQR)
      return false
    }

    let old = anchorDepth
    applyPlaceAndHoldDepth(median, source: "ARKit locked ray rebase")
    placeAndHoldAlternateDepthHits.removeAll()
    placeAndHoldRefinementHits.removeAll()

    if iqr <= placeAndHoldRefinementIQR {
      placeAndHoldDepthLocked = true
      dav2RefineState = .done
      NSLog("🅿️ [PlaceHoldRefine] ✅ DEPTH LOCKED %.2fm → %.2fm via alternate cluster (IQR %.2fm, Δ%.0fcm)",
            old, median, iqr, abs(old - median) * 100)
    } else {
      NSLog("🅿️ [PlaceHoldRefine] ✅ REBASED %.2fm → %.2fm via alternate cluster (IQR %.2fm, Δ%.0fcm) — continuing refinement",
            old, median, iqr, abs(old - median) * 100)
    }
    return true
  }

  private func applyPlaceAndHoldDepth(_ depth: Float, source: String) {
    let worldPos = placementRayOrigin + placementRayDir * depth
    objectWorldPosition = worldPos
    anchorDepth = depth
    liveDistanceToObject = depth
    placeAndHoldLastDepthSource = source

    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = min(depth * Float(bboxNormW * placementHorizScale) * 0.5, depth * 0.45)
    objectWorldHalfH = min(depth * Float(bboxNormH) * 0.5, depth * 0.45)

    if let camT = lastARFrame?.camera.transform {
      let right = -simd_normalize(simd_make_float3(camT.columns.1))
      let up    =  simd_normalize(simd_make_float3(camT.columns.0))
      objectWorldCornerTR = worldPos + right * objectWorldHalfW + up * objectWorldHalfH
      objectWorldCornerBL = worldPos - right * objectWorldHalfW - up * objectWorldHalfH
    }

    DispatchQueue.main.async { [weak self] in
      self?.distanceLabel.text = "\(Int(depth * 100)) cm"
    }
  }

  private func speakInitialDirection(photoCenterX: CGFloat, photoCenterY: CGFloat) {
    var dir = "straight ahead"
    if photoCenterX < 0.35 { dir = "to your left" }
    else if photoCenterX > 0.65 { dir = "to your right" }
    var vert = ""
    if photoCenterY < 0.30 { vert = " Point phone up." }
    else if photoCenterY > 0.70 { vert = " Point phone down." }
    let msg = "\(objectName) is \(dir).\(vert)"
    NSLog("🅿️ [PlaceHold] Direction: %@", msg)
    if guidanceAudioEnabled { say(msg) }
  }

    private func finalizePlacement(worldPos: simd_float3, depth: Float,
                                     camera: ARCamera, horizScale: CGFloat,
                                     source: String, frame: ARFrame,
                                     fixedHalfExtents: (w: Float, h: Float)? = nil) {
        objectWorldPosition = worldPos
        anchorDepth = depth
        liveDistanceToObject = depth
        placeAndHoldDepthLocked = false
        placeAndHoldRefinementHits.removeAll()
        placeAndHoldAlternateDepthHits.removeAll()
        placeAndHoldLastDepthSource = source

        if let fixedHalfExtents {
            // Spatial-target mode: the POI is a point on the object, there is
            // no detection box. Back-projecting the generic seed region at
            // lock distance made a hand-sized object metres wide (locked from
            // 9.75m → 1.56m × 2.34m box). Use real-world object extents.
            objectWorldHalfW = fixedHalfExtents.w
            objectWorldHalfH = fixedHalfExtents.h
        } else {
            // Box size from the REAL detected bbox — no cap, so the overlay
            // wraps the actual object instead of a fixed narrow pill.
            // Loose safety rail (depth * 0.45) only catches a runaway full-screen
            // VLM detection; real object boxes stay well under it.
            let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
            let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
            objectWorldHalfW = min(depth * Float(bboxNormW * horizScale) * 0.5, depth * 0.45)
            objectWorldHalfH = min(depth * Float(bboxNormH) * 0.5, depth * 0.45)
        }

        let camT = camera.transform
        let right = -simd_normalize(simd_make_float3(camT.columns.1))
        let up    =  simd_normalize(simd_make_float3(camT.columns.0))
        objectWorldCornerTR = worldPos + right * objectWorldHalfW + up * objectWorldHalfH
        objectWorldCornerBL = worldPos - right * objectWorldHalfW - up * objectWorldHalfH
        anchorPlaced = true

        NSLog("🅿️ [PlaceHold] ✅ ANCHOR at (%.3f,%.3f,%.3f) depth=%.2fm halfW=%.3f halfH=%.3f via %@",
              worldPos.x, worldPos.y, worldPos.z, depth, objectWorldHalfW, objectWorldHalfH, source)

        let viewSize = CGSize(width: cachedSW, height: cachedSH)
        let back = camera.projectPoint(worldPos, orientation: .portrait, viewportSize: viewSize)
        NSLog("🅿️ [PlaceHold] SelfCheck → screen (%.0f,%.0f)", back.x, back.y)

        // ── Seed visual tracker so subsequent refinement uses fresh 2D pixel target ──
        // Skipped in spatial-target mode: bboxNormalized is a generic centered
        // seed there, so the tracker would latch onto whatever happened to be
        // mid-screen at relocalization time, not the target object.
        if trackerEnabled, spatialTargetWorldPosition == nil {
          seedTracker(initialBboxPhotoNorm: bboxNormalized, frame: frame)
        }

        DispatchQueue.main.async { [weak self] in
          self?.distanceLabel.text = "\(Int(depth * 100)) cm"
        }
        say("Target locked.")
      }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Spatial Target Extent & Center Refinement (on-device Vision)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // A map POI is a POINT — it carries no object extent, so placement falls
  // back to name-prior box sizes, and the pin itself can sit tens of cm off
  // the real object (mapping-time raycast error + relocalization drift).
  // The surface snap above corrects DEPTH along the camera→pin ray, but
  // nothing corrected the LATERAL error or measured the box SIZE.
  //
  // This pass looks at the actual camera image: objectness-based saliency
  // (Apple Vision, fully on-device, ~20ms) on a crop around the projected
  // anchor point finds the distinct object nearest the pin. From its rect:
  //   - true metric half-extents  (rect px × depth / focal length)
  //   - a lateral correction      (anchor re-aimed along the rect-center ray
  //                                at the same camera distance — the surface
  //                                snap owns depth, this pass owns bearing)
  //
  // Safety gates — for a blind user a confidently WRONG box is worse than a
  // big honest one, so every step is evidence-gated:
  //   - candidate must lie within 30cm of the projected pin
  //   - metric size must be graspable-plausible (1.5–45cm half-extent)
  //   - 3-candidate consensus with ≤12cm world spread (same evidence style
  //     as the surface snap above)
  //   - total lateral correction bounded at 45cm; one-shot lock on success
  //   - never blocks guidance — Vision runs on its own queue, state changes
  //     apply on visionQ (see reaching-placement non-blocking rules)
  // On any failure it silently keeps the prior-sized box — never worse than
  // the behaviour before this pass existed.

  func tryRefineSpatialTargetExtent(_ frame: ARFrame) {
    guard spatialTargetWorldPosition != nil,
          anchorPlaced,
          !extentRefineLocked,
          !extentRefineInFlight,
          !hasCompleted,
          extentRefineAttempts < extentRefineMaxAttempts,
          let anchorPos = objectWorldPosition else { return }
    guard case .normal = frame.camera.trackingState else { return }

    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastExtentRefineAttemptAt >= extentRefineInterval else { return }

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let dist = simd_distance(anchorPos, camPos)
    // Too close → object overflows the frame; too far → too few pixels.
    guard dist >= 0.35, dist <= 3.0 else { return }

    // Camera must be aimed at the anchor and the anchor must project well
    // inside the frame, or the crop would clip the object.
    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    guard simd_dot(camFwd, simd_normalize(anchorPos - camPos)) > 0.85 else { return }
    guard let p = arPortraitNorm(of: anchorPos, camera: camera),
          p.x > 0.15, p.x < 0.85, p.y > 0.12, p.y < 0.88 else { return }

    lastExtentRefineAttemptAt = now
    extentRefineAttempts += 1
    extentRefineInFlight = true

    // Snapshot value types only — an ARFrame must not cross queues
    // (CVPixelBuffer is refcounted and safe, same pattern as DAv2).
    let pixelBuffer = frame.capturedImage
    let camTransform = camera.transform
    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution

    extentQ.async { [weak self] in
      guard let self = self else { return }
      guard self.running, !self.hasCompleted else {
        self.visionQ.async { self.extentRefineInFlight = false }
        return
      }
      let candidate = self.detectSpatialExtentCandidate(
        pixelBuffer: pixelBuffer,
        camTransform: camTransform,
        intrinsics: intrinsics,
        imageResolution: imgRes,
        projectedPoint: p,
        anchorDistance: dist
      )
      self.visionQ.async {
        self.extentRefineInFlight = false
        guard let candidate else { return }
        self.recordSpatialExtentCandidate(candidate)
      }
    }
  }

  /// Runs saliency on a crop around the projected pin and returns the best
  /// object candidate, or nil when nothing near the pin passes the gates.
  /// Pure function of its snapshot inputs — safe on extentQ.
  private func detectSpatialExtentCandidate(
    pixelBuffer: CVPixelBuffer,
    camTransform: simd_float4x4,
    intrinsics: simd_float3x3,
    imageResolution: CGSize,
    projectedPoint p: CGPoint,
    anchorDistance: Float
  ) -> SpatialExtentCandidate? {
    let arW = imageResolution.width, arH = imageResolution.height  // landscape, e.g. 1920×1440
    let fx = CGFloat(intrinsics[0][0]), fy = CGFloat(intrinsics[1][1])

    // Orient to portrait so we share the .right convention every other
    // Vision call in this pipeline uses. CIImage coords are bottom-left.
    let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
    let pw = ci.extent.width    // = arH
    let ph = ci.extent.height   // = arW

    // Portrait px per metre at the anchor. Portrait-x spans the landscape-y
    // axis (fy) and portrait-y spans landscape-x (fx) — see the
    // portrait→landscape pixel mapping in attemptPlaceAndHold.
    let pxPerMeterX = fy / CGFloat(anchorDistance)
    let pxPerMeterY = fx / CGFloat(anchorDistance)

    // Crop a window covering ~1.1m of scene around the pin: object + context
    // fits, and the small saliency net gets a zoomed view of the target
    // instead of the whole room.
    let cropW = min(max(pxPerMeterX * 1.1, pw * 0.28), pw * 0.8)
    let cropH = min(max(pxPerMeterY * 1.1, ph * 0.28), ph * 0.8)
    let pinCiX = p.x * pw
    let pinCiY = (1.0 - p.y) * ph   // portrait-norm is top-left, CI is bottom-left
    var crop = CGRect(x: pinCiX - cropW / 2, y: pinCiY - cropH / 2,
                      width: cropW, height: cropH)
    crop = crop.intersection(ci.extent).integral
    guard crop.width > 60, crop.height > 60 else { return nil }

    let cropped = ci.cropped(to: crop)
      .transformed(by: CGAffineTransform(translationX: -crop.origin.x, y: -crop.origin.y))

    let request = VNGenerateObjectnessBasedSaliencyImageRequest()
    let handler = VNImageRequestHandler(ciImage: cropped, orientation: .up, options: [:])
    do {
      try handler.perform([request])
    } catch {
      NSLog("◎ [ExtentRefine] Saliency failed: %@", error.localizedDescription)
      return nil
    }
    guard let salient = (request.results?.first as? VNSaliencyImageObservation)?.salientObjects,
          !salient.isEmpty else { return nil }

    // Pin position inside the crop — Vision-normalized (bottom-left origin),
    // same space as the salient rects.
    let pInCrop = CGPoint(x: (pinCiX - crop.origin.x) / crop.width,
                          y: (pinCiY - crop.origin.y) / crop.height)

    var bestRect: CGRect?
    var bestGap: Float = .greatestFiniteMagnitude
    var bestScore: Float = .greatestFiniteMagnitude
    for obs in salient {
      let r = obs.boundingBox   // normalized to the crop, bottom-left origin
      // Whole-crop blobs are the shelf/door/wall, not the object.
      if r.width > 0.92 && r.height > 0.92 { continue }
      // Metric size gate — graspable objects only.
      let halfWm = Float(r.width * crop.width / pxPerMeterX) / 2
      let halfHm = Float(r.height * crop.height / pxPerMeterY) / 2
      guard halfWm >= 0.015, halfWm <= 0.45,
            halfHm >= 0.015, halfHm <= 0.45 else { continue }
      // Must be at/near the pin.
      let dxM = Float((r.midX - pInCrop.x) * crop.width) / Float(pxPerMeterX)
      let dyM = Float((r.midY - pInCrop.y) * crop.height) / Float(pxPerMeterY)
      let gap = (dxM * dxM + dyM * dyM).squareRoot()
      guard gap <= 0.30 else { continue }
      // Prefer the rect containing the pin; break ties by distance.
      let score = r.contains(pInCrop) ? gap * 0.5 : gap
      if score < bestScore {
        bestScore = score
        bestGap = gap
        bestRect = r
      }
    }
    guard let chosen = bestRect else { return nil }

    // ── Chosen rect → world ──────────────────────────────────────────────
    // Rect center: crop Vision coords → full-portrait CI px → AR-portrait
    // norm (top-left) → landscape px → camera ray → world point at the
    // anchor's current camera distance. Angular correction only — the
    // surface snap owns depth.
    let centerCiX = crop.origin.x + chosen.midX * crop.width
    let centerCiY = crop.origin.y + chosen.midY * crop.height
    let portraitX = centerCiX / pw
    let portraitY = 1.0 - (centerCiY / ph)
    let arPxX = portraitY * arW
    let arPxY = (1.0 - portraitX) * arH
    let cxi = CGFloat(intrinsics[2][0]), cyi = CGFloat(intrinsics[2][1])
    let rX = Float((arPxX - cxi) / fx)
    let rY = Float((arPxY - cyi) / fy)
    let rayCam = simd_normalize(simd_float3(rX, -rY, -1.0))
    let worldRay = simd_normalize(simd_make_float3(camTransform * simd_float4(rayCam, 0)))
    let camPos = simd_make_float3(camTransform.columns.3)
    let worldCenter = camPos + worldRay * anchorDistance

    return SpatialExtentCandidate(
      worldCenter: worldCenter,
      halfW: Float(chosen.width * crop.width / pxPerMeterX) / 2,
      halfH: Float(chosen.height * crop.height / pxPerMeterY) / 2,
      gapMeters: bestGap
    )
  }

  /// Consensus + apply. Runs on visionQ (the pipeline's state-mutation queue).
  private func recordSpatialExtentCandidate(_ candidate: SpatialExtentCandidate) {
    guard !extentRefineLocked, anchorPlaced else { return }

    extentCandidates.append(candidate)
    if extentCandidates.count > 5 {
      extentCandidates.removeFirst()
    }
    NSLog("◎ [ExtentRefine] Candidate #%d: %.0f×%.0fcm, %.0fcm from pin (%d buffered)",
          extentRefineAttempts, candidate.halfW * 200, candidate.halfH * 200,
          candidate.gapMeters * 100, extentCandidates.count)

    guard extentCandidates.count >= 3 else { return }
    let recent = Array(extentCandidates.suffix(3))
    let centroid = (recent[0].worldCenter + recent[1].worldCenter + recent[2].worldCenter) / 3
    let spread = recent.map { simd_distance($0.worldCenter, centroid) }.max() ?? 0
    guard spread <= 0.12 else { return }

    guard let anchorPos = objectWorldPosition else { return }
    let correction = simd_distance(centroid, anchorPos)
    guard correction <= extentRefineMaxLateralCorrection else {
      // A stable object that far from the pin is probably a DIFFERENT
      // object — moving the anchor to it would guide the user's hand to
      // the wrong thing. Drop the cluster and keep looking.
      NSLog("◎ [ExtentRefine] Consistent object %.0fcm from anchor — beyond %.0fcm budget, rejecting cluster",
            correction * 100, extentRefineMaxLateralCorrection * 100)
      extentCandidates.removeAll()
      return
    }

    let medHalfW = recent.map { $0.halfW }.sorted()[1]
    let medHalfH = recent.map { $0.halfH }.sorted()[1]
    applySpatialExtentRefinement(center: centroid, halfW: medHalfW, halfH: medHalfH,
                                 correction: correction)
  }

  private func applySpatialExtentRefinement(center: simd_float3, halfW: Float, halfH: Float,
                                            correction: Float) {
    // Prior bounds the measurement: saliency occasionally merges the object
    // with its surroundings, and a runaway box would re-blur the centering
    // signal this pass exists to sharpen.
    let prior = spatialTargetPriorHalfExtents()
    let newHalfW = min(max(halfW, 0.02), max(prior.w * 2.5, 0.25))
    let newHalfH = min(max(halfH, 0.02), max(prior.h * 2.5, 0.30))
    let oldW = objectWorldHalfW, oldH = objectWorldHalfH

    objectWorldPosition = center
    objectWorldHalfW = newHalfW
    objectWorldHalfH = newHalfH
    if let camT = lastARFrame?.camera.transform {
      let camPos = simd_make_float3(camT.columns.3)
      anchorDepth = simd_distance(center, camPos)
      liveDistanceToObject = anchorDepth
      let right = -simd_normalize(simd_make_float3(camT.columns.1))
      let up    =  simd_normalize(simd_make_float3(camT.columns.0))
      objectWorldCornerTR = center + right * newHalfW + up * newHalfH
      objectWorldCornerBL = center - right * newHalfW - up * newHalfH
    }
    extentRefineLocked = true
    extentCandidates.removeAll()

    NSLog("◎ [ExtentRefine] ✅ LOCKED — box %.0f×%.0fcm → %.0f×%.0fcm, center corrected %.0fcm (saliency consensus)",
          oldW * 200, oldH * 200, newHalfW * 200, newHalfH * 200, correction * 100)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.distanceLabel.text = "\(Int(self.anchorDepth * 100)) cm"
    }
  }

  /// Blind size prior for the box, from the POI name. Used at placement and
  /// as the sanity bound for measured extents. If the saliency pass never
  /// locks, this is what the user gets — so it should describe the physical
  /// object, not the pin uncertainty.
  func spatialTargetPriorHalfExtents() -> (w: Float, h: Float) {
    // Split compound words the same way ReachingModule's POI lookup does,
    // or "Doorknob" never matches the "knob" token and falls to the default.
    let key = objectName.lowercased()
      .replacingOccurrences(of: "doorknob", with: "door knob")
      .replacingOccurrences(of: "doorhandle", with: "door handle")
    let tokens = Set(
      key
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
    )
    // Ordered — first matching row wins ("door handle" must hit the handle
    // row, not the door row).
    let table: [(tokens: [String], half: (w: Float, h: Float))] = [
      (["handle", "knob", "lever", "latch", "button", "switch", "keyhole", "lock"], (0.10, 0.07)),
      (["bottle", "can", "cup", "mug", "glass", "jar", "flask", "thermos"],         (0.07, 0.14)),
      (["phone", "remote", "wallet", "keys", "key", "card", "mouse", "glasses"],    (0.09, 0.07)),
      (["book", "folder", "tablet", "notebook", "laptop", "keyboard"],              (0.14, 0.11)),
      (["box", "package", "parcel", "bag", "backpack", "basket"],                   (0.18, 0.18)),
      (["door", "gate", "exit", "entrance", "doorway", "fridge", "cabinet"],        (0.40, 0.55)),
      (["chair", "seat", "stool", "desk", "table", "shelf", "counter"],             (0.35, 0.30)),
    ]
    for entry in table where !tokens.isDisjoint(with: entry.tokens) {
      return entry.half
    }
    return (0.14, 0.16)
  }

  /// Project a world point into AR-portrait normalized coordinates
  /// (top-left origin) — the inverse of the ray construction used across
  /// this pipeline (see attemptPlaceAndHold). nil when behind the camera.
  private func arPortraitNorm(of world: simd_float3, camera: ARCamera) -> CGPoint? {
    let local = simd_inverse(camera.transform) * simd_float4(world, 1)
    guard local.z < -0.05 else { return nil }   // camera looks down -z
    let intr = camera.intrinsics
    let fx = CGFloat(intr[0][0]), fy = CGFloat(intr[1][1])
    let cx = CGFloat(intr[2][0]), cy = CGFloat(intr[2][1])
    let pxX = cx + fx * CGFloat(local.x / -local.z)
    let pxY = cy + fy * CGFloat(local.y / local.z)
    let imgRes = camera.imageResolution
    // Landscape px → portrait norm: inverse of pxX = pY·W, pxY = (1-pX)·H
    return CGPoint(x: 1.0 - pxY / imgRes.height, y: pxX / imgRes.width)
  }
}
