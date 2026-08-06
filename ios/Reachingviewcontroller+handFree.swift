//
//  Reachingviewcontroller+handFree.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-28.
//
//  HAND-FREE MODE — All hand-free specific logic lives here.
//  Direction via 3D world-space dot products, contextual speech,
//  LiDAR/ARKit depth, and acquisition-validated auto-exit.
//
//  This file is INDEPENDENT of +withHand.swift. Debugging hand-free
//  mode = open this file. No cross-contamination.

import ARKit
import SceneKit
import UIKit

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Hand-Free Frame Processing (3D world-space directions)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Direction = dot product of (camera → anchor) against camera's PORTRAIT axes.
  //
  // ⚠️  ARKit camera.transform columns are LANDSCAPE-NATIVE:
  //   columns.0 (landscape right) → portrait DOWN
  //   columns.1 (landscape up)    → portrait RIGHT
  // We swap & negate for correct portrait orientation:
  //   camRight =  columns.1          (portrait right)
  //   camUp    = -columns.0          (portrait up)
  //   camFwd   = -columns.2          (unchanged — depth axis)
  //
  // Directions: left / right / straight ahead / tilt up / tilt down / behind.
  // "Tilt phone down" = user pointing at ceiling (object below view).
  // "Tilt phone up"   = user pointing at floor  (object above view).
  // "Turn around"     = object directly behind user.
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
    // Portrait axis correction: ARKit native axes are landscape-rotated.
    //   columns.0 (landscape right) = portrait DOWN
    //   columns.1 (landscape up)    = portrait RIGHT
    let camRight =  simd_normalize(simd_make_float3(camera.transform.columns.1))  // portrait right
    let camUp    = -simd_normalize(simd_make_float3(camera.transform.columns.0))  // portrait up (negate)

    let toObj = anchorPos - camPos
    let dist = simd_length(toObj)
    liveDistanceToObject = dist
    let toObjNorm = simd_normalize(toObj)

    let rightDot = simd_dot(toObjNorm, camRight)   // + = right, - = left
    let upDot    = simd_dot(toObjNorm, camUp)       // + = up, - = down
    let fwdDot   = simd_dot(toObjNorm, camFwd)      // + = in front, - = behind
    lastRightDot = rightDot

    // Track last known horizontal for beep panning and "out of view" memory
    // Threshold 0.15: ignore minor sway so "behind you" can fire cleanly
    if abs(rightDot) > 0.15 {
      lastKnownHorizontalSign = rightDot > 0 ? 1.0 : -1.0
      lastKnownDirectionLabel = ReachLoc.lastSeenSide(toRight: rightDot > 0)
    }

    // ── Object behind camera ─────────────────────────────────────────────
    if fwdDot < 0 {
      objectOffScreen = true
      proximityZone = .far

      let now = ProcessInfo.processInfo.systemUptime

      // State-change: was centered → now lost
      if isCenteredState {
        isCenteredState = false
        playUncenteredSound()
      }

      // Determine if object is directly behind or off to one side
      let behindCentered = abs(rightDot) < 0.30  // roughly centered behind

      if now - lastSpeechTime > 3.0 {
        if behindCentered {
          // Object directly behind — don't confuse with left/right, just turn around
          say(ReachLoc.objectBehindTurnAround())
        } else {
          let toRight = rightDot > 0
          if lastKnownDirectionLabel.isEmpty {
            say(ReachLoc.objectBehindTurn(toRight: toRight))
          } else {
            say(ReachLoc.outOfViewTurn(lastSeen: lastKnownDirectionLabel, toRight: toRight))
          }
        }
        lastSpeechTime = now
        lastSpokenDirection = .searching
      }

      let uiText = behindCentered ? "Turn around" : (rightDot > 0 ? "Turn right" : "Turn left")
      let uiMethod = behindCentered ? "behind → turn around" : "behind → \(rightDot > 0 ? "right" : "left")"
      DispatchQueue.main.async { [weak self] in
        guard let self = self else { return }
        self.directionLabel.text = uiText
        self.directionLabel.textColor = .systemOrange
        self.depthHintLabel.isHidden = true
        self.bboxLayer.isHidden = true; self.innerBboxLayer.isHidden = true
        self.distanceLabel.text = "\(Int(dist * 100)) cm"
        self.depthMethodLabel.text = uiMethod
      }
      return
    }

    // ── Object in front of camera ────────────────────────────────────────
    let horizThreshold: Float = 0.20
    let vertThreshold: Float  = 0.50   // extreme tilt — user pointing at ceiling/floor

    let direction: Direction
    if abs(rightDot) < horizThreshold && abs(upDot) < 0.40 {
      // Horizontally & vertically aligned — on target
      direction = .centered
      objectOffScreen = false
    } else if upDot > vertThreshold {
      // Object above camera view → user pointing at floor → "Tilt phone up"
      direction = .top
      objectOffScreen = true
    } else if upDot < -vertThreshold {
      // Object below camera view → user pointing at ceiling → "Tilt phone down"
      direction = .down
      objectOffScreen = true
    } else if abs(rightDot) >= horizThreshold {
      direction = rightDot > 0 ? .right : .left
      objectOffScreen = abs(rightDot) > 0.55
    } else {
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

    // ── Speech — suppressed during active acquisition polling ────────────
    // Exception: tilt guidance always speaks (safety-critical orientation)
    if acquisitionTriggered && !acquisitionTimedOut && direction != .top && direction != .down {
      // Acquisition zone — suppress normal guidance speech.
      // Acquisition callbacks handle speech. Parking sensor + state-change
      // sounds continue to give non-verbal proximity/alignment feedback.
    } else {
      speakDirectionHandFree(direction)
    }

    // Reproject bbox for visual overlay only
    reprojectBbox(frame: frame)

    // ── UI update ────────────────────────────────────────────────────────
    let cm = Int(dist * 100)
    let depthSource = hasLiDAR ? "LiDAR" : "ARKit"
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.updateDirectionUI(direction)
      self.distanceLabel.text = "\(cm) cm"
      self.depthMethodLabel.text = "\(depthSource) \(cm)cm"

      if self.acquisitionTriggered && !self.acquisitionTimedOut {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "Reaching for \(self.objectName)…"
      } else if direction == .centered && dist < 0.30 {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "\(self.objectName) here — reach forward"
      } else if direction == .centered {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = self.distanceDescription(dist)
      } else {
        self.depthHintLabel.isHidden = true
      }
    }

    // ── Acquisition validation (auto-exit) ───────────────────────────────
    checkAcquisitionTrigger()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Hand-Free Speech Feedback
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Distance spoken as STEPS (75cm each) or CM based on distanceUnit setting.
  // Progressive confidence: first time aligned → "About N steps ahead"
  //   As user approaches: "N steps, going the right way" (first 2 times only)
  //   Close: "One step away" → "Arm's reach" → "{object} here. Reach forward."
  //
  // Screen still shows cm for debugging.

  /// Convert distance to human-friendly description based on distanceUnit setting
  func distanceDescription(_ dist: Float) -> String {
    if distanceUnit == "cm" {
      let cm = Int(dist * 100)
      if cm < 30 { return ReachLoc.armsReachDistance() }
      return ReachLoc.centimeters(cm)
    } else {
      let steps = Int(round(dist / 0.75))  // 75cm per step
      if steps <= 0 { return ReachLoc.armsReachDistance() }
      if steps == 1 { return ReachLoc.oneStepAway() }
      return ReachLoc.aboutStepsAway(steps)
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
          hint = ReachLoc.slightlySideHint(toRight: lastRightDot > 0)
        }
        say(ReachLoc.objectHereReachForward(object: objectName, hint: hint))
        lastSpokenDirection = direction; lastSpeechTime = now
      }
      return
    }

    // ── Case 2: Very close (<50cm) — "arm's reach" ─────────────────────
    // Threshold 50cm (not 75cm): non-LiDAR estimated-plane depth can
    // undershoot by ~15-25cm, so keep tight to avoid false "arm's reach"
    // announcements at 80-100cm actual distance.
    if direction == .centered && dist < 0.50 {
      if direction != lastSpokenDirection {
        say(ReachLoc.armsReachKeepGoing())
        lastSpokenDirection = direction; lastSpeechTime = now
      } else if now - lastSpeechTime > 4.0 {
        say(ReachLoc.almostThere())
        lastSpeechTime = now
      }
      return
    }

    // ── Case 3: Aligned, walking toward ─────────────────────────────────
    if direction == .centered {
      if direction != lastSpokenDirection {
        say(ReachLoc.straightAheadDistance(distanceDescription(dist)))
        lastSpokenDirection = direction; lastSpeechTime = now
        lastAnnouncedSteps = steps
      } else if now - lastSpeechTime > 4.0 {
        if steps < lastAnnouncedSteps && progressConfirmations < 2 {
          say(ReachLoc.goingTheRightWay(distanceDescription(dist)))
          progressConfirmations += 1
        } else if steps > lastAnnouncedSteps + 1 && progressConfirmations > 0 {
          say(ReachLoc.gettingFurther(distanceDescription(dist)))
          progressConfirmations = 0
        } else {
          say(ReachLoc.distanceOnly(distanceDescription(dist)))
        }
        lastAnnouncedSteps = steps
        lastSpeechTime = now
      }
      return
    }

    // ── Case 4: Extreme vertical tilt — phone pointed at ceiling or floor ─
    if direction == .top || direction == .down {
      if direction != lastSpokenDirection && (now - lastSpeechTime) >= speechCooldown {
        if direction == .top {
          // Object is above camera → user pointing at floor → tilt up
          say(ReachLoc.tiltPhoneUp())
        } else {
          // Object is below camera → user pointing at ceiling → tilt down
          say(ReachLoc.tiltPhoneDown())
        }
        lastSpokenDirection = direction; lastSpeechTime = now
      }
      return
    }

    // ── Case 5: Not aligned — contextual direction ──────────────────────
    if direction == lastSpokenDirection { return }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      let dirLabel = ReachLoc.lastSeenSide(toRight: direction == .right)

      if lastSpokenDirection == .centered && progressConfirmations > 0 {
        say(ReachLoc.offTrackObjectIs(dirLabel))
      } else {
        say(ReachLoc.objectIs(dirLabel))
      }
      lastSpokenDirection = direction; lastSpeechTime = now
      progressConfirmations = 0
      triggerHaptic(0.4)
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Acquisition Validation (Auto-Exit)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // When camera-to-anchor distance drops below acquisitionDepthThreshold (40cm):
  //   1. Capture AR frame → JPEG → POST to acquisitionUrl
  //   2. Backend VLM returns { "acquisition": true | false }
  //   3. true → handleSuccess() (auto-exit)
  //   4. false → poll again after acquisitionPollInterval (2s)
  //   5. Timeout after acquisitionTimeout (30s) → manual exit only
  //
  // No acquisitionUrl = no auto-exit (manual tap only — the fallback).

  func checkAcquisitionTrigger() {
    guard !hasCompleted, !acquisitionTimedOut else { return }
    guard acquisitionUrl != nil else { return }  // no URL = manual-only

    let dist = liveDistanceToObject

    // ── Not close enough → check if user backed away from active zone ────
    if dist >= acquisitionDepthThreshold {
      if acquisitionTriggered && dist > acquisitionDepthThreshold * 1.5 {
        // User backed away significantly — reset acquisition state
        acquisitionTriggered = false
        acquisitionPollStart = 0
        acquisitionCheckCount = 0
        isPollingAcquisition = false
        NSLog("🔍 [Acquisition] User backed away (%.2fm) — resetting", dist)
      }
      return
    }

    let now = ProcessInfo.processInfo.systemUptime

    // ── First time entering acquisition zone ─────────────────────────────
    if !acquisitionTriggered {
      acquisitionTriggered = true
      acquisitionPollStart = now
      say(ReachLoc.almostThereReachFor(objectName))
      triggerHaptic(0.6)
      NSLog("🔍 [Acquisition] ── ENTERED zone (%.2fm < %.2fm) ── polling starts",
            dist, acquisitionDepthThreshold)
    }

    // ── Check timeout ────────────────────────────────────────────────────
    if now - acquisitionPollStart > acquisitionTimeout {
      acquisitionTimedOut = true
      say(ReachLoc.tapWhenYouHave(objectName))
      NSLog("🔍 [Acquisition] ⏱ TIMEOUT after %.0fs — manual exit only", acquisitionTimeout)
      return
    }

    // ── Rate limit polls ─────────────────────────────────────────────────
    guard now - lastAcquisitionPollTime >= acquisitionPollInterval else { return }
    guard !isPollingAcquisition else { return }

    pollAcquisitionEndpoint()
  }

  func pollAcquisitionEndpoint() {
    guard let urlStr = acquisitionUrl, let url = URL(string: urlStr) else { return }
    guard let frame = lastARFrame else {
      NSLog("🔍 [Acquisition] No AR frame available")
      return
    }

    isPollingAcquisition = true
    lastAcquisitionPollTime = ProcessInfo.processInfo.systemUptime
    acquisitionCheckCount += 1

    // ── Capture AR frame → JPEG ──────────────────────────────────────────
    // NOTE: Using frame.capturedImage directly — do NOT capture `frame` in
    // the network closure (ARFrame retention). We extract the image data
    // synchronously here, then fire the async request.
    let pixelBuffer = frame.capturedImage
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let context = CIContext()
    guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
      NSLog("🔍 [Acquisition] Failed to create CGImage")
      isPollingAcquisition = false
      return
    }

    // AR camera is landscape — rotate to portrait for backend
    let fullImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: .right)

    // Resize to ~512px max for fast transfer (acquisition doesn't need high res)
    let maxDim: CGFloat = 512
    let scale = min(maxDim / fullImage.size.width, maxDim / fullImage.size.height, 1.0)
    let newSize = CGSize(width: fullImage.size.width * scale, height: fullImage.size.height * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
    fullImage.draw(in: CGRect(origin: .zero, size: newSize))
    let resized = UIGraphicsGetImageFromCurrentImageContext() ?? fullImage
    UIGraphicsEndImageContext()

    guard let jpegData = resized.jpegData(compressionQuality: 0.6) else {
      NSLog("🔍 [Acquisition] Failed to encode JPEG")
      isPollingAcquisition = false
      return
    }

    let checkNum = acquisitionCheckCount
    let requestId = "mobile-\(Int(Date().timeIntervalSince1970 * 1000))"
    let imageWidth = String(Int(newSize.width))
    let imageHeight = String(Int(newSize.height))

    NSLog("🔍 [Acquisition] Poll #%d — %.0fKB → %@",
          checkNum, Double(jpegData.count) / 1024.0, urlStr)

    // ── Build request ────────────────────────────────────────────────────
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 10  // Acquisition model should be fast

    // Match working workflow call format: multipart/form-data with string fields
    // and binary JPEG image part named "image".
    let boundary = "Boundary-\(UUID().uuidString)"
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

    var bodyData = Data()

    func appendField(_ name: String, _ value: String) {
      bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
      bodyData.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
      bodyData.append("\(value)\r\n".data(using: .utf8)!)
    }

    func appendFile(_ name: String, filename: String, mimeType: String, data: Data) {
      bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
      bodyData.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
      bodyData.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
      bodyData.append(data)
      bodyData.append("\r\n".data(using: .utf8)!)
    }

    // Keep field names aligned with sendToWorkflow FormData payload.
    appendField("transcript", "acquisition_check")
    appendField("navigation", "false")
    // iOS reaching mode: keep the standard reaching flag off for acquisition polls.
    // Backend should route via reaching_ios=true for this path.
    appendField("reaching_flag", "false")
    appendField("user_id", "mobile-user")
    appendField("request_id", requestId)
    appendField("session_id", sessionId)
    appendField("sessionId", sessionId)  // compatibility alias for camelCase readers
    appendField("continuousMode", "true")
    appendField("imageWidth", imageWidth)
    appendField("imageHeight", imageHeight)
    appendCameraIntrinsicsFields(appendField, frame: frame, outputImageSize: newSize)
    appendField("object", objectName)
    appendField("mode", mode.rawValue)
    appendField("reaching_ios", "true")
    appendFile("image", filename: "photo.jpg", mimeType: "image/jpeg", data: jpegData)
    bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

    request.httpBody = bodyData

    // ── Fire async — no ARFrame captured in closure ──────────────────────
    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      defer { self?.isPollingAcquisition = false }
      guard let self = self, self.running, !self.hasCompleted else { return }

      if let error = error {
        NSLog("🔍 [Acquisition] Request failed: %@", error.localizedDescription)
        return
      }

      let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

      guard let data = data,
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        let raw = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? "(no data)"
        NSLog("🔍 [Acquisition] Parse failed (HTTP %d): %@", httpStatus, raw)
        return
      }

      func coerceBool(_ value: Any?) -> Bool? {
        switch value {
        case let b as Bool:
          return b
        case let n as NSNumber:
          return n.intValue != 0
        case let s as String:
          let normalized = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          if ["true", "1", "yes", "y"].contains(normalized) { return true }
          if ["false", "0", "no", "n", "null", "nil", ""].contains(normalized) { return false }
          return nil
        default:
          return nil
        }
      }

      let output = json["output"] as? [String: Any]
      let acquisition =
        coerceBool(json["acquisition"]) ??
        coerceBool(output?["acquisition"]) ??
        coerceBool(json["reaching_completed"]) ??
        coerceBool(output?["reaching_completed"]) ??
        coerceBool(json["reached"]) ??
        coerceBool(output?["reached"]) ??
        false

      NSLog("🔍 [Acquisition] #%d → acquisition=%@ (HTTP %d, dist=%.2fm)",
            checkNum, acquisition ? "TRUE ✅" : "false ❌", httpStatus,
            self.liveDistanceToObject)

      if !acquisition {
        let rawAcq = String(describing: json["acquisition"] ?? output?["acquisition"] ?? "nil")
        let rawReached = String(describing: json["reaching_completed"] ?? output?["reaching_completed"] ?? "nil")
        NSLog("🔍 [Acquisition] Raw flags — acquisition=%@ reaching_completed=%@ keys=%@",
          rawAcq, rawReached, json.keys.joined(separator: ","))
      }

      if acquisition {
        // ── SUCCESS — object acquired ───────────────────────────────────
        DispatchQueue.main.async {
          self.handleSuccess()
        }
      } else if checkNum == 1 {
        // ── First failed check — encourage user (once only) ─────────────
        self.say(ReachLoc.keepReachingRightInFront(self.objectName))
      }
      // Subsequent failures: silent. Parking sensor tone provides feedback.
    }.resume()
  }
}
