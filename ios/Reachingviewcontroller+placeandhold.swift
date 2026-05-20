//
//  Reachingviewcontroller+placeAndHold.swift
//  shelfscout
//
//  PROTOTYPE — "place once, then hold" reaching, the Reality-Composer way.
//
//  PURPOSE
//  -------
//  Prove the single most important hypothesis before rebuilding anything:
//  if we place ONE ARKit world anchor at a real raycast hit and then NEVER
//  touch it again, ARKit's SLAM keeps it pinned in the world and the on-screen
//  box sits still as the user moves. No visual tracker, no backend re-detection,
//  no refinement convergence buffer, no DAv2, no fallback-depth guessing.
//
//  This file is fully self-contained. It does not call into +visualTracking,
//  +depth, the refinement loop, or the DAv2 path. The only shared things it
//  reads/writes are the anchor state (objectWorldPosition / corners / halfW/H),
//  the existing reprojectBbox() drawing, and say() for audio. Those are pure
//  consumers of the anchor — they never move it.
//
//  HOW IT WORKS
//  ------------
//  1. Wait a few frames for ARKit world tracking to stabilise.
//  2. Convert the bbox center (photo-normalized) to a PORTRAIT SCREEN point.
//  3. sceneView.raycast(...) from that screen point against ARKit geometry.
//     The hit's worldTransform.translation IS the anchor — real position,
//     real depth, in one shot. This is exactly what Reality Composer does.
//  4. If the raycast misses (no geometry yet), retry on later frames up to a
//     deadline. If still nothing by the deadline, place along the ray at a
//     fixed depth as a LAST resort — and still never touch it afterwards.
//  5. After placement: do NOTHING to the anchor. Just reproject (draw) and
//     speak guidance. The whole point is to watch it stay still.
//
//  TO DISABLE: set `placeAndHoldPrototype = false` in the property below and
//  the original pipeline runs unchanged.

import ARKit

extension ReachingViewController {

  // ── Prototype entry point ─────────────────────────────────────────────────
  // Returns true if the prototype handled this frame (caller should return).
  // Returns false if the prototype is disabled (caller runs the old pipeline).
  func handlePlaceAndHoldFrame(_ frame: ARFrame) -> Bool {
    guard placeAndHoldPrototype else { return false }

    if !anchorPlaced {
      attemptPlaceAndHold(frame)
      return true
    }

    // ── Anchor is placed. We do NOTHING to it. Just draw + guide. ──────────
    // reprojectBbox reads objectWorldPosition and re-billboards each frame
    // using the live camera. It never mutates the anchor. This is the part
    // we want to watch: does the box stay glued to the object as we move?
    reprojectBbox(frame: frame)

    // Directional guidance: spoken + earcons + spatial beeps (the beep loop
    // reads currentDirection / proximityZone, which we set here).
    updateGuidance(frame: frame)

    return true
  }

  // ── Placement: raycast once against real ARKit geometry ───────────────────
  private func attemptPlaceAndHold(_ frame: ARFrame) {
    let camera = frame.camera

    // Give ARKit a few frames to start tracking before we raycast.
    let framesSinceStart = arFrameCount
    if framesSinceStart < 3 { return }

    // ── bbox center → portrait screen point ──────────────────────────────
    // bboxNormalized is photo-normalized (VisionCamera 16:9, center-cropped
    // from the 4:3 sensor). Apply the same horizontal crop correction the
    // old code used, then map to the portrait viewport in points.
    let imgRes = camera.imageResolution               // landscape-native, e.g. 1920×1440
    let arPortraitAspect = imgRes.height / imgRes.width       // 0.75
    let photoPortraitAspect = imageWidth / imageHeight        // 0.5625

    let horizScale: CGFloat
    let horizOffset: CGFloat
    if photoPortraitAspect < arPortraitAspect - 0.01 {
      horizScale = photoPortraitAspect / arPortraitAspect
      horizOffset = (1.0 - horizScale) / 2.0
    } else {
      horizScale = 1.0; horizOffset = 0.0
    }

    let photoCenterX = (bboxNormalized[0] + bboxNormalized[2]) / 2
    let photoCenterY = (bboxNormalized[1] + bboxNormalized[3]) / 2
    let arNormX = photoCenterX * horizScale + horizOffset
    let arNormY = photoCenterY

    let sw = cachedSW, sh = cachedSH
    let screenPoint = CGPoint(x: arNormX * sw, y: arNormY * sh)

    // ── The raycast — this is the whole game ─────────────────────────────
    // Try existing plane geometry first (most accurate), then estimated
    // planes (works before full plane extent is known). First hit wins.
    // The hit point is real ARKit world geometry.
    var hitWorldPos: simd_float3? = nil
    var hitKind = ""
    var queryBuiltCount = 0
    var resultsSeen = 0
    let targets: [(ARRaycastQuery.Target, ARRaycastQuery.TargetAlignment, String)] = [
      (.existingPlaneGeometry, .any, "existingGeometry"),
      (.estimatedPlane,        .any, "estimatedPlane"),
    ]
    for (target, alignment, label) in targets {
      guard let query = sceneView.raycastQuery(from: screenPoint, allowing: target, alignment: alignment) else { continue }
      queryBuiltCount += 1
      let results = sceneView.session.raycast(query)
      resultsSeen += results.count
      if let hit = results.first {
        hitWorldPos = simd_make_float3(hit.worldTransform.columns.3)
        hitKind = label
        break
      }
    }

    let camPos = simd_make_float3(camera.transform.columns.3)

    if let worldPos = hitWorldPos {
      let depth = simd_length(worldPos - camPos)
      finalizePlacement(worldPos: worldPos, depth: depth, camera: camera,
                        arNormX: arNormX, arNormY: arNormY,
                        horizScale: horizScale, source: "raycast:\(hitKind)")
      return
    }

    // ── No hit yet. Keep trying until a deadline, then last-resort place. ──
    // Low-texture surfaces (plain bedsheets, white desks) can take several
    // seconds for ARKit to map, so we keep hammering the raycast every frame
    // for up to 8s before falling back to a blind fixed depth.
    let elapsed = ProcessInfo.processInfo.systemUptime - sessionStartTime
    let placementDeadlineSec: TimeInterval = 8.0
    if elapsed < placementDeadlineSec {
      if framesSinceStart % 30 == 0 {
        // Diagnostic: did the query even build? Did the raycast return anything?
        // queryBuilt=2 means both queries constructed fine (screen point valid).
        // resultsSeen=0 means ARKit has no geometry along that ray yet.
        NSLog("🅿️ [PlaceHold] no hit (%.1fs) screenPt=(%.0f,%.0f) queryBuilt=%d resultsSeen=%d trackingState=%@ — retrying",
              elapsed, screenPoint.x, screenPoint.y, queryBuiltCount, resultsSeen,
              self.trackingStateLabel(camera.trackingState))
      }
      return
    }

    // Last resort: unproject along the ray at a fixed depth. Not great, but
    // we place ONCE and then hold — no chasing. User can re-trigger if wrong.
    NSLog("🅿️ [PlaceHold] ⚠️ NO GEOMETRY after %.1fs — BLIND fixed-depth placement (this session's depth is a GUESS, not a real hit)", elapsed)
    let intr = camera.intrinsics
    let arPxX = arNormY * imgRes.width
    let arPxY = (1.0 - arNormX) * imgRes.height
    let fx = CGFloat(intr[0][0]), fy = CGFloat(intr[1][1])
    let cx = CGFloat(intr[2][0]), cy = CGFloat(intr[2][1])
    let rX = Float((arPxX - cx) / fx)
    let rY = Float((arPxY - cy) / fy)
    let rayCam = simd_normalize(simd_float3(rX, -rY, -1.0))
    let worldRay = simd_normalize(simd_make_float3(camera.transform * simd_float4(rayCam, 0)))
    let fixedDepth: Float = 1.0
    let worldPos = camPos + worldRay * fixedDepth
    finalizePlacement(worldPos: worldPos, depth: fixedDepth, camera: camera,
                      arNormX: arNormX, arNormY: arNormY,
                      horizScale: horizScale, source: "fixed-depth-fallback")
  }

  // Human-readable ARKit tracking state for diagnostics.
  private func trackingStateLabel(_ s: ARCamera.TrackingState) -> String {
    switch s {
    case .normal: return "normal"
    case .limited(let r):
      switch r {
      case .initializing: return "limited:initializing"
      case .excessiveMotion: return "limited:excessiveMotion"
      case .insufficientFeatures: return "limited:insufficientFeatures"
      case .relocalizing: return "limited:relocalizing"
      @unknown default: return "limited:unknown"
      }
    case .notAvailable: return "notAvailable"
    @unknown default: return "unknown"
    }
  }

  // ── Commit the anchor and freeze it ───────────────────────────────────────
  private func finalizePlacement(worldPos: simd_float3, depth: Float, camera: ARCamera,
                                 arNormX: CGFloat, arNormY: CGFloat,
                                 horizScale: CGFloat, source: String) {
    objectWorldPosition = worldPos
    anchorDepth = depth

    // Box size in world space, sized off the bbox and depth (cosmetic only —
    // never affects placement). Re-billboarded each frame in reprojectBbox.
    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = depth * Float(bboxNormW * horizScale) * 0.5
    objectWorldHalfH = depth * Float(bboxNormH) * 0.8

    let camT = camera.transform
    let right = -simd_normalize(simd_make_float3(camT.columns.1))
    let up    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = worldPos + right * objectWorldHalfW + up * objectWorldHalfH
    objectWorldCornerBL = worldPos - right * objectWorldHalfW - up * objectWorldHalfH

    anchorPlaced = true

    NSLog("🅿️ [PlaceHold] ✅ ANCHOR PLACED at (%.3f, %.3f, %.3f) depth=%.2fm via %@ — HOLDING, will not touch again",
          worldPos.x, worldPos.y, worldPos.z, depth, source)

    // Self-check: project the anchor back and compare to intended screen point.
    let viewSize = CGSize(width: cachedSW, height: cachedSH)
    let intendedX = arNormX * cachedSW
    let intendedY = arNormY * cachedSH
    let back = camera.projectPoint(worldPos, orientation: .portrait, viewportSize: viewSize)
    let err = sqrt(pow(back.x - intendedX, 2) + pow(back.y - intendedY, 2))
    NSLog("🅿️ [PlaceHold] SelfCheck: intended (%.0f,%.0f) projects to (%.0f,%.0f) err=%.1fpx",
          intendedX, intendedY, back.x, back.y, err)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.distanceLabel.text = "\(Int(depth * 100)) cm"
    }

    // End silent bootstrap so guidance audio can begin.
    say("Target locked.")
  }

  // ── Full guidance: crosshair + earcons + spatial beeps + speech ───────────
  // We set currentDirection and proximityZone so the existing beep loop
  // (tickBeep) pans and paces the spatial beeps. We trigger the
  // centered/uncentered earcons on alignment transitions. And we draw a
  // debug crosshair at the bbox aim point so the tester can SEE whether the
  // aim is on the object (separates aiming error from depth error).
  private func updateGuidance(frame: ARFrame) {
    guard let anchor = objectWorldPosition else { return }
    let camera = frame.camera
    let camT = camera.transform
    let camPos = simd_make_float3(camT.columns.3)

    let dist = simd_length(anchor - camPos)
    liveDistanceToObject = dist
    let toAnchor = simd_normalize(anchor - camPos)

    // Left/right via the portrait "right" axis (codebase convention:
    // in portrait, camera columns.1 is right, negated).
    let camRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let rightDot = simd_dot(toAnchor, camRight)

    // ── Direction + alignment state (drives beep pan + earcons) ──────────
    let wasCentered = isCenteredState
    let newDir: Direction
    if rightDot > 0.10 { newDir = .right; lastKnownHorizontalSign = 1 }
    else if rightDot < -0.10 { newDir = .left; lastKnownHorizontalSign = -1 }
    else { newDir = .centered }
    currentDirection = newDir
    isCenteredState = (newDir == .centered)

    // ── Proximity zone (drives beep interval/volume) ─────────────────────
    let zone: ProximityZone
    switch dist {
    case ..<0.30: zone = .centered
    case ..<0.50: zone = .veryClose
    case ..<0.90: zone = .close
    case ..<1.50: zone = .medium
    default:      zone = .far
    }
    proximityZone = zone

    // ── Alignment earcons on transition ──────────────────────────────────
    if isCenteredState && !wasCentered { playCenteredSound() }
    else if !isCenteredState && wasCentered { playUncenteredSound() }

    // ── Debug crosshair at the live-projected anchor point ───────────────
    // Reuses the unused handDot/handDotGlow layers. Shows EXACTLY where the
    // anchor projects on screen this frame. If this dot sits on the object,
    // aiming is correct and any box offset is depth/billboard sizing. If the
    // dot sits off the object, aiming (bbox→ray) is wrong.
    let viewSize = CGSize(width: cachedSW, height: cachedSH)
    let dotPt = camera.projectPoint(anchor, orientation: .portrait, viewportSize: viewSize)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let r: CGFloat = 10
      let path = UIBezierPath(ovalIn: CGRect(x: dotPt.x - r, y: dotPt.y - r, width: 2*r, height: 2*r)).cgPath
      self.handDot.path = path; self.handDot.isHidden = false
      self.handDotGlow.path = UIBezierPath(ovalIn: CGRect(x: dotPt.x - r*2, y: dotPt.y - r*2, width: 4*r, height: 4*r)).cgPath
      self.handDotGlow.isHidden = false
    }

    // ── Spoken guidance, throttled ────────────────────────────────────────
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastSpeechTime > 2.5 else { return }
    lastSpeechTime = now
    let dir: String
    switch newDir {
    case .right: dir = "Object is to your right."
    case .left:  dir = "Object is to your left."
    default:     dir = "Straight ahead."
    }
    say("\(dir) \(Int(dist * 100)) centimeters.")
  }
}
