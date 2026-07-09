// ReachingModule.swift — React Native Bridge
// ARKit Reaching v10 — 2D Progressive Re-detection

import Foundation
import AVFoundation
import AudioToolbox
import UIKit
import ARKit

@objc(ReachingModule)
class ReachingModule: NSObject {

  /// Static reference to active VC so updateBbox can reach it
  static weak var activeVC: ReachingViewController?

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  @objc func startReaching(
    _ params: NSDictionary,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    NSLog("🎯 [ReachingModule] startReaching params: %@", params)

    var bbox: [CGFloat] = []
    if let raw = params["bbox"] {
      if let arr = raw as? [NSNumber] {
        bbox = arr.map { CGFloat($0.doubleValue) }
      } else if let arr = raw as? [Any] {
        bbox = arr.compactMap { v -> CGFloat? in
          if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
          if let s = v as? String, let d = Double(s) { return CGFloat(d) }
          return nil
        }
      }
    }
    guard bbox.count == 4 else {
      rejecter("BAD_BBOX", "bbox needs 4 values, got \(bbox.count)", nil)
      return
    }
    let objectName = (params["object"] as? String) ?? "object"

    // Parse reaching mode: handFree (default) or withHand
    let modeStr = (params["mode"] as? String) ?? "handFree"
    let mode: ReachingViewController.ReachingMode = modeStr == "withHand" ? .withHand : .handFree
    NSLog("🎯 [ReachingModule] mode: %@", mode.rawValue)

    // Parse TTS rate from user's app settings (0.1-1.0, default 0.5)
    let ttsRate: Float = (params["ttsRate"] as? NSNumber)?.floatValue ?? 0.5

    // Parse distance unit preference: "steps" (default) or "cm"
    let distanceUnit = (params["distanceUnit"] as? String) ?? "steps"
    let startupSilent = (params["startupSilent"] as? Bool) ?? false
    let voiceOverEnabled = (params["voiceOverEnabled"] as? Bool) ?? UIAccessibility.isVoiceOverRunning

    var backendDepth: Float? = nil
    if let d = params["depth"] {
      var rawValue: Float? = nil
      if let n = d as? NSNumber { rawValue = n.floatValue }
      else if let s = d as? String, let v = Float(s) { rawValue = v }
      if var v = rawValue, v > 0 {
        if v > 10 { v = v / 100.0 }
        if v >= 0.1 && v <= 10.0 { backendDepth = v }
      }
    }
    NSLog("🎯 [ReachingModule] depth from backend (RELATIVE, not used for metric placement): %@", backendDepth.map { "\($0)" } ?? "nil")

    var imgW: CGFloat = 0, imgH: CGFloat = 0
    if let w = params["imageWidth"] as? NSNumber  { imgW = CGFloat(w.doubleValue) }
    if let h = params["imageHeight"] as? NSNumber { imgH = CGFloat(h.doubleValue) }

    let detectionUrl = params["detectionUrl"] as? String
    let acquisitionUrl = params["acquisitionUrl"] as? String
    let sessionId = params["sessionId"] as? String

    let status = AVCaptureDevice.authorizationStatus(for: .video)
    let launch = {
      ReachingModule.presentReachingVC(bbox: bbox, objectName: objectName,
                                       depth: backendDepth, imageW: imgW, imageH: imgH,
                                       detectionUrl: detectionUrl,
                                       acquisitionUrl: acquisitionUrl,
                                       sessionId: sessionId,
                                       mode: mode,
                                       startupSilent: startupSilent,
                                       voiceOverEnabled: voiceOverEnabled,
                                       ttsRate: ttsRate, distanceUnit: distanceUnit,
                                       resolver: resolver, rejecter: rejecter)
    }
    if status == .authorized { launch() }
    else if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { ok in
        if ok { launch() } else { rejecter("CAM", "Camera denied", nil) }
      }
    } else { rejecter("CAM", "Camera not authorized", nil) }
  }

  @objc func startSpatialTargetReaching(
    _ params: NSDictionary,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    NSLog("◎ [ReachingModule] startSpatialTargetReaching params: %@", params)

    let targetName = ((params["targetName"] as? String) ?? "target")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    var targetRegion: [CGFloat] = [0.42, 0.38, 0.58, 0.62]
    if let raw = params["targetRegion"] {
      var parsed: [CGFloat] = []
      if let arr = raw as? [NSNumber] {
        parsed = arr.map { CGFloat($0.doubleValue) }
      } else if let arr = raw as? [Any] {
        parsed = arr.compactMap { v -> CGFloat? in
          if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
          if let s = v as? String, let d = Double(s) { return CGFloat(d) }
          return nil
        }
      }
      if parsed.count == 4 {
        targetRegion = parsed.map { min(max($0, 0), 1) }
      }
    }

    let modeStr = (params["mode"] as? String) ?? "handFree"
    let mode: ReachingViewController.ReachingMode = modeStr == "withHand" ? .withHand : .handFree

    ReachingModule.launchSpatialTargetReaching(
      targetName: targetName,
      routeMapId: (params["routeMapId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
      routeMapName: params["routeMapName"] as? String,
      targetWorldPosition: Self.parseWorldPosition(params["targetWorldPosition"]),
      targetRegion: targetRegion,
      mode: mode,
      startupSilent: (params["startupSilent"] as? Bool) ?? false,
      voiceOverEnabled: (params["voiceOverEnabled"] as? Bool) ?? UIAccessibility.isVoiceOverRunning,
      ttsRate: (params["ttsRate"] as? NSNumber)?.floatValue ?? 0.5,
      distanceUnit: (params["distanceUnit"] as? String) ?? "steps",
      sessionId: params["sessionId"] as? String,
      onFailure: { code, message, error in
        rejecter(code, message, error)
      },
      onDone: { result in
        resolver(result)
      }
    )
  }

  /// Shared spatial-target launcher. The RN bridge method above and native
  /// callers (ARKit navigation's arrival handoff) both come through here so
  /// map resolution, permission handling, and presentation stay identical.
  static func launchSpatialTargetReaching(
    targetName rawTargetName: String,
    routeMapId: String? = nil,
    routeMapName: String? = nil,
    targetWorldPosition: simd_float3? = nil,
    targetRegion: [CGFloat] = [0.42, 0.38, 0.58, 0.62],
    mode: ReachingViewController.ReachingMode = .handFree,
    startupSilent: Bool = false,
    voiceOverEnabled: Bool = UIAccessibility.isVoiceOverRunning,
    ttsRate: Float = 0.5,
    distanceUnit: String = "steps",
    sessionId: String? = nil,
    onFailure: @escaping (_ code: String, _ message: String, _ error: Error?) -> Void,
    onDone: @escaping ([String: Any]) -> Void
  ) {
    let targetName = rawTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !targetName.isEmpty else {
      onFailure("BAD_TARGET", "targetName is required for spatial target reaching", nil)
      return
    }

    var resolvedWorldMap: ARWorldMap?
    var resolvedTargetPosition: simd_float3? = targetWorldPosition
    var resolvedMapName: String? = routeMapName
    var resolvedIsSurfacePlacement = targetWorldPosition != nil
    var resolvedPOIName: String? = nil

    do {
      if resolvedTargetPosition == nil || resolvedWorldMap == nil {
        let mapContext = try resolveMapTarget(
          targetName: targetName,
          routeMapId: routeMapId,
          routeMapName: routeMapName
        )
        resolvedWorldMap = mapContext.worldMap
        if resolvedTargetPosition == nil {
          resolvedTargetPosition = mapContext.targetPosition
        }
        // The stored POI record knows how the pin was actually placed
        // (surface raycast vs camera-pose fallback). The caller passing an
        // explicit position doesn't change that — the seed above
        // (`targetWorldPosition != nil` → surface) was mislabeling legacy
        // camera-pose pins as surface pins, which gave them tight extents
        // and skipped the "saved spot near X" caveat.
        resolvedIsSurfacePlacement = mapContext.isSurfacePlacement
        resolvedMapName = mapContext.mapName
        resolvedPOIName = mapContext.poiName
      }
    } catch {
      if routeMapId?.isEmpty == false || (routeMapName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
        onFailure("TARGET_NOT_IN_MAP", error.localizedDescription, error)
        return
      }
      NSLog("◎ [ReachingModule] Spatial target map lookup skipped/fallback: %@", error.localizedDescription)
    }

    if resolvedTargetPosition != nil && resolvedWorldMap == nil {
      onFailure(
        "MAP_NOT_FOUND",
        "Spatial Target has a saved target position but no ARWorldMap to relocalize against.",
        nil
      )
      return
    }

    NSLog(
      "◎ [ReachingModule] Spatial target=%@ map=%@ world=%@ placement=%@ region=[%.2f,%.2f,%.2f,%.2f] mode=%@",
      targetName,
      resolvedMapName ?? "current",
      resolvedTargetPosition.map { String(format: "(%.2f,%.2f,%.2f)", $0.x, $0.y, $0.z) } ?? "nil",
      resolvedIsSurfacePlacement ? "surface" : "camera_pose(legacy)",
      targetRegion[0], targetRegion[1], targetRegion[2], targetRegion[3],
      mode.rawValue
    )

    let status = AVCaptureDevice.authorizationStatus(for: .video)
    let launch = {
      presentReachingVC(
        bbox: targetRegion,
        objectName: targetName,
        depth: nil,
        imageW: 1,
        imageH: 1,
        detectionUrl: nil,
        acquisitionUrl: nil,
        sessionId: sessionId,
        initialWorldMap: resolvedWorldMap,
        spatialTargetWorldPosition: resolvedTargetPosition,
        spatialTargetMapName: resolvedMapName,
        spatialTargetIsSurfacePlacement: resolvedIsSurfacePlacement,
        spatialTargetPOIName: resolvedPOIName,
        mode: mode,
        startupSilent: startupSilent,
        voiceOverEnabled: voiceOverEnabled,
        ttsRate: ttsRate,
        distanceUnit: distanceUnit,
        resolver: { result in onDone(result as? [String: Any] ?? [:]) },
        rejecter: { code, message, error in onFailure(code ?? "ERROR", message ?? "Reaching failed.", error) }
      )
    }
    if status == .authorized { launch() }
    else if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { ok in
        if ok { launch() } else { onFailure("CAM", "Camera denied", nil) }
      }
    } else { onFailure("CAM", "Camera not authorized", nil) }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Update Bbox (called from RN during progressive re-detection)
  // ═══════════════════════════════════════════════════════════════════════════

  @objc func updateBbox(
    _ params: NSDictionary,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    var bbox: [CGFloat] = []
    if let raw = params["bbox"] {
      if let arr = raw as? [NSNumber] {
        bbox = arr.map { CGFloat($0.doubleValue) }
      } else if let arr = raw as? [Any] {
        bbox = arr.compactMap { v -> CGFloat? in
          if let n = v as? NSNumber { return CGFloat(n.doubleValue) }
          if let s = v as? String, let d = Double(s) { return CGFloat(d) }
          return nil
        }
      }
    }
    guard bbox.count == 4 else {
      rejecter("BAD_BBOX", "updateBbox needs 4 values", nil); return
    }

    var imgW: CGFloat = 0, imgH: CGFloat = 0
    if let w = params["imageWidth"] as? NSNumber  { imgW = CGFloat(w.doubleValue) }
    if let h = params["imageHeight"] as? NSNumber { imgH = CGFloat(h.doubleValue) }

    var depth: Float? = nil
    if let d = params["depth"] {
      if let n = d as? NSNumber { depth = n.floatValue }
      else if let s = d as? String { depth = Float(s) }
    }

    NSLog("🔄 [ReachingModule] updateBbox: [%.0f,%.0f,%.0f,%.0f] img=%.0f×%.0f",
          bbox[0], bbox[1], bbox[2], bbox[3], imgW, imgH)

    DispatchQueue.main.async {
      if let vc = ReachingModule.activeVC, !vc.hasCompleted {
        vc.updateBboxFromBackend(newBbox: bbox, newImgW: imgW, newImgH: imgH, newDepth: depth)
        resolver(["success": true])
      } else {
        resolver(["success": false, "reason": "no_active_vc"])
      }
    }
  }

  @objc func stopReaching(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard let root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        resolver(["success": false, "reason": "no_vc"]); return
      }
      var top = root; while let p = top.presentedViewController { top = p }
      if top is ReachingViewController {
        top.dismiss(animated: true) { resolver(["success": false, "reason": "user_cancelled"]) }
      } else { resolver(["success": false, "reason": "not_active"]) }
    }
  }

  @objc func enableGuidanceAudio(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard let vc = ReachingModule.activeVC, !vc.hasCompleted else {
        resolver(["success": false, "reason": "no_active_vc"])
        return
      }
      vc.enableGuidanceAudio()
      resolver(["success": true])
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Audio Session Configuration
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // After @react-native-voice/voice runs, the iOS audio session is left in
  // Record+Measurement mode (deactivated). react-native-sound's setCategory
  // only calls [session setCategory:error:] — it never calls setActive:YES
  // or sets the mode/options explicitly. This produces noticeably lower
  // volume on the RN side compared to the native reaching pipeline which
  // calls setCategory(.playback, mode:.default, options:[]) + setActive(true).
  //
  // This method mirrors the reaching pipeline's audio session config so
  // all RN audio (earcons + TTS) plays at the same level.
  // ═══════════════════════════════════════════════════════════════════════════

  @objc func configurePlaybackSession(
    _ useSpeaker: NSNumber?,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    do {
      let shouldUseSpeaker = useSpeaker?.boolValue ?? true
      let session = AVAudioSession.sharedInstance()

      if shouldUseSpeaker {
        // Force phone speaker — requires .playAndRecord + .defaultToSpeaker.
        // overrideOutputAudioPort(.speaker) on .playback throws OSStatus -50.
        try session.setCategory(
          .playAndRecord,
          mode: .default,
          options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        NSLog("🔊 [ReachingModule] Audio → playAndRecord + speaker")
      } else {
        // Let iOS route to the active Bluetooth sink (Ray-Bans).
        // No port override — .playback routes via system route automatically.
        try session.setCategory(
          .playback,
          mode: .default,
          options: [.allowBluetoothA2DP]
        )
        try session.setActive(true)
        NSLog("🔊 [ReachingModule] Audio → playback (Bluetooth)")
      }
      resolver(["success": true])
    } catch {
      NSLog("⚠️ [ReachingModule] configurePlaybackSession error: %@", error.localizedDescription)
      resolver(["success": false, "error": error.localizedDescription])
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Bluetooth Recording Session (Meta Glasses Mic)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Configures the audio session for recording via the Bluetooth HFP
  // microphone (Meta Ray-Ban glasses). The critical option is .allowBluetooth
  // which enables the Hands-Free Profile mic input. Without this option,
  // iOS defaults to the phone's built-in mic.
  //
  // Note: .allowBluetooth ≠ .allowBluetoothA2DP:
  //   .allowBluetooth  → enables HFP (mic input + mono output)
  //   .allowBluetoothA2DP → enables A2DP (stereo output only, no mic)
  //
  // For wake-word listening, we want .allowBluetooth so the speech
  // recognizer receives audio from the glasses' mic.
  // ═══════════════════════════════════════════════════════════════════════════

  private enum RecordingMicrophoneSource: String {
    case wearables
    case phone
  }

  private func ensureMicrophonePermission() async -> Bool {
    let session = AVAudioSession.sharedInstance()

    switch session.recordPermission {
    case .granted:
      return true
    case .denied:
      return false
    case .undetermined:
      return await withCheckedContinuation { continuation in
        session.requestRecordPermission { granted in
          continuation.resume(returning: granted)
        }
      }
    @unknown default:
      return false
    }
  }

  private func isLikelyMetaGlassesInput(_ input: AVAudioSessionPortDescription) -> Bool {
    let name = input.portName.lowercased()
    return name.contains("meta") ||
           name.contains("ray-ban") ||
           name.contains("rayban") ||
           name.contains("ray ban") ||
           name.contains("glasses")
  }

  private func inputPayload(_ inputs: [AVAudioSessionPortDescription]) -> [[String: String]] {
    return inputs.map { input in
      [
        "portName": input.portName,
        "portType": input.portType.rawValue,
      ]
    }
  }

  private func configureRecordingSession(
    preferredSource: RecordingMicrophoneSource
  ) async throws -> [String: Any] {
    guard await ensureMicrophonePermission() else {
      throw NSError(
        domain: "ReachingModule",
        code: 2001,
        userInfo: [NSLocalizedDescriptionKey:
          "Microphone permission denied. Enable microphone access for ShelfScout in iOS Settings."]
      )
    }

    let session = AVAudioSession.sharedInstance()
    var selectedSource = preferredSource.rawValue
    var fallbackReason: String?
    var preferredInput: AVAudioSessionPortDescription?

    switch preferredSource {
    case .wearables:
      // .allowBluetooth enables the HFP microphone. We then explicitly select
      // the HFP input because iOS may otherwise keep the built-in iPhone mic.
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.allowBluetooth]
      )
      try session.setActive(true)

      let inputs = session.availableInputs ?? []
      let hfpInputs = inputs.filter { $0.portType == .bluetoothHFP }

      if let metaInput = hfpInputs.first(where: isLikelyMetaGlassesInput) {
        preferredInput = metaInput
      } else if let bluetoothInput = hfpInputs.first {
        preferredInput = bluetoothInput
        fallbackReason = "No Meta-named Bluetooth microphone was advertised; using the available Bluetooth HFP microphone."
      } else {
        selectedSource = RecordingMicrophoneSource.phone.rawValue
        preferredInput = inputs.first { $0.portType == .builtInMic }
        fallbackReason = "No Bluetooth HFP microphone is available; using the iPhone microphone."
      }

      if let preferredInput {
        try session.setPreferredInput(preferredInput)
      }

    case .phone:
      // Omit .allowBluetooth so the recognizer uses the local iPhone mic even
      // when glasses or another headset are connected.
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: []
      )
      try session.setActive(true)

      let inputs = session.availableInputs ?? []
      preferredInput = inputs.first { $0.portType == .builtInMic }
      if let preferredInput {
        try session.setPreferredInput(preferredInput)
      } else {
        try session.setPreferredInput(nil)
        fallbackReason = "Built-in microphone was not advertised; using the system-selected input."
      }
    }

    try session.setActive(true)
    try? await Task.sleep(nanoseconds: 100_000_000)

    let input = session.currentRoute.inputs.first ?? preferredInput
    let output = session.currentRoute.outputs.first
    let availableInputs = session.availableInputs ?? []

    NSLog("🎤 [ReachingModule] Recording → requested=%@ selected=%@ input=%@ (%@), output=%@ (%@)",
          preferredSource.rawValue,
          selectedSource,
          input?.portName ?? "none",
          input?.portType.rawValue ?? "?",
          output?.portName ?? "none",
          output?.portType.rawValue ?? "?")

    var payload: [String: Any] = [
      "success": true,
      "requestedSource": preferredSource.rawValue,
      "source": selectedSource,
      "inputPort": input?.portName ?? "unknown",
      "inputType": input?.portType.rawValue ?? "unknown",
      "availableInputs": inputPayload(availableInputs),
    ]

    if let fallbackReason {
      payload["fallbackReason"] = fallbackReason
    }

    return payload
  }

  @objc func configureBluetoothRecordingSession(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    configureRecordingSession("wearables" as NSString, resolver: resolver, rejecter: rejecter)
  }

  @objc func configureRecordingSession(
    _ preferredSource: NSString,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    let source = RecordingMicrophoneSource(rawValue: preferredSource as String) ?? .wearables

    Task { [weak self] in
      guard let self else { return }
      do {
        let payload = try await self.configureRecordingSession(preferredSource: source)
        resolver(payload)
      } catch {
        NSLog("❌ [ReachingModule] configureRecordingSession error: %@", error.localizedDescription)
        resolver([
          "success": false,
          "requestedSource": source.rawValue,
          "source": "phone",
          "inputPort": "unknown",
          "inputType": "unknown",
          "fallbackReason": error.localizedDescription,
        ])
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - System Shutter Sound
  // ═══════════════════════════════════════════════════════════════════════════
  // Plays the native iOS camera shutter sound (SystemSoundID 1108).
  // This matches the default iPhone Camera sound and respects system policies.
  @objc func playSystemShutter(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    AudioServicesPlaySystemSound(1108)
    resolver(["success": true])
  }

  @objc func prewarmDAv2(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      prewarmDepthAnythingV2Model()
      resolver(["success": true])
    }
  }

  private struct SpatialTargetMapContext {
    let worldMap: ARWorldMap
    let targetPosition: simd_float3
    let mapName: String
    let isSurfacePlacement: Bool
    /// Exact name of the POI anchor pinned inside the ARWorldMap — the
    /// reaching session uses it to find the RESTORED ARAnchor after
    /// relocalization instead of trusting the stored raw coordinate.
    let poiName: String
  }

  private static func resolveMapTarget(
    targetName: String,
    routeMapId: String?,
    routeMapName: String?
  ) throws -> SpatialTargetMapContext {
    let store = ARMapStore()
    let summaries = store.loadSummaries()
    let trimmedMapId = routeMapId?.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedMapName = routeMapName?.trimmingCharacters(in: .whitespacesAndNewlines)

    let selectedSummary: ARStoredMapSummary?
    if let trimmedMapId, !trimmedMapId.isEmpty {
      selectedSummary = summaries.first { $0.id == trimmedMapId }
    } else if let trimmedMapName, !trimmedMapName.isEmpty {
      selectedSummary = summaries.first {
        $0.name.caseInsensitiveCompare(trimmedMapName) == .orderedSame
      }
    } else {
      selectedSummary = summaries.first { summary in
        guard let loaded = try? store.load(id: summary.id) else { return false }
        return bestPOI(named: targetName, in: loaded.metadata.pois) != nil
      }
    }

    guard let selectedSummary else {
      throw NSError(
        domain: "ReachingModule",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "No saved AR map was found for Spatial Target reaching."]
      )
    }

    let loaded = try store.load(id: selectedSummary.id)
    guard let poi = bestPOI(named: targetName, in: loaded.metadata.pois) else {
      throw NSError(
        domain: "ReachingModule",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "\(targetName) is not pinned in \(loaded.metadata.name). Pin it as a POI and save the AR map first."]
      )
    }

    return SpatialTargetMapContext(
      worldMap: loaded.worldMap,
      targetPosition: poi.position.simdValue,
      mapName: loaded.metadata.name,
      isSurfacePlacement: poi.isSurfacePlacement,
      poiName: poi.name
    )
  }

  private static func bestPOI(named targetName: String, in pois: [ARStoredPOI]) -> ARStoredPOI? {
    let targetKey = normalizedLookupKey(targetName)
    guard !targetKey.isEmpty else { return nil }

    if let exact = pois.first(where: { normalizedLookupKey($0.name) == targetKey }) {
      return exact
    }

    let targetTokens = Set(targetKey.split(separator: " ").map(String.init))
    return pois
      .map { poi -> (poi: ARStoredPOI, score: Int) in
        let poiTokens = Set(normalizedLookupKey(poi.name).split(separator: " ").map(String.init))
        return (poi, targetTokens.intersection(poiTokens).count)
      }
      .filter { $0.score > 0 }
      .sorted { $0.score > $1.score }
      .first?
      .poi
  }

  private static func normalizedLookupKey(_ raw: String) -> String {
    raw
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "doorknob", with: "door knob")
      .replacingOccurrences(of: "doorhandle", with: "door handle")
      .replacingOccurrences(of: "_", with: " ")
      .replacingOccurrences(of: "-", with: " ")
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty && !["the", "a", "an", "room", "rm", "suite", "office"].contains($0) }
      .joined(separator: " ")
  }

  private static func parseWorldPosition(_ raw: Any?) -> simd_float3? {
    if let dict = raw as? [String: Any] {
      guard let x = floatValue(dict["x"]),
            let y = floatValue(dict["y"]),
            let z = floatValue(dict["z"]) else {
        return nil
      }
      return simd_make_float3(x, y, z)
    }

    if let arr = raw as? [Any], arr.count >= 3,
       let x = floatValue(arr[0]),
       let y = floatValue(arr[1]),
       let z = floatValue(arr[2]) {
      return simd_make_float3(x, y, z)
    }

    return nil
  }

  private static func floatValue(_ raw: Any?) -> Float? {
    if let number = raw as? NSNumber { return number.floatValue }
    if let string = raw as? String { return Float(string) }
    return nil
  }

  private static func presentReachingVC(
    bbox: [CGFloat], objectName: String, depth: Float?,
    imageW: CGFloat, imageH: CGFloat,
    detectionUrl: String?,
    acquisitionUrl: String?,
    sessionId: String?,
    initialWorldMap: ARWorldMap? = nil,
    spatialTargetWorldPosition: simd_float3? = nil,
    spatialTargetMapName: String? = nil,
    spatialTargetIsSurfacePlacement: Bool = true,
    spatialTargetPOIName: String? = nil,
    mode: ReachingViewController.ReachingMode,
    startupSilent: Bool,
    voiceOverEnabled: Bool,
    ttsRate: Float,
    distanceUnit: String,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.main.async {
      guard let root = UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
        rejecter("NO_VC", "No root VC", nil); return
      }
      var top = root; while let p = top.presentedViewController { top = p }
      if top is ReachingViewController {
        top.dismiss(animated: false) {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            presentReachingVC(bbox: bbox, objectName: objectName, depth: depth,
                                   imageW: imageW, imageH: imageH,
                                   detectionUrl: detectionUrl,
                                   acquisitionUrl: acquisitionUrl,
                                   sessionId: sessionId,
                                   initialWorldMap: initialWorldMap,
                                   spatialTargetWorldPosition: spatialTargetWorldPosition,
                                   spatialTargetMapName: spatialTargetMapName,
                                   spatialTargetIsSurfacePlacement: spatialTargetIsSurfacePlacement,
                                   spatialTargetPOIName: spatialTargetPOIName,
                                   mode: mode,
                                   startupSilent: startupSilent,
                                   voiceOverEnabled: voiceOverEnabled,
                                   ttsRate: ttsRate, distanceUnit: distanceUnit,
                                   resolver: resolver, rejecter: rejecter)
          }
        }
        return
      }
      let vc = ReachingViewController(
        bboxRaw: bbox, objectName: objectName, backendDepth: depth,
        imageWidth: imageW, imageHeight: imageH,
        detectionUrl: detectionUrl,
        acquisitionUrl: acquisitionUrl,
        sessionId: sessionId,
        initialWorldMap: initialWorldMap,
        spatialTargetWorldPosition: spatialTargetWorldPosition,
        spatialTargetMapName: spatialTargetMapName,
        spatialTargetIsSurfacePlacement: spatialTargetIsSurfacePlacement,
        spatialTargetPOIName: spatialTargetPOIName,
        mode: mode,
        startupSilent: startupSilent,
        voiceOverEnabled: voiceOverEnabled,
        ttsRate: ttsRate,
        distanceUnit: distanceUnit,
        onDone: { result in
          ReachingModule.activeVC = nil
          resolver(result)
        }
      )
      ReachingModule.activeVC = vc
      vc.modalPresentationStyle = .fullScreen
      top.present(vc, animated: true)
    }
  }
}
