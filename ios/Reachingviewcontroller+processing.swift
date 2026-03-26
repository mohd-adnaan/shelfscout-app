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
    // Hand-free: refinement NEVER stops — keep raycasting for the entire session.
    // As user walks closer, ARKit plane estimates improve dramatically.
    if mode == .handFree && anchorRefinementFrames >= anchorRefinementLimit {
      // Reset to keep refining
      anchorRefinementFrames = 1
    }

    // Route to mode-specific processing
    if mode == .handFree {
      // Hand-free: direction computed in 3D world space, reprojectBbox called
      // inside for visual overlay only (not for direction computation)
      processARFrameHandFree(frame)
    } else {
      reprojectBbox(frame: frame)
      processARFrameWithHand(frame)
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Hand-Free Processing (3D world-space directions)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Direction = dot product of (camera → anchor) against camera's own axes.
  // Only 3 directions: left / right / straight ahead.
  // "Up"/"down" suppressed — user is walking, phone tilt is noise.
  // Exception: "Tilt phone down" at extreme vertical angle.
  //
  // State-change sounds (Nicolas approach):
  //   centered_sound.wav → plays ONCE when entering alignment
  //   uncentered_sound.wav → plays ONCE when leaving alignment
  //   bip.wav → proximity beeps (faster = closer)
  //
  // Speech uses contextual phrasing:
  //   "Object is to your right" not bare "right"
  //   "Out of view, was to your right" when lost

  func processARFrameHandFree(_ frame: ARFrame) {
    guard let anchorPos = objectWorldPosition else { return }

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    let camRight = simd_normalize(simd_make_float3(camera.transform.columns.0))
    let camUp = simd_normalize(simd_make_float3(camera.transform.columns.1))

    let toObj = anchorPos - camPos
    let dist = simd_length(toObj)
    liveDistanceToObject = dist
    let toObjNorm = simd_normalize(toObj)

    let rightDot = simd_dot(toObjNorm, camRight)   // + = right, - = left
    let upDot    = simd_dot(toObjNorm, camUp)       // + = up, - = down
    let fwdDot   = simd_dot(toObjNorm, camFwd)      // + = in front, - = behind
    lastRightDot = rightDot

    // Track last known horizontal for beep panning and "out of view" memory
    if abs(rightDot) > 0.05 {
      lastKnownHorizontalSign = rightDot > 0 ? 1.0 : -1.0
      lastKnownDirectionLabel = rightDot > 0 ? "to your right" : "to your left"
    }

    // ── Object behind camera ─────────────────────────────────────────────
    if fwdDot < 0 {
      objectOffScreen = true
      proximityZone = .far

      // Use horizontal dot to tell user which way to turn
      let turnDir = rightDot >= 0 ? "right" : "left"
      let now = ProcessInfo.processInfo.systemUptime

      // State-change: was centered → now lost
      if isCenteredState {
        isCenteredState = false
        playUncenteredSound()
      }

      if now - lastSpeechTime > 3.0 {
        if lastKnownDirectionLabel.isEmpty {
          say("Object is behind you. Turn \(turnDir).")
        } else {
          say("Out of view, was \(lastKnownDirectionLabel). Turn \(turnDir).")
        }
        lastSpeechTime = now
        lastSpokenDirection = .searching
      }

      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.directionLabel.text = "Turn \(turnDir)"
        self.directionLabel.textColor = .systemOrange
        self.depthHintLabel.isHidden = true
        self.bboxLayer.isHidden = true; self.innerBboxLayer.isHidden = true
        self.distanceLabel.text = "\(Int(dist * 100)) cm"
        self.depthMethodLabel.text = "behind → \(turnDir)"
      }
      return
    }

    // ── Object in front of camera ────────────────────────────────────────
    // Only 3 directions: left / right / straight
    // Suppress "up"/"down" — phone tilt is noise when walking
    // Exception: extreme downward angle means phone pointed at ceiling
    let horizThreshold: Float = 0.20

    let direction: Direction
    if abs(rightDot) < horizThreshold && upDot < 0.40 {
      direction = .centered
      objectOffScreen = false
    } else if upDot > 0.50 {
      // Phone pointed way too low — object is above camera view
      direction = .top  // will be spoken as "Tilt phone down" (object above = phone too low)
      objectOffScreen = true
    } else if abs(rightDot) >= horizThreshold {
      direction = rightDot > 0 ? .right : .left
      objectOffScreen = abs(rightDot) > 0.55
    } else {
      // Mild vertical offset — treat as aligned (user is walking, phone bobs)
      direction = .centered
      objectOffScreen = false
    }

    // ── State-change sounds (Nicolas approach) ───────────────────────────
    if direction == .centered && !isCenteredState {
      isCenteredState = true
      playCenteredSound()
    } else if direction != .centered && isCenteredState {
      isCenteredState = false
      playUncenteredSound()
    }

    // ── Proximity zone ───────────────────────────────────────────────────
    let newProx: ProximityZone
    if objectOffScreen {
      newProx = .far
    } else if dist < 0.15 {
      newProx = .centered
    } else if dist < 0.30 {
      newProx = .veryClose
    } else if dist < 0.70 {
      newProx = .close
    } else if dist < 1.50 {
      newProx = .medium
    } else {
      newProx = .far
    }
    proximityZone = newProx

    speakDirectionHandFree(direction)

    // Reproject bbox for visual overlay only
    reprojectBbox(frame: frame)

    // ── UI update ────────────────────────────────────────────────────────
    let cm = Int(dist * 100)
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateDirectionUI(direction)
      self.distanceLabel.text = "\(cm) cm"
      self.depthMethodLabel.text = "cam→obj \(cm)cm"

      if direction == .centered && dist < 0.30 {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "\(self.objectName) here — reach forward"
      } else if direction == .centered {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = self.distanceDescription(dist)
      } else {
        self.depthHintLabel.isHidden = true
      }
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
  // Distance spoken as STEPS (75cm each), not centimeters.
  // Progressive confidence: first time aligned → "About N steps ahead"
  //   As user approaches: "N steps, going the right way" (first 2 times only)
  //   Close: "One step away" → "Arm's reach" → "{object} here. Reach forward."
  //
  // Screen still shows cm for debugging.

  /// Convert distance to human-friendly description based on distanceUnit setting
  func distanceDescription(_ dist: Float) -> String {
    if distanceUnit == "cm" {
      let cm = Int(dist * 100)
      if cm < 30 { return "arm's reach" }
      return "\(cm) centimeters"
    } else {
      let steps = Int(round(dist / 0.75))  // 75cm per step
      if steps <= 0 { return "arm's reach" }
      if steps == 1 { return "one step away" }
      return "about \(steps) steps"
    }
  }

  func speakDirectionHandFree(_ direction: Direction) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if direction == currentDirection { directionStableFrames += 1 } else { directionStableFrames = 0 }

    let dist = liveDistanceToObject
    let steps = Int(round(dist / 0.75))

    // ── Case 1: Arms reach (<30cm) — grab guidance with 3D hint ─────────
    if direction == .centered && dist < 0.30 {
      if direction != lastSpokenDirection || now - lastSpeechTime > 5.0 {
        var hint = ""
        if abs(lastRightDot) > 0.10 {
          hint = lastRightDot > 0 ? ", slightly right" : ", slightly left"
        }
        say("\(objectName) here. Reach forward\(hint).")
        lastSpokenDirection = direction; lastSpeechTime = now
      }
      return
    }

    // ── Case 2: Very close (<75cm) — "arm's reach" ─────────────────────
    if direction == .centered && dist < 0.75 {
      if direction != lastSpokenDirection {
        say("Arm's reach. Keep going.")
        lastSpokenDirection = direction; lastSpeechTime = now
      } else if now - lastSpeechTime > 4.0 {
        say("Almost there.")
        lastSpeechTime = now
      }
      return
    }

    // ── Case 3: Aligned, walking toward ─────────────────────────────────
    if direction == .centered {
      if direction != lastSpokenDirection {
        say("Straight ahead. \(distanceDescription(dist)).")
        lastSpokenDirection = direction; lastSpeechTime = now
        lastAnnouncedSteps = steps
      } else if now - lastSpeechTime > 4.0 {
        if steps < lastAnnouncedSteps && progressConfirmations < 2 {
          say("\(distanceDescription(dist)). Going the right way.")
          progressConfirmations += 1
        } else if steps > lastAnnouncedSteps + 1 && progressConfirmations > 0 {
          say("Getting further. \(distanceDescription(dist)).")
          progressConfirmations = 0
        } else {
          say("\(distanceDescription(dist)).")
        }
        lastAnnouncedSteps = steps
        lastSpeechTime = now
      }
      return
    }

    // ── Case 4: "Tilt phone down" for extreme vertical ──────────────────
    if direction == .top {
      if direction != lastSpokenDirection && (now - lastSpeechTime) >= speechCooldown {
        say("Tilt phone down.")
        lastSpokenDirection = direction; lastSpeechTime = now
      }
      return
    }

    // ── Case 5: Not aligned — contextual direction ──────────────────────
    if direction == lastSpokenDirection { return }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      let dirLabel = direction == .right ? "to your right" : "to your left"

      // If user was aligned and drifted off
      if lastSpokenDirection == .centered && progressConfirmations > 0 {
        say("Off track. Object is \(dirLabel).")
      } else {
        say("Object is \(dirLabel).")
      }
      lastSpokenDirection = direction; lastSpeechTime = now
      progressConfirmations = 0
      triggerHaptic(0.4)
    }
  }
}
