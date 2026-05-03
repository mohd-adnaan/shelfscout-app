// WearablesCameraModule.swift
// React Native bridge for Meta Wearables Device Access Toolkit (iOS)
//
// Key change vs previous version:
//   • We now OBSERVE devicesStream from the moment the module wakes up,
//     keeping a cached `availableDevices` list. preWarm/capturePhoto wait
//     for at least one device to appear (with timeout) before creating a
//     session. This is the only pattern that works reliably given the
//     Bluetooth startup race ("API MISUSE: CBCentralManager can only
//     accept this command while in the powered on state") that delays
//     device discovery for a few seconds after app launch.
//
//   • registrationStateStream is also observed — purely diagnostic, gives
//     us logs to debug from instead of guessing.
//
//   • Errors carry distinct codes so JS can tell "no glasses" from
//     "no permission" from "stream failed".

import Foundation
import MWDATCore
import MWDATCamera

@objc(WearablesCameraModule)
class WearablesCameraModule: NSObject {

  // ── SDK handles ────────────────────────────────────────────────────────
  private var wearables: WearablesInterface?
  private var deviceSession: DeviceSession?
  private var streamSession: StreamSession?

  // ── Listeners (tokens kept alive while module is alive) ────────────────
  private var stateListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoListenerToken: AnyListenerToken?

  // ── Background tasks for stream observation ────────────────────────────
  private var devicesObserverTask: Task<Void, Never>?
  private var registrationObserverTask: Task<Void, Never>?

  // ── Cached state populated by observers ────────────────────────────────
  // Use a serial queue for thread safety — Swift actors would be cleaner
  // but require pushing the bridge methods to be actor-isolated.
  private let stateQueue = DispatchQueue(label: "wearables.state")
  // devicesStream yields [DeviceIdentifier] (typealias for [String]),
  // not [Device]. We just need to know if the count is > 0 — the actual
  // device selection is handled by AutoDeviceSelector inside createSession.
  private var _availableDevices: [DeviceIdentifier] = []
  private var availableDevices: [DeviceIdentifier] {
    get { stateQueue.sync { _availableDevices } }
    set { stateQueue.sync { _availableDevices = newValue } }
  }

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - SDK lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns the cached SDK instance. SDK is configured by AppDelegate at
  /// app launch — we never call Wearables.configure() here.
  private func ensureConfigured() throws -> WearablesInterface {
    if let wearables = wearables { return wearables }
    let instance = Wearables.shared
    wearables = instance
    startObservers(instance)
    return instance
  }

  /// Spin up the background observers ONCE. They run for the lifetime of
  /// the module and continuously update `availableDevices`.
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
        NSLog("👀 [Wearables] devicesStream observer ended")
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

  /// Wait until at least one device is present in the cache, polling
  /// every 250ms up to `timeoutSeconds`. Returns false on timeout.
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
  // MARK: - Permission + Device + Stream
  // ═══════════════════════════════════════════════════════════════════════════

  private func ensureCameraPermission(_ wearables: WearablesInterface) async throws {
    var status = try await wearables.checkPermissionStatus(.camera)
    NSLog("🔑 [Wearables] camera permission status (initial): %@", "\(status)")
    if status != .granted {
      // This call may bounce the user to the Meta AI app to approve.
      status = try await wearables.requestPermission(.camera)
      NSLog("🔑 [Wearables] camera permission status (after request): %@", "\(status)")
    }
    if status != .granted {
      throw NSError(
        domain: "WearablesCamera",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey:
          "Camera permission not granted in Meta AI app. Open Meta AI → your glasses → grant ShelfScout camera access."]
      )
    }
  }

  private func createSessionWithFallback(_ wearables: WearablesInterface) throws -> DeviceSession {
    // Strategy: try SpecificDeviceSelector first (using the cached device
    // ID from devicesStream), then fall back to AutoDeviceSelector. The
    // explicit selector tends to succeed when AutoDeviceSelector returns
    // "No eligible device available" — the device is known to the SDK but
    // Auto's own eligibility heuristic refuses it (often happens when a
    // device's per-glasses camera permission hasn't been granted to this
    // app in the Meta AI app's per-device "Connected apps" list).
    let cachedIDs = availableDevices

    if let firstID = cachedIDs.first {
      NSLog("🎯 [Wearables] Trying SpecificDeviceSelector for id=%@", firstID)
      let specific = SpecificDeviceSelector(device: firstID)
      do {
        let session = try wearables.createSession(deviceSelector: specific)
        NSLog("✅ [Wearables] SpecificDeviceSelector accepted")
        return session
      } catch {
        NSLog("⚠️ [Wearables] SpecificDeviceSelector failed: %@ — falling back to Auto",
              error.localizedDescription)
      }
    }

    NSLog("🎯 [Wearables] Trying AutoDeviceSelector")
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

    // Wait for devices to populate BEFORE asking the selector to find one.
    let haveDevice = try await waitForDevice(timeoutSeconds: 12)
    if !haveDevice {
      throw NSError(
        domain: "WearablesCamera",
        code: 1010,
        userInfo: [NSLocalizedDescriptionKey:
          "No glasses visible to the SDK. Make sure the Meta AI app is open in the background, glasses are paired in Meta AI, and ShelfScout has camera permission for these glasses in Meta AI."]
      )
    }

    let session: DeviceSession
    do {
      session = try createSessionWithFallback(wearables)
    } catch {
      // Both selectors failed → almost always the per-glasses app permission.
      let nsErr = error as NSError
      NSLog("⛔ [Wearables] Both selectors rejected: %@ (domain=%@ code=%d)",
            nsErr.localizedDescription, nsErr.domain, nsErr.code)
      throw NSError(
        domain: "WearablesCamera",
        code: 1011,
        userInfo: [NSLocalizedDescriptionKey:
          "Glasses are paired but not allowed to share the camera with ShelfScout. In the Meta AI app, open your Wayfarer card → Settings (gear) → Connected apps → enable Camera for ShelfScout. Then toggle this setting OFF and ON again."]
      )
    }
    deviceSession = session

    let stateStream = session.stateStream()
    try session.start()

    for await state in stateStream {
      NSLog("📡 [Wearables] deviceSession state → %@", "\(state)")
      if state == .started { return session }
      if state == .stopped {
        throw NSError(
          domain: "WearablesCamera",
          code: 1002,
          userInfo: [NSLocalizedDescriptionKey:
            "Device session stopped before reaching started state. The glasses may have disconnected from Meta AI."]
        )
      }
    }

    throw NSError(
      domain: "WearablesCamera",
      code: 1002,
      userInfo: [NSLocalizedDescriptionKey: "Device session stateStream ended without becoming started."]
    )
  }

  private func ensureStreamSession(_ deviceSession: DeviceSession) async throws -> StreamSession {
    if let stream = streamSession {
      if stream.state == .streaming {
        return stream
      }

      if stream.state != .stopped {
        NSLog("♻️ [Wearables] Existing stream in state=%@ — attempting start",
              "\(stream.state)")
        if stream.state != .starting {
          await stream.start()
        }
        if try await waitForStreaming(stream) {
          return stream
        }
      }

      await stream.stop()
      streamSession = nil
      stateListenerToken = nil
      errorListenerToken = nil
      photoListenerToken = nil
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

    stateListenerToken = stream.statePublisher.listen { state in
      NSLog("📡 [Wearables] Stream state: %@", "\(state)")
    }
    errorListenerToken = stream.errorPublisher.listen { error in
      NSLog("⚠️ [Wearables] Stream error: %@", "\(error)")
    }

    await stream.start()

    let started = try await waitForStreaming(stream)
    if !started {
      throw NSError(
        domain: "WearablesCamera",
        code: 1003,
        userInfo: [NSLocalizedDescriptionKey: "Stream did not reach streaming state within 15s"]
      )
    }
    return stream
  }

  private func waitForStreaming(_ stream: StreamSession) async throws -> Bool {
    let timeoutSeconds: TimeInterval = 15
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

  private func capturePhotoData(from stream: StreamSession) async throws -> Data {
    let timeoutNs: UInt64 = 8_000_000_000

    return try await withCheckedThrowingContinuation { continuation in
      let lock = NSLock()
      var didFinish = false

      func finish(_ result: Result<Data, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        photoListenerToken = nil
        switch result {
        case .success(let data):
          NSLog("✅ [Wearables] Photo received: %d bytes", data.count)
          continuation.resume(returning: data)
        case .failure(let error):
          continuation.resume(throwing: error)
        }
      }

      photoListenerToken = stream.photoDataPublisher.listen { photoData in
        let data = photoData.data
        if data.isEmpty {
          finish(.failure(NSError(
            domain: "WearablesCamera",
            code: 1006,
            userInfo: [NSLocalizedDescriptionKey: "Photo data was empty"]
          )))
          return
        }
        finish(.success(data))
      }

      let accepted = stream.capturePhoto(format: .jpeg)
      if !accepted {
        finish(.failure(NSError(
          domain: "WearablesCamera",
          code: 1004,
          userInfo: [NSLocalizedDescriptionKey: "Photo capture rejected by stream"]
        )))
        return
      }

      Task {
        try await Task.sleep(nanoseconds: timeoutNs)
        finish(.failure(NSError(
          domain: "WearablesCamera",
          code: 1005,
          userInfo: [NSLocalizedDescriptionKey: "Photo capture timed out"]
        )))
      }
    }
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
        NSLog("⚠️ [Wearables] startRegistration failed: domain=%@ code=%d",
              nsErr.domain, nsErr.code)
        rejecter("REGISTRATION", nsErr.localizedDescription, nsErr)
      }
    }
  }

  @objc func getStatus(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    if let stream = streamSession {
      switch stream.state {
      case .streaming:
        resolver("connected"); return
      case .paused, .waitingForDevice, .starting, .stopping, .stopped:
        // fall through to device-list check
        break
      @unknown default:
        resolver("unknown"); return
      }
    }
    // No active stream — but glasses may still be visible in the SDK.
    // Surface that as "disconnected" with a hint we have devices in cache.
    if !availableDevices.isEmpty {
      resolver("disconnected")
    } else {
      resolver("disconnected")
    }
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
        let deviceSession = try await self.ensureDeviceSession(wearables)
        let stream = try await self.ensureStreamSession(deviceSession)
        let data = try await self.capturePhotoData(from: stream)
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
        let deviceSession = try await self.ensureDeviceSession(wearables)
        _ = try await self.ensureStreamSession(deviceSession)
        NSLog("✅ [Wearables] preWarm complete — session streaming")
        resolver(["success": true])
      } catch {
        let nsErr = error as NSError
        NSLog("⚠️ [Wearables] preWarm failed: %@", nsErr.localizedDescription)
        rejecter("PREWARM", nsErr.localizedDescription, nsErr)
      }
    }
  }

  /// Tear down stream + device session so the next toggle-ON starts fresh.
  /// Critical: without this, a half-failed previous attempt leaves a
  /// `streamSession` or `deviceSession` reference behind that's in an
  /// indeterminate state, and `ensureStreamSession`'s "if state != .stopped
  /// reuse it" branch hands back a dead session to the next capture call.
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
      self.stateListenerToken = nil
      self.errorListenerToken = nil
      self.photoListenerToken = nil
      // DeviceSession has no public stop on this SDK version — drop the
      // reference and let the SDK reclaim it on the next createSession.
      self.deviceSession = nil
      NSLog("🧹 [Wearables] disconnect complete")
      resolver(["success": true])
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  deinit {
    devicesObserverTask?.cancel()
    registrationObserverTask?.cancel()
    stateListenerToken = nil
    errorListenerToken = nil
    photoListenerToken = nil
  }
}
