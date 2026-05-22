//
//  Reachingviewcontroller+placeAndHold.swift
//  shelfscout
//
//  PLACE-AND-HOLD v7 — X-mirror fix + clean placement.
//
//  THE BUG: VisionCamera's OrientationFix produces a photo that is
//  horizontally mirrored relative to what ARKit's capturedImage shows.
//  Photo X must be flipped (X → 1-X) before computing the placement ray.
//  Objects near center-X worked because X ≈ 1-X; off-center objects
//  were placed on the mirror-image side every time.

import ARKit

extension ReachingViewController {

  func handlePlaceAndHoldFrame(_ frame: ARFrame) -> Bool {
    guard placeAndHoldPrototype else { return false }
    if !anchorPlaced {
      attemptPlaceAndHold(frame)
      return true
    }
    processARFrameHandFree(frame)
    return true
  }

  private func attemptPlaceAndHold(_ frame: ARFrame) {
    let camera = frame.camera
    let framesSinceStart = arFrameCount
    if framesSinceStart < 5 { return }

    let sw = cachedSW, sh = cachedSH
    let viewSize = CGSize(width: sw, height: sh)

    // ── Bbox center — FLIP X to fix the mirror ──────────────────────────
    let rawCenterX = (bboxNormalized[0] + bboxNormalized[2]) / 2
    let photoCenterX = 1.0 - rawCenterX   // ← THE FIX
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

    // ── Try ARKit raycast along the bbox ray ─────────────────────────────
    let targets: [(ARRaycastQuery.Target, ARRaycastQuery.TargetAlignment, String)] = [
      (.existingPlaneGeometry, .any, "existingGeometry"),
      (.estimatedPlane,        .any, "estimatedPlane"),
    ]
    for (target, alignment, label) in targets {
      let query = ARRaycastQuery(origin: camPos, direction: worldRayDir,
                                 allowing: target, alignment: alignment)
      let results = sceneView.session.raycast(query)
      if let hit = results.first {
        let hitPos = simd_make_float3(hit.worldTransform.columns.3)
        let d = simd_length(hitPos - camPos)
        if d >= 0.15 && d <= 5.0 {
          NSLog("🅿️ [PlaceHold] ✅ ARKit HIT at %.2fm via %@", d, label)
          finalizePlacement(worldPos: hitPos, depth: d, camera: camera,
                            horizScale: horizScale, source: "raycast:\(label)")
          return
        }
      }
    }

    // ── No hit — use backend depth if available ─────────────────────────
    if let bd = backendDepth, bd >= 0.1, bd <= 10.0 {
      let worldPos = camPos + worldRayDir * bd
      NSLog("🅿️ [PlaceHold] No raycast hit — placing at backend depth %.2fm", bd)
      finalizePlacement(worldPos: worldPos, depth: bd, camera: camera,
                        horizScale: horizScale, source: "backend-depth")
      return
    }

    // ── No depth — wait for geometry ────────────────────────────────────
    let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartTime
    if elapsed < 10.0 {
      if framesSinceStart % 30 == 0 {
        NSLog("🅿️ [PlaceHold] no hit, no backend depth (%.1fs) — waiting", elapsed)
      }
      return
    }

    NSLog("🅿️ [PlaceHold] ⚠️ FALLBACK 1.0m")
    let worldPos = camPos + worldRayDir * Float(1.0)
    finalizePlacement(worldPos: worldPos, depth: 1.0, camera: camera,
                      horizScale: horizScale, source: "fixed-fallback")
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
                                   source: String) {
      objectWorldPosition = worldPos
      anchorDepth = depth
      liveDistanceToObject = depth

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

      DispatchQueue.main.async { [weak self] in
        self?.distanceLabel.text = "\(Int(depth * 100)) cm"
      }
      say("Target locked.")
    }
}
