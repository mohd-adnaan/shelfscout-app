//
//  Reachingviewcontroller+processing.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//
// Frame Processing, Success Gate, Directions

import Vision
import ARKit

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Process AR Frame (router)
  // ═══════════════════════════════════════════════════════════════════════════

  func processARFrame(_ frame: ARFrame) {
    guard running else { return }
    arFrameCount += 1

    if !anchorPlaced {
      if arFrameCount >= anchorWaitFrames { placeWorldAnchor(frame: frame); say("Target locked.") }
      return
    }

    if anchorRefinementFrames > 0 && anchorRefinementFrames < anchorRefinementLimit {
      anchorRefinementFrames += 1
      tryRefineAnchorDepth(frame: frame)
    }

    reprojectBbox(frame: frame)

    // Route to mode-specific processing
    if mode == .handFree {
      processARFrameHandFree(frame)
    } else {
      processARFrameWithHand(frame)
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Hand-Free Processing (camera center as reference)
  // ═══════════════════════════════════════════════════════════════════════════

  func processARFrameHandFree(_ frame: ARFrame) {
    guard projectedBboxW > 0 else { return }

    let bboxCx    = projectedBboxCenter.x
    let bboxCy    = projectedBboxCenter.y
    let bboxHalfW = projectedBboxW / 2
    let bboxHalfH = projectedBboxH / 2

    // Reference point = screen center (where camera points)
    let refX = cachedSW / 2
    let refY = cachedSH / 2

    // ── Proximity zone (camera distance only — no hand) ──────────────────
    let dist = liveDistanceToObject
    let newProx: ProximityZone
    if dist < 0.15       { newProx = .centered }
    else if dist < 0.30  { newProx = .veryClose }
    else if dist < 0.70  { newProx = .close }
    else if dist < 1.50  { newProx = .medium }
    else                  { newProx = .far }
    proximityZone = newProx

    // ── Direction (camera center vs projected bbox center) ───────────────
    let direction = computeDirection(handX: refX, handY: refY,
                                     bboxCx: bboxCx, bboxCy: bboxCy,
                                     bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH)
    speakDirectionHandFree(direction)

    // ── UI update ────────────────────────────────────────────────────────
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateDirectionUI(direction)

      // Show proximity hints based on camera distance
      if direction == .centered && dist < 0.50 {
        self.depthHintLabel.isHidden = false
        if dist < 0.15 {
          self.depthHintLabel.text = "Within reach — tap to confirm"
          self.distanceLabel.text = "Within reach"
        } else {
          let remaining = max(0, Int(dist * 100) - 15)
          self.depthHintLabel.text = "Move \(remaining)cm closer"
          self.distanceLabel.text = "\(remaining)cm to go"
        }
      } else if direction == .centered {
        self.depthHintLabel.isHidden = false
        let remaining = Int(dist * 100)
        self.depthHintLabel.text = "Aligned — \(remaining)cm ahead"
      } else {
        self.depthHintLabel.isHidden = true
      }

      self.depthMethodLabel.text = "cam→obj \(Int(dist*100))cm"
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Processing (existing logic, unchanged)
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
    // Inner overlap uses 1.3x bbox to account for anchor placement error.
    // The bbox projection from a stale photo will never be pixel-perfect.
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

      // Show manual-exit hint whenever hand is aligned (inner overlap)
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

      if innerOverlap && (liveDistanceToObject < 0.30 || cameraIsClose) {
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
    // MARK: Depth Tracking (informational only — v9 manual exit)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // Auto-success is DISABLED. The anchor placement + depth estimation
    // is not reliable enough (< 80% accuracy) to confirm object acquisition.
    // User must tap "Done" to exit. Depth tracking still drives:
    //   - Proximity beeps (faster = closer)
    //   - "Move closer" hints
    //   - Progress ring (visual feedback only, does NOT auto-dismiss)

    if depthOk {
      depthConfirmedFrames = min(depthConfirmedFrames + 1, 15)
    } else if depthFar {
      depthConfirmedFrames = max(0, depthConfirmedFrames - 3)
    }
    // .noData: don't touch depthConfirmedFrames — preserve recent evidence

    // Track alignment progress for visual ring feedback (informational only)
    if innerOverlap && (liveDistanceToObject < 0.30 || cameraIsClose) {
      successFrames = min(successFrames + 1, successThreshold)
    } else if !innerOverlap {
      successFrames = max(0, successFrames - 2)
    }
    // NOTE: No handleSuccess() call — user exits via "Done" button
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Direction Computation
  // ═══════════════════════════════════════════════════════════════════════════

  func computeDirection(handX: CGFloat, handY: CGFloat,
                        bboxCx: CGFloat, bboxCy: CGFloat,
                        bboxHalfW: CGFloat, bboxHalfH: CGFloat) -> Direction {
    let dx = handX - bboxCx, dy = handY - bboxCy
    // v9: Use 1.3x tolerance matching the widened innerOverlap zone
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
  // MARK: - Hand-Free Speech Feedback
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // In hand-free mode, speech semantics differ:
  // - "left"/"right" means "turn the phone left/right"
  // - "Aligned" means "camera is pointing at the object"
  // - Distance announcements use camera-to-object distance
  // - No "show your hand" prompts ever

  func speakDirectionHandFree(_ direction: Direction) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if direction == currentDirection { directionStableFrames += 1 } else { directionStableFrames = 1 }

    let dist = liveDistanceToObject

    // Case 1: Aligned — announce distance-based guidance
    if direction == .centered {
      if dist < 0.15 {
        // Within reach — strong confirmation
        if direction != lastSpokenDirection {
          say("Right there. Reach forward and tap when done.")
          lastSpokenDirection = direction; lastSpeechTime = now
        } else if now - lastSpeechTime > 4.0 {
          say("Object right ahead. Tap when you have it.")
          lastSpeechTime = now
        }
      } else if dist < 0.50 {
        // Very close — encourage final approach
        if direction != lastSpokenDirection {
          let cm = Int(dist * 100)
          say("Aligned. \(cm) centimeters ahead.")
          lastSpokenDirection = direction; lastSpeechTime = now
        } else if now - lastSpeechTime > 3.0 {
          let cm = Int(dist * 100)
          say("\(cm) centimeters. Keep moving forward.")
          lastSpeechTime = now
        }
      } else {
        // Aligned but far — announce distance
        if direction != lastSpokenDirection || now - lastSpeechTime > 3.5 {
          let cm = Int(dist * 100)
          say("Aligned. \(cm) centimeters ahead. Walk forward.")
          lastSpokenDirection = direction; lastSpeechTime = now
        }
      }
      return
    }

    // Case 2: Not aligned — speak direction
    if direction == lastSpokenDirection { return }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      say(direction.rawValue)
      lastSpokenDirection = direction; lastSpeechTime = now
      if direction != .centered && direction != .searching { triggerHaptic(0.4) }
    }
  }
}