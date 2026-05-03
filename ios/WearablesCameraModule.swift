// WearablesCameraModule.swift
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
  }

  private func createSessionWithFallback(_ wearables: WearablesInterface) throws -> DeviceSession {
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

    let haveDevice = try await waitForDevice(timeoutSeconds: 12)
    if !haveDevice {
      throw NSError(
        domain: "WearablesCamera",
        code: 1010,
        userInfo: [NSLocalizedDescriptionKey:
          "No glasses visible to the SDK. Make sure the Meta AI app is open and glasses are paired in Meta AI."]
      )
    }

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
          "Glasses paired but not allowed to share camera. In Meta AI app: open your glasses card → Settings → Connected apps → enable Camera for ShelfScout."]
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
          userInfo: [NSLocalizedDescriptionKey: "Device session stopped before becoming started."]
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
    if let stream = streamSession, stream.state != .stopped {
      return stream
    }
    streamSession = nil
    latestVideoFrame = nil

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