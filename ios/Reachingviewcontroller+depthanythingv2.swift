//
//  Reachingviewcontroller+depthAnythingV2.swift
//  shelfscout
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

// MARK: - Startup Validation (call once to confirm model is bundled & loadable)

/// Pre-warms the DepthAnythingV2 model by forcing it to load into the cached singleton.
/// Call this from a background thread to avoid blocking the main UI.
func prewarmDepthAnythingV2Model() {
  _ = DepthAnythingV2Loader.shared.model()
}

/// Eagerly loads and validates the DepthAnythingV2 model, logging detailed
/// diagnostics. Call from viewDidLoad() so you get immediate confirmation
/// in the console that the model is present and functional — no AR session needed.
func validateDepthAnythingModel() {
  let t0 = ProcessInfo.processInfo.systemUptime

  NSLog("🌊 [DAv2-Validate] ═══════════════════════════════════════════════════")
  NSLog("🌊 [DAv2-Validate] Starting DepthAnythingV2 model validation...")
  NSLog("🌊 [DAv2-Validate] ═══════════════════════════════════════════════════")

  // 1. Check if the compiled model is in the app bundle
  let bundledNames = ["DepthAnythingV2SmallF16", "DepthAnythingV2MetricSmallInt8"]
  var foundUrl: URL? = nil
  var foundName: String? = nil
  for name in bundledNames {
    if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") {
      foundUrl = url
      foundName = name
      NSLog("🌊 [DAv2-Validate] ✅ Found compiled model in bundle: %@ (.mlmodelc)", name)
      break
    } else if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") {
      foundUrl = url
      foundName = name
      NSLog("🌊 [DAv2-Validate] ✅ Found model package in bundle: %@ (.mlpackage)", name)
      break
    } else {
      NSLog("🌊 [DAv2-Validate] ⏭️  '%@' not found in bundle (tried .mlmodelc and .mlpackage)", name)
    }
  }

  guard let modelUrl = foundUrl, let modelName = foundName else {
    NSLog("🌊 [DAv2-Validate] ❌ NO DepthAnythingV2 model found in app bundle!")
    NSLog("🌊 [DAv2-Validate]    Make sure the .mlpackage is added to the Xcode target.")
    NSLog("🌊 [DAv2-Validate] ═══════════════════════════════════════════════════")
    return
  }

  NSLog("🌊 [DAv2-Validate] 📁 Model URL: %@", modelUrl.path)

  // 2. Try loading the MLModel
  let config = MLModelConfiguration()
  config.computeUnits = .all
  do {
    let mlModel = try MLModel(contentsOf: modelUrl, configuration: config)
    let loadMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
    NSLog("🌊 [DAv2-Validate] ✅ MLModel loaded successfully in %.0fms", loadMs)

    // 3. Log model metadata
    let desc = mlModel.modelDescription
    NSLog("🌊 [DAv2-Validate] 📋 Model: %@", modelName)

    // Input details
    NSLog("🌊 [DAv2-Validate] 📥 Inputs (%d):", desc.inputDescriptionsByName.count)
    for (name, input) in desc.inputDescriptionsByName {
      if let imageConstraint = input.imageConstraint {
        NSLog("🌊 [DAv2-Validate]    • '%@': Image %dx%d (type: %d)",
              name,
              imageConstraint.pixelsWide,
              imageConstraint.pixelsHigh,
              imageConstraint.pixelFormatType)
      } else if let multiArrayConstraint = input.multiArrayConstraint {
        NSLog("🌊 [DAv2-Validate]    • '%@': MultiArray shape=%@ dtype=%d",
              name,
              multiArrayConstraint.shape,
              multiArrayConstraint.dataType.rawValue)
      } else {
        NSLog("🌊 [DAv2-Validate]    • '%@': %@", name, input.type.rawValue as CVarArg)
      }
    }

    // Output details
    NSLog("🌊 [DAv2-Validate] 📤 Outputs (%d):", desc.outputDescriptionsByName.count)
    for (name, output) in desc.outputDescriptionsByName {
      if let imageConstraint = output.imageConstraint {
        NSLog("🌊 [DAv2-Validate]    • '%@': Image %dx%d (type: %d)",
              name,
              imageConstraint.pixelsWide,
              imageConstraint.pixelsHigh,
              imageConstraint.pixelFormatType)
      } else if let multiArrayConstraint = output.multiArrayConstraint {
        NSLog("🌊 [DAv2-Validate]    • '%@': MultiArray shape=%@ dtype=%d",
              name,
              multiArrayConstraint.shape,
              multiArrayConstraint.dataType.rawValue)
      } else {
        NSLog("🌊 [DAv2-Validate]    • '%@': type=%d", name, output.type.rawValue)
      }
    }

    // 4. Try wrapping in VNCoreMLModel (same as runtime path)
    let visionModel = try VNCoreMLModel(for: mlModel)
    NSLog("🌊 [DAv2-Validate] ✅ VNCoreMLModel wrapper created successfully")
    _ = visionModel  // suppress unused warning

    // 5. Pre-warm the lazy singleton so first real inference is faster
    _ = DepthAnythingV2Loader.shared.model()

    let totalMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
    NSLog("🌊 [DAv2-Validate] ═══════════════════════════════════════════════════")
    NSLog("🌊 [DAv2-Validate] ✅ ALL CHECKS PASSED — model is ready (total: %.0fms)", totalMs)
    NSLog("🌊 [DAv2-Validate]    Name:    %@", modelName)
    NSLog("🌊 [DAv2-Validate]    Compute: .all (Neural Engine + GPU + CPU)")
    NSLog("🌊 [DAv2-Validate]    Status:  OPERATIONAL ✅")
    NSLog("🌊 [DAv2-Validate] ═══════════════════════════════════════════════════")

  } catch {
    let failMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
    NSLog("🌊 [DAv2-Validate] ❌ MODEL LOAD FAILED after %.0fms: %@", failMs, error.localizedDescription)
    NSLog("🌊 [DAv2-Validate] ═══════════════════════════════════════════════════")
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

    // ── Scale anchor: try multiple sample points to maximize hit success ──
    //
    // PROBLEM with original single-point approach: when this fires at the
    // start of an AR session, ARKit has typically not built any planes yet,
    // so a raycast through the bbox center returns nothing. The whole
    // DAv2 path then aborts and we fall back to 1.5m every single time —
    // exactly what the logs from 18 May show.
    //
    // FIX: try a grid of 9 sample points (bbox center + bbox corners + a
    // few floor-direction samples). As long as ANY raycast hits a plane
    // anywhere in the visible scene, we have a scale anchor.
    //
    // The scale anchor's actual SURFACE doesn't matter — DAv2 gives us
    // relative depth at any pixel, so we can scale-anchor against any
    // known-metric pixel. We just sample DAv2 at the SAME pixel where
    // we got a metric hit, then propagate the scale factor to the bbox center.
    let sampleCandidates: [(CGFloat, CGFloat, String)] = [
      (cx, cy, "bbox center"),
      (cx, cy + 0.08, "below bbox"),
      (cx - 0.08, cy + 0.08, "below-left"),
      (cx + 0.08, cy + 0.08, "below-right"),
      (cx, cy - 0.08, "above bbox"),
    ]

    var scaleAnchorMetricDepth: Float? = nil
    var scaleAnchorPixelX: CGFloat = cx  // for sampling DAv2 at this pixel later
    var scaleAnchorPixelY: CGFloat = cy
    var scaleAnchorLabel: String = "none"
    let baselineDepth: Float? = (anchorDepth > 0.2 && anchorDepth < 6.0) ? anchorDepth : nil

    for (sx, sy, label) in sampleCandidates {
      // Clamp to valid normalized range
      let ssx = max(0.05, min(0.95, sx))
      let ssy = max(0.05, min(0.95, sy))
      // Convert sample point to landscape pixel + world ray
      let sArPxX = ssy * arW
      let sArPxY = (1.0 - ssx) * arH
      let sRX = Float((sArPxX - cxi) / fx)
      let sRY = Float((sArPxY - cyi) / fy)
      let sRayCam = simd_normalize(simd_float3(sRX, -sRY, -1.0))
      let sWorldRay = simd_normalize(simd_make_float3(camTransform * simd_float4(sRayCam, 0)))
      let q = ARRaycastQuery(origin: camPos, direction: sWorldRay,
                             allowing: .estimatedPlane, alignment: .any)
      if let hit = sceneView.session.raycast(q).first {
        let hp = simd_make_float3(hit.worldTransform.columns.3)
        let dist = simd_length(hp - camPos)
        if dist > 0.3 && dist < 8.0 {
          if let base = baselineDepth {
            let maxJump = max(1.5, base * 2.0)
            if label == "bbox center" && abs(dist - base) > maxJump {
              NSLog("🌊 [DAv2] Skipping bbox-center anchor: %.2fm (base=%.2fm, maxJump=%.2fm)",
                    dist, base, maxJump)
              continue
            }
            if hit.targetAlignment == .vertical && dist > base * 2.0 {
              NSLog("🌊 [DAv2] Skipping vertical anchor: %.2fm (>2x base %.2fm)", dist, base)
              continue
            }
          }
          scaleAnchorMetricDepth = dist
          scaleAnchorPixelX = ssx
          scaleAnchorPixelY = ssy
          scaleAnchorLabel = label
          NSLog("🌊 [DAv2] Scale anchor found at '%@' (%.2f, %.2f) → %.2fm", label, ssx, ssy, dist)
          break
        }
      }
    }

    // ── Feature-point fallback scale anchor ────────────────────────────────
    //
    // Raycasts need ARKit PLANES, which on a non-LiDAR device only form after
    // the user walks around for several seconds — that is the cold-start
    // failure that left DAv2 unable to produce depth at all.
    //
    // Raw feature points appear within ~1s from the natural hand-shake of
    // holding a phone — no walking required. We take the feature points whose
    // bearing falls inside the bbox cone and use their median camera distance
    // as the metric anchor. Because these points sit ON/near the target, the
    // anchor pixel is the bbox center itself: DAv2's relative ratio is ~1 and
    // the returned metric depth is essentially the feature-point median — a
    // correct, motion-free depth estimate.
    if scaleAnchorMetricDepth == nil, let cloud = frame.rawFeaturePoints {
      var dists: [Float] = []
      for p in cloud.points {
        let toP = p - camPos
        let d = simd_length(toP)
        guard d > 0.3 && d < 8.0 else { continue }
        let dot = simd_dot(toP / d, worldRay)
        // Within ~35 deg of the bbox-center ray (cos 35 deg ~= 0.819).
        // Widened from 18° to catch more desk-edge/surface feature points
        // near smooth objects like water bottles.
        if dot > 0.819 { dists.append(d) }
      }
      if dists.count >= 2 {
        dists.sort()
        let med = dists[dists.count / 2]
        scaleAnchorMetricDepth = med
        scaleAnchorPixelX = cx
        scaleAnchorPixelY = cy
        scaleAnchorLabel = "featurePoints(\(dists.count),cone35)"
        NSLog("🌊 [DAv2] Scale anchor from %d feature points in bbox cone (35°) → %.2fm", dists.count, med)
      }
    }

    let featureCount = frame.rawFeaturePoints?.points.count ?? 0

    guard let metricAnchor = scaleAnchorMetricDepth else {
      // Throttle log: only emit once per ~60 frames (~1/sec at 60fps)
      self.dav2NoAnchorLogCount += 1
      if self.dav2NoAnchorLogCount == 1 || self.dav2NoAnchorLogCount % 60 == 0 {
        NSLog("🌊 [DAv2] No scale anchor (featurePoints=%d) — attempt #%d, retrying...",
              featureCount, self.dav2NoAnchorLogCount)
      }
      // No way to convert relative→metric without a scale reference.
      completion(nil)
      return
    }
    _ = scaleAnchorLabel  // suppress unused warning; only useful for logging
    // Const-copy for closure capture; these will be read on a background queue
    // after the guard above succeeds.
    let anchorPixelX: CGFloat = scaleAnchorPixelX
    let anchorPixelY: CGFloat = scaleAnchorPixelY

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

        // Sample DAv2 at two pixels:
        //   d_rel_obj    — at the bbox center (the object pixel)
        //   d_rel_anchor — at the scale-anchor pixel where ARKit gave us
        //                  a confirmed metric distance
        //
        // The scale-anchor pixel is wherever ARKit's raycast actually hit a
        // plane. We pass that pixel through scaleAnchorPixelX/Y captured
        // when the raycast succeeded. This is much more reliable than
        // guessing "5% below bbox bottom" because:
        //  - The pixel ACTUALLY has a known metric depth (raycast hit)
        //  - Whatever surface it's on (floor, table, wall), DAv2 sees
        //    it too — the ratio between obj-pixel and anchor-pixel
        //    relative depths gives us the depth ratio
        let dW = depthArr.shape[depthArr.shape.count - 1].intValue
        let dH = depthArr.shape[depthArr.shape.count - 2].intValue

        // Image is portrait-oriented (rotated .right from landscape AR pixel buffer).
        // bbox/scale-anchor are in AR-portrait normalized, map directly to depth map.
        let objX = max(0, min(dW - 1, Int(CGFloat(dW) * cx)))
        let objY = max(0, min(dH - 1, Int(CGFloat(dH) * cy)))
        let dRelObj = self.sampleMultiArray(depthArr, x: objX, y: objY)

        // Anchor sample: pixel where ARKit raycast confirmed a metric distance
        let anchorX = max(0, min(dW - 1, Int(CGFloat(dW) * anchorPixelX)))
        let anchorY = max(0, min(dH - 1, Int(CGFloat(dH) * anchorPixelY)))
        let dRelAnchor = self.sampleMultiArray(depthArr, x: anchorX, y: anchorY)

        guard dRelObj > 0.001, dRelAnchor > 0.001 else {
          NSLog("🌊 [DAv2] Degenerate samples — obj=%.4f anchor=%.4f", dRelObj, dRelAnchor)
          self.visionQ.async { completion(nil) }
          return
        }

        // DAv2 output is INVERSE depth (disparity): larger values = closer.
        // Convert ratio: metric_obj / metric_anchor = (1/dRelObj) / (1/dRelAnchor)
        //                                            = dRelAnchor / dRelObj
        let ratio = dRelAnchor / dRelObj
        if ratio < 0.4 || ratio > 2.5 {
          NSLog("🌊 [DAv2] Ratio out of bounds: %.3f (anchor=%.2fm)", ratio, metricAnchor)
          self.visionQ.async { completion(nil) }
          return
        }
        let metricObj = metricAnchor * ratio

        // Sanity bound: reject implausible results.
        guard metricObj > 0.2, metricObj < 6.0 else {
          NSLog("🌊 [DAv2] Estimated depth out of bounds: %.2fm (anchor=%.2fm dRelObj=%.4f dRelAnchor=%.4f)",
                metricObj, metricAnchor, dRelObj, dRelAnchor)
          self.visionQ.async { completion(nil) }
          return
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
          NSLog("🌊 [DAv2] ✅ Metric depth=%.2fm (anchor=%.2fm, ratio=%.3f, inference=%.0fms, mapDims=%dx%d)",
            metricObj, metricAnchor, ratio, elapsedMs, dW, dH)

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