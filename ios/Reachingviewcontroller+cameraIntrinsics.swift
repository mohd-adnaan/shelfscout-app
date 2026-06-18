//
//  Reachingviewcontroller+cameraIntrinsics.swift
//  shelfscout
//
//  Camera intrinsic matrix payloads for backend depth containers.
//

import ARKit
import Foundation
import UIKit

extension ReachingViewController {

  /// Builds a JSON-safe intrinsics payload for the JPEG sent to the backend.
  ///
  /// ARKit exposes `camera.intrinsics` in the landscape-native coordinates of
  /// `frame.capturedImage`. The reaching pipeline rotates that frame to portrait
  /// with `.right` and may resize it before upload, so this returns K in the
  /// uploaded image's coordinate space and keeps the raw ARKit K alongside it.
  func cameraIntrinsicsPayload(frame: ARFrame, outputImageSize: CGSize) -> [String: Any] {
    let camera = frame.camera
    let intrinsics = camera.intrinsics
    let imageResolution = camera.imageResolution

    let rawWidth = Double(imageResolution.width)
    let rawHeight = Double(imageResolution.height)
    let outputWidth = Double(outputImageSize.width)
    let outputHeight = Double(outputImageSize.height)

    let rawFx = Double(intrinsics[0][0])
    let rawFy = Double(intrinsics[1][1])
    let rawCx = Double(intrinsics[2][0])
    let rawCy = Double(intrinsics[2][1])

    let scaleX = rawHeight > 0 ? outputWidth / rawHeight : 1.0
    let scaleY = rawWidth > 0 ? outputHeight / rawWidth : 1.0

    // Portrait-right mapping used by the JPEG upload:
    //   portrait x = raw landscape height - raw y
    //   portrait y = raw landscape x
    let fx = rawFy * scaleX
    let fy = rawFx * scaleY
    let cx = (rawHeight - rawCy) * scaleX
    let cy = rawCx * scaleY

    let k: [[Double]] = [
      [fx, 0.0, cx],
      [0.0, fy, cy],
      [0.0, 0.0, 1.0],
    ]
    let rawK: [[Double]] = [
      [rawFx, 0.0, rawCx],
      [0.0, rawFy, rawCy],
      [0.0, 0.0, 1.0],
    ]

    return [
      "schema": "shelfscout.camera_intrinsics.v1",
      "source": "ARFrame.camera.intrinsics",
      "orientation": "portrait-right",
      "image_width": outputWidth,
      "image_height": outputHeight,
      "fx": fx,
      "fy": fy,
      "cx": cx,
      "cy": cy,
      "K": k,
      "K_row_major": [fx, 0.0, cx, 0.0, fy, cy, 0.0, 0.0, 1.0],
      "raw_landscape": [
        "image_width": rawWidth,
        "image_height": rawHeight,
        "fx": rawFx,
        "fy": rawFy,
        "cx": rawCx,
        "cy": rawCy,
        "K": rawK,
        "K_row_major": [rawFx, 0.0, rawCx, 0.0, rawFy, rawCy, 0.0, 0.0, 1.0],
      ],
    ]
  }

  func cameraIntrinsicsJson(frame: ARFrame, outputImageSize: CGSize) -> String? {
    let payload = cameraIntrinsicsPayload(frame: frame, outputImageSize: outputImageSize)
    guard JSONSerialization.isValidJSONObject(payload),
          let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func cameraIntrinsicMatrixJson(frame: ARFrame, outputImageSize: CGSize) -> String? {
    let payload = cameraIntrinsicsPayload(frame: frame, outputImageSize: outputImageSize)
    guard let matrix = payload["K"],
          JSONSerialization.isValidJSONObject(matrix),
          let data = try? JSONSerialization.data(withJSONObject: matrix, options: []) else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func appendCameraIntrinsicsFields(
    _ appendField: (String, String) -> Void,
    frame: ARFrame,
    outputImageSize: CGSize
  ) {
    let payload = cameraIntrinsicsPayload(frame: frame, outputImageSize: outputImageSize)

    if let json = cameraIntrinsicsJson(frame: frame, outputImageSize: outputImageSize) {
      appendField("camera_intrinsics", json)
      appendField("camera_intrinsics_json", json)
    }
    if let matrixJson = cameraIntrinsicMatrixJson(frame: frame, outputImageSize: outputImageSize) {
      appendField("K", matrixJson)
      appendField("camera_intrinsic_matrix", matrixJson)
    }

    for key in ["fx", "fy", "cx", "cy"] {
      if let value = payload[key] as? Double {
        appendField(key, String(value))
        appendField("camera_\(key)", String(value))
      }
    }
  }

  func bodyAddingCameraIntrinsics(
    _ body: [String: Any],
    frame: ARFrame,
    outputImageSize: CGSize
  ) -> [String: Any] {
    var next = body
    let payload = cameraIntrinsicsPayload(frame: frame, outputImageSize: outputImageSize)
    next["camera_intrinsics"] = payload
    next["K"] = payload["K"]
    next["camera_intrinsic_matrix"] = payload["K"]
    next["fx"] = payload["fx"]
    next["fy"] = payload["fy"]
    next["cx"] = payload["cx"]
    next["cy"] = payload["cy"]
    next["camera_fx"] = payload["fx"]
    next["camera_fy"] = payload["fy"]
    next["camera_cx"] = payload["cx"]
    next["camera_cy"] = payload["cy"]
    return next
  }
}
