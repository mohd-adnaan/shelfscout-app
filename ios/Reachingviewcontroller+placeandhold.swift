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
    // DEPTH SOURCE — DAv2 metric depth is PRIMARY.
    // ═══════════════════════════════════════════════════════════════════════
    //
    // The old ladder (raw raycast → backend-relative → fixed 1.0m) was the
    // root cause of every mis-placed box: on a non-LiDAR device the first
    // raycast at frame 5 lands on the floor/back-wall (or nothing), and the
    // fixed fallback slammed the anchor down the ray onto whatever was behind
    // the object. The bearing was right; the DISTANCE was garbage.
    //
    // DepthAnythingV2 gives a learned metric depth at the bbox center,
    // scale-anchored to ONE raycast (the raycast is now just a metre
    // reference for DAv2 — we never *place* from it directly). We kick it
    // off once, hold placement until it returns, then place at the DAv2
    // depth down the SAME bbox ray. Only if DAv2 is genuinely unavailable
    // (model missing, or no plane anywhere yet for the scale anchor) do we
    // fall through to the legacy ladder.
    // ═══════════════════════════════════════════════════════════════════════

    // AR-portrait normalized bbox for DAv2 (it re-derives the landscape pixel
    // mapping internally; pass the crop-corrected X so DAv2 samples the same
    // pixel column the placement ray points through).
    let arBboxNormalized: [CGFloat] = [
      bboxNormalized[0] * horizScale + horizOffset, bboxNormalized[1],
      bboxNormalized[2] * horizScale + horizOffset, bboxNormalized[3]
    ]

    switch dav2PlacementState {
    case .idle:
      dav2PlacementState = .inFlight
      // Set the deadline clock only on the FIRST kickoff. Synchronous "no
      // plane yet" nils bounce us back to .idle and re-enter here each frame;
      // if we reset the clock every time, the dav2MaxWaitSec deadline would
      // never accumulate and we'd retry forever. dav2KickoffTime == 0 means
      // "never started".
      if dav2KickoffTime == 0 {
        dav2KickoffTime = ProcessInfo.processInfo.systemUptime
        NSLog("🅿️ [PlaceHold] 🌊 Kicking off DAv2 metric depth estimate…")
      }
      estimateMetricDepth(frame: frame, bboxARNormalized: arBboxNormalized) { [weak self] metric in
        guard let self = self else { return }
        if let m = metric {
          // Success — DAv2 produced a metric depth. Place on the next frame.
          self.dav2MetricDepth = m
          self.dav2PlacementState = .done
          NSLog("🅿️ [PlaceHold] 🌊 DAv2 returned %.2fm", m)
        } else {
          // nil = either the model is missing, OR (the common early case) no
          // ARKit plane exists yet to scale-anchor against. The latter is
          // TRANSIENT: planes form over the next 1–2s. We must NOT lock to
          // .done here — that would permanently skip DAv2 on the very first
          // frame, before any plane exists, which is precisely the failure we
          // are fixing. Reset to .idle so the next frame retries; the
          // dav2MaxWaitSec deadline (checked in .inFlight) bounds the retries.
          self.dav2PlacementState = .idle
          NSLog("🅿️ [PlaceHold] 🌊 DAv2 nil (no scale anchor yet or model missing) — will retry until %.1fs deadline", self.dav2MaxWaitSec)
        }
      }
      return  // hold this frame; placement happens once .done

    case .inFlight:
      // Either DAv2 inference is genuinely in flight, OR a synchronous nil
      // bounced us back to .idle and we're between retries. Bound total wait
      // from the FIRST kickoff so repeated "no plane yet" nils can't stall
      // placement forever — after dav2MaxWaitSec, give up on DAv2 and let the
      // fallback ladder take over.
      let waited = ProcessInfo.processInfo.systemUptime - dav2KickoffTime
      if waited > dav2MaxWaitSec {
        NSLog("🅿️ [PlaceHold] 🌊 DAv2 wait exceeded %.1fs — proceeding to fallback ladder", dav2MaxWaitSec)
        dav2MetricDepth = nil
        dav2PlacementState = .done
      }
      return

    case .done:
      if let metric = dav2MetricDepth {
        let worldPos = camPos + worldRayDir * metric
        NSLog("🅿️ [PlaceHold] ✅ Placing at DAv2 metric depth %.2fm", metric)
        finalizePlacement(worldPos: worldPos, depth: metric, camera: camera,
                          horizScale: horizScale, source: "dav2-metric")
        return
      }
      // DAv2 unavailable after deadline — fall through to the legacy ladder below.
    }

    // ── FALLBACK LADDER (only reached when DAv2 returned nil) ────────────
    // Try ARKit raycast along the bbox ray.
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
          NSLog("🅿️ [PlaceHold] ✅ (fallback) ARKit HIT at %.2fm via %@", d, label)
          finalizePlacement(worldPos: hitPos, depth: d, camera: camera,
                            horizScale: horizScale, source: "raycast:\(label)")
          return
        }
      }
    }

    // ── No hit — use backend depth if available ─────────────────────────
    if let bd = backendDepth, bd >= 0.1, bd <= 10.0 {
      let worldPos = camPos + worldRayDir * bd
      NSLog("🅿️ [PlaceHold] (fallback) No raycast hit — placing at backend depth %.2fm", bd)
      finalizePlacement(worldPos: worldPos, depth: bd, camera: camera,
                        horizScale: horizScale, source: "backend-depth")
      return
    }

    // ── No depth — wait for geometry ────────────────────────────────────
    let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartTime
    if elapsed < 10.0 {
      if framesSinceStart % 30 == 0 {
        NSLog("🅿️ [PlaceHold] (fallback) no hit, no backend depth (%.1fs) — waiting", elapsed)
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