//
//  WearablesCameraModule.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-05-17.
//

// React Native bridge for Meta Wearables Device Access Toolkit (iOS)
//
// CRITICAL DESIGN NOTE — photo path vs video-frame fallback:
//
// Meta's MWDAT photo path (StreamSession.capturePhoto + photoDataPublisher)
// is unreliable with our raw video codec config: the command is sent and
// acknowledged by the device (we see WARP type 23 ack=0 in logs), the
// glasses fire a confirmation tone, but photoDataPublisher never delivers
// the encoded photo back. The video stream keeps running at 24fps with no
// pause — meaning the device side never actually executed the still
// capture, despite acking the request.
//
// Workaround: we subscribe to videoFramePublisher at stream-creation time
// and cache the latest VideoFrame. On capturePhoto request, we attempt
// the photo path with a short timeout; if it doesn't deliver in time, we
// fall back to encoding the latest cached video frame as JPEG. Same
// camera, same moment, indistinguishable for our backend's purposes.

import Foundation
import UIKit
import AVFoundation
import MWDATCore
import MWDATCamera

@objc(WearablesCameraModule)
class WearablesCameraModule: NSObject {

  // ── SDK handles ────────────────────────────────────────────────────────
  private var wearables: WearablesInterface?
  private var deviceSession: DeviceSession?
  private var streamSession: StreamSession?

  /// Long-lived AutoDeviceSelector. The SDK's `activeDeviceStream()` requires
  /// the selector instance to be retained across the wait — recreating it
  /// each call loses the active-device watcher. This is the same pattern
  /// Meta's v0.6 sample CameraAccess app uses to work around the "glasses
  /// not yet active" race that surfaces as ActivityManagerError code 11.
  private var sharedDeviceSelector: AutoDeviceSelector?

  // ── Listeners (tokens kept alive while module is alive) ────────────────
  private var stateListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?

  // ── Background tasks for stream observation ────────────────────────────
  private var devicesObserverTask: Task<Void, Never>?
  private var registrationObserverTask: Task<Void, Never>?

  // ── Cached state ──────────────────────────────────────────────────────
  private let stateQueue = DispatchQueue(label: "wearables.state")
  private var _availableDevices: [DeviceIdentifier] = []
  private var availableDevices: [DeviceIdentifier] {
    get { stateQueue.sync { _availableDevices } }
    set { stateQueue.sync { _availableDevices = newValue } }
  }

  /// Most recent video frame — used as a fallback when capturePhoto's
  /// photoDataPublisher fails to deliver within the timeout window.
  private var _latestVideoFrame: VideoFrame?
  private var latestVideoFrame: VideoFrame? {
    get { stateQueue.sync { _latestVideoFrame } }
    set { stateQueue.sync { _latestVideoFrame = newValue } }
  }

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - SDK lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  private func ensureConfigured() throws -> WearablesInterface {
    if let wearables = wearables { return wearables }
    let instance = Wearables.shared
    wearables = instance
    // Construct AutoDeviceSelector ONCE and retain it — the SDK's
    // activeDeviceStream is backed by this instance's lifetime.
    if sharedDeviceSelector == nil {
      sharedDeviceSelector = AutoDeviceSelector(wearables: instance)
    }
    startObservers(instance)
    return instance
  }

  private func startObservers(_ wearables: WearablesInterface) {
    if devicesObserverTask == nil {
      devicesObserverTask = Task { [weak self] in
        guard let self else { return }
        NSLog("👀 [Wearables] devicesStream observer started")
        for await devices in wearables.devicesStream() {
          self.availableDevices = devices
          NSLog("👀 [Wearables] devicesStream → %d device(s): %@",
                devices.count, devices.joined(separator: ", "))
        }
      }
    }
    if registrationObserverTask == nil {
      registrationObserverTask = Task { [weak self] in
        guard self != nil else { return }
        NSLog("👀 [Wearables] registrationStateStream observer started")
        for await state in wearables.registrationStateStream() {
          NSLog("👀 [Wearables] registrationState → %@", "\(state)")
        }
      }
    }
  }

  /// Wait for the SDK to report an ACTIVE device — not just a paired one.
  ///
  /// Background: `wearables.devicesStream()` returns the catalog of paired
  /// devices and emits as soon as the user has paired glasses in Meta AI.
  /// That is NOT the same as "the BT link is up and the device-side
  /// ActivityManagerService is ready to honor a session start". Calling
  /// `wearables.createSession(...).start()` while the device is paired
  /// but not yet active causes the device's ActivityManagerService to
  /// reject the activity ~5s later with error code 11 (the symptom we
  /// see in logs as `MediaStreamSession - connect complete: 11` followed
  /// by `Stream did not reach streaming state within 8s`).
  ///
  /// `AutoDeviceSelector.activeDeviceStream()` only emits a non-nil value
  /// when the device is actually reachable. This is the gate Meta's v0.6
  /// sample app uses (see DeviceSessionManager.swift in the SDK sample).
  private func waitForActiveDevice(timeoutSeconds: TimeInterval = 20) async -> Bool {
    guard let selector = sharedDeviceSelector else {
      NSLog("⚠️ [Wearables] waitForActiveDevice: no shared selector")
      return false
    }
    NSLog("⏳ [Wearables] Waiting up to %.0fs for an ACTIVE device…", timeoutSeconds)

    return await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await device in selector.activeDeviceStream() {
          if device != nil {
            NSLog("✅ [Wearables] activeDeviceStream emitted an active device")
            return true
          }
        }
        return false
      }
      group.addTask {
        do {
          try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        } catch {
          return false
        }
        guard !Task.isCancelled else { return false }
        NSLog("⏱️ [Wearables] waitForActiveDevice timed out after %.0fs", timeoutSeconds)
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  /// Legacy helper kept for any non-streaming callers — checks the paired
  /// catalog only. Streaming paths must use `waitForActiveDevice` instead.
  private func waitForDevice(timeoutSeconds: TimeInterval = 12) async throws -> Bool {
    if !availableDevices.isEmpty { return true }
    NSLog("⏳ [Wearables] Waiting up to %.0fs for a device to appear…", timeoutSeconds)
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
      try await Task.sleep(nanoseconds: 250_000_000)
      if !availableDevices.isEmpty {
        NSLog("✅ [Wearables] Device(s) appeared after wait")
        return true
      }
    }
    NSLog("⏱️ [Wearables] waitForDevice timed out — devicesStream is empty")
    return false
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - BT Radio Arbitration (CRITICAL — root cause of error 11)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Root cause of `ActivityManagerError code 11` ("a session already exists
  // for this device") that surfaces as "Stream did not reach streaming
  // state within 8s":
  //
  // The Ray-Ban Meta glasses speak two protocols over their single BT
  // radio:
  //   1. HFP (Hands-Free Profile) — used by iOS's AVAudioSession when the
  //      app's audio session category is `.playAndRecord` + `.allowBluetooth`.
  //      This is what `ReachingModule.configureBluetoothRecordingSession()`
  //      sets up so the wake-word recognizer can hear the user via the
  //      glasses' mic.
  //   2. MWDAT data session — used by the Meta SDK for video stream +
  //      photo capture. Goes through External Accessory / WARP transport.
  //
  // On the glasses side, the ActivityManagerService enforces "ONE app
  // session at a time" over the BT link. When HFP is active (iOS holding
  // the AVAudioSession), the glasses see the iPhone as already "in
  // session" — so when MWDAT tries to add its own data session, the
  // ActivityManager rejects with error code 11.
  //
  // This was masked in earlier builds because MWDAT preWarm ran BEFORE
  // the wake-word recognizer activated HFP. In the current build, the
  // wake-word recognizer activates HFP at app launch (immediately when
  // the wake-word hook is `enabled`), so by the time the user actually
  // wants to capture a photo, HFP has already claimed the BT link.
  //
  // Fix: temporarily deactivate iOS's AVAudioSession before each MWDAT
  // session start. This releases HFP, freeing the BT radio for MWDAT
  // exclusively. After capture completes, the wake-word recognizer will
  // re-acquire HFP on its next session start (the JS-side `resume()`
  // path already calls `configureBluetoothRecordingSession` before
  // restarting Voice).
  //
  // The audio session must be deactivated with .notifyOthersOnDeactivation
  // so any active audio output (TTS) is gracefully wound down rather than
  // killed mid-utterance.
  // ═══════════════════════════════════════════════════════════════════════════

  /// Release the iOS BT-HFP audio session so MWDAT has exclusive BT radio
  /// access. Safe to call even if no session is active. Logs result for
  /// debugging but never throws — a failure here doesn't necessarily
  /// block MWDAT from trying.
  private func releaseBTRadioForMWDAT() async {
    let session = AVAudioSession.sharedInstance()
    // Log what we're releasing so the BT radio handoff is observable.
    let beforeInput = session.currentRoute.inputs.first?.portName ?? "none"
    let beforeOutput = session.currentRoute.outputs.first?.portName ?? "none"
    NSLog("📻 [Wearables] Releasing BT radio for MWDAT (was: input=%@ output=%@)",
          beforeInput, beforeOutput)
    do {
      // Deactivating with .notifyOthersOnDeactivation lets other audio
      // clients (TTS via AVSpeechSynthesizer, react-native-sound) get a
      // clean handoff instead of being killed mid-buffer.
      try session.setActive(false, options: [.notifyOthersOnDeactivation])
      NSLog("📻 [Wearables] AVAudioSession deactivated")
    } catch {
      // Non-fatal — proceed and let the MWDAT start attempt log its
      // specific failure if BT is still occupied.
      NSLog("⚠️ [Wearables] AVAudioSession deactivate warning: %@",
            (error as NSError).localizedDescription)
    }
    // Brief settle period so the glasses' ActivityManager actually
    // observes HFP teardown before MWDAT issues its session-start.
    // 250ms is empirically enough on iPhone 16 — shorter values
    // sometimes still race with the BT controller.
    try? await Task.sleep(nanoseconds: 250_000_000)
  }



  private func humanizePermissionError(_ rawValue: Int) -> String {
    // From MWDATCore.PermissionError (Int-backed enum, v0.6):
    //   0 noDevice              — No paired wearables visible to the SDK
    //   1 noDeviceWithConnection — Paired but EA-channel disconnected
    //   2 connectionError       — EA channel error
    //   3 metaAINotInstalled    — Meta AI app missing
    //   4 requestInProgress     — Another permission flow active
    //   5 requestTimeout        — User didn't respond in time
    //   6 internalError         — SDK-internal failure
    switch rawValue {
    case 0:
      return "No glasses found. Pair Ray-Ban Meta in the Meta AI app and try again."
    case 1:
      return "Glasses paired but not actively connected to ShelfScout. " +
             "Open the Meta AI app, confirm the glasses card shows 'Connected'. " +
             "If it does and this still fails, enable Developer Mode on the glasses " +
             "(Meta AI → glasses card → Settings → About → tap Version 5x → turn on Developer Mode), " +
             "then power-cycle the glasses with the frame switch."
    case 2:
      return "Connection error talking to glasses. Power-cycle the glasses and try again."
    case 3:
      return "Meta AI app not installed. Install it from the App Store."
    case 4:
      return "A permission request is already in progress. Wait a few seconds and try again."
    case 5:
      return "Permission request timed out. Open the Meta AI app and accept when prompted."
    case 6:
      return "Internal SDK error. Toggle Bluetooth off/on, then try again."
    default:
      return "Unknown permission error (\(rawValue))."
    }
  }

  private func ensureCameraPermission(_ wearables: WearablesInterface) async throws {
    do {
      var status = try await wearables.checkPermissionStatus(.camera)
      NSLog("🔑 [Wearables] camera permission status (initial): %@", "\(status)")
      if status != .granted {
        status = try await wearables.requestPermission(.camera)
        NSLog("🔑 [Wearables] camera permission status (after request): %@", "\(status)")
      }
      if status != .granted {
        throw NSError(
          domain: "WearablesCamera",
          code: 1001,
          userInfo: [NSLocalizedDescriptionKey:
            "Camera permission not granted in Meta AI app."]
        )
      }
    } catch {
      let nsErr = error as NSError
      // MWDATCore.PermissionError surfaces as `MWDATCore.PermissionError`
      // domain with `code` = the raw value of the enum case. Translate so
      // the user sees what's actually wrong (not "error 1").
      if nsErr.domain == "MWDATCore.PermissionError" {
        let humanMsg = humanizePermissionError(nsErr.code)
        NSLog("⚠️ [Wearables] PermissionError(%d): %@", nsErr.code, humanMsg)
        throw NSError(
          domain: "WearablesCamera",
          code: 1000 + nsErr.code,
          userInfo: [NSLocalizedDescriptionKey: humanMsg]
        )
      }
      throw error
    }
  }

  private func createSessionWithFallback(_ wearables: WearablesInterface) throws -> DeviceSession {
    // Auto FIRST — this is the path Meta's v0.6 sample uses exclusively.
    // SpecificDeviceSelector targets a paired-but-not-necessarily-active
    // device by ID, which is exactly what triggers the
    // ActivityManagerError code 11 race. Auto picks only currently-active
    // devices (per v0.6 changelog: "AutoDeviceSelector now selects or
    // drops devices based on connectivity state").
    if let selector = sharedDeviceSelector {
      NSLog("🎯 [Wearables] Trying shared AutoDeviceSelector")
      do {
        let session = try wearables.createSession(deviceSelector: selector)
        NSLog("✅ [Wearables] AutoDeviceSelector accepted")
        return session
      } catch {
        NSLog("⚠️ [Wearables] AutoDeviceSelector rejected: %@ — trying SpecificDeviceSelector",
              (error as NSError).localizedDescription)
      }
    }

    // Last-resort fallback: SpecificDeviceSelector. Only used if Auto fails
    // (e.g. selector not yet initialized, or no active device the SDK can
    // pick automatically). Prefer Auto in normal operation.
    if let firstID = availableDevices.first {
      NSLog("🎯 [Wearables] Falling back to SpecificDeviceSelector for id=%@", firstID)
      let specific = SpecificDeviceSelector(device: firstID)
      let session = try wearables.createSession(deviceSelector: specific)
      NSLog("✅ [Wearables] SpecificDeviceSelector accepted (fallback)")
      return session
    }

    // Nothing worked — surface a fresh AutoDeviceSelector attempt so the
    // caller gets a consistent error path.
    let auto = AutoDeviceSelector(wearables: wearables)
    return try wearables.createSession(deviceSelector: auto)
  }

  private func ensureDeviceSession(_ wearables: WearablesInterface) async throws -> DeviceSession {
    if let session = deviceSession, session.state == .started {
      return session
    }
    if deviceSession?.state == .stopped {
      deviceSession = nil
    }

    // Active-device wait is now ADVISORY, not gating.
    //
    // Background: in some environments (Developer Mode off on glasses,
    // release-channel attestation pending, EA channel stuck) the SDK
    // never emits a non-nil device on activeDeviceStream — but a session
    // start can still succeed against the paired device, OR fail with a
    // more specific device-side error code that's much more useful for
    // debugging than "no active device". So we wait briefly, then try
    // anyway and let the SDK's own error reporting do the diagnosis.
    let haveActive = await waitForActiveDevice(timeoutSeconds: 5)
    if !haveActive {
      NSLog("⚠️ [Wearables] activeDeviceStream silent after 5s — attempting session anyway. " +
            "Likely causes: Developer Mode off on glasses, app not on user's release channel, " +
            "or EA channel stuck (try power-cycling the glasses with the frame switch).")
    }

    let maxAttempts = 3
    var lastError: NSError?

    for attempt in 1...maxAttempts {
      let session: DeviceSession
      do {
        session = try createSessionWithFallback(wearables)
      } catch {
        let nsErr = error as NSError
        NSLog("⛔ [Wearables] Both selectors rejected: %@", nsErr.localizedDescription)
        throw NSError(
          domain: "WearablesCamera",
          code: 1011,
          userInfo: [NSLocalizedDescriptionKey:
            "Glasses paired but not allowed to share camera. In Meta AI app: open your glasses card → Settings → Connected apps → enable Camera for ShelfScout. " +
            "If the option is missing, enable Developer Mode on the glasses first."]
        )
      }
      deviceSession = session

      do {
        let stateStream = session.stateStream()
        try session.start()

        for await state in stateStream {
          NSLog("📡 [Wearables] deviceSession state → %@", "\(state)")
          if state == .started { return session }
          if state == .stopped {
            throw NSError(
              domain: "WearablesCamera",
              code: 1002,
              userInfo: [NSLocalizedDescriptionKey: "Device session stopped before becoming started."]
            )
          }
        }

        throw NSError(
          domain: "WearablesCamera",
          code: 1002,
          userInfo: [NSLocalizedDescriptionKey: "Device session stateStream ended without becoming started."]
        )
      } catch {
        let nsErr = error as NSError
        lastError = nsErr
        NSLog("⚠️ [Wearables] Device session start failed (attempt %d/%d) [%@:%d]: %@",
              attempt, maxAttempts, nsErr.domain, nsErr.code, nsErr.localizedDescription)
        if session.state != .stopped {
          await session.stop()
        }
        deviceSession = nil
        if attempt < maxAttempts {
          // Brief pause; re-poll active device but don't block on it.
          _ = await waitForActiveDevice(timeoutSeconds: 3)
        }
      }
    }

    throw lastError ?? NSError(
      domain: "WearablesCamera",
      code: 1002,
      userInfo: [NSLocalizedDescriptionKey: "Device session failed to start."]
    )
  }

  private func ensureStreamSession(_ deviceSession: DeviceSession) async throws -> StreamSession {
    if let stream = streamSession {
      switch stream.state {
      case .streaming:
        return stream
      case .starting, .waitingForDevice:
        if stream.state != .starting {
          await stream.start()
        }
        if try await waitForStreaming(stream) {
          return stream
        }
      case .stopping, .stopped:
        break
      @unknown default:
        break
      }

      // Stream exists but never reached .streaming; reset and recreate it.
      if stream.state != .stopped {
        await stream.stop()
      }
      streamSession = nil
      latestVideoFrame = nil
      stateListenerToken = nil
      errorListenerToken = nil
      photoListenerToken = nil
      videoFrameListenerToken = nil
    }

    let config = StreamSessionConfig(
      videoCodec: .raw,
      resolution: .low,
      frameRate: 24
    )

    guard let stream = try? deviceSession.addStream(config: config) else {
      throw NSError(
        domain: "WearablesCamera",
        code: 1003,
        userInfo: [NSLocalizedDescriptionKey: "Failed to create stream session"]
      )
    }
    streamSession = stream

    // ── Subscribe BEFORE start() — listeners must be live the moment frames arrive
    stateListenerToken = stream.statePublisher.listen { state in
      NSLog("📡 [Wearables] Stream state: %@", "\(state)")
    }
    errorListenerToken = stream.errorPublisher.listen { error in
      NSLog("⚠️ [Wearables] Stream error: %@", "\(error)")
    }

    // ── Cache every video frame as it arrives — this is our photo fallback.
    // The MWDAT photo path is unreliable; we trade exact "shutter moment"
    // precision for guaranteed delivery.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      self?.latestVideoFrame = frame
    }

    await stream.start()

    let started = try await waitForStreaming(stream)
    if !started {
      throw NSError(
        domain: "WearablesCamera",
        code: 1003,
        userInfo: [NSLocalizedDescriptionKey: "Stream did not reach streaming state within 8s"]
      )
    }
    return stream
  }

  private func waitForStreaming(_ stream: StreamSession) async throws -> Bool {
    let timeoutSeconds: TimeInterval = 8
    let pollIntervalNs: UInt64 = 200_000_000
    let start = Date()
    while Date().timeIntervalSince(start) < timeoutSeconds {
      switch stream.state {
      case .streaming: return true
      case .stopped:   return false
      default: break
      }
      try await Task.sleep(nanoseconds: pollIntervalNs)
    }
    return false
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Capture (with photo path + video-frame fallback)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Try the MWDAT photo capture path with a hard timeout. Returns nil on
  /// timeout — caller is expected to fall back to a cached video frame.
  private func capturePhotoData(
    from stream: StreamSession,
    timeoutSeconds: TimeInterval = 5.0
  ) async -> Data? {
    return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
      // Single-resume guard — both the listener and the timeout race.
      let resumed = AtomicBool()

      photoListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
        guard !resumed.swap(true) else { return }
        self?.photoListenerToken = nil
        NSLog("📸 [Wearables] Photo path delivered %d bytes via photoDataPublisher",
              photoData.data.count)
        continuation.resume(returning: photoData.data)
      }

      let accepted = stream.capturePhoto(format: .jpeg)
      NSLog("📸 [Wearables] capturePhoto accepted = %@", "\(accepted)")
      if !accepted {
        guard !resumed.swap(true) else { return }
        photoListenerToken = nil
        NSLog("⚠️ [Wearables] capturePhoto rejected (capture in progress or no device)")
        continuation.resume(returning: nil)
        return
      }

      // Hard timeout — never hang.
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
        guard !resumed.swap(true) else { return }
        self?.photoListenerToken = nil
        NSLog("⏱️ [Wearables] photoDataPublisher timed out after %.1fs — using video-frame fallback",
              timeoutSeconds)
        continuation.resume(returning: nil)
      }
    }
  }

  /// Encode the latest cached video frame as JPEG. This is our reliable
  /// fallback when the photo path doesn't deliver.
  private func captureVideoFrameAsJPEG() -> Data? {
    guard let frame = latestVideoFrame else {
      NSLog("⚠️ [Wearables] No cached video frame available for fallback")
      return nil
    }
    guard let image = frame.makeUIImage() else {
      NSLog("⚠️ [Wearables] VideoFrame.makeUIImage() returned nil")
      return nil
    }
    guard let jpeg = image.jpegData(compressionQuality: 0.85) else {
      NSLog("⚠️ [Wearables] UIImage.jpegData() returned nil")
      return nil
    }
    NSLog("📸 [Wearables] Video-frame fallback produced %d-byte JPEG (%.0fx%.0f)",
          jpeg.count, image.size.width, image.size.height)
    return jpeg
  }

  private func writePhotoData(_ data: Data) throws -> String {
    let filename = "wearables-\(UUID().uuidString).jpg"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try data.write(to: url, options: .atomic)
    return url.absoluteString
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - React Native exposed methods
  // ═══════════════════════════════════════════════════════════════════════════

  @objc func startRegistration(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let wearables = try self.ensureConfigured()
        try await wearables.startRegistration()
        NSLog("✅ [Wearables] startRegistration completed")
        resolver(["success": true, "alreadyRegistered": false])
      } catch {
        let nsErr = error as NSError
        if nsErr.domain == "MWDATCore.RegistrationError" && nsErr.code == 0 {
          NSLog("ℹ️ [Wearables] Already registered — treating as success")
          resolver(["success": true, "alreadyRegistered": true])
          return
        }
        NSLog("⚠️ [Wearables] startRegistration failed: %@", nsErr.localizedDescription)
        rejecter("REGISTRATION", nsErr.localizedDescription, nsErr)
      }
    }
  }

  @objc func getStatus(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    if let stream = streamSession, stream.state == .streaming {
      resolver("connected"); return
    }
    if let session = deviceSession, session.state == .started {
      resolver("connected"); return
    }
    if !availableDevices.isEmpty {
      resolver("paired"); return
    }
    resolver("disconnected")
  }

  @objc func capturePhoto(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let wearables = try self.ensureConfigured()
        try await self.ensureCameraPermission(wearables)
        // CRITICAL: Release iOS's hold on the BT radio (HFP audio session)
        // before MWDAT tries to claim it. Without this, the glasses'
        // ActivityManagerService rejects MWDAT with error code 11.
        await self.releaseBTRadioForMWDAT()
        let deviceSession = try await self.ensureDeviceSession(wearables)
        let stream = try await self.ensureStreamSession(deviceSession)

        // Give videoFramePublisher a moment to populate the cache after
        // .streaming. If we entered with a fresh stream, latestVideoFrame
        // may be nil for the first ~50-100ms.
        if self.latestVideoFrame == nil {
          for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if self.latestVideoFrame != nil { break }
          }
        }

        // Try the photo path first (5s timeout), fall back to video frame.
        var imageData: Data? = await self.capturePhotoData(from: stream, timeoutSeconds: 5.0)
        if imageData == nil {
          imageData = self.captureVideoFrameAsJPEG()
        }

        guard let data = imageData else {
          throw NSError(
            domain: "WearablesCamera",
            code: 1005,
            userInfo: [NSLocalizedDescriptionKey:
              "Could not get an image from the glasses. Photo path timed out and no video frame was cached. Try toggling the glasses camera off and on."]
          )
        }

        let path = try self.writePhotoData(data)
        resolver(path)
      } catch {
        let nsErr = error as NSError
        NSLog("⚠️ [Wearables] capturePhoto failed: %@", nsErr.localizedDescription)
        rejecter("CAPTURE", nsErr.localizedDescription, nsErr)
      }
    }
  }

  @objc func preWarm(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    Task { [weak self] in
      guard let self else { return }
      do {
        let wearables = try self.ensureConfigured()
        try await self.ensureCameraPermission(wearables)
        // CRITICAL: Release BT-HFP before MWDAT claims the radio.
        // See releaseBTRadioForMWDAT() comment block for full rationale.
        await self.releaseBTRadioForMWDAT()
        let deviceSession = try await self.ensureDeviceSession(wearables)
        _ = try await self.ensureStreamSession(deviceSession)
        NSLog("✅ [Wearables] preWarm complete — session streaming, video frames flowing")
        resolver(["success": true])
      } catch {
        let nsErr = error as NSError
        NSLog("⚠️ [Wearables] preWarm failed: %@", nsErr.localizedDescription)
        rejecter("PREWARM", nsErr.localizedDescription, nsErr)
      }
    }
  }

  @objc func disconnect(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    Task { [weak self] in
      guard let self else { return }
      NSLog("🧹 [Wearables] disconnect — tearing down sessions")
      if let stream = self.streamSession {
        await stream.stop()
      }
      self.streamSession = nil
      self.latestVideoFrame = nil
      self.stateListenerToken = nil
      self.errorListenerToken = nil
      self.photoListenerToken = nil
      self.videoFrameListenerToken = nil
      // Properly stop the device session before niling — without this,
      // the device-side ActivityManager keeps its session alive and the
      // next reconnect collides with error code 11.
      if let ds = self.deviceSession, ds.state != .stopped {
        NSLog("🧹 [Wearables] disconnect — stopping device session (state=%@)", "\(ds.state)")
        await ds.stop()
      }
      self.deviceSession = nil
      NSLog("🧹 [Wearables] disconnect complete")
      resolver(["success": true])
    }
  }

  deinit {
    devicesObserverTask?.cancel()
    registrationObserverTask?.cancel()
    stateListenerToken = nil
    errorListenerToken = nil
    photoListenerToken = nil
    videoFrameListenerToken = nil
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Tiny atomic Bool for race-free continuation resume
// ═══════════════════════════════════════════════════════════════════════════
//
// `withCheckedContinuation` requires exactly one resume() call. With both
// a listener AND a timeout that can race, we need a thread-safe "first
// one wins" flag.

private final class AtomicBool {
  private let lock = NSLock()
  private var value: Bool = false

  /// Atomically sets to `true` and returns the PREVIOUS value.
  /// Pattern: `guard !atomic.swap(true) else { return }` — only the first
  /// racer proceeds.
  func swap(_ newValue: Bool) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let old = value
    value = newValue
    return old
  }
}
