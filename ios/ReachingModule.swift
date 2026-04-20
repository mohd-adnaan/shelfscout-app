// ReachingModule.swift — React Native Bridge
// ARKit Reaching v10 — 2D Progressive Re-detection

import Foundation
import AVFoundation
import UIKit

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
    NSLog("🎯 [ReachingModule] depth from backend: %@", backendDepth.map { "\($0)m" } ?? "nil")

    var imgW: CGFloat = 0, imgH: CGFloat = 0
    if let w = params["imageWidth"] as? NSNumber  { imgW = CGFloat(w.doubleValue) }
    if let h = params["imageHeight"] as? NSNumber { imgH = CGFloat(h.doubleValue) }

    let detectionUrl = params["detectionUrl"] as? String
    let acquisitionUrl = params["acquisitionUrl"] as? String
    let sessionId = params["sessionId"] as? String

    let status = AVCaptureDevice.authorizationStatus(for: .video)
    let launch = { [weak self] in
      self?.presentReachingVC(bbox: bbox, objectName: objectName,
                              depth: backendDepth, imageW: imgW, imageH: imgH,
                              detectionUrl: detectionUrl,
                              acquisitionUrl: acquisitionUrl,
                              sessionId: sessionId,
                              mode: mode,
                              startupSilent: startupSilent,
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
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true)
      try session.overrideOutputAudioPort(.speaker)
      NSLog("🔊 [ReachingModule] Audio session configured for playback (speaker, active)")
      resolver(["success": true])
    } catch {
      NSLog("⚠️ [ReachingModule] configurePlaybackSession error: %@", error.localizedDescription)
      // Non-fatal — audio will still play, just possibly quieter
      resolver(["success": false, "error": error.localizedDescription])
    }
  }

  private func presentReachingVC(
    bbox: [CGFloat], objectName: String, depth: Float?,
    imageW: CGFloat, imageH: CGFloat,
    detectionUrl: String?,
    acquisitionUrl: String?,
    sessionId: String?,
    mode: ReachingViewController.ReachingMode,
    startupSilent: Bool,
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
            self.presentReachingVC(bbox: bbox, objectName: objectName, depth: depth,
                                   imageW: imageW, imageH: imageH,
                                   detectionUrl: detectionUrl,
                                   acquisitionUrl: acquisitionUrl,
                                   sessionId: sessionId,
                                   mode: mode,
                                   startupSilent: startupSilent,
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
        mode: mode,
        startupSilent: startupSilent,
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