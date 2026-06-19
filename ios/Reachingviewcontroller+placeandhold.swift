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

    processARFrameHandFree(frame)
    return true
  }

  private func attemptSpatialTargetPlacement(_ frame: ARFrame) {
    guard let target = spatialTargetWorldPosition else { return }
    guard arFrameCount >= 5 else { return }

    switch frame.camera.trackingState {
    case .normal:
      break
    default:
      if arFrameCount % 30 == 0 {
        NSLog("◎ [SpatialTarget] Waiting for ARKit relocalization before placing %@",
              objectName)
      }
      return
    }

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let offset = target - camPos
    let depth = simd_length(offset)
    guard depth >= 0.10 && depth <= 12.0 else {
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

    finalizePlacement(
      worldPos: target,
      depth: depth,
      camera: camera,
      horizScale: 1.0,
      source: "saved map POI \(spatialTargetMapName ?? "unknown map")",
      frame: frame
    )
    placeAndHoldDepthLocked = true

    NSLog("◎ [SpatialTarget] ✅ Map target %@ locked at (%.3f,%.3f,%.3f), distance %.2fm",
          objectName, target.x, target.y, target.z, depth)
    if guidanceAudioEnabled {
      say("Map target locked.")
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

    // 1. ARKit raycast along the bbox ray — best immediate depth IF a plane
    //    already exists. Usually nothing this early; that's expected.
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

    // Arm parallel DAv2 refinement — handled by tryDav2Refine() on later frames.
    dav2RefineState = .pending
    dav2RequestInFlight = false
    dav2NoAnchorLogCount = 0
    dav2RefineDeadline = ProcessInfo.processInfo.systemUptime + dav2RefineWindowSec
    NSLog("🅿️ [PlaceHold] 🌊 DAv2 refinement armed (%.0fs window) — placement NOT blocked", dav2RefineWindowSec)
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
                                     source: String, frame: ARFrame) {
        objectWorldPosition = worldPos
        anchorDepth = depth
        liveDistanceToObject = depth
        placeAndHoldDepthLocked = false
        placeAndHoldRefinementHits.removeAll()
        placeAndHoldAlternateDepthHits.removeAll()
        placeAndHoldLastDepthSource = source

        // Box size from the REAL detected bbox — no cap, so the overlay
        // wraps the actual object instead of a fixed narrow pill.
        // Loose safety rail (depth * 0.45) only catches a runaway full-screen
        // VLM detection; real object boxes stay well under it.
        let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
        let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
        objectWorldHalfW = min(depth * Float(bboxNormW * horizScale) * 0.5, depth * 0.45)
        objectWorldHalfH = min(depth * Float(bboxNormH) * 0.5, depth * 0.45)

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
        if trackerEnabled {
          seedTracker(initialBboxPhotoNorm: bboxNormalized, frame: frame)
        }

        DispatchQueue.main.async { [weak self] in
          self?.distanceLabel.text = "\(Int(depth * 100)) cm"
        }
        say("Target locked.")
      }
}
