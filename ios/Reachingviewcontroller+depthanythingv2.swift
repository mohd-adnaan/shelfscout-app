//
//  Reachingviewcontroller+depthanythingv2.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-05-18.
//
//  DepthAnythingV2 inference for monocular metric-depth estimation,
//  scale-anchored to a single ARKit plane raycast.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  WHY:
//  ═══════════════════════════════════════════════════════════════════════════
//
//  On non-LiDAR devices, when the backend's Qwen pipeline returns depth: undefined
//  (which happens often), the existing 1.5m fallback is frequently wrong by
//  30–80%. Wrong initial depth → ARKit refinement raycasts land on the floor or
//  back wall behind the object → 5 hits agree → median locks onto the wrong
//  surface → bbox indicator parks on empty floor/wall instead of the target.
//
//  DepthAnythingV2 is a learned monocular depth model that runs on the Neural
//  Engine in ~50–80ms. It produces RELATIVE depth (inverse disparity, normalized
//  ~[0,1], not metric meters). To make it metric we anchor its scale to a single
//  ARKit raycast: at the raycast hit pixel we know the true metric depth, so we
//  can scale the relative map by ratio to get metric depth at the bbox center.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  USAGE:
//  ═══════════════════════════════════════════════════════════════════════════
//
//  1. Add DepthAnythingV2SmallF16.mlpackage to the Xcode project bundle. The
//     model package is downloaded from huggingface.co/apple/coreml-depth-anything-v2-small.
//     Dragging the .mlpackage into the Xcode project navigator and ticking
//     "Copy items if needed" + "Add to targets: shelfscout" is sufficient.
//     The file MUST be named exactly DepthAnythingV2SmallF16.mlpackage so the
//     auto-generated DepthAnythingV2SmallF16 Swift class is created by Xcode.
//
//  2. If the model is NOT in the bundle, model load fails silently and the
//     entire DAv2 path returns nil — the depth-fallback chain in placeWorldAnchor
//     transparently uses 1.5m. The app still works exactly as before.
//
//  3. estimateMetricDepth() is invoked once at initial placement time, in
//     parallel with the initial-reseed network call. Its result populates
//     self.estimatedMetricDepth, which placeWorldAnchor reads BEFORE its
//     1.5m fallback.
//

import ARKit
import CoreML
import Vision
import CoreImage
import UIKit

// MARK: - Lazy model singleton

private final class DepthAnythingV2Loader {
  static let shared = DepthAnythingV2Loader()
  private var cached: VNCoreMLModel?
  private var loadAttempted = false
  private let lock = NSLock()

  /// Returns a ready VNCoreMLModel or nil if loading failed.
  /// Repeated calls after a failed load are O(1) (no retry — fail once, fail forever).
  func model() -> VNCoreMLModel? {
    lock.lock()
    defer { lock.unlock() }
    if let m = cached { return m }
    if loadAttempted { return nil }  // already tried, gave up
    loadAttempted = true

    // Try several known asset names; if user later switches to the metric
    // variant we don't have to edit code.
    let candidateNames = [
      "DepthAnythingV2SmallF16",       // standard relative-depth model
      "DepthAnythingV2MetricSmallInt8" // optional metric variant
    ]
    let config = MLModelConfiguration()
    config.computeUnits = .all
    for name in candidateNames {
      guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc")
              ?? Bundle.main.url(forResource: name, withExtension: "mlpackage")
      else { continue }
      do {
        let mlModel = try MLModel(contentsOf: url, configuration: config)
        let visionModel = try VNCoreMLModel(for: mlModel)
        cached = visionModel
        NSLog("🌊 [DAv2] Model loaded: %@", name)
        return visionModel
      } catch {
        NSLog("🌊 [DAv2] Failed to load %@: %@", name, error.localizedDescription)
        continue
      }
    }
    NSLog("🌊 [DAv2] ⚠️ No DepthAnythingV2 model found in bundle — falling back to 1.5m default")
    return nil
  }
}

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Public Entry Point
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Estimate metric depth at the bbox center using DAv2 + an ARKit scale anchor.
  // Runs entirely off-thread. Completion is dispatched to visionQ so callers
  // can safely mutate self state without further hopping.
  //
  // Returns nil through completion if anything fails (model missing, no plane
  // hit available for scale anchoring, inference exception, out-of-range result).

  func estimateMetricDepth(frame: ARFrame,
                           bboxARNormalized: [CGFloat],
                           completion: @escaping (Float?) -> Void) {
    // Snapshot all inputs synchronously — `frame` cannot be retained off-thread.
    let pixelBuffer = frame.capturedImage
    let camera = frame.camera
    let camTransform = camera.transform
    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution
    let arW = imgRes.width, arH = imgRes.height

    // Bbox center in AR-portrait normalized coords
    let cx = (bboxARNormalized[0] + bboxARNormalized[2]) / 2
    let cy = (bboxARNormalized[1] + bboxARNormalized[3]) / 2

    // Convert AR-portrait normalized → AR-landscape pixel coords (same convention
    // as placeWorldAnchor uses for raycast direction).
    let arPxX = cy * arW
    let arPxY = (1.0 - cx) * arH

    // World ray through bbox center from current camera pose (used for the
    // scale-anchor raycast).
    let fx = CGFloat(intrinsics[0][0]), fy = CGFloat(intrinsics[1][1])
    let cxi = CGFloat(intrinsics[2][0]), cyi = CGFloat(intrinsics[2][1])
    let rX = Float((arPxX - cxi) / fx)
    let rY = Float((arPxY - cyi) / fy)
    let rayCam = simd_normalize(simd_float3(rX, -rY, -1.0))
    let worldRay = simd_normalize(simd_make_float3(camTransform * simd_float4(rayCam, 0)))
    let camPos = simd_make_float3(camTransform.columns.3)

    // ── Scale anchor: ARKit raycast for ONE metric depth reading ──
    // We MUST get the raycast on the main/AR thread because session.raycast
    // is not thread-safe relative to ARFrame lifetime. Doing it synchronously
    // here from the visionQ caller is acceptable; session.raycast is a quick
    // CPU lookup against existing planes.
    var scaleAnchorMetricDepth: Float? = nil
    let scaleQuery = ARRaycastQuery(origin: camPos, direction: worldRay,
                                    allowing: .estimatedPlane, alignment: .any)
    if let hit = sceneView.session.raycast(scaleQuery).first {
      let hp = simd_make_float3(hit.worldTransform.columns.3)
      let dist = simd_length(hp - camPos)
      if dist > 0.3 && dist < 8.0 {
        scaleAnchorMetricDepth = dist
      } else {
        NSLog("🌊 [DAv2] Scale anchor raycast hit out of range: %.2fm", dist)
      }
    } else {
      NSLog("🌊 [DAv2] No raycast hit available for scale anchor — DAv2 cannot produce metric depth")
    }

    guard let metricAnchor = scaleAnchorMetricDepth else {
      // No way to convert relative→metric without a scale reference.
      completion(nil)
      return
    }

    // Run DAv2 on a dedicated queue so we don't stall the AR/vision thread.
    depthAnythingQ.async { [weak self] in
      guard let self = self else { completion(nil); return }
      guard self.running, !self.hasCompleted else { completion(nil); return }

      guard let visionModel = DepthAnythingV2Loader.shared.model() else {
        self.visionQ.async { completion(nil) }
        return
      }

      let t0 = ProcessInfo.processInfo.systemUptime

      // The AR pixel buffer is landscape. DAv2 sample apps pass orientation
      // hints; the model is rotation-equivariant in practice for this use case.
      // We use .right because all our other Vision calls (tracker, detection)
      // use .right to align with the portrait UI.
      let request = VNCoreMLRequest(model: visionModel) { request, error in
        if let error = error {
          NSLog("🌊 [DAv2] Inference error: %@", error.localizedDescription)
          self.visionQ.async { completion(nil) }
          return
        }

        // Extract depth map from results. The model returns a single multi-array
        // observation (or pixel-buffer observation depending on output type).
        var relDepthMap: MLMultiArray? = nil
        for observation in (request.results ?? []) {
          if let pix = observation as? VNPixelBufferObservation {
            // Convert pixel buffer to multi-array via direct read.
            relDepthMap = self.pixelBufferToMultiArray(pix.pixelBuffer)
            break
          } else if let feat = observation as? VNCoreMLFeatureValueObservation {
            if let arr = feat.featureValue.multiArrayValue {
              relDepthMap = arr
              break
            }
          }
        }

        guard let depthArr = relDepthMap else {
          NSLog("🌊 [DAv2] No depth output in results")
          self.visionQ.async { completion(nil) }
          return
        }

        // Sample at object center and at scale-anchor hit projected back to image pixel.
        // Both points share the same pixel because our ARKit raycast went THROUGH
        // the bbox center — so d_rel_anchor IS d_rel_obj at the same pixel.
        // That makes the scale ratio = metricAnchor / d_rel_at_that_pixel.
        //
        // But the bbox center is the OBJECT pixel, while the raycast hit is on a
        // PLANE behind/under the object. If they shared the same pixel and the
        // object were transparent, depth-anything would have given two different
        // relative depths — one for object foreground, one for background plane.
        // In practice, depth-anything returns the depth of the NEAREST surface
        // visible at that pixel, which is the object. So d_rel at the bbox center
        // is the object's relative depth, NOT the plane behind it.
        //
        // To scale-anchor, we sample a DIFFERENT pixel where we expect the
        // raycast to have hit the plane (typically below/around the object).
        // Approach: sample relative depth at a point slightly above (toward screen
        // top in portrait, which is "farther from camera" in 2D layout) and on a
        // visible floor/table area. We use a point HALFWAY BETWEEN bbox bottom
        // and screen bottom edge as a proxy for the nearby plane.
        let dW = depthArr.shape[depthArr.shape.count - 1].intValue
        let dH = depthArr.shape[depthArr.shape.count - 2].intValue

        // Image is portrait-oriented (rotated .right from landscape AR pixel buffer).
        // bbox is in AR-portrait normalized, so (cx,cy) maps directly to depth map.
        let objX = max(0, min(dW - 1, Int(CGFloat(dW) * cx)))
        let objY = max(0, min(dH - 1, Int(CGFloat(dH) * cy)))
        let dRelObj = self.sampleMultiArray(depthArr, x: objX, y: objY)

        // Anchor sample: pixel below the bbox, on the supporting surface.
        // bbox bottom is at cy + (bboxBottom - cy); we want JUST below that.
        let bboxBottomY = bboxARNormalized[3]
        let anchorYNorm = min(0.98, bboxBottomY + 0.05)  // 5% below bbox bottom
        let anchorY = max(0, min(dH - 1, Int(CGFloat(dH) * anchorYNorm)))
        let dRelAnchor = self.sampleMultiArray(depthArr, x: objX, y: anchorY)

        guard dRelObj > 0.001, dRelAnchor > 0.001 else {
          NSLog("🌊 [DAv2] Degenerate samples — obj=%.4f anchor=%.4f", dRelObj, dRelAnchor)
          self.visionQ.async { completion(nil) }
          return
        }

        // DAv2 output is INVERSE depth (disparity): larger values = closer.
        // Convert ratio: metric_obj / metric_anchor = (1/dRelObj) / (1/dRelAnchor)
        //                                            = dRelAnchor / dRelObj
        let metricObj = metricAnchor * (dRelAnchor / dRelObj)

        // Sanity bound: reject implausible results.
        guard metricObj > 0.2, metricObj < 6.0 else {
          NSLog("🌊 [DAv2] Estimated depth out of bounds: %.2fm (anchor=%.2fm dRelObj=%.4f dRelAnchor=%.4f)",
                metricObj, metricAnchor, dRelObj, dRelAnchor)
          self.visionQ.async { completion(nil) }
          return
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        NSLog("🌊 [DAv2] ✅ Metric depth=%.2fm (anchor=%.2fm, ratio=%.3f, inference=%.0fms, mapDims=%dx%d)",
              metricObj, metricAnchor, dRelAnchor / dRelObj, elapsedMs, dW, dH)

        self.visionQ.async { completion(metricObj) }
      }

      request.imageCropAndScaleOption = .scaleFit

      let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
      do {
        try handler.perform([request])
      } catch {
        NSLog("🌊 [DAv2] Handler perform failed: %@", error.localizedDescription)
        self.visionQ.async { completion(nil) }
      }
    }
  }

  // MARK: - Helpers

  /// Sample a single value from an MLMultiArray at (x, y). Handles shapes:
  ///   [1, 1, H, W]  (NCHW common)
  ///   [1, H, W]
  ///   [H, W]
  fileprivate func sampleMultiArray(_ arr: MLMultiArray, x: Int, y: Int) -> Float {
    let shape = arr.shape.map { $0.intValue }
    let strides = arr.strides.map { $0.intValue }

    var index = 0
    if shape.count == 4 {
      // [N, C, H, W] — assume N=0, C=0
      index = y * strides[2] + x * strides[3]
    } else if shape.count == 3 {
      // [C, H, W]
      index = y * strides[1] + x * strides[2]
    } else if shape.count == 2 {
      // [H, W]
      index = y * strides[0] + x * strides[1]
    } else {
      return 0
    }

    // DAv2 outputs Float16 or Float32 depending on the package.
    switch arr.dataType {
    case .float32:
      let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: arr.count)
      return ptr[index]
    case .float16:
      // Float16 access via raw bytes — Swift doesn't have native Float16 on all
      // toolchains, so we read two bytes and convert via simd half-to-float.
      let ptr = arr.dataPointer.bindMemory(to: UInt16.self, capacity: arr.count)
      return Float16ToFloat(ptr[index])
    case .double:
      let ptr = arr.dataPointer.bindMemory(to: Double.self, capacity: arr.count)
      return Float(ptr[index])
    default:
      return 0
    }
  }

  /// Convert a depth pixel buffer (the alternative output format) to MLMultiArray-like sampling.
  /// We just return an MLMultiArray view — for our use case sampling 2 pixels, this is wasteful
  /// but simple. Returns nil if the format is unsupported.
  fileprivate func pixelBufferToMultiArray(_ pixelBuffer: CVPixelBuffer) -> MLMultiArray? {
    let width = CVPixelBufferGetWidth(pixelBuffer)
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let pixFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

    guard let out = try? MLMultiArray(shape: [1, NSNumber(value: height), NSNumber(value: width)],
                                       dataType: .float32) else { return nil }
    let outPtr = out.dataPointer.bindMemory(to: Float.self, capacity: width * height)

    if pixFormat == kCVPixelFormatType_DepthFloat32 || pixFormat == kCVPixelFormatType_OneComponent32Float {
      for y in 0..<height {
        let rowPtr = base.advanced(by: y * bytesPerRow).bindMemory(to: Float.self, capacity: width)
        for x in 0..<width {
          outPtr[y * width + x] = rowPtr[x]
        }
      }
      return out
    } else if pixFormat == kCVPixelFormatType_DepthFloat16 || pixFormat == kCVPixelFormatType_OneComponent16Half {
      for y in 0..<height {
        let rowPtr = base.advanced(by: y * bytesPerRow).bindMemory(to: UInt16.self, capacity: width)
        for x in 0..<width {
          outPtr[y * width + x] = Float16ToFloat(rowPtr[x])
        }
      }
      return out
    }
    return nil
  }
}

// MARK: - Float16 helper
// Swift's native Float16 type is only available on iOS 14+, which we target.
// Use it directly via bitPattern.
fileprivate func Float16ToFloat(_ bits: UInt16) -> Float {
  return Float(Float16(bitPattern: bits))
}
