//
//  Reachingviewcontroller+depth.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//
//  Depth Checking (Heuristic, LiDAR, Raycast)

import ARKit
import Vision

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Depth Check (3 methods + proximity bypass)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Method priority:
  //   1. Hand span heuristic (PRIMARY — measures hand itself, all devices)
  //   2. LiDAR depth map (Pro devices only)
  //   3. ARKit raycast (LAST RESORT — hits surface behind hand)
  //   4. Small-span proximity bypass (FIX 16 — when hand too close for heuristic)

  func checkHandDepth(
    frame: ARFrame,
    handScreenPt: CGPoint,
    handObs: VNHumanHandPoseObservation
  ) -> (result: DepthResult, method: String) {

    let objectDist = liveDistanceToObject

    // ── Method 1 (PRIMARY): Hand span heuristic ────────────────────────────
    //   k=0.25 from iPhone FOV math. Threshold=0.12m (FIX 15, was 0.25).
    if let wrist = try? handObs.recognizedPoint(.wrist),
       let mTip  = try? handObs.recognizedPoint(.middleTip),
       wrist.confidence > 0.15, mTip.confidence > 0.15 {

      let span = hypot(wrist.location.x - mTip.location.x,
                       wrist.location.y - mTip.location.y)

      // ── FIX 16: Small-span proximity bypass ────────────────────────────
      // When hand is very close to camera, span shrinks dramatically
      // (fingers bunched, only fingertips visible). k/span gives absurd
      // estimates (2-4m). But if camera is within 60cm of the anchor,
      // the user has physically walked up to the object. Trust proximity.
      if span < 0.15 {
        let cameraClose = liveDistanceToObject < 0.60
        if arFrameCount % 20 == 0 {
          NSLog("📏 [Depth-SmallSpan] span=%.3f (<0.15) cameraDist=%.2fm bypass=%@",
                span, liveDistanceToObject, cameraClose ? "YES" : "NO")
        }
        if cameraClose {
          return (.close, "proximity-bypass ✅ (span=\(String(format:"%.2f",span)))")
        }
        // Span too small for reliable estimate, but camera not close enough
        // Fall through to other methods
      } else {
        // Normal span — use heuristic
        let k: CGFloat = 0.25
        let est  = Float(k / max(span, 0.01))
        let diff = abs(est - objectDist)
        let isClose = diff < heuristicDepthThreshold  // FIX 15: 0.12m

        if arFrameCount % 20 == 0 {
          NSLog("📏 [Depth-Heuristic] span=%.3f est=%.2fm obj=%.2fm diff=%.2fm close=%d",
                span, est, objectDist, diff, isClose ? 1 : 0)
        }
        return (isClose ? .close : .far, isClose ? "heuristic ✅" : "heuristic ❌ \(Int(diff*100))cm")
      }
    }

    // ── Method 2: LiDAR depth map (Pro devices only) ───────────────────────
    if let sceneDepth = frame.sceneDepth {
      let depthMap = sceneDepth.depthMap
      let dW = CVPixelBufferGetWidth(depthMap)
      let dH = CVPixelBufferGetHeight(depthMap)

      let normScreenX = handScreenPt.x / cachedSW
      let normScreenY = handScreenPt.y / cachedSH
      let dpX = Int(normScreenY * CGFloat(dW))
      let dpY = Int((1.0 - normScreenX) * CGFloat(dH))
      let clampedX = max(0, min(dpX, dW - 1))
      let clampedY = max(0, min(dpY, dH - 1))

      CVPixelBufferLockBaseAddress(depthMap, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

      if let base = CVPixelBufferGetBaseAddress(depthMap) {
        let bpr       = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr       = base.advanced(by: clampedY * bpr + clampedX * MemoryLayout<Float32>.size)
        let handDepth = ptr.load(as: Float32.self)

        if handDepth > 0.05 && handDepth < 8.0 {
          let diff    = abs(handDepth - objectDist)
          let isClose = diff < lidarDepthThreshold

          if arFrameCount % 20 == 0 {
            NSLog("📏 [Depth-LiDAR] hand=%.2fm obj=%.2fm diff=%.2fm close=%d",
                  handDepth, objectDist, diff, isClose ? 1 : 0)
          }
          return (isClose ? .close : .far, isClose ? "LiDAR ✅" : "LiDAR ❌ \(Int(diff*100))cm")
        }
      }
    }

    // ── Method 3 (LAST RESORT): ARKit Raycast ──────────────────────────────
    let camera     = frame.camera
    let intrinsics = camera.intrinsics
    let imgRes     = camera.imageResolution

    let arPxX = (handScreenPt.y / cachedSH) * imgRes.width
    let arPxY = (1.0 - handScreenPt.x / cachedSW) * imgRes.height
    let fx = Float(intrinsics[0][0]), fy = Float(intrinsics[1][1])
    let cx = Float(intrinsics[2][0]), cy = Float(intrinsics[2][1])
    let rX = (Float(arPxX) - cx) / fx
    let rY = (Float(arPxY) - cy) / fy
    let rayCam   = simd_normalize(simd_float3(rX, -rY, -1.0))
    let camT     = camera.transform
    let worldDir = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos   = simd_make_float3(camT.columns.3)

    let query = ARRaycastQuery(origin: camPos, direction: worldDir,
                               allowing: .estimatedPlane, alignment: .any)
    let rayResults = sceneView.session.raycast(query)

    if let hit = rayResults.first {
      let hitPos      = simd_make_float3(hit.worldTransform.columns.3)
      let surfaceDist = simd_length(hitPos - camPos)
      let diff        = abs(surfaceDist - objectDist)
      let isClose     = diff < 0.30

      if arFrameCount % 20 == 0 {
        NSLog("📏 [Depth-Raycast] surface=%.2fm obj=%.2fm diff=%.2fm close=%d (surface behind hand)",
              surfaceDist, objectDist, diff, isClose ? 1 : 0)
      }
      return (isClose ? .close : .far, isClose ? "raycast ✅" : "raycast ❌ \(Int(diff*100))cm")
    }

    NSLog("📏 [Depth] No depth method succeeded — camera proximity will gate success")
    return (.noData, "no data")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Aspect-Fill Crop
  // ═══════════════════════════════════════════════════════════════════════════

  func computeAspectFillCrop(imageW: CGFloat, imageH: CGFloat) {
    guard !cropComputed, cachedSW > 0, cachedSH > 0, imageW > 0, imageH > 0 else { return }
    let rotW = imageH, rotH = imageW
    if rotW / rotH > cachedSW / cachedSH {
      let dW = rotW * (cachedSH / rotH)
      cropFracX = ((dW - cachedSW) / 2) / dW
    }
    cropComputed = true
    NSLog("📐 [ReachingVC] cropFracX=%.4f", cropFracX)
  }

  func visionToScreen(_ pt: CGPoint) -> CGPoint {
    let adjX = cropFracX > 0
      ? ((pt.x - cropFracX) / (1.0 - 2 * cropFracX)) * cachedSW
      : pt.x * cachedSW
    return CGPoint(x: adjX, y: (1 - pt.y) * cachedSH)
  }
}
