//
//  Reachingviewcontroller+withHand.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-28.
//  Rewritten: 2026-04-05 — Two-phase architecture.
//
//  WITH-HAND MODE — Two-phase reaching pipeline:
//
//  PHASE 1 — NAVIGATION (dist >= handGuidanceThreshold):
//    3D world-space dot products (identical to hand-free).
//    Walks user to the object using camera orientation.
//    No hand tracking. Same speech, beeps, state-change sounds.
//
//  PHASE 2 — HAND GUIDANCE (dist < handGuidanceThreshold):
//    Vision hand tracking + 2D screen-space directions.
//    Guides user's hand to the projected bbox.
//    Acquisition validation polls backend for auto-exit.
//
//  One-shot Qwen detection + ARKit refinement only.
//  Re-detection is OFF — it causes bbox drift and anchor instability.
//
//  Depth strategy:
//    Pro (LiDAR)  → metric depth via sceneDepth (auto-detected, logged)
//    Non-Pro      → Qwen/backend depth + ARKit raycast refinement (logged)
//
//  This file is INDEPENDENT of +handFree.swift. Debugging with-hand
//  mode = open this file. No cross-contamination.

import Vision
import ARKit
import UIKit

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Main Entry (Phase Router)
  // ═══════════════════════════════════════════════════════════════════════════

  func processARFrameWithHand(_ frame: ARFrame) {
    guard let anchorPos = objectWorldPosition else { return }

    let camera = frame.camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let dist = simd_length(anchorPos - camPos)
    liveDistanceToObject = dist

    // ── Phase routing with hysteresis ───────────────────────────────────
    // Enter Phase 2: dist < handGuidanceThreshold (0.50m)
    // Exit  Phase 2: dist > handGuidanceExitThreshold (0.65m)
    if handGuidanceActive && dist > handGuidanceExitThreshold {
      // User backed away — drop to Phase 1
      handGuidanceActive = false
      handGuidanceAnnounced = false
      noHandFrames = 0; successFrames = 0; depthConfirmedFrames = 0
      say("Moved away. Resuming navigation.")
      NSLog("🤚 [WithHand] Phase 2 → Phase 1 (dist=%.2fm > %.2fm)", dist, handGuidanceExitThreshold)
      // Hide hand UI
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
        self?.progressRing.isHidden = true; self?.progressRing.strokeEnd = 0
      }
    }

    if !handGuidanceActive && dist < handGuidanceThreshold {
      // Enter Phase 2
      handGuidanceActive = true
      NSLog("🤚 [WithHand] Phase 1 → Phase 2 (dist=%.2fm < %.2fm)", dist, handGuidanceThreshold)
      if !handGuidanceAnnounced {
        handGuidanceAnnounced = true
        say("Close enough. Raise your hand to reach for \(objectName).")
        triggerHaptic(0.6)
      }
    }

    // ── Reproject bbox for visual overlay (both phases) ──────────────────
    reprojectBbox(frame: frame)

    // ── Dispatch to phase handler ────────────────────────────────────────
    if handGuidanceActive {
      processHandGuidancePhase(frame, anchorPos: anchorPos, camera: camera, camPos: camPos, dist: dist)
    } else {
      processNavigationPhaseWithHand(frame, anchorPos: anchorPos, camera: camera, camPos: camPos, dist: dist)
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Phase 1: Navigation (3D World-Space — mirrors hand-free)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Identical direction computation to hand-free:
  //   camRight =  columns.1 (portrait right)
  //   camUp    = -columns.0 (portrait up — negated)
  //   camFwd   = -columns.2 (depth axis)
  //
  // Same state-change sounds, proximity zones, speech patterns.
  // Hand dot HIDDEN. Bbox overlay visible for sighted debugging.

  private func processNavigationPhaseWithHand(
    _ frame: ARFrame,
    anchorPos: simd_float3, camera: ARCamera,
    camPos: simd_float3, dist: Float
  ) {
    let camFwd   = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    let camRight =  simd_normalize(simd_make_float3(camera.transform.columns.1))
    let camUp    = -simd_normalize(simd_make_float3(camera.transform.columns.0))

    let toObj = anchorPos - camPos
    let toObjNorm = simd_normalize(toObj)

    let rightDot = simd_dot(toObjNorm, camRight)
    let upDot    = simd_dot(toObjNorm, camUp)
    let fwdDot   = simd_dot(toObjNorm, camFwd)
    lastRightDot = rightDot

    // Track horizontal for beep panning and "out of view" memory
    if abs(rightDot) > 0.15 {
      lastKnownHorizontalSign = rightDot > 0 ? 1.0 : -1.0
      lastKnownDirectionLabel = rightDot > 0 ? "to your right" : "to your left"
    }

    // ── Object behind camera ─────────────────────────────────────────────
    if fwdDot < 0 {
      objectOffScreen = true
      proximityZone = .far

      if isCenteredState { isCenteredState = false; playUncenteredSound() }

      let now = ProcessInfo.processInfo.systemUptime
      let behindCentered = abs(rightDot) < 0.30

      if now - lastSpeechTime > 3.0 {
        if behindCentered {
          say("Turn around. Object is behind you.")
        } else {
          let turnDir = rightDot > 0 ? "right" : "left"
          if lastKnownDirectionLabel.isEmpty {
            say("Object is behind you. Turn \(turnDir).")
          } else {
            say("Out of view, was \(lastKnownDirectionLabel). Turn \(turnDir).")
          }
        }
        lastSpeechTime = now
        lastSpokenDirection = .searching
      }

      let uiText = behindCentered ? "Turn around" : (rightDot > 0 ? "Turn right" : "Turn left")
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.directionLabel.text = uiText
        self.directionLabel.textColor = .systemOrange
        self.depthHintLabel.isHidden = true
        self.bboxLayer.isHidden = true; self.innerBboxLayer.isHidden = true
        self.handDot.isHidden = true; self.handDotGlow.isHidden = true
        self.distanceLabel.text = "\(Int(dist * 100)) cm"
      }
      return
    }

    // ── Object in front of camera ────────────────────────────────────────
    let horizThreshold: Float = 0.20
    let vertThreshold: Float  = 0.50

    let direction: Direction
    if abs(rightDot) < horizThreshold && abs(upDot) < 0.40 {
      direction = .centered
      objectOffScreen = false
    } else if upDot > vertThreshold {
      direction = .top; objectOffScreen = true
    } else if upDot < -vertThreshold {
      direction = .down; objectOffScreen = true
    } else if abs(rightDot) >= horizThreshold {
      direction = rightDot > 0 ? .right : .left
      objectOffScreen = abs(rightDot) > 0.55
    } else {
      direction = .centered; objectOffScreen = false
    }

    // ── State-change sounds ──────────────────────────────────────────────
    if direction == .centered && !isCenteredState {
      isCenteredState = true; playCenteredSound()
    } else if direction != .centered && isCenteredState {
      isCenteredState = false; playUncenteredSound()
    }

    // ── Proximity zone ───────────────────────────────────────────────────
    let newProx: ProximityZone
    if objectOffScreen       { newProx = .far }
    else if dist < 0.15      { newProx = .centered }
    else if dist < 0.30      { newProx = .veryClose }
    else if dist < 0.70      { newProx = .close }
    else if dist < 1.50      { newProx = .medium }
    else                      { newProx = .far }
    proximityZone = newProx

    // ── Speech (same patterns as hand-free) ──────────────────────────────
    speakNavigationWithHand(direction, dist: dist)

    // ── UI update ────────────────────────────────────────────────────────
    let cm = Int(dist * 100)
    let depthSource = hasLiDAR ? "LiDAR" : "Qwen+ARKit"
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateDirectionUI(direction)
      self.distanceLabel.text = "\(cm) cm"
      self.depthMethodLabel.text = "\(depthSource) \(cm)cm"
      self.handDot.isHidden = true; self.handDotGlow.isHidden = true
      self.progressRing.isHidden = true

      if direction == .centered && dist < 0.70 {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = self.distanceDescription(dist)
      } else {
        self.depthHintLabel.isHidden = true
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Phase 1 Speech (mirrors hand-free patterns)
  // ═══════════════════════════════════════════════════════════════════════════

  private func speakNavigationWithHand(_ direction: Direction, dist: Float) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if direction == currentDirection { directionStableFrames += 1 } else { directionStableFrames = 0 }

    let steps = Int(round(dist / 0.75))

    // ── Very close (<50cm) — about to transition to Phase 2 ─────────────
    if direction == .centered && dist < 0.50 {
      // Phase 2 will handle speech from here
      return
    }

    // ── Aligned, walking toward ─────────────────────────────────────────
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

    // ── Extreme vertical tilt ───────────────────────────────────────────
    if direction == .top || direction == .down {
      if direction != lastSpokenDirection && (now - lastSpeechTime) >= speechCooldown {
        say(direction == .top ? "Tilt phone up." : "Tilt phone down.")
        lastSpokenDirection = direction; lastSpeechTime = now
      }
      return
    }

    // ── Not aligned — contextual direction ──────────────────────────────
    if direction == lastSpokenDirection { return }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      let dirLabel = direction == .right ? "to your right" : "to your left"
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

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Phase 2: Hand Guidance (Vision Hand Tracking + 2D)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // User is within ~50cm. Vision framework tracks their hand.
  // 2D screen-space directions guide hand to projected bbox.
  // Acquisition validation polls backend when hand overlaps bbox.

  private func processHandGuidancePhase(
    _ frame: ARFrame,
    anchorPos: simd_float3, camera: ARCamera,
    camPos: simd_float3, dist: Float
  ) {
    let pb = frame.capturedImage
    computeAspectFillCrop(imageW: CGFloat(CVPixelBufferGetWidth(pb)),
                          imageH: CGFloat(CVPixelBufferGetHeight(pb)))

    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
    do { try handler.perform([handReq]) } catch { return }

    guard projectedBboxW > 0 else { return }

    let bboxCx    = projectedBboxCenter.x
    let bboxCy    = projectedBboxCenter.y
    let handTol   = handAlignmentHalfExtents()
    let bboxHalfW = handTol.w
    let bboxHalfH = handTol.h

    // ── No hand detected ────────────────────────────────────────────────
    guard let obs = handReq.results?.first else {
      noHandFrames += 1; successFrames = 0; depthConfirmedFrames = 0
      handIsCloseEnoughInDepth = false
      proximityZone = .close  // still close to object, just no hand visible

      if noHandFrames == noHandLimit {
        say("Show your hand to the camera.")
      } else if noHandFrames > 0 && noHandFrames % noHandRepeatCycle == 0 {
        say("I can't see your hand. Hold it up in front of the camera.")
      }

      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
        self?.progressRing.isHidden = true
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

    // ── Update hand dot ─────────────────────────────────────────────────
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

    // ── Overlap checks ──────────────────────────────────────────────────
    let innerTolW = bboxHalfW * 1.3, innerTolH = bboxHalfH * 1.3
    let innerOverlap = abs(dx) < innerTolW && abs(dy) < innerTolH
    let tolX = max(bboxHalfW * 0.5, 30), tolY = max(bboxHalfH * 0.5, 30)
    let nearOverlap = CGRect(
      x: bboxCx - bboxHalfW - tolX, y: bboxCy - bboxHalfH - tolY,
      width: bboxHalfW*2 + tolX*2, height: bboxHalfH*2 + tolY*2
    ).contains(CGPoint(x: screenX, y: screenY))

    // ── Depth check (informational — acquisition is backend-validated) ──
    let (depthResult, depthMethodStr) =
      checkHandDepth(frame: frame, handScreenPt: handScreen, handObs: obs)
    let depthOk = depthResult == .close
    handIsCloseEnoughInDepth = depthOk

    // ── Proximity zone ──────────────────────────────────────────────────
    let normDist = sqrt(dx*dx+dy*dy) / max(cachedSW, cachedSH)
    let newProx: ProximityZone
    if innerOverlap && depthOk { newProx = .centered }
    else if innerOverlap       { newProx = .veryClose }
    else if nearOverlap        { newProx = .close }
    else if normDist < 0.15    { newProx = .close }
    else if normDist < 0.30    { newProx = .medium }
    else                       { newProx = .far }
    proximityZone = newProx

    // ── Direction computation (2D screen-space) ─────────────────────────
    let direction = computeDirection(handX: screenX, handY: screenY,
                                     bboxCx: bboxCx, bboxCy: bboxCy,
                                     bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH)

    // ── Speech — suppressed during active acquisition polling ────────────
    if acquisitionTriggered && !acquisitionTimedOut {
      // Acquisition zone — suppress normal guidance speech.
      // pollAcquisitionEndpoint handles speech. Beeps provide feedback.
    } else {
      speakHandGuidanceDirection(direction)
    }

    // ── UI update ───────────────────────────────────────────────────────
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateDirectionUI(direction)
      self.depthMethodLabel.text = depthMethodStr

      if self.acquisitionTriggered && !self.acquisitionTimedOut {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "Reaching for \(self.objectName)…"
      } else if innerOverlap {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "Hand aligned — reach forward. Tap when done."
      } else {
        self.depthHintLabel.isHidden = true
      }

      self.distanceLabel.text = "\(Int(dist * 100)) cm"

      if innerOverlap {
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

    // ── Success frame tracking (visual only) ────────────────────────────
    if innerOverlap {
      successFrames = min(successFrames + 1, successThreshold)
    } else {
      successFrames = max(0, successFrames - 2)
    }

    if depthOk {
      depthConfirmedFrames = min(depthConfirmedFrames + 1, 15)
    } else if depthResult == .far {
      depthConfirmedFrames = max(0, depthConfirmedFrames - 3)
    }

    // ── Acquisition validation (auto-exit) ──────────────────────────────
    checkAcquisitionTriggerWithHand(innerOverlap: innerOverlap, dist: dist)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Phase 2 Alignment Tolerance
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // The drawn box is not always the object. A backend bbox outlines the thing
  // itself, so the hand belongs anywhere inside it and the drawn box is the
  // right tolerance. A spatial (map POI) target draws a SIZE PRIOR instead —
  // 80×110cm for a door, 60×70cm for a legacy camera-pose pin — and taking
  // that at face value calls the hand "aligned" the moment it enters frame,
  // which collapses with-hand back into hand-free.
  //
  // Tolerance per axis: never demand better than a palm (the pin itself is
  // only good to a few cm), never accept more than half the box. Small map
  // targets — a handle at 10cm — keep their box untouched. The overlay still
  // draws the full target box; only the alignment test tightens.

  private func handAlignmentHalfExtents() -> (w: CGFloat, h: CGFloat) {
    let drawn = (w: projectedBboxW / 2, h: projectedBboxH / 2)
    guard spatialTargetWorldPosition != nil else { return drawn }

    let palm: Float = 0.12   // metres
    func shrink(_ halfExtent: Float) -> CGFloat {
      let cap = max(palm, halfExtent * 0.5)
      return halfExtent > cap ? CGFloat(cap / halfExtent) : 1
    }
    // Floor at 20pt: a tolerance smaller than the hand dot itself is
    // unreachable and would leave the user hunting a pixel.
    return (max(drawn.w * shrink(objectWorldHalfW), 20),
            max(drawn.h * shrink(objectWorldHalfH), 20))
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Phase 2 Speech (Hand Guidance Directions)
  // ═══════════════════════════════════════════════════════════════════════════

  func speakHandGuidanceDirection(_ direction: Direction) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime

    // Aligned — tell user to reach forward
    if direction == .centered {
      if direction != lastSpokenDirection {
        say("Hand aligned. Reach forward to grab \(objectName).")
        lastSpokenDirection = direction; lastSpeechTime = now
      } else if (now - lastSpeechTime) > 3.5 {
        say("Reach forward. Tap anywhere when you have it.")
        lastSpeechTime = now
      }
      return
    }

    // Not aligned — speak direction with tighter cooldown for hand guidance
    if direction == lastSpokenDirection { return }
    let handSpeechCooldown: TimeInterval = 1.0  // tighter than Phase 1 — hand moves faster
    if directionStableFrames >= 3 && (now - lastSpeechTime) >= handSpeechCooldown {
      // Use the direction raw value ("left", "right", "up", "down", etc.)
      say("Move hand \(direction.rawValue)")
      lastSpokenDirection = direction; lastSpeechTime = now
      if direction != .centered && direction != .searching { triggerHaptic(0.3) }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Phase 2 Acquisition Validation (Auto-Exit)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Triggers acquisition polling when:
  //   1. Hand overlaps bbox (innerOverlap = true)
  //   2. Distance < acquisitionDepthThreshold (0.40m)
  // Calls the SHARED pollAcquisitionEndpoint() from +handFree.swift.

  private func checkAcquisitionTriggerWithHand(innerOverlap: Bool, dist: Float) {
    guard !hasCompleted, !acquisitionTimedOut else { return }
    guard acquisitionUrl != nil else { return }

    // Need BOTH hand alignment and proximity to trigger
    if !innerOverlap || dist >= acquisitionDepthThreshold {
      // Not ready — check if user lost alignment after triggering
      if acquisitionTriggered && !innerOverlap && dist > acquisitionDepthThreshold * 1.2 {
        acquisitionTriggered = false
        acquisitionPollStart = 0
        acquisitionCheckCount = 0
        isPollingAcquisition = false
        NSLog("🔍 [Acquisition-WithHand] Hand moved away — resetting")
      }
      return
    }

    let now = ProcessInfo.processInfo.systemUptime

    // ── First time entering acquisition zone ─────────────────────────────
    if !acquisitionTriggered {
      acquisitionTriggered = true
      acquisitionPollStart = now
      say("Almost there. Grab \(objectName).")
      triggerHaptic(0.6)
      NSLog("🔍 [Acquisition-WithHand] ── ENTERED zone (hand aligned, %.2fm < %.2fm) ── polling starts",
            dist, acquisitionDepthThreshold)
    }

    // ── Check timeout ────────────────────────────────────────────────────
    if now - acquisitionPollStart > acquisitionTimeout {
      acquisitionTimedOut = true
      say("Tap anywhere when you have \(objectName).")
      NSLog("🔍 [Acquisition-WithHand] ⏱ TIMEOUT after %.0fs — manual exit only", acquisitionTimeout)
      return
    }

    // ── Rate limit polls ─────────────────────────────────────────────────
    guard now - lastAcquisitionPollTime >= acquisitionPollInterval else { return }
    guard !isPollingAcquisition else { return }

    // Reuse the shared acquisition polling from +handFree.swift
    pollAcquisitionEndpoint()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Direction Computation (2D screen-space — Phase 2 only)
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
  // MARK: - With-Hand Depth Check (informational — Phase 2 only)
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

      // ── Small-span proximity bypass ────────────────────────
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
