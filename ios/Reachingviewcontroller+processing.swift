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
  // MARK: - Process AR Frame (main loop)
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

    // ── Overlap checks ────────────────────────────────────────────────────
    let innerOverlap = abs(dx) < bboxHalfW && abs(dy) < bboxHalfH
    let tolX = max(bboxHalfW * 0.3, 20), tolY = max(bboxHalfH * 0.3, 20)
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

      self.depthHintLabel.isHidden = !(innerOverlap && !cameraIsClose)
      if innerOverlap && !cameraIsClose {
        let remaining = max(0, Int((self.liveDistanceToObject - self.reachProximityThreshold) * 100))
        if remaining <= 5 {
          self.depthHintLabel.text = "Grab it now!"
          self.distanceLabel.text = "Within reach"
        } else {
          self.depthHintLabel.text = "Move \(remaining)cm closer"
          self.distanceLabel.text = "\(remaining)cm to go"
        }
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
    // MARK: Success Gate — Two-Tier + 3-State Depth (v8.2)
    // ═══════════════════════════════════════════════════════════════════════
    //
    // TIER 1 (dist < 0.30m): innerOverlap only. Physics guarantee.
    // TIER 2 (dist 0.30–0.70m): innerOverlap + depthGateOk.
    // TIER 3 (dist >= 0.70m): Walk closer.
    //
    // 3-STATE DEPTH (fixes "stuck with bottle in hand"):
    //   .close → increment progress + confirmed counter
    //   .far   → RESET progress (hand confirmed away from object)
    //   .noData → FREEZE progress (don't increment, don't reset)
    //   This prevents "No depth method succeeded" frames from flushing
    //   legitimate progress accumulated from real depth confirmations.

    if depthOk {
      depthConfirmedFrames = min(depthConfirmedFrames + 1, 15)
    } else if depthFar {
      depthConfirmedFrames = max(0, depthConfirmedFrames - 3)
    }
    // .noData: don't touch depthConfirmedFrames — preserve recent evidence

    let depthGateOk: Bool
    if depthOk {
      depthGateOk = true
    } else if depthConfirmedFrames >= 8 {
      depthGateOk = true
    } else {
      depthGateOk = false
    }

    // Two-tier decision
    let tier1 = liveDistanceToObject < 0.30  // physics guarantee (was 0.40)
    let tier2 = cameraIsClose && depthGateOk // depth-confirmed zone

    let gateOpen = innerOverlap && (tier1 || tier2)

    if gateOpen {
      successFrames += 1
      if arFrameCount % 10 == 0 {
        NSLog("✅ [Gate] progress=%d/%d tier=%@ depth=%@ confirmed=%d dist=%.2fm",
              successFrames, successThreshold,
              tier1 ? "T1-physics" : "T2-depth",
              depthOk ? "YES" : "no", depthConfirmedFrames, liveDistanceToObject)
      }
      if successFrames >= successThreshold {
        handleSuccess()
      }
    } else if depthFar || !innerOverlap {
      // Only RESET when depth actively says NO or hand left the bbox.
      // "No data" frames preserve progress — don't punish sensor gaps.
      if successFrames > 0 && arFrameCount % 30 == 0 {
        NSLog("❌ [Gate] RESET — overlap=%@ dist=%.2f depthFar=%@ (confirmed=%d)",
              innerOverlap ? "Y" : "N", liveDistanceToObject,
              depthFar ? "Y" : "N", depthConfirmedFrames)
      }
      successFrames = 0
    }
    // else: noData + innerOverlap → freeze (don't increment, don't reset)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Direction Computation
  // ═══════════════════════════════════════════════════════════════════════════

  func computeDirection(handX: CGFloat, handY: CGFloat,
                        bboxCx: CGFloat, bboxCy: CGFloat,
                        bboxHalfW: CGFloat, bboxHalfH: CGFloat) -> Direction {
    let dx = handX - bboxCx, dy = handY - bboxCy
    if abs(dx) < bboxHalfW && abs(dy) < bboxHalfH { return .centered }
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
}
