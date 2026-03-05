// ReachingModule.swift — React Native Bridge
// ARKit Reaching v13

import Foundation
import AVFoundation
import UIKit

@objc(ReachingModule)
class ReachingModule: NSObject {

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

    var backendDepth: Float? = nil
    if let d = params["depth"] {
      var rawValue: Float? = nil
      if let n = d as? NSNumber { rawValue = n.floatValue }
      else if let s = d as? String, let v = Float(s) { rawValue = v }
      if var v = rawValue, v > 0 {
        if v > 10 { v = v / 100.0 }
        if v >= 0.1 && v <= 5.0 { backendDepth = v }
      }
    }
    NSLog("🎯 [ReachingModule] depth from backend: %@", backendDepth.map { "\($0)m" } ?? "nil")

    var imgW: CGFloat = 0, imgH: CGFloat = 0
    if let w = params["imageWidth"] as? NSNumber  { imgW = CGFloat(w.doubleValue) }
    if let h = params["imageHeight"] as? NSNumber { imgH = CGFloat(h.doubleValue) }

    let status = AVCaptureDevice.authorizationStatus(for: .video)
    let launch = { [weak self] in
      self?.presentReachingVC(bbox: bbox, objectName: objectName,
                              depth: backendDepth, imageW: imgW, imageH: imgH,
                              resolver: resolver, rejecter: rejecter)
    }
    if status == .authorized { launch() }
    else if status == .notDetermined {
      AVCaptureDevice.requestAccess(for: .video) { ok in
        if ok { launch() } else { rejecter("CAM", "Camera denied", nil) }
      }
    } else { rejecter("CAM", "Camera not authorized", nil) }
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

  private func presentReachingVC(
    bbox: [CGFloat], objectName: String, depth: Float?,
    imageW: CGFloat, imageH: CGFloat,
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
                                   resolver: resolver, rejecter: rejecter)
          }
        }
        return
      }
      let vc = ReachingViewController(
        bboxRaw: bbox, objectName: objectName, backendDepth: depth,
        imageWidth: imageW, imageHeight: imageH,
        onDone: { result in resolver(result) }
      )
      vc.modalPresentationStyle = .fullScreen
      top.present(vc, animated: true)
    }
  }
}
