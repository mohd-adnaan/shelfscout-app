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
      NSLog("📷 [ReachingVC] LiDAR scene depth ENABLED")
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
    NSLog("📷 [ReachingVC] AR session started")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Place World Anchor
  // ═══════════════════════════════════════════════════════════════════════════

  func placeWorldAnchor(frame: ARFrame) {
    let sw = cachedSW, sh = cachedSH
    let photoAspect = imageWidth / imageHeight
    let screenAspect = sw / sh

    var scaleX: CGFloat = 1, scaleY: CGFloat = 1
    var offsetX: CGFloat = 0, offsetY: CGFloat = 0
    if photoAspect > screenAspect {
      scaleX = photoAspect / screenAspect; offsetX = (scaleX - 1) / 2
    } else {
      scaleY = screenAspect / photoAspect; offsetY = (scaleY - 1) / 2
    }

    let bx1 = (bboxNormalized[0] * scaleX - offsetX) * sw
    let by1 = (bboxNormalized[1] * scaleY - offsetY) * sh
    let bx2 = (bboxNormalized[2] * scaleX - offsetX) * sw
    let by2 = (bboxNormalized[3] * scaleY - offsetY) * sh
    let screenCenter = CGPoint(x: (bx1+bx2)/2, y: (by1+by2)/2)

    let camera = frame.camera
    let depth  = backendDepth ?? 0.5
    anchorDepth = depth

    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution
    let arW = imgRes.width, arH = imgRes.height
    let arPxX = (screenCenter.y / sh) * arW
    let arPxY = (1.0 - screenCenter.x / sw) * arH
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

    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = depth * Float(bboxNormW) * 0.5
    objectWorldHalfH = depth * Float(bboxNormH) * 0.8

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
      if let d = self.backendDepth { self.distanceLabel.text = "\(Int(d*100)) cm" }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Refine Anchor Depth
  // ═══════════════════════════════════════════════════════════════════════════

  func tryRefineAnchorDepth(frame: ARFrame) {
    guard let currentPos = objectWorldPosition else { return }

    let sw = cachedSW, sh = cachedSH
    let camera = frame.camera
    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution

    let photoAspect = imageWidth / imageHeight
    let screenAspect = sw / sh
    var scaleX: CGFloat = 1, scaleY: CGFloat = 1
    var offsetX: CGFloat = 0, offsetY: CGFloat = 0
    if photoAspect > screenAspect {
      scaleX = photoAspect / screenAspect; offsetX = (scaleX - 1) / 2
    } else {
      scaleY = screenAspect / photoAspect; offsetY = (scaleY - 1) / 2
    }
    let bx1 = (bboxNormalized[0] * scaleX - offsetX) * sw
    let by1 = (bboxNormalized[1] * scaleY - offsetY) * sh
    let bx2 = (bboxNormalized[2] * scaleX - offsetX) * sw
    let by2 = (bboxNormalized[3] * scaleY - offsetY) * sh
    let screenCenter = CGPoint(x: (bx1+bx2)/2, y: (by1+by2)/2)

    let arPxX = (screenCenter.y / sh) * imgRes.width
    let arPxY = (1.0 - screenCenter.x / sw) * imgRes.height
    let fx = Float(intrinsics[0][0]), fy = Float(intrinsics[1][1])
    let cx = Float(intrinsics[2][0]), cy = Float(intrinsics[2][1])
    let rX = (Float(arPxX) - cx) / fx
    let rY = (Float(arPxY) - cy) / fy
    let rayCam   = simd_normalize(simd_float3(rX, -rY, -1.0))
    let camT     = camera.transform
    let worldDir = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos   = simd_make_float3(camT.columns.3)

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

    // FIX 13: Reject raycasts beyond 2x backend estimate
    if let bd = backendDepth, hitDepth > bd * 2.0 {
      NSLog("🎯 [Refine] Rejected hit at %.2fm (>2x backend %.2fm)", hitDepth, bd)
      return
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

    guard iqr < refinementConvergeThreshold else {
      NSLog("🎯 [Refine] IQR too wide (%.2fm) — still accumulating", iqr)
      return
    }

    if lastRefinementAppliedDepth > 0 && abs(median - lastRefinementAppliedDepth) < 0.02 {
      NSLog("🎯 [Refine] ✅ CONVERGED at %.2fm (Δ=%.1fcm from last) — stopping",
            median, abs(median - lastRefinementAppliedDepth) * 100)
      anchorRefinementFrames = anchorRefinementLimit
      return
    }

    let prevDepth = simd_length(currentPos - camPos)
    let newWorldPos = camPos + worldDir * median
    objectWorldPosition = newWorldPos

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
      if camToAnchorDist < 0.25 {
        NSLog("🎯 [ReachingVC] Anchor behind camera at %.2fm — auto-success", camToAnchorDist)
        DispatchQueue.main.async { [weak self] in self?.handleSuccess() }
        return
      }
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
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ARSessionDelegate
// ═══════════════════════════════════════════════════════════════════════════════

extension ReachingViewController: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running, !hasCompleted else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastFrameProcessedAt >= frameProcessInterval else { return }
    lastFrameProcessedAt = now
    visionQ.async { [weak self] in self?.processARFrame(frame) }
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
