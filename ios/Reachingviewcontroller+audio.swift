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
      let sr: Double = 44100; let dur: Double = 0.06; let freq: Double = 1000
      let fc = AVAudioFrameCount(sr * dur)
      guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
      audioFmt = fmt; engine.connect(player, to: engine.mainMixerNode, format: fmt)
      guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
      buf.frameLength = fc; let d = buf.floatChannelData![0]
      for i in 0..<Int(fc) {
        let t = Double(i)/sr
        let env = min(t/0.005, 1) * min((dur-t)/0.005, 1)
        d[i] = Float(sin(2 * .pi * freq * t) * 0.5 * env)
      }
      beepBuf = buf; playerNode = player; audioEngine = engine
      try engine.start()
    } catch { NSLog("⚠️ Audio: %@", error.localizedDescription) }
  }

  func setupHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    hapticEngine = try? CHHapticEngine()
    try? hapticEngine?.start()
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
    let now = ProcessInfo.processInfo.systemUptime
    let iv: TimeInterval = {
      switch proximityZone {
      case .searching: return 99
      case .far:       return 0.7
      case .medium:    return 0.4
      case .close:     return 0.2
      case .veryClose: return 0.08
      case .centered:  return 0.04
      }
    }()
    if now - lastBeep >= iv {
      if let p = playerNode, let b = beepBuf {
        switch currentDirection {
        case .left, .topLeft, .downLeft:    p.pan = -0.8
        case .right, .topRight, .downRight: p.pan =  0.8
        default:                            p.pan =  0.0
        }
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        if !p.isPlaying { p.play() }
      }
      lastBeep = now
    }
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
    u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
    u.voice = AVSpeechSynthesisVoice(language: "en-US")
    synth.speak(u); NSLog("🗣 [ReachingVC] %@", text)
  }

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
        // First time entering aligned+close — give the key instruction
        say("Aligned. Move your hand forward to grab it.")
        lastSpokenDirection = direction; lastSpeechTime = now
      } else if (now - lastSpeechTime) > 3.0 {
        // Repeated — remind to reach forward and tap
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
}