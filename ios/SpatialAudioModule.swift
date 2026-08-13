//
//  SpatialAudioModule.swift
//  shelfscout
//
//  HRTF spatial-audio renderer for the standard reaching tracker.
//
//  Melody's tracker returns a per-frame `sonification` block:
//
//      { "emit": true,
//        "position": {"x": -0.766, "y": 0.0, "z": -1.0},
//        "centered": false,
//        "pan": null, "pitch_hz": 648.4, "beep_rate_hz": 5.32 }
//
//  and the app renders it. Each axis is carried EITHER by 3D position (HRTF)
//  or by a symbolic parameter, decided server-side per axis:
//
//    azimuth    position.x, always — unless `pan` is non-null, in which case
//               x is already flattened to 0 server-side and `pan` carries
//               left/right as plain stereo pan.
//    elevation  position.y when the server carries elevation via HRTF, and/or
//               `pitch_hz` as the tone frequency. In the server's pitch mode y
//               is flattened to 0 and frequency alone carries up/down: generic
//               HRTFs localize elevation poorly, and bone conduction bypasses
//               the pinna entirely, which is where HRTF elevation filtering
//               happens.
//    depth      position.z when depth is carried by HRTF, and/or
//               `beep_rate_hz` as the repetition rate. In the server's beep
//               mode z sits at a fixed reference distance and rate alone
//               carries near/far: z is the axis that produces front/back
//               confusion in HRTF.
//
//  As of Melody's Aug 2026 change the server populates pitch_hz and
//  beep_rate_hz on EVERY frame, including HRTF mode — in HRTF mode they set
//  the carrier tone and pulse rate while position.y/z still carry the cue.
//  So this module simply renders whatever it is given: it uses pitch_hz and
//  beep_rate_hz for the tone whenever present, and position for placement,
//  without inferring which mode the server is in. The flattening is the
//  server's job and it has already happened by the time we see the values.
//  The constants below are fallbacks for a field arriving null, not defaults
//  the renderer expects to hit.
//
//  Listener orientation is FIXED facing forward and never rotated with device
//  heading. The positions arriving from the server are already expressed
//  relative to how the phone is pointed; rotating the listener as well would
//  apply the phone's rotation twice.
//
//  Coordinate convention (AVAudioEnvironmentNode's own, which is what Melody's
//  sonification.py documents — confirmed rather than assumed):
//      +x right, +y up, -z in front of the listener.
//

import Foundation
import AVFoundation
import React

@objc(SpatialAudioModule)
class SpatialAudioModule: NSObject {

  // ── Rendering state, written from JS, read on the audio timer ────────────
  private struct SonificationState {
    var emit = false
    var x: Float = 0
    var y: Float = 0
    var z: Float = -1
    var centered = false
    var pan: Float?
    var pitchHz: Double?
    var beepRateHz: Double?
    /// systemUptime of the update that produced this state.
    var receivedAt: TimeInterval = 0
  }

  private let engine = AVAudioEngine()
  private let environmentNode = AVAudioEnvironmentNode()
  /// Spatialized source: mono → environment node → main mixer.
  private let spatialPlayer = AVAudioPlayerNode()
  /// Non-spatialized source used when the server carries azimuth as `pan`.
  /// AVAudioEnvironmentNode ignores AVAudioMixing.pan (position is the only
  /// azimuth input it honours), so pan mode needs its own path straight to
  /// the main mixer.
  private let panPlayer = AVAudioPlayerNode()

  private var centeredPlayer: AVAudioPlayer?

  private let audioQueue = DispatchQueue(label: "com.shelfscout.spatialaudio")
  private let stateLock = NSLock()
  private var state = SonificationState()
  private var beepTimer: DispatchSourceTimer?
  private var lastBeepAt: TimeInterval = 0
  private var lastCentered = false
  private var isRunning = false
  /// The node graph is wired exactly once per process. AVAudioEngine raises on
  /// attaching a node that is already attached, so a stop/start cycle must
  /// restart the engine rather than rebuild the graph.
  private var graphBuilt = false
  private var toneVolume: Float = 0.6
  private var staleTimeout: TimeInterval = 2.0

  /// Tone buffers are cached per (rounded) frequency — synthesizing a fresh
  /// buffer on every beep at up to 6 Hz is pointless churn on the audio queue.
  private var toneCache: [Int: AVAudioPCMBuffer] = [:]

  private static let sampleRate: Double = 44100
  private static let toneDuration: Double = 0.08
  /// Fallback carrier frequency if pitch_hz ever arrives null. A4, matching
  /// sonification.py's neutral. The server now always sends a value.
  private static let defaultToneHz: Double = 440.0
  /// Fallback repetition rate if beep_rate_hz ever arrives null. The source
  /// still has to pulse to be localizable. The server now always sends one.
  private static let defaultBeepRateHz: Double = 2.0
  /// Timer granularity — the beep interval is compared against elapsed time on
  /// each tick, so rate changes take effect without rescheduling the timer.
  private static let tickIntervalMs = 20

  @objc static func requiresMainQueueSetup() -> Bool { false }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  /// options:
  ///   volume: Double (0..1, default 0.6)
  ///   manageAudioSession: Bool (default true)
  ///   staleTimeoutMs: Double (default 2000)
  @objc func start(
    _ options: NSDictionary?,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    audioQueue.async { [weak self] in
      guard let self = self else { return }

      if let v = (options?["volume"] as? NSNumber)?.floatValue {
        self.toneVolume = min(1.0, max(0.0, v))
      }
      if let t = (options?["staleTimeoutMs"] as? NSNumber)?.doubleValue {
        self.staleTimeout = max(0.2, t / 1000.0)
      }
      let manageSession = (options?["manageAudioSession"] as? NSNumber)?.boolValue ?? true

      if self.isRunning {
        resolver(["success": true, "restarted": false])
        return
      }

      if manageSession {
        self.configureAudioSession()
      }

      do {
        if self.graphBuilt {
          self.engine.prepare()
          try self.engine.start()
        } else {
          try self.buildGraph()
          self.graphBuilt = true
        }
      } catch {
        NSLog("⚠️ [SpatialAudio] Engine start failed: %@", error.localizedDescription)
        resolver(["success": false, "error": error.localizedDescription])
        return
      }

      self.loadCenteredChime()

      self.stateLock.lock()
      self.state = SonificationState()
      self.lastCentered = false
      self.stateLock.unlock()

      self.startBeepTimer()
      self.isRunning = true

      NSLog("🎧 [SpatialAudio] Started (HRTFHQ, volume=%.2f)", self.toneVolume)
      resolver(["success": true, "restarted": true])
    }
  }

  @objc func stop(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    audioQueue.async { [weak self] in
      guard let self = self else { return }
      guard self.isRunning else {
        resolver(["success": true])
        return
      }

      self.beepTimer?.cancel()
      self.beepTimer = nil
      self.spatialPlayer.stop()
      self.panPlayer.stop()
      self.engine.stop()
      self.toneCache.removeAll()
      self.isRunning = false

      self.stateLock.lock()
      self.state = SonificationState()
      self.lastCentered = false
      self.stateLock.unlock()

      // The audio session is deliberately left alone — TTS and the wake-word
      // recognizer share it, and tearing it down here would stomp whatever
      // configurePlaybackSession last set up.
      NSLog("🎧 [SpatialAudio] Stopped")
      resolver(["success": true])
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Per-frame update
  // ═══════════════════════════════════════════════════════════════════════════

  /// Feeds one `sonification` block from the tracker response. Cheap and
  /// non-blocking: it only swaps state, the audio timer does the rendering.
  ///
  /// params mirror the wire shape exactly — emit, position{x,y,z}, centered,
  /// pan, pitch_hz, beep_rate_hz — with null meaning "this axis is not carried
  /// by this parameter on this frame".
  @objc func update(
    _ params: NSDictionary,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    let emit = (params["emit"] as? NSNumber)?.boolValue ?? false
    let position = params["position"] as? NSDictionary
    let centered = (params["centered"] as? NSNumber)?.boolValue ?? false

    var next = SonificationState()
    next.emit = emit
    next.x = (position?["x"] as? NSNumber)?.floatValue ?? 0
    next.y = (position?["y"] as? NSNumber)?.floatValue ?? 0
    next.z = (position?["z"] as? NSNumber)?.floatValue ?? -1
    next.centered = centered
    // NSNull survives the bridge as NSNull, and `as? NSNumber` correctly
    // yields nil for it — so a null pan/pitch/rate stays "axis not carried
    // here" rather than collapsing to 0.
    next.pan = (params["pan"] as? NSNumber)?.floatValue
    next.pitchHz = (params["pitch_hz"] as? NSNumber)?.doubleValue
    next.beepRateHz = (params["beep_rate_hz"] as? NSNumber)?.doubleValue
    next.receivedAt = ProcessInfo.processInfo.systemUptime

    stateLock.lock()
    let wasCentered = lastCentered
    state = next
    lastCentered = emit && centered
    stateLock.unlock()

    // Centered chime on the rising edge only — a one-shot confirmation at the
    // transition, not a sound that repeats while centered.
    if emit && centered && !wasCentered {
      playCenteredChime()
    }

    resolver(["success": true])
  }

  /// Silences output without tearing the engine down — for pauses where the
  /// tracker is still alive (TTS talking over the cue, loop between targets).
  @objc func silence(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    stateLock.lock()
    state.emit = false
    lastCentered = false
    stateLock.unlock()
    resolver(["success": true])
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Audio graph
  // ═══════════════════════════════════════════════════════════════════════════

  private func buildGraph() throws {
    guard let monoFormat = AVAudioFormat(
      standardFormatWithSampleRate: Self.sampleRate,
      channels: 1
    ) else {
      throw NSError(domain: "SpatialAudio", code: -1, userInfo: [
        NSLocalizedDescriptionKey: "Failed to build mono format"
      ])
    }

    engine.attach(environmentNode)
    engine.attach(spatialPlayer)
    engine.attach(panPlayer)

    // Sources feeding an environment node MUST be mono — a stereo input is
    // passed through unspatialized, which would silently disable HRTF.
    engine.connect(spatialPlayer, to: environmentNode, format: monoFormat)
    // nil lets the engine negotiate the environment node's stereo output
    // against the current hardware format, which changes when the route does.
    engine.connect(environmentNode, to: engine.mainMixerNode, format: nil)
    // Pan path bypasses the environment node entirely.
    engine.connect(panPlayer, to: engine.mainMixerNode, format: monoFormat)

    // Rendering algorithm is a property of the source's mixing destination, so
    // it has to be set after the connection exists.
    spatialPlayer.renderingAlgorithm = .HRTFHQ

    // Force binaural rendering. Left on .auto, the environment node falls back
    // to plain stereo when it doesn't recognise the route as headphones —
    // and bone conduction sets are exactly the case it misjudges.
    environmentNode.outputType = .headphones

    // Fixed listener. Set once here and never touched again: the server's
    // positions are already phone-relative.
    environmentNode.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
    environmentNode.listenerAngularOrientation =
      AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)

    // Distance attenuation tuned to sonification.py's z range (-0.3 m at
    // arm's reach out to -3.0 m). referenceDistance sits at the near end so
    // the cue doesn't clip to full volume across the whole useful range.
    let attenuation = environmentNode.distanceAttenuationParameters
    attenuation.distanceAttenuationModel = .inverse
    attenuation.referenceDistance = 0.3
    attenuation.maximumDistance = 5.0
    attenuation.rolloffFactor = 1.0

    engine.prepare()
    try engine.start()
  }

  private func configureAudioSession() {
    // A live glasses camera stream holds the single Bluetooth radio on HFP.
    // Switching the category here would tear that down mid-stream (the same
    // failure ReachingModule.configurePlaybackSession guards against), so
    // leave the session exactly as-is and let the cue render over HFP.
    if GlassesAudioCoordinator.shared.isStreamActive {
      NSLog("🎧 [SpatialAudio] DAT stream active — leaving audio session untouched (HRTF degraded over HFP mono)")
      return
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playback,
        mode: .default,
        options: [.mixWithOthers, .allowBluetoothA2DP]
      )
      try session.setActive(true)
    } catch {
      NSLog("⚠️ [SpatialAudio] Audio session config failed: %@", error.localizedDescription)
    }
  }

  private func loadCenteredChime() {
    guard centeredPlayer == nil,
          let url = Bundle.main.url(forResource: "centered_sound", withExtension: "wav")
    else { return }
    centeredPlayer = try? AVAudioPlayer(contentsOf: url)
    centeredPlayer?.prepareToPlay()
    centeredPlayer?.volume = 0.6
  }

  private func playCenteredChime() {
    // Hop to the audio queue: `update` runs on the bridge queue, and the
    // player itself is created there.
    audioQueue.async { [weak self] in
      guard let player = self?.centeredPlayer else { return }
      player.currentTime = 0
      player.play()
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Beep loop
  // ═══════════════════════════════════════════════════════════════════════════

  private func startBeepTimer() {
    let timer = DispatchSource.makeTimerSource(queue: audioQueue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(Self.tickIntervalMs))
    timer.setEventHandler { [weak self] in self?.tick() }
    beepTimer = timer
    timer.resume()
  }

  private func tick() {
    stateLock.lock()
    let current = state
    stateLock.unlock()

    guard current.emit else { return }

    // Stale-state guard: if the tracker stalls or the network drops, keep
    // beeping only briefly. A cue frozen at the last known position is worse
    // than silence — it points the user at where the object used to be.
    let now = ProcessInfo.processInfo.systemUptime
    if now - current.receivedAt > staleTimeout {
      return
    }

    let rate = current.beepRateHz ?? Self.defaultBeepRateHz
    guard rate > 0 else { return }
    let interval = 1.0 / rate
    guard now - lastBeepAt >= interval else { return }

    guard engine.isRunning else {
      try? engine.start()
      return
    }

    let freq = current.pitchHz ?? Self.defaultToneHz
    guard let buffer = toneBuffer(frequency: freq) else { return }

    if let pan = current.pan {
      // Pan mode: azimuth as stereo pan, x already flattened server-side.
      // Stop the spatial voice so the two paths never overlap.
      if spatialPlayer.isPlaying { spatialPlayer.stop() }
      panPlayer.pan = pan.isNaN ? 0 : max(-1, min(1, pan))
      panPlayer.volume = toneVolume
      panPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
      if !panPlayer.isPlaying { panPlayer.play() }
    } else {
      if panPlayer.isPlaying { panPlayer.stop() }
      spatialPlayer.position = AVAudio3DPoint(
        x: current.x.isNaN ? 0 : current.x,
        y: current.y.isNaN ? 0 : current.y,
        z: current.z.isNaN ? -1 : current.z
      )
      spatialPlayer.volume = toneVolume
      spatialPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
      if !spatialPlayer.isPlaying { spatialPlayer.play() }
    }

    lastBeepAt = now
  }

  /// Mono sine burst with a short attack/decay envelope. Cached per whole Hz —
  /// the server's pitch resolution is 0.1 Hz but nobody hears that, and an
  /// uncapped cache would grow with every distinct frequency.
  private func toneBuffer(frequency: Double) -> AVAudioPCMBuffer? {
    let key = Int(frequency.rounded())
    if let cached = toneCache[key] { return cached }

    guard let format = AVAudioFormat(
      standardFormatWithSampleRate: Self.sampleRate,
      channels: 1
    ) else { return nil }

    let frameCount = AVAudioFrameCount(Self.sampleRate * Self.toneDuration)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
          let channel = buffer.floatChannelData?[0]
    else { return nil }

    buffer.frameLength = frameCount
    let ramp = 0.005
    for i in 0..<Int(frameCount) {
      let t = Double(i) / Self.sampleRate
      let envelope = min(t / ramp, 1) * min((Self.toneDuration - t) / ramp, 1)
      channel[i] = Float(sin(2 * .pi * frequency * t) * envelope)
    }

    // The distinct frequencies the server can emit are bounded (220–880 Hz),
    // so this cap is a safety net, not a working limit.
    if toneCache.count > 128 { toneCache.removeAll() }
    toneCache[key] = buffer
    return buffer
  }
}
