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
      attemptPlaceAndHold(frame)
      return true
    }
    tryDav2Refine(frame)        // parallel, non-blocking DAv2 depth correction

    // ── Visual Tracker ──────────────────────────────────────────────────
    // Disabled for place-and-hold to prevent lateral drift from noisy 2D
    // tracking while the anchor should stay locked in world space.

    // ── Continuous ARKit depth refinement ──────────────────────────────
    // Critical fix: without this, the anchor depth is FROZEN after
    // DAv2's one-shot estimate. As the user walks and ARKit detects
    // planes, raycast refinement corrects the depth continuously.
    // This is the same refinement loop the non-prototype path runs.
    if anchorRefinementFrames == 0 { anchorRefinementFrames = 1 }
    anchorRefinementFrames += 1
    if anchorRefinementFrames >= anchorRefinementLimit {
      anchorRefinementFrames = 1  // keep refining forever
    }
    tryRefineAnchorDepth(frame: frame)

    processARFrameHandFree(frame)
    return true
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

    let camT = camera.transform
    let worldRayDir = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos = simd_make_float3(camT.columns.3)

    if framesSinceStart == 5 {
      NSLog("🅿️ [PlaceHold] photo(%.3f,%.3f)→AR(%.3f,%.3f)→px(%.0f,%.0f) ray=(%.3f,%.3f,%.3f)",
            photoCenterX, photoCenterY, arNormX, arNormY, arPxX, arPxY,
            worldRayDir.x, worldRayDir.y, worldRayDir.z)
      speakInitialDirection(photoCenterX: photoCenterX, photoCenterY: photoCenterY)
    }

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

    // 3. Scene-distance default — 0.9m is typical desk reach.
    //    ARKit continuous refinement + DAv2 correct this as planes form.
    let depth = placedDepth ?? 0.9
    if placedDepth == nil { placedSource = "default(0.9m, refinement pending)" }

    let worldPos = camPos + worldRayDir * depth

    // Stash the ray so a late DAv2 result can re-place along the same bearing.
    placementRayOrigin = camPos
    placementRayDir = worldRayDir
    placementHorizScale = horizScale

    finalizePlacement(worldPos: worldPos, depth: depth, camera: camera,
                      horizScale: horizScale, source: placedSource, frame: frame)

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
    estimateMetricDepth(frame: frame, bboxARNormalized: arBboxNormalized) { [weak self] metric in
      guard let self = self else { return }
      self.dav2RequestInFlight = false
      guard self.dav2RefineState == .pending else { return }
      if let m = metric {
        self.dav2RefineState = .done
        self.applyDav2Depth(m)
      }
      // nil → still .pending; the next frame retries until the deadline.
    }
  }

  /// Snap the already-placed anchor to a DAv2 metric depth along the stored
  /// placement ray. Runs on visionQ (estimateMetricDepth's completion queue),
  /// the same queue as frame processing — no locking needed.
  private func applyDav2Depth(_ metric: Float) {
    guard anchorPlaced else { return }
    let oldDepth = anchorDepth
    let worldPos = placementRayOrigin + placementRayDir * metric
    objectWorldPosition  = worldPos
    anchorDepth          = metric
    liveDistanceToObject = metric

    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = min(metric * Float(bboxNormW * placementHorizScale) * 0.5, metric * 0.45)
    objectWorldHalfH = min(metric * Float(bboxNormH) * 0.5, metric * 0.45)

    // Re-billboard from the most recent camera so the corners stay upright.
    if let camT = lastARFrame?.camera.transform {
      let right = -simd_normalize(simd_make_float3(camT.columns.1))
      let up    =  simd_normalize(simd_make_float3(camT.columns.0))
      objectWorldCornerTR = worldPos + right * objectWorldHalfW + up * objectWorldHalfH
      objectWorldCornerBL = worldPos - right * objectWorldHalfW - up * objectWorldHalfH
    }

    NSLog("🅿️ [PlaceHold] 🌊 ✅ DAv2 refined depth %.2fm → %.2fm (Δ%.0fcm)",
          oldDepth, metric, abs(metric - oldDepth) * 100)
    placeAndHoldDepthLocked = true
    DispatchQueue.main.async { [weak self] in
      self?.distanceLabel.text = "\(Int(metric * 100)) cm"
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