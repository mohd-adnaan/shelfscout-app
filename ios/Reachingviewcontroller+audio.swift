//
//  Reachingviewcontroller+audio.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//
//  Audio Engine, Speech, Haptics

import AVFoundation
import CoreHaptics

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Audio Setup
  // ═══════════════════════════════════════════════════════════════════════════

  func setupAudio() {
    do {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try s.setActive(true)
      let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
      engine.attach(player)

      // ── Load beep buffer ─────────────────────────────────────────────
      // Try Nicolas's bip.wav first; fall back to synthesized beep
      var loadedBuf: AVAudioPCMBuffer?
      var loadedFmt: AVAudioFormat?
      if let bipURL = Bundle.main.url(forResource: "bip", withExtension: "wav") {
        do {
          let bipFile = try AVAudioFile(forReading: bipURL)
          loadedFmt = bipFile.processingFormat
          let frameCount = UInt32(bipFile.length)
          if let buf = AVAudioPCMBuffer(pcmFormat: bipFile.processingFormat, frameCapacity: frameCount) {
            try bipFile.read(into: buf)
            loadedBuf = buf
            NSLog("🔊 [Audio] Loaded bip.wav (%d frames, %.0fHz)", frameCount, bipFile.processingFormat.sampleRate)
          }
        } catch {
          NSLog("⚠️ [Audio] Failed to load bip.wav: %@", error.localizedDescription)
        }
      }

      // Fallback: synthesized 60ms 1000Hz beep
      if loadedBuf == nil {
        let sr: Double = 44100; let dur: Double = 0.06; let freq: Double = 1000
        let fc = AVAudioFrameCount(sr * dur)
        loadedFmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)
        if let fmt = loadedFmt, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) {
          buf.frameLength = fc; let d = buf.floatChannelData![0]
          for i in 0..<Int(fc) {
            let t = Double(i)/sr
            let env = min(t/0.005, 1) * min((dur-t)/0.005, 1)
            d[i] = Float(sin(2 * .pi * freq * t) * 0.5 * env)
          }
          loadedBuf = buf
          NSLog("🔊 [Audio] Using synthesized beep (bip.wav not in bundle)")
        }
      }

      guard let fmt = loadedFmt, let buf = loadedBuf else { return }
      audioFmt = fmt
      engine.connect(player, to: engine.mainMixerNode, format: fmt)
      beepBuf = buf; playerNode = player; audioEngine = engine
      try engine.start()

      // ── Load state-change sounds (Nicolas approach) ──────────────────
      if let url = Bundle.main.url(forResource: "centered_sound", withExtension: "wav") {
        centeredPlayer = try? AVAudioPlayer(contentsOf: url)
        centeredPlayer?.prepareToPlay()
        centeredPlayer?.volume = 0.6
        NSLog("🔊 [Audio] Loaded centered_sound.wav")
      }
      if let url = Bundle.main.url(forResource: "uncentered_sound", withExtension: "wav") {
        uncenteredPlayer = try? AVAudioPlayer(contentsOf: url)
        uncenteredPlayer?.prepareToPlay()
        uncenteredPlayer?.volume = 0.5
        NSLog("🔊 [Audio] Loaded uncentered_sound.wav")
      }
      if let url = Bundle.main.url(forResource: "targetLost", withExtension: "wav") {
        targetLostPlayer = try? AVAudioPlayer(contentsOf: url)
        targetLostPlayer?.prepareToPlay()
        targetLostPlayer?.volume = 0.4
        NSLog("🔊 [Audio] Loaded targetLost.wav")
      }

    } catch { NSLog("⚠️ Audio: %@", error.localizedDescription) }
  }

  func setupHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    hapticEngine = try? CHHapticEngine()
    try? hapticEngine?.start()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - State-Change Sounds (Nicolas Approach)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // These play ONCE at the transition moment — not continuously.
  // centered_sound.wav → entering alignment (positive confirmation)
  // uncentered_sound.wav → leaving alignment (gentle alert)
  // targetLost.wav → object completely lost from view

  func playCenteredSound() {
    centeredPlayer?.currentTime = 0
    centeredPlayer?.play()
    NSLog("🔔 [Audio] centered_sound")
  }

  func playUncenteredSound() {
    uncenteredPlayer?.currentTime = 0
    uncenteredPlayer?.play()
    NSLog("🔔 [Audio] uncentered_sound")
  }

  func playTargetLostSound() {
    targetLostPlayer?.currentTime = 0
    targetLostPlayer?.play()
    NSLog("🔔 [Audio] targetLost")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Beep Loop
  // ═══════════════════════════════════════════════════════════════════════════

  func startBeepLoop() {
    let t = DispatchSource.makeTimerSource(queue: audioQ)
    t.schedule(deadline: .now(), repeating: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.tickBeep() }
    beepTimer = t; t.resume()
  }

  func tickBeep() {
    guard running, proximityZone != .searching else { return }

    // ── Phase-aware mode selection ────────────────────────────────────────
    // With-hand Phase 1 (navigation) uses hand-free style beeps.
    // With-hand Phase 2 (hand guidance) uses with-hand style beeps.
    let useNavigationBeeps = mode == .handFree || (mode == .withHand && !handGuidanceActive)

    // Parking sensor: gentle continuous tone when very close + aligned
    if useNavigationBeeps && !objectOffScreen
       && (proximityZone == .centered || proximityZone == .veryClose) {
      tickParkingSensor()
      return
    }

    let now = ProcessInfo.processInfo.systemUptime
    let iv: TimeInterval
    let vol: Float
    let pan: Float

    if useNavigationBeeps {
      // ── Navigation beeps (hand-free style — both modes Phase 1) ──────
      if objectOffScreen {
        // Object off-screen: slow sparse beeps, hard-panned toward object
        iv = 1.2
        vol = 0.15
        pan = Float(lastKnownHorizontalSign) * 0.9
      } else {
        // Object on-screen: normal progressive beeps
        switch proximityZone {
        case .searching: iv = 99; vol = 0; pan = 0
        case .far:       iv = 0.7; vol = 0.25; pan = 0
        case .medium:    iv = 0.35; vol = 0.35; pan = 0
        case .close:     iv = 0.15; vol = 0.45; pan = 0
        case .veryClose: iv = 0.06; vol = 0.5; pan = 0
        case .centered:  iv = 0.03; vol = 0.5; pan = 0
        }
      }
    } else {
      // ── Hand guidance beeps (with-hand Phase 2) ──────────────────────
      vol = 0.5
      switch proximityZone {
      case .searching: iv = 99
      case .far:       iv = 0.7
      case .medium:    iv = 0.4
      case .close:     iv = 0.2
      case .veryClose: iv = 0.08
      case .centered:  iv = 0.04
      }
      switch currentDirection {
      case .left, .topLeft, .downLeft:    pan = -0.8
      case .right, .topRight, .downRight: pan =  0.8
      default:                            pan =  0.0
      }
    }

    if now - lastBeep >= iv {
      if let p = playerNode, let b = beepBuf {
        p.pan = pan
        p.volume = vol
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        if !p.isPlaying { p.play() }
      }
      lastBeep = now
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Parking Sensor Tone (Hand-Free, Close + Aligned)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Gentle continuous tone — NOT alarm-like. Warm frequency range.
  //   30cm → 440Hz (A4 — warm, musical)
  //   15cm → 523Hz (C5 — brighter)
  //   <5cm → 587Hz (D5 — gentle high)
  // Volume stays moderate. This is "you're close" not "danger".

  func tickParkingSensor() {
    guard let player = playerNode, let fmt = audioFmt else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastBeep >= 0.18 else { return }

    let sr: Double = 44100
    let dur: Double = 0.22
    let fc = AVAudioFrameCount(sr * dur)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
    buf.frameLength = fc; let d = buf.floatChannelData![0]

    // Gentle frequency ramp: 440Hz → 587Hz over 30cm → 0cm
    let dist = max(Double(liveDistanceToObject), 0.0)
    let freq = min(587, max(440, 440 + (0.30 - dist) * 490))
    // Moderate volume — never above 0.4
    let vol = min(0.4, max(0.2, 0.2 + (0.30 - dist) * 0.67))

    for i in 0..<Int(fc) {
      let t = Double(i) / sr
      let env = min(t / 0.005, 1) * min((dur - t) / 0.005, 1)
      d[i] = Float(sin(2 * .pi * freq * t) * vol * env)
    }

    player.pan = 0
    player.volume = 1.0  // volume is baked into the buffer
    player.scheduleBuffer(buf, at: nil, options: .interrupts)
    if !player.isPlaying { player.play() }
    lastBeep = now
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Success Tone
  // ═══════════════════════════════════════════════════════════════════════════

  func playSuccessTone() {
    guard let player = playerNode, let fmt = audioFmt else { return }
    let sr: Double = 44100; let dur: Double = 0.5; let fc = AVAudioFrameCount(sr * dur)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
    buf.frameLength = fc; let d = buf.floatChannelData![0]
    for i in 0..<Int(fc) {
      let t = Double(i)/sr; let f = 523.25 * pow(2, t/dur)
      d[i] = Float(sin(2 * .pi * f * t) * 0.6 * min(t/0.01, 1) * min((dur-t)/0.08, 1))
    }
    player.pan = 0; player.scheduleBuffer(buf, at: nil, options: .interrupts)
    if !player.isPlaying { player.play() }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Haptics
  // ═══════════════════════════════════════════════════════════════════════════

  func triggerHaptic(_ intensity: Float) {
    guard let engine = hapticEngine else { return }
    let event = CHHapticEvent(
      eventType: .hapticTransient,
      parameters: [
        CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
        CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
      ],
      relativeTime: 0)
    try? engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: 0)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Speech
  // ═══════════════════════════════════════════════════════════════════════════

  func say(_ text: String) {
    synth.stopSpeaking(at: .immediate)
    let u = AVSpeechUtterance(string: text)
    // ttsRate is already 0.1-1.0 (from user settings), which maps directly
    // to AVSpeech's 0.0-1.0 range. DO NOT multiply by DefaultSpeechRate
    // (that was causing 0.5 * 0.5 = 0.25 = half the expected speed)
    u.rate = ttsRate
    u.voice = premiumVoice
    u.pitchMultiplier = 1.0
    u.preUtteranceDelay = 0.0
    synth.speak(u); NSLog("🗣 [ReachingVC] rate=%.2f voice=%@ | %@", ttsRate, premiumVoice?.identifier ?? "nil", text)
  }

  // NOTE: speakDirectionIfNeeded() moved to +withHand.swift
  // NOTE: speakDirectionHandFree() lives in +handFree.swift
}
