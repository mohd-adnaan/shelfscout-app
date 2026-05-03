// WearablesCameraModule.swift
// React Native bridge for Meta Wearables Device Access Toolkit (iOS)

import Foundation
import MWDATCore
import MWDATCamera

@objc(WearablesCameraModule)
class WearablesCameraModule: NSObject {
  private var wearables: WearablesInterface?
  private var deviceSession: DeviceSession?
  private var streamSession: StreamSession?

  private var stateListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoListenerToken: AnyListenerToken?

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  private func ensureConfigured() throws -> WearablesInterface {
    if let wearables = wearables { return wearables }
    // SDK is already configured by AppDelegate. Don't double-configure.
    let instance = Wearables.shared
    wearables = instance
    return instance
}

  private func ensureCameraPermission(_ wearables: WearablesInterface) async throws {
    var status = try await wearables.checkPermissionStatus(.camera)
    if status != .granted {
      status = try await wearables.requestPermission(.camera)
    }
    if status != .granted {
      throw NSError(
        domain: "WearablesCamera",
        code: 1001,
        userInfo: [NSLocalizedDescriptionKey: "Camera permission denied"]
      )
    }
  }

  private func ensureDeviceSession(_ wearables: WearablesInterface) async throws -> DeviceSession {
    if let session = deviceSession, session.state == .started {
      return session
    }

    if deviceSession?.state == .stopped {
      deviceSession = nil
    }

    let selector = AutoDeviceSelector(wearables: wearables)
    let session = try wearables.createSession(deviceSelector: selector)
    deviceSession = session

    let stateStream = session.stateStream()
    try session.start()

    for await state in stateStream {
      if state == .started {
        return session
      }
      if state == .stopped {
        break
      }
    }

    throw NSError(
      domain: "WearablesCamera",
      code: 1002,
      userInfo: [NSLocalizedDescriptionKey: "Device session failed to start"]
    )
  }

  private func ensureStreamSession(_ deviceSession: DeviceSession) async throws -> StreamSession {
    if let stream = streamSession {
      if stream.state != .stopped {
        return stream
      }
      streamSession = nil
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
        userInfo: [NSLocalizedDescriptionKey: "Stream did not reach streaming state"]
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
      case .streaming:
        return true
      case .stopped:
        return false
      default:
        break
      }
      try await Task.sleep(nanoseconds: pollIntervalNs)
    }

    return false
  }

  private func capturePhotoData(from stream: StreamSession) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      photoListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
        self?.photoListenerToken = nil
        continuation.resume(returning: photoData.data)
      }

      let accepted = stream.capturePhoto(format: .jpeg)
      if !accepted {
        photoListenerToken = nil
        continuation.resume(
          throwing: NSError(
            domain: "WearablesCamera",
            code: 1004,
            userInfo: [NSLocalizedDescriptionKey: "Photo capture rejected"]
          )
        )
      }
    }
  }

  private func writePhotoData(_ data: Data) throws -> String {
    let filename = "wearables-\(UUID().uuidString).jpg"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    try data.write(to: url, options: .atomic)
    return url.absoluteString
  }

  // MARK: - React Native exposed methods

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
        // RegistrationError 0 = already registered. This is not an error.
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
        resolver("connected")
      case .paused, .waitingForDevice, .starting, .stopping:
        resolver("disconnected")
      case .stopped:
        resolver("disconnected")
      @unknown default:
        resolver("unknown")
      }
      return
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
        let data = try await self.capturePhotoData(from: stream)
        let path = try self.writePhotoData(data)
        resolver(path)
      } catch {
        rejecter("CAPTURE", error.localizedDescription, error)
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
        NSLog("⚠️ [Wearables] preWarm failed: %@", error.localizedDescription)
        rejecter("PREWARM", error.localizedDescription, error as NSError)
      }
    }
  }
}

