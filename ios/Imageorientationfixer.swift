/**
 * ImageOrientationFixer.swift
 *
 */

import Foundation
import UIKit

@objc(ImageOrientationFixer)
class ImageOrientationFixer: NSObject {

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  /// Fix image orientation by applying EXIF rotation to pixel data.
  /// Input: path to JPEG file
  /// Output: path to orientation-corrected JPEG file
  @objc func fixOrientation(
    _ imagePath: String,
    maxDimension: Int,
    quality: Double,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    DispatchQueue.global(qos: .userInitiated).async {
      let cleanPath = imagePath.replacingOccurrences(of: "file://", with: "")

      guard let image = UIImage(contentsOfFile: cleanPath) else {
        rejecter("LOAD_FAILED", "Cannot load image at: \(cleanPath)", nil)
        return
      }

      NSLog("📐 [OrientationFix] Original: %.0f×%.0f, orientation=%d",
            image.size.width, image.size.height, image.imageOrientation.rawValue)

      // Apply orientation to pixel data
      let corrected = self.normalizeOrientation(image)

      // Optionally resize if too large
      let maxDim = CGFloat(maxDimension > 0 ? maxDimension : 2048)
      let resized = self.resizeIfNeeded(corrected, maxDimension: maxDim)

      NSLog("📐 [OrientationFix] Corrected: %.0f×%.0f (orientation=up)",
            resized.size.width, resized.size.height)

      // Save to temp file
      let qual = quality > 0 ? quality : 0.85
      guard let jpegData = resized.jpegData(compressionQuality: qual) else {
        rejecter("ENCODE_FAILED", "Failed to encode JPEG", nil)
        return
      }

      let outputPath = NSTemporaryDirectory() + "corrected_\(UUID().uuidString).jpg"
      do {
        try jpegData.write(to: URL(fileURLWithPath: outputPath))
        let outputUri = "file://\(outputPath)"
        NSLog("✅ [OrientationFix] Saved to: %@, size: %d bytes", outputUri, jpegData.count)
        resolver([
          "uri": outputUri,
          "path": outputPath,
          "width": Int(resized.size.width),
          "height": Int(resized.size.height),
          "size": jpegData.count
        ])
      } catch {
        rejecter("SAVE_FAILED", "Failed to save: \(error.localizedDescription)", error)
      }
    }
  }

  /// Apply EXIF orientation to actual pixel data, returning .up orientation image
  private func normalizeOrientation(_ image: UIImage) -> UIImage {
    // Already correct
    if image.imageOrientation == .up {
      return image
    }

    // Draw into a new context with the correct transform applied
    UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
    image.draw(in: CGRect(origin: .zero, size: image.size))
    let normalized = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return normalized ?? image
  }

  /// Resize image if larger than maxDimension on either side
  private func resizeIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
    let w = image.size.width
    let h = image.size.height

    if w <= maxDimension && h <= maxDimension {
      return image
    }

    let scale: CGFloat
    if w > h {
      scale = maxDimension / w
    } else {
      scale = maxDimension / h
    }

    let newSize = CGSize(width: w * scale, height: h * scale)
    UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
    image.draw(in: CGRect(origin: .zero, size: newSize))
    let resized = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()

    return resized ?? image
  }
}
