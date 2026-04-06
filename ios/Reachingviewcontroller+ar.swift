//
//  Reachingviewcontroller+ar.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//
//  ARKit Session, Anchor, Refinement, Reprojection

import ARKit
import SceneKit

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - AR Setup
  // ═══════════════════════════════════════════════════════════════════════════

  func setupARView() {
    sceneView = ARSCNView(frame: view.bounds)
    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sceneView.session.delegate = self
    sceneView.showsStatistics = false
    sceneView.automaticallyUpdatesLighting = false
    view.addSubview(sceneView)
  }

  func startAR() {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = [.horizontal, .vertical]

    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      config.frameSemantics.insert(.sceneDepth)
      hasLiDAR = true
      NSLog("📷 [ReachingVC] ✅ LiDAR DETECTED (Pro device) — using LiDAR metric depth for anchor seeding")
      NSLog("📷 [ReachingVC] 🔬 Depth source: LiDAR sceneDepth (metric, no calibration needed)")
    } else {
      hasLiDAR = false
      NSLog("📷 [ReachingVC] ❌ No LiDAR (non-Pro device) — using Qwen backend depth + ARKit raycast refinement")
      NSLog("📷 [ReachingVC] 🔬 Depth source: Qwen/backend relative depth → ARKit estimatedPlane refinement")
    }
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      config.sceneReconstruction = .mesh
      meshReconstructionEnabled = true
      NSLog("📷 [ReachingVC] Mesh reconstruction ENABLED")
    } else {
      NSLog("📷 [ReachingVC] No mesh — using plane estimation + LiDAR fallback")
    }

    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    startBeepLoop()
    startRedetectionLoop()
    NSLog("📷 [ReachingVC] AR session started — mode=%@ hasLiDAR=%@",
          mode.rawValue, hasLiDAR ? "YES" : "NO")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Place World Anchor
  // ═══════════════════════════════════════════════════════════════════════════

  func placeWorldAnchor(frame: ARFrame) {
    let camera = frame.camera

    // ── FOV Crop Correction ────────────────────────────────────────────
    // VisionCamera captures 16:9 (center-cropped from 4:3 sensor).
    // ARKit uses the full 4:3 sensor.
    // Map photo-normalized bbox directly to AR camera pixels, bypassing
    // screen coordinates entirely — this eliminates the double aspect-fill
    // error that caused the bbox to drift horizontally.
    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution      // AR camera resolution (landscape-native)
    let arW = imgRes.width, arH = imgRes.height  // e.g., 1920×1440

    // AR camera in portrait: width=arH, height=arW
    let arPortraitAspect = arH / arW             // e.g., 1440/1920 = 0.75
    let photoPortraitAspect = imageWidth / imageHeight  // e.g., 1152/2048 = 0.5625

    // Compute horizontal crop factor: photo is narrower than AR camera in portrait
    let horizScale: CGFloat
    let horizOffset: CGFloat
    if photoPortraitAspect < arPortraitAspect - 0.01 {
      horizScale = photoPortraitAspect / arPortraitAspect  // e.g., 0.75
      horizOffset = (1.0 - horizScale) / 2.0               // e.g., 0.125
    } else {
      horizScale = 1.0; horizOffset = 0.0  // same aspect — no correction
    }

    // Bbox center in photo-normalized coords
    let photoCenterX = (bboxNormalized[0] + bboxNormalized[2]) / 2
    let photoCenterY = (bboxNormalized[1] + bboxNormalized[3]) / 2

    // Convert to AR-camera-normalized portrait coords
    let arNormX = photoCenterX * horizScale + horizOffset  // horizontal crop correction
    let arNormY = photoCenterY                              // vertical: same FOV, no correction

    // Convert AR portrait-normalized → AR landscape pixels
    // Portrait (X,Y) → Landscape: pxX = Y * arW, pxY = (1-X) * arH
    let arPxX = arNormY * arW
    let arPxY = (1.0 - arNormX) * arH

    NSLog("📐 [FOV] Photo=%.4f AR=%.4f horizScale=%.3f offset=%.3f | photo(%.3f,%.3f)→AR(%.3f,%.3f)→px(%.0f,%.0f) arRes=%.0f×%.0f",
          photoPortraitAspect, arPortraitAspect, horizScale, horizOffset,
          photoCenterX, photoCenterY, arNormX, arNormY, arPxX, arPxY, arW, arH)

    // ── LiDAR screen center (approximate — only for depth sampling) ────
    let sw = cachedSW, sh = cachedSH
    let screenCenter = CGPoint(x: arNormX * sw, y: arNormY * sh)

    // ── Depth source selection ───────────────────────────────────────────
    let depth: Float
    if hasLiDAR, let lidarDepth = sampleLiDARDepth(frame: frame, screenCenter: screenCenter) {
      depth = lidarDepth
      anchorDepth = lidarDepth
      lidarDepthSeeded = true
      NSLog("🎯 [ReachingVC] ✅ LiDAR depth seed: %.2fm (backend was %.2fm)",
            depth, backendDepth ?? -1)
    } else if bboxUpdateCount > 0, anchorDepth > 0.05 {
      depth = anchorDepth
      NSLog("🎯 [ReachingVC] Using re-detection depth: %.2fm", depth)
    } else {
      depth = backendDepth ?? 0.5
      anchorDepth = depth
      NSLog("🎯 [ReachingVC] Using %@ depth: %.2fm",
            hasLiDAR ? "backend (LiDAR miss)" : "Qwen/backend", depth)
    }

    let fx = CGFloat(intrinsics[0][0]), fy = CGFloat(intrinsics[1][1])
    let cx = CGFloat(intrinsics[2][0]), cy = CGFloat(intrinsics[2][1])
    let rX = Float((arPxX - cx) / fx)
    let rY = Float((arPxY - cy) / fy)

    let camT     = camera.transform
    let rayCam   = simd_normalize(simd_float3(rX, -rY, -1.0))
    let worldRay = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos   = simd_make_float3(camT.columns.3)
    let worldPos = camPos + worldRay * depth

    objectWorldPosition = worldPos

    // Bbox size in world space — correct width for photo→AR crop
    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = depth * Float(bboxNormW * horizScale) * 0.5  // crop-corrected width
    objectWorldHalfH = depth * Float(bboxNormH) * 0.8               // vertical: no correction

    let placementRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let placementUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = worldPos + placementRight * objectWorldHalfW + placementUp * objectWorldHalfH
    objectWorldCornerBL = worldPos - placementRight * objectWorldHalfW - placementUp * objectWorldHalfH

    anchorPlaced = true
    anchorRefinementFrames = 1
    NSLog("🎯 [ReachingVC] ✅ Anchor SEEDED at (%.3f, %.3f, %.3f) depth=%.2fm (refining with ARKit...)",
          worldPos.x, worldPos.y, worldPos.z, depth)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.distanceLabel.text = "\(Int(depth * 100)) cm"
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Refine Anchor Depth
  // ═══════════════════════════════════════════════════════════════════════════

  func tryRefineAnchorDepth(frame: ARFrame) {
    guard let currentPos = objectWorldPosition else { return }

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))

    // ── Guard: skip refinement if object is behind or far off-axis ──────
    let toObj = simd_normalize(currentPos - camPos)
    let fwdAlignment = simd_dot(toObj, camFwd)
    if fwdAlignment < 0.4 {
      // Object behind or far off-axis — flush stale hits so the buffer
      // starts clean when the user faces the object again.
      if !refinementHits.isEmpty {
        refinementHits.removeAll()
        lastRefinementAppliedDepth = 0
        NSLog("🎯 [Refine] Buffer CLEARED — object off-axis (fwdDot=%.2f)", fwdAlignment)
      }
      return
    }

    // ── Raycast toward the 3D anchor (not fixed bbox pixels) ────────────
    // As the user walks, fixed bbox pixel coordinates drift away from the
    // object in the camera frame, causing the ray to hit the far wall.
    // Instead, raycast directly from camera → anchor position. This tracks
    // the anchor correctly regardless of how the camera has moved.
    let worldDir = toObj  // already normalized above
    let currentAnchorDist = simd_length(currentPos - camPos)

    var hitPos: simd_float3? = nil
    var hitSource = ""
    for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
      let query = ARRaycastQuery(origin: camPos, direction: worldDir,
                                 allowing: target, alignment: .any)
      if let hit = sceneView.session.raycast(query).first {
        hitPos = simd_make_float3(hit.worldTransform.columns.3)
        hitSource = target == .existingPlaneGeometry ? "existingPlane" : "estimatedPlane"
        break
      }
    }

    guard let hp = hitPos else {
      if anchorRefinementFrames % 60 == 0 {
        NSLog("🎯 [Refine] No plane hit yet (frame %d, %d hits buffered) — planes still forming",
              anchorRefinementFrames, refinementHits.count)
      }
      return
    }

    let hitDepth = simd_length(hp - camPos)

    guard hitDepth > 0.15 && hitDepth < 4.0 else {
      NSLog("🎯 [Refine] Rejected hit at %.2fm (out of range)", hitDepth)
      return
    }

    // FIX 13: Reject raycasts beyond 2x backend estimate (with-hand only)
    // Hand-free: backend depth is unreliable (Qwen is not a depth estimator).
    // ARKit plane hits at 2m when backend said 0.93m means backend was WRONG,
    // not ARKit. Trust ARKit hits in hand-free mode.
    if mode != .handFree, let bd = backendDepth, hitDepth > bd * 2.0 {
      NSLog("🎯 [Refine] Rejected hit at %.2fm (>2x backend %.2fm)", hitDepth, bd)
      return
    }

    // Hand-free: reject hits that overshoot the anchor by >50cm.
    // The ray points camera→anchor, so hits beyond the anchor are the WALL
    // behind the object. Only apply after first convergence (before that,
    // the anchor depth from backend may be inaccurate).
    if mode == .handFree && lastRefinementAppliedDepth > 0 {
      let maxAllowed = currentAnchorDist + 0.50
      if hitDepth > maxAllowed {
        NSLog("🎯 [Refine] Rejected wall hit at %.2fm (anchor at %.2fm, max %.2fm)",
              hitDepth, currentAnchorDist, maxAllowed)
        return
      }
    }

    refinementHits.append(hitDepth)
    if refinementHits.count > 20 { refinementHits.removeFirst() }

    NSLog("🎯 [Refine] Hit #%d: %.2fm (%@) | buffer: %d hits",
          refinementHits.count, hitDepth, hitSource, refinementHits.count)

    guard refinementHits.count >= refinementMinHits else { return }

    let sorted = refinementHits.sorted()
    let n = sorted.count
    let median: Float = n % 2 == 0 ? (sorted[n/2-1] + sorted[n/2]) / 2.0 : sorted[n/2]
    let q1 = sorted[n/4], q3 = sorted[3*n/4]
    let iqr = q3 - q1

    NSLog("🎯 [Refine] Median=%.2fm IQR=%.2fm (need <%.2fm) hits=%d",
          median, iqr, refinementConvergeThreshold, n)

    // Hand-free: wider threshold since user is walking (depth is changing)
    let convergeThreshold: Float = mode == .handFree ? 0.15 : refinementConvergeThreshold
    guard iqr < convergeThreshold else {
      NSLog("🎯 [Refine] IQR too wide (%.2fm, need <%.2fm) — still accumulating", iqr, convergeThreshold)
      return
    }

    if lastRefinementAppliedDepth > 0 && abs(median - lastRefinementAppliedDepth) < 0.02 {
      if mode == .handFree {
        // Hand-free: depth converged — great! Clear buffer to start fresh
        // from the new position as user continues walking.
        NSLog("🎯 [Refine] ✅ CONVERGED at %.2fm (Δ=%.1fcm) — clearing buffer, continuing refinement",
              median, abs(median - lastRefinementAppliedDepth) * 100)
        refinementHits.removeAll()
        // DON'T set anchorRefinementFrames = limit — keep refining
      } else {
        NSLog("🎯 [Refine] ✅ CONVERGED at %.2fm (Δ=%.1fcm from last) — stopping",
              median, abs(median - lastRefinementAppliedDepth) * 100)
        anchorRefinementFrames = anchorRefinementLimit
      }
      return
    }

    let prevDepth = simd_length(currentPos - camPos)
    let newWorldPos = camPos + worldDir * median
    objectWorldPosition = newWorldPos

    let camT = camera.transform
    let placementRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let placementUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = newWorldPos + placementRight * objectWorldHalfW + placementUp * objectWorldHalfH
    objectWorldCornerBL = newWorldPos - placementRight * objectWorldHalfW - placementUp * objectWorldHalfH
    anchorDepth         = median
    liveDistanceToObject = median
    lastRefinementAppliedDepth = median

    NSLog("🎯 [Refine] ✅ DEPTH UPDATED: was=%.2fm → median=%.2fm (Δ=%.1fcm, %d hits, IQR=%.2f)",
          prevDepth, median, abs(prevDepth - median) * 100, n, iqr)

    DispatchQueue.main.async { [weak self] in
      self?.distanceLabel.text = "\(Int(median * 100)) cm"
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Reproject Bbox
  // ═══════════════════════════════════════════════════════════════════════════

  func reprojectBbox(frame: ARFrame) {
    guard let center3D = objectWorldPosition else { return }
    let sw = cachedSW, sh = cachedSH
    let camera = frame.camera
    let viewSize = CGSize(width: sw, height: sh)

    let camPos = simd_make_float3(camera.transform.columns.3)
    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    let camToAnchorDist = simd_length(center3D - camPos)
    if simd_dot(center3D - camPos, camFwd) < 0 {
      // v10: NO auto-success. Manual exit only.
      // Just tell user object is behind them.
      DispatchQueue.main.async { [weak self] in
        self?.bboxLayer.isHidden = true; self?.innerBboxLayer.isHidden = true
        self?.directionLabel.text = "Turn back"
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
      }
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastSpeechTime > 3 { say("Object is behind you. Turn back."); lastSpeechTime = now }
      return
    }

    let centerScreen = camera.projectPoint(center3D, orientation: .portrait, viewportSize: viewSize)

    // FIX 10: Re-billboard every frame from current camera orientation
    let camT = camera.transform
    let billboardRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let billboardUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    let liveTR = center3D + billboardRight * objectWorldHalfW + billboardUp * objectWorldHalfH
    let liveBL = center3D - billboardRight * objectWorldHalfW - billboardUp * objectWorldHalfH

    let trScreen = camera.projectPoint(liveTR, orientation: .portrait, viewportSize: viewSize)
    let blScreen = camera.projectPoint(liveBL, orientation: .portrait, viewportSize: viewSize)

    let screenW = max(abs(trScreen.x - blScreen.x), 20)
    let screenH = max(abs(trScreen.y - blScreen.y), 20)
    let dist    = simd_length(center3D - camPos)

    liveDistanceToObject = dist
    projectedBboxCenter  = centerScreen
    projectedBboxW = screenW
    projectedBboxH = screenH

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.bboxLayer.isHidden = false; self.innerBboxLayer.isHidden = false
      let innerRect = CGRect(x: centerScreen.x - screenW/2, y: centerScreen.y - screenH/2,
                             width: screenW, height: screenH)
      let tolX = max(screenW * 0.25, 15), tolY = max(screenH * 0.25, 15)
      self.innerBboxLayer.path = UIBezierPath(roundedRect: innerRect, cornerRadius: 8).cgPath
      self.bboxLayer.path      = UIBezierPath(roundedRect: innerRect.insetBy(dx: -tolX, dy: -tolY),
                                              cornerRadius: 12).cgPath
      self.distanceLabel.text  = "\(Int(dist*100)) cm"
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Progressive Re-detection Loop
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Every N seconds: capture ARKit camera frame → JPEG → POST to detection
  // endpoint → parse fresh bbox → re-normalize → re-place anchor from
  // CURRENT camera pose + FRESH bbox. This eliminates the stale-photo
  // anchor drift that made v9 unusable.

  func startRedetectionLoop() {
    // Re-detection DISABLED for BOTH modes.
    //
    // Hand-free: The blend approach failed — each re-detection from a different
    // camera angle computes a wrong world position, and blending wrong with
    // less-wrong drifts the anchor further away with every update.
    //
    // With-hand: Same anchor drift problem. Re-detection while user walks
    // causes bbox to jump to wrong objects and anchor to destabilize.
    //
    // Both modes use: one-shot Qwen detection + continuous ARKit refinement.
    NSLog("🔄 [Redetect] DISABLED — one-shot detection + continuous ARKit refinement only (mode=%@)", mode.rawValue)
    return
  }

  func captureAndRedetect() {
    guard running, !hasCompleted, !isRedetecting else { return }
    guard let urlStr = detectionUrl, let url = URL(string: urlStr) else { return }
    guard let frame = lastARFrame else {
      NSLog("🔄 [Redetect] No AR frame available yet")
      return
    }

    // ── Layer 1: Don't re-detect when object is behind camera ──────────
    // When user turns away, Qwen sees different scenery and detects
    // the wrong object with high confidence. Skip entirely.
    if let pos = objectWorldPosition {
      let cam = frame.camera
      let camPos = simd_make_float3(cam.transform.columns.3)
      let camFwd = -simd_normalize(simd_make_float3(cam.transform.columns.2))
      if simd_dot(pos - camPos, camFwd) < 0 {
        NSLog("🔄 [Redetect] ⏭ Skipping — object behind camera (user facing away)")
        return
      }
    }

    isRedetecting = true

    // Capture current AR camera image as JPEG
    let pixelBuffer = frame.capturedImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      NSLog("🔄 [Redetect] Failed to create CGImage from frame")
      isRedetecting = false
      return
    }

    // AR camera is landscape — rotate to portrait for backend
    let fullImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

    // Resize to ~750px max to reduce payload (1440×1920 → ~562×750)
    let maxDim: CGFloat = 750
    let scale = min(maxDim / fullImage.size.width, maxDim / fullImage.size.height, 1.0)
    let newSize = CGSize(width: fullImage.size.width * scale, height: fullImage.size.height * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
    fullImage.draw(in: CGRect(origin: .zero, size: newSize))
    let resizedImage = UIGraphicsGetImageFromCurrentImageContext() ?? fullImage
    UIGraphicsEndImageContext()

    guard let jpegData = resizedImage.jpegData(compressionQuality: 0.5) else {
      NSLog("🔄 [Redetect] Failed to encode JPEG")
      isRedetecting = false
      return
    }

    let base64Str = "data:image/jpeg;base64," + jpegData.base64EncodedString()
    let imgW = resizedImage.size.width
    let imgH = resizedImage.size.height

    NSLog("🔄 [Redetect] Captured %.0f×%.0f (%.0fKB) — sending to backend...",
          imgW, imgH, Double(jpegData.count) / 1024.0)

    // Build request
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 60  // Qwen inference can take 20-40s on CPU

    let body: [String: Any] = [
      "image": base64Str,
      "object": objectName,
      "score_threshold": 0.1
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
      NSLog("🔄 [Redetect] Failed to serialize request body")
      isRedetecting = false
      return
    }
    request.httpBody = bodyData

    // Fire async — NOTE: We don't capture the frame here to avoid ARFrame retention.
    // updateBboxFromBackend will use lastARFrame (the MOST RECENT frame), which is
    // better anyway since the response arrives 10-30s later when the user has moved.
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      defer { self?.isRedetecting = false }
      guard let self = self, self.running, !self.hasCompleted else { return }

      if let error = error {
        NSLog("🔄 [Redetect] Request failed: %@", error.localizedDescription)
        return
      }

      // Check HTTP status
      let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

      guard let data = data else {
        NSLog("🔄 [Redetect] No data in response (HTTP %d)", httpStatus)
        return
      }

      // Log raw response on failure for debugging
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let rawStr = String(data: data.prefix(500), encoding: .utf8) ?? "(binary)"
        NSLog("🔄 [Redetect] Failed to parse JSON (HTTP %d): %@", httpStatus, rawStr)
        return
      }

      // 404 = object not found
      if httpStatus == 404 {
        let err = json["error"] as? String ?? "not found"
        NSLog("🔄 [Redetect] Object not found (404): %@", err)
        return
      }

      // Extract bbox — handle multiple formats from vision pipeline
      var newBbox: [CGFloat]? = nil

      if let bboxArr = json["bbox"] as? [Any] {
        // Array of numbers (Int or Double or NSNumber)
        let mapped = bboxArr.compactMap { v -> CGFloat? in
          if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
          if let i = v as? Int { return CGFloat(i) }
          if let d = v as? Double { return CGFloat(d) }
          return nil
        }
        if mapped.count == 4 { newBbox = mapped }
      } else if let bboxStr = json["bbox"] as? String {
        // String format "[x1, y1, x2, y2]"
        let cleaned = bboxStr.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 4 { newBbox = parts.map { CGFloat($0) } }
      }

      guard let bbox = newBbox, bbox.count == 4 else {
        NSLog("🔄 [Redetect] No valid bbox — keys: %@", json.keys.joined(separator: ", "))
        return
      }

      // Extract depth if available
      var newDepth: Float? = nil
      if let d = json["depth"] as? NSNumber {
        newDepth = d.floatValue
      }

      let conf = (json["confidence"] as? NSNumber)?.floatValue ?? 0

      NSLog("🔄 [Redetect] ✅ Got fresh bbox [%.0f,%.0f,%.0f,%.0f] conf=%.2f depth=%@ img=%.0f×%.0f",
            bbox[0], bbox[1], bbox[2], bbox[3], conf,
            newDepth.map{String(format:"%.2f",$0)} ?? "nil", imgW, imgH)

      // Apply update on main thread (fromFrame: nil → uses lastARFrame)
      DispatchQueue.main.async { [weak self] in
        self?.updateBboxFromBackend(newBbox: bbox, newImgW: imgW, newImgH: imgH,
                                    newDepth: newDepth)
      }
    }.resume()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Update Bbox from Backend Re-detection
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Re-normalizes the bbox, resets anchor state, and re-places the 3D anchor
  // from the CURRENT camera pose. This is the key fix: the anchor is always
  // placed from a recent frame, not from the stale initial photo.

  func updateBboxFromBackend(newBbox: [CGFloat], newImgW: CGFloat, newImgH: CGFloat,
                             newDepth: Float?, fromFrame: ARFrame? = nil) {
    bboxUpdateCount += 1

    // ── Normalize the fresh bbox ──────────────────────────────────────────
    let x1 = min(newBbox[0], newBbox[2])
    let y1 = min(newBbox[1], newBbox[3])
    let x2 = max(newBbox[0], newBbox[2])
    let y2 = max(newBbox[1], newBbox[3])

    var newNorm: [CGFloat]
    if newImgW > 0 && newImgH > 0 {
      newNorm = [x1/newImgW, y1/newImgH, x2/newImgW, y2/newImgH]
    } else {
      let maxVal = max(x1, y1, x2, y2)
      if maxVal <= 1.0 {
        newNorm = [x1, y1, x2, y2]
      } else if maxVal <= 1000 {
        newNorm = [x1/1000, y1/1000, x2/1000, y2/1000]
      } else {
        NSLog("🔄 [Redetect] ⚠️ Can't normalize bbox, skipping update #%d", bboxUpdateCount)
        return
      }
    }
    newNorm = newNorm.map { min(max($0, 0), 1) }

    let newW = newNorm[2] - newNorm[0]
    let newH = newNorm[3] - newNorm[1]
    let newCx = (newNorm[0] + newNorm[2]) / 2
    let newCy = (newNorm[1] + newNorm[3]) / 2

    // ── Reject degenerate detections ──────────────────────────────────────
    if newW < 0.01 || newH < 0.01 {
      NSLog("🔄 [Redetect] ⚠️ Degenerate bbox (%.3f×%.3f), skipping update #%d", newW, newH, bboxUpdateCount)
      return
    }

    // ── Layer 2: Spatial Consistency Gate ─────────────────────────────────
    // Compare re-detected center against the INITIAL N8N bbox center.
    // If the new detection is too far away, Qwen likely found a different
    // similar-looking object (e.g. user turned and another bottle appeared).
    // Reject and keep the existing anchor position.
    let dCx = newCx - initialBboxCenter.cx
    let dCy = newCy - initialBboxCenter.cy
    let displacement = sqrt(dCx * dCx + dCy * dCy)

    // NOTE: This threshold is in normalized screen-space [0..1].
    // Hand-free: wider because user walks between re-detections (object moves more)
    // With-hand: user is stationary, tighter gate rejects wrong objects
    let maxDisplacement: CGFloat = mode == .handFree ? 0.40 : 0.25

    if displacement > maxDisplacement {
      consecutiveRejects += 1
      NSLog("🔄 [Redetect] ❌ REJECTED #%d — displacement=%.3f (max=%.3f) center=(%.3f,%.3f) vs ref=(%.3f,%.3f) [%d consecutive]",
            bboxUpdateCount, displacement, maxDisplacement,
            newCx, newCy, initialBboxCenter.cx, initialBboxCenter.cy,
            consecutiveRejects)

      // Hand-free: accept after 3 consecutive rejects (user moved a lot)
      // With-hand: accept after 5 (more conservative)
      let rejectLimit = mode == .handFree ? 3 : 5
      if consecutiveRejects >= rejectLimit {
        initialBboxCenter = (cx: newCx, cy: newCy)
        consecutiveRejects = 0
        NSLog("🔄 [Redetect] 🔁 Reference center UPDATED after 5 rejects → (%.3f,%.3f)", newCx, newCy)
        // Fall through to apply this update
      } else {
        return  // Keep existing anchor position
      }
    } else {
      consecutiveRejects = 0
    }

    // ── Use re-detected CENTER but keep controlled SIZE ──────────────────
    // Take the larger of old vs new, but cap at 3× the initial size to
    // prevent runaway inflation from one bad detection.
    let oldW = bboxNormalized[2] - bboxNormalized[0]
    let oldH = bboxNormalized[3] - bboxNormalized[1]
    let maxW = initialBboxSize.w * 3.0  // cap at 3× original
    let maxH = initialBboxSize.h * 3.0
    let useW = min(max(oldW, newW, 0.03), maxW)
    let useH = min(max(oldH, newH, 0.04), maxH)

    // Build new bbox: fresh center + controlled size
    let finalX1 = max(newCx - useW / 2, 0)
    let finalY1 = max(newCy - useH / 2, 0)
    let finalX2 = min(newCx + useW / 2, 1)
    let finalY2 = min(newCy + useH / 2, 1)

    NSLog("🔄 [Redetect] ✅ ACCEPTED #%d — disp=%.3f center=(%.3f,%.3f) size=%.3f×%.3f → %.3f×%.3f",
          bboxUpdateCount, displacement, newCx, newCy, newW, newH, useW, useH)
    NSLog("🔄 [Redetect] Old norm: [%.3f,%.3f,%.3f,%.3f] → New norm: [%.3f,%.3f,%.3f,%.3f]",
          bboxNormalized[0], bboxNormalized[1], bboxNormalized[2], bboxNormalized[3],
          finalX1, finalY1, finalX2, finalY2)

    bboxNormalized = [finalX1, finalY1, finalX2, finalY2]

    // Update image dimensions for aspect-fill mapping in placeWorldAnchor
    if newImgW > 0 && newImgH > 0 {
      imageWidth = newImgW
      imageHeight = newImgH
    }

    // Update depth if provided and reasonable
    if let d = newDepth, d > 0.05, d < 10.0 {
      // Only use backend depth if we don't have ARKit refinement data
      if mode == .handFree && !refinementHits.isEmpty {
        NSLog("🔄 [Redetect] Ignoring backend depth %.2fm — using ARKit refinement (%.2fm)", d, anchorDepth)
      } else {
        anchorDepth = d
        NSLog("🔄 [Redetect] Updated anchorDepth → %.2fm", d)
      }
    }

    if mode == .handFree {
      // ── Hand-free: smooth anchor update WITHOUT resetting refinement ────
      // Update bbox for visual overlay
      // Re-place anchor center using current best depth (from refinement)
      // Refinement buffer stays intact and keeps running
      // Update the spatial consistency reference to track the moving screen position
      initialBboxCenter = (cx: (finalX1 + finalX2) / 2, cy: (finalY1 + finalY2) / 2)

      if let frame = fromFrame ?? lastARFrame {
        // Re-compute world position from fresh bbox center + current best depth
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let imgRes = camera.imageResolution
        let arW = imgRes.width, arH = imgRes.height

        // FOV crop correction (same as placeWorldAnchor)
        let arPortraitAspect = arH / arW
        let photoPortraitAspect = imageWidth / imageHeight
        let horizScale: CGFloat = (photoPortraitAspect < arPortraitAspect - 0.01)
          ? photoPortraitAspect / arPortraitAspect : 1.0
        let horizOffset: CGFloat = (1.0 - horizScale) / 2.0

        let photoCenterX = (bboxNormalized[0] + bboxNormalized[2]) / 2
        let photoCenterY = (bboxNormalized[1] + bboxNormalized[3]) / 2
        let arNormX = photoCenterX * horizScale + horizOffset
        let arNormY = photoCenterY

        let arPxX = arNormY * arW
        let arPxY = (1.0 - arNormX) * arH
        let fx = CGFloat(intrinsics[0][0]), fy = CGFloat(intrinsics[1][1])
        let cx = CGFloat(intrinsics[2][0]), cy = CGFloat(intrinsics[2][1])
        let rX = Float((arPxX - cx) / fx)
        let rY = Float((arPxY - cy) / fy)
        let camT = camera.transform
        let rayCam = simd_normalize(simd_float3(rX, -rY, -1.0))
        let worldRay = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
        let camPos = simd_make_float3(camT.columns.3)
        let newWorldPos = camPos + worldRay * anchorDepth

        // Smooth the position update — don't jump, blend
        if let oldPos = objectWorldPosition {
          let blendFactor: Float = 0.6  // 60% new, 40% old — smooth transition
          objectWorldPosition = oldPos * (1 - blendFactor) + newWorldPos * blendFactor
          NSLog("🔄 [Redetect] ✅ Hand-free anchor BLENDED #%d — old=(%.2f,%.2f,%.2f) new=(%.2f,%.2f,%.2f) → blend=(%.2f,%.2f,%.2f)",
                bboxUpdateCount, oldPos.x, oldPos.y, oldPos.z,
                newWorldPos.x, newWorldPos.y, newWorldPos.z,
                objectWorldPosition!.x, objectWorldPosition!.y, objectWorldPosition!.z)
        } else {
          objectWorldPosition = newWorldPos
          NSLog("🔄 [Redetect] ✅ Hand-free anchor PLACED #%d at (%.2f,%.2f,%.2f) depth=%.2fm",
                bboxUpdateCount, newWorldPos.x, newWorldPos.y, newWorldPos.z, anchorDepth)
        }

        // Update corners for bbox projection (re-billboard from current camera)
        let billboardRight = -simd_normalize(simd_make_float3(camT.columns.1))
        let billboardUp = simd_normalize(simd_make_float3(camT.columns.0))
        let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
        let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
        objectWorldHalfW = anchorDepth * Float(bboxNormW * horizScale) * 0.5
        objectWorldHalfH = anchorDepth * Float(bboxNormH) * 0.8
        if let pos = objectWorldPosition {
          objectWorldCornerTR = pos + billboardRight * objectWorldHalfW + billboardUp * objectWorldHalfH
          objectWorldCornerBL = pos - billboardRight * objectWorldHalfW - billboardUp * objectWorldHalfH
        }
      }
      // NOTE: anchorPlaced stays true, refinementHits stays intact, refinement keeps running
    } else {
      // ── With-hand: existing full reset behavior ────────────────────────
      // Reset anchor state so placeWorldAnchor fires with fresh position
      anchorPlaced = false
      anchorRefinementFrames = 0
      refinementHits.removeAll()
      lastRefinementAppliedDepth = 0
      objectWorldPosition = nil

      // Re-anchor from the most recent AR frame (not the stale capture frame)
      if let frame = fromFrame ?? lastARFrame {
        placeWorldAnchor(frame: frame)
        NSLog("🔄 [Redetect] ✅ Anchor RE-PLACED from fresh frame + fresh center")
      } else {
        NSLog("🔄 [Redetect] ⏳ Anchor reset — will re-place on next AR frame")
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ARSessionDelegate
// ═══════════════════════════════════════════════════════════════════════════════

extension ReachingViewController: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running, !hasCompleted else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastFrameProcessedAt >= frameProcessInterval else { return }
    // Skip if visionQ is still processing a previous frame (prevents ARFrame retention buildup)
    guard !isProcessingFrame else { return }
    lastFrameProcessedAt = now
    lastARFrame = frame
    isProcessingFrame = true
    visionQ.async { [weak self] in
      guard let self = self else { return }
      self.processARFrame(frame)
      self.isProcessingFrame = false
    }
  }
  func session(_ session: ARSession, didFailWithError error: Error) {
    say("Tracking failed.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.finishWith(success: false, reason: "ar_error")
    }
  }
  func sessionWasInterrupted(_ session: ARSession)   { say("Tracking paused") }
  func sessionInterruptionEnded(_ session: ARSession) { say("Tracking resumed") }
}
