//
//  Reachingviewcontroller+visualTracking.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-04-26.
//
//  VISUAL TRACKING — Single-Object Tracker (VNTrackObjectRequest).
//
//  Why this file exists:
//    The legacy refinement (+ar.swift `tryRefineAnchorDepth`) raycasts from
//    camera toward the existing 3D anchor. If the initial anchor depth is
//    wrong, the ray points through the wrong pixels, plane hits land on the
//    wall behind the object, and the rejection filters reject them. The
//    anchor stays floating in mid-air.
//
//    The fix: track the object in 2D every frame, use the tracker's bbox
//    center as the screen target, raycast from camera through THAT pixel.
//    Depth is now sampled at the actual object pixels regardless of where
//    the (possibly wrong) old anchor sits.
//
//  Tracker contract:
//    - Apple's VNTrackObjectRequest. No model file, no Pod.
//    - Seed once with the initial bbox after anchor placement.
//    - updateTracker(frame:) per AR frame returns the latest observation.
//    - On confidence drop (12 consecutive low-conf frames), reseedTrackerFromBackend
//      fires a fresh /vision/detect call and re-seeds with the new bbox.
//    - All state mutations happen on visionQ to match ARSessionDelegate threading.
//
//  Coordinate spaces handled here:
//    - Photo-portrait (top-left origin, normalized) — what the workflow returns
//    - AR-portrait (top-left origin, normalized) — after FOV crop correction
//    - Vision-normalized (lower-left origin, normalized) — what the tracker speaks
//    Conversion is done at seed time and read-out time, never inside the loop.

import Foundation
import UIKit
import Vision
import ARKit

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Seed
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Called once after the first anchor placement, and again on each successful
  // backend reseed. Converts photo-portrait normalized bbox → Vision-normalized
  // bbox in AR-camera-portrait space, then primes the tracker.

  func seedTracker(initialBboxPhotoNorm: [CGFloat], frame: ARFrame) {
    guard trackerEnabled else { return }
    guard initialBboxPhotoNorm.count == 4 else {
      NSLog("🎯 [Tracker] ❌ Cannot seed — bbox has %d elements (need 4)", initialBboxPhotoNorm.count)
      return
    }

    // ── Reject degenerate seeds — Vision is unreliable below ~5% of frame ──
    let bw = initialBboxPhotoNorm[2] - initialBboxPhotoNorm[0]
    let bh = initialBboxPhotoNorm[3] - initialBboxPhotoNorm[1]
    guard bw >= 0.02, bh >= 0.02 else {
      NSLog("🎯 [Tracker] ❌ Cannot seed — bbox too small (%.3f×%.3f)", bw, bh)
      return
    }

    // ── Photo-portrait → AR-portrait (FOV crop correction) ───────────────────
    let imgRes = frame.camera.imageResolution
    let arPortraitAspect = imgRes.height / imgRes.width
    let photoPortraitAspect = imageWidth / imageHeight
    let horizScale: CGFloat = (photoPortraitAspect < arPortraitAspect - 0.01)
      ? photoPortraitAspect / arPortraitAspect : 1.0
    let horizOffset: CGFloat = (1.0 - horizScale) / 2.0

    let arPx1 = initialBboxPhotoNorm[0] * horizScale + horizOffset
    let arPy1 = initialBboxPhotoNorm[1]
    let arPx2 = initialBboxPhotoNorm[2] * horizScale + horizOffset
    let arPy2 = initialBboxPhotoNorm[3]

    // ── AR-portrait (top-left origin) → Vision-normalized (bottom-left origin) ─
    // We pass orientation: .right to Vision, so Vision sees the buffer rotated
    // to portrait. Y is bottom-up in Vision, so we flip from our top-down convention.
    var visX = arPx1
    var visY = 1.0 - arPy2     // top-down maxY → bottom-up minY
    var visW = arPx2 - arPx1
    var visH = arPy2 - arPy1

    // ── Vision Framework Minimum Size Enforcement ────────────────────────────
    // VNTrackObjectRequest will throw "Internal error: unexpected tracked object
    // bounding box size" if the box is too small (e.g., < ~5% of the frame).
    // The Rubik's cube at a distance can easily be 3%x2%.
    // We symmetrically inflate the box to a minimum of 0.05 to satisfy Vision.
    // Since tryRefineAnchorDepth only uses the CENTER of the tracker bbox to
    // cast its ray, inflating symmetrically has ZERO effect on the ray's accuracy.
    let minSize: CGFloat = 0.05
    if visW < minSize {
      let diff = minSize - visW
      visX -= diff / 2.0
      visW = minSize
    }
    if visH < minSize {
      let diff = minSize - visH
      visY -= diff / 2.0
      visH = minSize
    }

    // Clamp to valid normalized rect [0..1]
    visX = max(0.0, min(visX, 1.0 - visW))
    visY = max(0.0, min(visY, 1.0 - visH))

    let visionBbox = CGRect(x: visX, y: visY, width: visW, height: visH)
    let observation = VNDetectedObjectObservation(boundingBox: visionBbox)

    // Fresh sequence handler — track state must restart cleanly
    trackerSequenceHandler = VNSequenceRequestHandler()
    lastTrackedObservation = observation
    consecutiveLowConfFrames = 0
    trackingActive = true
    lastTrackerReseedTime = ProcessInfo.processInfo.systemUptime

    // Reseed shifts the ray direction — stale depths in the median buffer
    // would pull the median toward the old (wrong) ray. Flush them.
    refinementHits.removeAll()
    lastRefinementAppliedDepth = 0

    NSLog("🎯 [Tracker] ✅ SEEDED — vision bbox=(%.3f, %.3f, %.3f×%.3f) photo→AR(scale=%.3f, off=%.3f)",
          visX, visY, visW, visH, horizScale, horizOffset)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Update
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Called every AR frame after the anchor is placed. Runs the tracker against
  // the live capturedImage buffer and stores the result. Returns nil when the
  // tracker fails (no result, exception); the caller can fall back to legacy
  // ray-to-anchor refinement.

  @discardableResult
  func updateTracker(frame: ARFrame) -> VNDetectedObjectObservation? {
    guard trackerEnabled, trackingActive,
          let lastObs = lastTrackedObservation else { return nil }

    var safeBox = lastObs.boundingBox
    let minSize: CGFloat = 0.05
    if safeBox.width < minSize {
      let diff = minSize - safeBox.width
      safeBox.origin.x -= diff / 2.0
      safeBox.size.width = minSize
    }
    if safeBox.height < minSize {
      let diff = minSize - safeBox.height
      safeBox.origin.y -= diff / 2.0
      safeBox.size.height = minSize
    }
    
    // Clamp to valid [0..1]
    safeBox.origin.x = max(0.0, min(safeBox.origin.x, 1.0 - safeBox.width))
    safeBox.origin.y = max(0.0, min(safeBox.origin.y, 1.0 - safeBox.height))
    
    let safeObs = VNDetectedObjectObservation(boundingBox: safeBox)
    let request = VNTrackObjectRequest(detectedObjectObservation: safeObs)
    request.trackingLevel = .accurate
    // isLastFrame = false — we're streaming. Apple's tracker uses this to free
    // tracking state when the sequence ends; we never end mid-session.

    do {
      try trackerSequenceHandler.perform([request], on: frame.capturedImage, orientation: .right)
    } catch {
      NSLog("🎯 [Tracker] perform() failed: %@", error.localizedDescription)
      consecutiveLowConfFrames += 1
      return nil
    }

    guard let result = request.results?.first as? VNDetectedObjectObservation else {
      consecutiveLowConfFrames += 1
      return nil
    }

    lastTrackedObservation = result

    if result.confidence < trackerLowConfThreshold {
      consecutiveLowConfFrames += 1
    } else {
      consecutiveLowConfFrames = 0
    }

    return result
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Reseed Gating
  // ═══════════════════════════════════════════════════════════════════════════

  /// True when the tracker has drifted enough that we should request a fresh
  /// detection from the backend. Cooldown prevents reseed spam.
  func shouldReseedTracker() -> Bool {
    guard trackerEnabled, trackingActive else { return false }
    guard !isTrackerReseeding else { return false }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastTrackerReseedTime >= trackerReseedCooldown else { return false }
    return consecutiveLowConfFrames >= trackerLowConfFramesNeeded
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Tracker → World Ray
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Computes the world-space ray direction from camera through the current
  // tracker bbox center. Used by tryRefineAnchorDepth to replace the legacy
  // camera→old-anchor ray. Skips FOV crop correction because the tracker
  // already operates in AR-camera coordinate space.

  func trackerWorldRay(observation: VNDetectedObjectObservation, camera: ARCamera) -> simd_float3 {
    let visBbox = observation.boundingBox

    // Vision (bottom-left origin) → AR-portrait (top-left origin)
    let arPortraitX = (visBbox.minX + visBbox.maxX) / 2
    let arPortraitY = 1.0 - (visBbox.minY + visBbox.maxY) / 2

    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution
    let arW = imgRes.width, arH = imgRes.height

    // AR-portrait normalized → AR-landscape pixels
    // Same convention as placeWorldAnchor: portraitY*W, (1-portraitX)*H
    let arPxX = arPortraitY * arW
    let arPxY = (1.0 - arPortraitX) * arH

    let fx = CGFloat(intrinsics[0][0]), fy = CGFloat(intrinsics[1][1])
    let cx = CGFloat(intrinsics[2][0]), cy = CGFloat(intrinsics[2][1])
    let rX = Float((arPxX - cx) / fx)
    let rY = Float((arPxY - cy) / fy)

    let camT = camera.transform
    let rayCam = simd_normalize(simd_float3(rX, -rY, -1.0))
    return simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Backend Reseed
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Captures the current AR frame as JPEG, posts to /vision/detect, parses the
  // returned bbox, applies the same spatial-consistency gate that the disabled
  // re-detection loop used, and re-seeds the tracker on success.
  //
  // Threading: dispatched from visionQ (ARSessionDelegate's processing queue).
  // Network completion runs on URLSession's queue; we hop back to visionQ
  // before mutating tracker state.

  func reseedTrackerFromBackend(frame: ARFrame) {
    guard trackerEnabled, !isTrackerReseeding else { return }
    guard let urlStr = detectionUrl, let url = URL(string: urlStr) else {
      NSLog("🎯 [Tracker] ⚠️ No detectionUrl — cannot reseed (will keep tracking with stale state)")
      return
    }

    isTrackerReseeding = true
    lastTrackerReseedTime = ProcessInfo.processInfo.systemUptime
    NSLog("🎯 [Tracker] ⚠️ Drift detected (%d low-conf frames) — requesting backend reseed",
          consecutiveLowConfFrames)

    // ── Capture JPEG synchronously (do NOT capture `frame` in async closure) ──
    let pixelBuffer = frame.capturedImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      NSLog("🎯 [Tracker] Reseed failed — CGImage creation failed")
      isTrackerReseeding = false
      return
    }
    // AR camera is landscape; rotate to portrait for backend
    let fullImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    let maxDim: CGFloat = 750
    let scale = min(maxDim / fullImage.size.width, maxDim / fullImage.size.height, 1.0)
    let newSize = CGSize(width: fullImage.size.width * scale, height: fullImage.size.height * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
    fullImage.draw(in: CGRect(origin: .zero, size: newSize))
    let resized = UIGraphicsGetImageFromCurrentImageContext() ?? fullImage
    UIGraphicsEndImageContext()

    guard let jpegData = resized.jpegData(compressionQuality: 0.5) else {
      NSLog("🎯 [Tracker] Reseed failed — JPEG encode failed")
      isTrackerReseeding = false
      return
    }

    let base64Str = "data:image/jpeg;base64," + jpegData.base64EncodedString()
    let imgW = resized.size.width
    let imgH = resized.size.height

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 30  // Qwen on CPU can take 10–25s

    let body: [String: Any] = [
      "image": base64Str,
      "object": objectName,
      "score_threshold": 0.1
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
      isTrackerReseeding = false
      return
    }
    request.httpBody = bodyData

    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }
      defer { self.isTrackerReseeding = false }
      guard self.running, !self.hasCompleted else { return }

      let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

      if let error = error {
        NSLog("🎯 [Tracker] Reseed request failed: %@", error.localizedDescription)
        return
      }
      guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        NSLog("🎯 [Tracker] Reseed parse failed (HTTP %d)", httpStatus)
        return
      }

      // ── Parse bbox (handles array of numbers, NSNumber, and stringified array) ─
      var newBbox: [CGFloat]?
      if let arr = json["bbox"] as? [Any] {
        let mapped = arr.compactMap { v -> CGFloat? in
          if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
          if let i = v as? Int { return CGFloat(i) }
          if let d = v as? Double { return CGFloat(d) }
          return nil
        }
        if mapped.count == 4 { newBbox = mapped }
      } else if let s = json["bbox"] as? String {
        let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned.split(separator: ",").compactMap {
          Double($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 4 { newBbox = parts.map { CGFloat($0) } }
      }

      guard let bbox = newBbox else {
        NSLog("🎯 [Tracker] Reseed returned no bbox (keys: %@)", json.keys.joined(separator: ","))
        return
      }

      // Extract fresh backend depth — refreshes the divergence gate baseline
      // so the next refinement run uses the latest Qwen estimate, not stale
      // depth from the original detection 30+s ago.
      var freshDepth: Float? = nil
      if let dNum = json["depth"] as? NSNumber {
        let d = dNum.floatValue
        if d > 0.05 && d < 10.0 { freshDepth = d }
      } else if let dStr = json["depth"] as? String, let d = Float(dStr) {
        if d > 0.05 && d < 10.0 { freshDepth = d }
      }

      // ── Normalize to [0..1] ────────────────────────────────────────────────
      let x1 = min(bbox[0], bbox[2])
      let y1 = min(bbox[1], bbox[3])
      let x2 = max(bbox[0], bbox[2])
      let y2 = max(bbox[1], bbox[3])

      var newNorm: [CGFloat]
      if imgW > 0 && imgH > 0 {
        newNorm = [x1/imgW, y1/imgH, x2/imgW, y2/imgH]
      } else {
        let maxVal = max(x1, y1, x2, y2)
        if maxVal <= 1.0 { newNorm = [x1, y1, x2, y2] }
        else if maxVal <= 1000 { newNorm = [x1/1000, y1/1000, x2/1000, y2/1000] }
        else {
          NSLog("🎯 [Tracker] Reseed bbox unparseable (maxVal=%.1f)", maxVal)
          return
        }
      }
      newNorm = newNorm.map { min(max($0, 0), 1) }

      let newW = newNorm[2] - newNorm[0]
      let newH = newNorm[3] - newNorm[1]
      let newCx = (newNorm[0] + newNorm[2]) / 2
      let newCy = (newNorm[1] + newNorm[3]) / 2

      if newW < 0.02 || newH < 0.02 {
        NSLog("🎯 [Tracker] Reseed bbox degenerate (%.3f×%.3f) — keeping current track", newW, newH)
        return
      }

      // ── Spatial Consistency Gate (mirrors the disabled re-detect path) ────
      // Reject reseeds that have jumped too far from the locked initial center.
      // If we keep getting rejected, eventually accept (user has actually moved).
      let dCx = newCx - self.initialBboxCenter.cx
      let dCy = newCy - self.initialBboxCenter.cy
      let displacement = sqrt(dCx * dCx + dCy * dCy)
      let maxDisplacement: CGFloat = self.mode == .handFree ? 0.40 : 0.25

      if displacement > maxDisplacement {
        NSLog("🎯 [Tracker] Reseed REJECTED — displacement=%.3f > %.3f (likely wrong object)",
              displacement, maxDisplacement)
        return
      }

      // ── Accept: re-seed tracker on visionQ to match thread of mutations ───
      let acceptedNorm = newNorm
      let acceptedImgW = imgW
      let acceptedImgH = imgH
      let acceptedDepth = freshDepth

      self.visionQ.async { [weak self] in
        guard let self = self else { return }
        guard let frame = self.lastARFrame else {
          NSLog("🎯 [Tracker] Reseed skipped — no current AR frame")
          return
        }
        // Update photo-space dims so future seeds use the right aspect
        self.imageWidth = acceptedImgW
        self.imageHeight = acceptedImgH
        self.bboxNormalized = acceptedNorm
        // Refresh backend depth so the divergence gate uses the new estimate.
        // seedTracker() will reset lastRefinementAppliedDepth and clear the
        // refinement buffer, so the gate re-engages with this updated baseline.
        if let d = acceptedDepth {
          self.backendDepth = d
          self.anchorDepth = d
          NSLog("🎯 [Tracker] Backend depth refreshed → %.2fm", d)
        }
        self.seedTracker(initialBboxPhotoNorm: acceptedNorm, frame: frame)
        NSLog("🎯 [Tracker] ✅ Reseeded from backend — bbox refreshed, low-conf counter cleared")
      }
    }.resume()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Initial Bbox Refresh from Live AR Frame (with pose save)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Called ONCE before initial anchor placement. Captures the current AR
  // frame as a JPEG, posts to /vision/detect, and replaces the photo bbox
  // with one in AR-frame coordinates. CRUCIALLY also saves the AR camera's
  // world-space transform AT THE MOMENT THE AR FRAME WAS CAPTURED, so
  // placeWorldAnchor can unproject through the SAME pose that produced
  // the image the bbox lives in — eliminating the residual 3–5 s drift
  // between the detection request firing and the response coming back.
  //
  // Differences from reseedTrackerFromBackend:
  //   - Saves frame.camera.transform synchronously to detectionFrameCameraTransform.
  //   - No spatial-consistency gate (we are DEFINING the initial reference).
  //   - No seedTracker call (no anchor exists yet — that happens in placeWorldAnchor).
  //   - On completion, flips initialReseedStatus to drive the placement gate.
  //
  // On any failure, status is set to .failed/.skipped, detectionFrameCameraTransform
  // is cleared, and processARFrame falls back to the photo bbox + live transform —
  // no worse than the prior behaviour.

  func requestInitialBboxFromAR(frame: ARFrame) {
    guard let urlStr = detectionUrl, let url = URL(string: urlStr) else {
      NSLog("🎯 [InitialReseed] ⚠️ No detectionUrl — skipping refresh, using photo bbox")
      initialReseedStatus = .skipped
      detectionFrameCameraTransform = nil
      return
    }

    // ── Save the camera transform NOW, before doing anything async ──
    // This is the world-space pose of the AR camera at the moment we
    // sample the pixel buffer. The bbox we receive from the backend
    // will live in coordinates of THIS image, taken from THIS pose.
    let savedTransform = frame.camera.transform
    detectionFrameCameraTransform = savedTransform

    initialReseedStartTime = ProcessInfo.processInfo.systemUptime
    NSLog("🎯 [InitialReseed] requesting fresh bbox for '%@' — saved cam pose t=(%.3f,%.3f,%.3f)",
          objectName,
          savedTransform.columns.3.x, savedTransform.columns.3.y, savedTransform.columns.3.z)

    // ── Capture JPEG synchronously — do NOT retain `frame` in async closure ──
    let pixelBuffer = frame.capturedImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      NSLog("🎯 [InitialReseed] CGImage creation failed — falling back to photo bbox")
      initialReseedStatus = .failed
      detectionFrameCameraTransform = nil
      return
    }
    // AR camera is landscape; rotate to portrait so bbox arrives in portrait coords
    // matching what placeWorldAnchor's FOV-crop logic expects.
    let fullImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)
    let maxDim: CGFloat = 750
    let scale = min(maxDim / fullImage.size.width, maxDim / fullImage.size.height, 1.0)
    let newSize = CGSize(width: fullImage.size.width * scale, height: fullImage.size.height * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
    fullImage.draw(in: CGRect(origin: .zero, size: newSize))
    let resized = UIGraphicsGetImageFromCurrentImageContext() ?? fullImage
    UIGraphicsEndImageContext()

    guard let jpegData = resized.jpegData(compressionQuality: 0.5) else {
      NSLog("🎯 [InitialReseed] JPEG encode failed — falling back to photo bbox")
      initialReseedStatus = .failed
      detectionFrameCameraTransform = nil
      return
    }

    let base64Str = "data:image/jpeg;base64," + jpegData.base64EncodedString()
    let imgW = resized.size.width
    let imgH = resized.size.height

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = initialReseedTimeoutSec

    let body: [String: Any] = [
      "image": base64Str,
      "object": objectName,
      "score_threshold": 0.1
    ]
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
      initialReseedStatus = .failed
      detectionFrameCameraTransform = nil
      return
    }
    request.httpBody = bodyData

    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self = self else { return }
      guard self.running, !self.hasCompleted else { return }

      let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

      // Helper to record failure and clear saved pose.
      func failAndFallback(_ reason: String) {
        NSLog("🎯 [InitialReseed] %@ — falling back to photo bbox + live pose", reason)
        self.visionQ.async {
          self.initialReseedStatus = .failed
          self.detectionFrameCameraTransform = nil
        }
      }

      if let error = error {
        failAndFallback("HTTP request failed: \(error.localizedDescription)")
        return
      }
      guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        failAndFallback("response parse failed (HTTP \(httpStatus))")
        return
      }

      // Parse bbox — same logic as reseedTrackerFromBackend
      var newBbox: [CGFloat]?
      if let arr = json["bbox"] as? [Any] {
        let mapped = arr.compactMap { v -> CGFloat? in
          if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
          if let i = v as? Int { return CGFloat(i) }
          if let d = v as? Double { return CGFloat(d) }
          return nil
        }
        if mapped.count == 4 { newBbox = mapped }
      } else if let s = json["bbox"] as? String {
        let cleaned = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        let parts = cleaned.split(separator: ",").compactMap {
          Double($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 4 { newBbox = parts.map { CGFloat($0) } }
      }

      guard let bbox = newBbox else {
        failAndFallback("no bbox in response (object may not be visible in current AR frame)")
        return
      }

      // Optional fresh depth
      var freshDepth: Float? = nil
      if let dNum = json["depth"] as? NSNumber {
        let d = dNum.floatValue
        if d > 0.05 && d < 10.0 { freshDepth = d }
      } else if let dStr = json["depth"] as? String, let d = Float(dStr) {
        if d > 0.05 && d < 10.0 { freshDepth = d }
      }

      // Normalize to [0..1] in the AR-frame's portrait coords
      let x1 = min(bbox[0], bbox[2])
      let y1 = min(bbox[1], bbox[3])
      let x2 = max(bbox[0], bbox[2])
      let y2 = max(bbox[1], bbox[3])
      var newNorm: [CGFloat]
      if imgW > 0 && imgH > 0 {
        newNorm = [x1/imgW, y1/imgH, x2/imgW, y2/imgH]
      } else {
        let maxVal = max(x1, y1, x2, y2)
        if maxVal <= 1.0 { newNorm = [x1, y1, x2, y2] }
        else if maxVal <= 1000 { newNorm = [x1/1000, y1/1000, x2/1000, y2/1000] }
        else {
          failAndFallback("bbox unparseable")
          return
        }
      }
      newNorm = newNorm.map { min(max($0, 0), 1) }

      let newW = newNorm[2] - newNorm[0]
      let newH = newNorm[3] - newNorm[1]
      if newW < 0.02 || newH < 0.02 {
        failAndFallback("bbox degenerate (\(String(format: "%.3f×%.3f", newW, newH)))")
        return
      }

      let newCx = (newNorm[0] + newNorm[2]) / 2
      let newCy = (newNorm[1] + newNorm[3]) / 2

      // Apply on visionQ to match other state-mutation thread.
      // NB: NO spatial gate here — we are DEFINING the spatial reference.
      // detectionFrameCameraTransform was already set synchronously above
      // and remains valid; placeWorldAnchor will read it on the next frame.
      self.visionQ.async {
        // Update the values used by placeWorldAnchor on the next frame
        self.imageWidth = imgW
        self.imageHeight = imgH
        self.bboxNormalized = newNorm
        self.initialBboxCenter = (cx: newCx, cy: newCy)
        self.initialBboxSize = (w: newW, h: newH)
        if let d = freshDepth {
          self.backendDepth = d
          self.anchorDepth = d
          NSLog("🎯 [InitialReseed] depth refreshed → %.2fm", d)
        }
        self.initialReseedStatus = .succeeded
        let elapsed = ProcessInfo.processInfo.systemUptime - self.initialReseedStartTime
        NSLog("🎯 [InitialReseed] ✅ fresh bbox in AR coords: center=(%.3f,%.3f) size=%.3f×%.3f imgDims=%.0f×%.0f (elapsed %.1fs) — saved pose retained for placement",
              newCx, newCy, newW, newH, imgW, imgH, elapsed)
      }
    }.resume()
  }
}