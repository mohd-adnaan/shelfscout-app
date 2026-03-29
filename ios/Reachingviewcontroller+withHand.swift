//
//  Reachingviewcontroller+withHand.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-28.
//
//  WITH-HAND MODE — All with-hand specific logic lives here.
//  Vision hand tracking, 2D screen-space directions, hand-span depth,
//  LiDAR/raycast depth checks, proximity-based feedback.
//
//  This file is INDEPENDENT of +handFree.swift. Debugging with-hand
//  mode = open this file. No cross-contamination.
//
//      NOT MODIFIED as part of hand-free refactor. This is the existing
//      with-hand logic moved here as-is from +processing.swift, +depth.swift,
//      and +audio.swift for code separation only.
 
import Vision
import ARKit
import UIKit
 
extension ReachingViewController {
 
  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Frame Processing (2D screen-space)
  // ═══════════════════════════════════════════════════════════════════════════
 
  func processARFrameWithHand(_ frame: ARFrame) {
    let pb = frame.capturedImage
    computeAspectFillCrop(imageW: CGFloat(CVPixelBufferGetWidth(pb)),
                          imageH: CGFloat(CVPixelBufferGetHeight(pb)))
 
    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
    do { try handler.perform([handReq]) } catch { return }
 
    guard projectedBboxW > 0 else { return }
 
    let bboxCx    = projectedBboxCenter.x
    let bboxCy    = projectedBboxCenter.y
    let bboxHalfW = projectedBboxW / 2
    let bboxHalfH = projectedBboxH / 2
 
    // ── No hand detected ──────────────────────────────────────────────────
    guard let obs = handReq.results?.first else {
      noHandFrames += 1; successFrames = 0; depthConfirmedFrames = 0
      handIsCloseEnoughInDepth = false
      proximityZone = .searching
 
      if noHandFrames == noHandLimit {
        say("Show your hand to the camera.")
      } else if noHandFrames > 0 && noHandFrames % noHandRepeatCycle == 0 {
        say("I can't see your hand. Hold it up in front of the camera.")
      }
 
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
      }
      return
    }
 
    noHandFrames = 0
 
    guard let visionPt = handCenter(obs) else {
      successFrames = 0; handIsCloseEnoughInDepth = false
      return
    }
 
    let handScreen = visionToScreen(visionPt)
    let screenX = handScreen.x, screenY = handScreen.y
    let dx = screenX - bboxCx, dy = screenY - bboxCy
 
    // ── Update hand dot ───────────────────────────────────────────────────
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let dotR: CGFloat = 10, glowR: CGFloat = 20
      self.handDot.isHidden = false; self.handDotGlow.isHidden = false
      self.handDot.path = UIBezierPath(ovalIn: CGRect(x: screenX-dotR, y: screenY-dotR,
                                                       width: dotR*2, height: dotR*2)).cgPath
      self.handDotGlow.path = UIBezierPath(ovalIn: CGRect(x: screenX-glowR, y: screenY-glowR,
                                                           width: glowR*2, height: glowR*2)).cgPath
      let dotColor: UIColor
      if abs(dx) < bboxHalfW && abs(dy) < bboxHalfH {
        dotColor = .systemGreen
      } else if sqrt(dx*dx+dy*dy) < max(bboxHalfW, bboxHalfH) * 2 {
        dotColor = .systemYellow
      } else {
        dotColor = .systemRed
      }
      self.handDot.fillColor = dotColor.cgColor
      self.handDotGlow.fillColor = dotColor.withAlphaComponent(0.3).cgColor
    }
 
    // ── Overlap checks (v9: widened — anchor is approximate) ─────────────
    let innerTolW = bboxHalfW * 1.3, innerTolH = bboxHalfH * 1.3
    let innerOverlap = abs(dx) < innerTolW && abs(dy) < innerTolH
    let tolX = max(bboxHalfW * 0.5, 30), tolY = max(bboxHalfH * 0.5, 30)
    let nearOverlap = CGRect(
      x: bboxCx - bboxHalfW - tolX, y: bboxCy - bboxHalfH - tolY,
      width: bboxHalfW*2 + tolX*2, height: bboxHalfH*2 + tolY*2
    ).contains(CGPoint(x: screenX, y: screenY))
 
    // ── Depth check (3-state) ──────────────────────────────────────────────
    let (depthResult, depthMethodStr) =
      checkHandDepth(frame: frame, handScreenPt: handScreen, handObs: obs)
    let depthOk = depthResult == .close
    let depthFar = depthResult == .far
    handIsCloseEnoughInDepth = depthOk
 
    // ── Proximity zone ────────────────────────────────────────────────────
    let normDist = sqrt(dx*dx+dy*dy) / max(cachedSW, cachedSH)
    let newProx: ProximityZone
    if innerOverlap && depthOk { newProx = .centered }
    else if innerOverlap       { newProx = .veryClose }
    else if nearOverlap        { newProx = .close }
    else if normDist < 0.15    { newProx = .close }
    else if normDist < 0.30    { newProx = .medium }
    else                       { newProx = .far }
    proximityZone = newProx
 
    // ── Direction ─────────────────────────────────────────────────────────
    let direction = computeDirection(handX: screenX, handY: screenY,
                                     bboxCx: bboxCx, bboxCy: bboxCy,
                                     bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH)
    speakDirectionIfNeeded(direction)
 
    let cameraIsClose = liveDistanceToObject < reachProximityThreshold
 
    // ── UI update ─────────────────────────────────────────────────────────
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateDirectionUI(direction)
 
      if innerOverlap && cameraIsClose {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "Move hand forward — tap anywhere when done"
        self.distanceLabel.text = "Within reach"
      } else if innerOverlap && !cameraIsClose {
        self.depthHintLabel.isHidden = false
        let remaining = max(0, Int((self.liveDistanceToObject - self.reachProximityThreshold) * 100))
        if remaining <= 5 {
          self.depthHintLabel.text = "Move hand forward — tap anywhere when done"
          self.distanceLabel.text = "Within reach"
        } else {
          self.depthHintLabel.text = "Move \(remaining)cm closer"
          self.distanceLabel.text = "\(remaining)cm to go"
        }
      } else {
        self.depthHintLabel.isHidden = true
      }
 
      self.depthMethodLabel.text = depthMethodStr
 
      if innerOverlap && (self.liveDistanceToObject < 0.30 || cameraIsClose) {
        self.progressRing.isHidden = false
        let progress = CGFloat(self.successFrames) / CGFloat(self.successThreshold)
        self.progressRing.strokeEnd = min(progress, 1.0)
        let ringR: CGFloat = 25
        self.progressRing.path = UIBezierPath(
          ovalIn: CGRect(x: screenX-ringR, y: screenY-ringR, width: ringR*2, height: ringR*2)
        ).cgPath
      } else {
        self.progressRing.isHidden = true; self.progressRing.strokeEnd = 0
      }
    }
 
    // ═══════════════════════════════════════════════════════════════════════
    // Depth Tracking (informational only — manual exit)
    // ═══════════════════════════════════════════════════════════════════════
 
    if depthOk {
      depthConfirmedFrames = min(depthConfirmedFrames + 1, 15)
    } else if depthFar {
      depthConfirmedFrames = max(0, depthConfirmedFrames - 3)
    }
 
    if innerOverlap && (liveDistanceToObject < 0.30 || cameraIsClose) {
      successFrames = min(successFrames + 1, successThreshold)
    } else if !innerOverlap {
      successFrames = max(0, successFrames - 2)
    }
    // NOTE: No handleSuccess() call — user exits via "Done" button
  }
 
  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Direction Speech
  // ═══════════════════════════════════════════════════════════════════════════
 
  func speakDirectionIfNeeded(_ direction: Direction) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if direction == currentDirection { directionStableFrames += 1 } else { directionStableFrames = 1 }
 
    // Case 1: Aligned but still far — tell user to walk closer
    if direction == .centered && liveDistanceToObject >= reachProximityThreshold {
      if now - lastSpeechTime > 2.5 {
        let remaining = max(0, Int((liveDistanceToObject - reachProximityThreshold) * 100))
        if remaining <= 5 {
          say("Aligned. Move your hand forward to grab it.")
        } else {
          say("Aligned. Move \(remaining) centimeters closer.")
        }
        lastSpeechTime = now
      }
      return
    }
 
    // Case 2: Aligned AND within reach — tell user to reach forward
    if direction == .centered && liveDistanceToObject < reachProximityThreshold {
      if direction != lastSpokenDirection {
        say("Aligned. Move your hand forward to grab it.")
        lastSpokenDirection = direction; lastSpeechTime = now
      } else if (now - lastSpeechTime) > 3.0 {
        say("Move your hand forward. Tap anywhere when you have it.")
        lastSpeechTime = now
      }
      return
    }
 
    // Case 3: Not aligned — speak direction
    if direction == lastSpokenDirection { return }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      say(direction.rawValue)
      lastSpokenDirection = direction; lastSpeechTime = now
      if direction != .centered && direction != .searching { triggerHaptic(0.4) }
    }
  }
 
  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Direction Computation (2D screen-space)
  // ═══════════════════════════════════════════════════════════════════════════
 
  func computeDirection(handX: CGFloat, handY: CGFloat,
                        bboxCx: CGFloat, bboxCy: CGFloat,
                        bboxHalfW: CGFloat, bboxHalfH: CGFloat) -> Direction {
    let dx = handX - bboxCx, dy = handY - bboxCy
    if abs(dx) < bboxHalfW * 1.3 && abs(dy) < bboxHalfH * 1.3 { return .centered }
    let angleRad = atan2(-(bboxCy - handY), bboxCx - handX)
    var angleDeg = angleRad * 180.0 / .pi
    if angleDeg < 0 { angleDeg += 360 }
    switch angleDeg {
    case 0..<22.5, 337.5...360: return .right
    case 22.5..<67.5:    return .topRight
    case 67.5..<112.5:   return .top
    case 112.5..<157.5:  return .topLeft
    case 157.5..<202.5:  return .left
    case 202.5..<247.5:  return .downLeft
    case 247.5..<292.5:  return .down
    case 292.5..<337.5:  return .downRight
    default: return .right
    }
  }
 
  func handCenter(_ obs: VNHumanHandPoseObservation) -> CGPoint? {
    if let tip = try? obs.recognizedPoint(.indexTip), tip.confidence > 0.3 { return tip.location }
    if let mcp = try? obs.recognizedPoint(.middleMCP), mcp.confidence > 0.3 { return mcp.location }
    if let w   = try? obs.recognizedPoint(.wrist),     w.confidence   > 0.3 { return w.location }
    return nil
  }
 
  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Depth Check (3 methods + proximity bypass)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Method priority:
  //   1. Hand span heuristic (PRIMARY — measures hand itself, all devices)
  //   2. LiDAR depth map (Pro devices only)
  //   3. ARKit raycast (LAST RESORT — hits surface behind hand)
  //   4. Small-span proximity bypass (when hand too close for heuristic)
 
  func checkHandDepth(
    frame: ARFrame,
    handScreenPt: CGPoint,
    handObs: VNHumanHandPoseObservation
  ) -> (result: DepthResult, method: String) {
 
    let objectDist = liveDistanceToObject
 
    // ── Method 1 (PRIMARY): Hand span heuristic ────────────────────────────
    if let wrist = try? handObs.recognizedPoint(.wrist),
       let mTip  = try? handObs.recognizedPoint(.middleTip),
       wrist.confidence > 0.15, mTip.confidence > 0.15 {
 
      let span = hypot(wrist.location.x - mTip.location.x,
                       wrist.location.y - mTip.location.y)
 
      // ── Small-span proximity bypass ────────────────────────────
      if span < 0.15 {
        let cameraClose = liveDistanceToObject < 0.60
        if arFrameCount % 20 == 0 {
          NSLog("📏 [Depth-SmallSpan] span=%.3f (<0.15) cameraDist=%.2fm bypass=%@",
                span, liveDistanceToObject, cameraClose ? "YES" : "NO")
        }
        if cameraClose {
          return (.close, "proximity-bypass ✅ (span=\(String(format:"%.2f",span)))")
        }
      } else {
        let k: CGFloat = 0.25
        let est  = Float(k / max(span, 0.01))
        let diff = abs(est - objectDist)
        let isClose = diff < heuristicDepthThreshold
 
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
}
 
