/**
 ReachingModule.swift — ARKit Reaching v6
*/

import Foundation
import AVFoundation
import Vision
import UIKit
import ARKit
import SceneKit
import CoreHaptics

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ReachingModule (React Native Bridge)
// ═══════════════════════════════════════════════════════════════════════════════

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

    // Parse depth from backend (handles both meters and centimeters)
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
    if let w = params["imageWidth"] as? NSNumber { imgW = CGFloat(w.doubleValue) }
    if let h = params["imageHeight"] as? NSNumber { imgH = CGFloat(h.doubleValue) }
    NSLog("🎯 [ReachingModule] image dimensions: %.0f×%.0f", imgW, imgH)

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

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ReachingViewController
// ═══════════════════════════════════════════════════════════════════════════════

class ReachingViewController: UIViewController {

  enum Direction: String {
    case left = "left", topLeft = "top left", top = "up", topRight = "top right"
    case right = "right", downRight = "down right", down = "down", downLeft = "down left"
    case centered = "Centered!", searching = "Show your hand"
  }

  private enum ProximityZone: String {
    case searching, far, medium, close, veryClose, centered
  }

  // ── Config ──────────────────────────────────────────────────────────────

  private let bboxRaw: [CGFloat]
  private let objectName: String
  private let backendDepth: Float?
  private let imageWidth: CGFloat
  private let imageHeight: CGFloat
  private let onDone: ([String: Any]) -> Void
  private var bboxNormalized: [CGFloat] = [0, 0, 0, 0]

  // ── 3D World Anchor (v6: LOCKED IN SPACE) ──────────────────────────────

  private var objectWorldPosition: simd_float3?
  private var objectWorldHalfW: Float = 0
  private var objectWorldHalfH: Float = 0
  private var anchorPlaced = false
  /// The initial depth used to place the anchor (from backend)
  private var anchorDepth: Float = 0.5
  /// LIVE distance from camera to the world anchor (updated every frame)
  private var liveDistanceToObject: Float = 0.5

  // Depth gating
  private let depthReachThreshold: Float = 0.35  // hand must be within 35cm of object
  private var handIsCloseEnoughInDepth = false

  // ── ARKit ───────────────────────────────────────────────────────────────

  private var sceneView: ARSCNView!
  private var arFrameCount = 0
  private let anchorWaitFrames = 15

  // ── Vision ──────────────────────────────────────────────────────────────

  private let handReq = VNDetectHumanHandPoseRequest()
  private let visionQ = DispatchQueue(label: "reach.vision", qos: .userInitiated)

  // ── Audio ───────────────────────────────────────────────────────────────

  private var audioEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var beepBuf: AVAudioPCMBuffer?
  private var audioFmt: AVAudioFormat?
  private var beepTimer: DispatchSourceTimer?
  private let audioQ = DispatchQueue(label: "reach.audio", qos: .userInitiated)
  private var lastBeep: TimeInterval = 0

  // ── Speech ──────────────────────────────────────────────────────────────

  private let synth = AVSpeechSynthesizer()
  private var lastSpokenDirection: Direction = .searching
  private var lastSpeechTime: TimeInterval = 0
  private let speechCooldown: TimeInterval = 1.2
  private var directionStableFrames: Int = 0
  private let directionStableThreshold: Int = 4

  // ── Haptics ─────────────────────────────────────────────────────────────

  private var hapticEngine: CHHapticEngine?

  // ── UI ──────────────────────────────────────────────────────────────────

  private let bboxLayer = CAShapeLayer()
  private let innerBboxLayer = CAShapeLayer()
  private let handDot = CAShapeLayer()
  private let handDotGlow = CAShapeLayer()
  private var topBar: UIVisualEffectView!
  private var bottomBar: UIVisualEffectView!
  private var directionLabel: UILabel!
  private var objectNameLabel: UILabel!
  private var cancelButton: UIButton!
  private var progressRing: CAShapeLayer!
  private var distanceLabel: UILabel!
  private var depthHintLabel: UILabel!  // v6: shows "Move hand closer" when 2D aligned but depth wrong

  // ── Projected bbox (updated every frame from world anchor) ─────────────

  private var projectedBboxCenter: CGPoint = .zero
  private var projectedBboxW: CGFloat = 0
  private var projectedBboxH: CGFloat = 0

  // ── State ───────────────────────────────────────────────────────────────

  private var running = false
  private var currentDirection: Direction = .searching
  private var proximityZone: ProximityZone = .searching
  private var noHandFrames = 0
  private var successFrames = 0
  private var hasCompleted = false

  private let successThreshold = 20
  private let noHandLimit = 50
  private let noHandRepeatCycle = 120

  // ── Cached screen bounds ──────────────────────────────────────────────

  private var cachedSW: CGFloat = 393
  private var cachedSH: CGFloat = 852

  // ── Aspect-fill crop ───────────────────────────────────────────────────

  private var cropFracX: CGFloat = 0
  private var cropComputed = false

  // ── Init ────────────────────────────────────────────────────────────────

  init(bboxRaw: [CGFloat], objectName: String, backendDepth: Float?,
       imageWidth: CGFloat, imageHeight: CGFloat,
       onDone: @escaping ([String: Any]) -> Void) {
    self.bboxRaw = bboxRaw
    self.objectName = objectName
    self.backendDepth = backendDepth
    self.imageWidth = imageWidth
    self.imageHeight = imageHeight
    self.onDone = onDone
    super.init(nibName: nil, bundle: nil)
    handReq.maximumHandCount = 1
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    cachedSW = UIScreen.main.bounds.width
    cachedSH = UIScreen.main.bounds.height
    NSLog("📐 [ReachingVC] Cached screen: %.0f×%.0f", cachedSW, cachedSH)

    normalizeBbox()
    setupARView()
    setupAppleUI()
    setupAudio()
    setupHaptics()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self = self, !self.hasCompleted else { return }
      self.startAR()
      self.running = true
      self.say("Guiding to \(self.objectName). Move your hand into view.")
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cleanup()
  }

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }

  // ── Normalize bbox ──────────────────────────────────────────────────────

  private func normalizeBbox() {
    let x1 = min(abs(bboxRaw[0]), abs(bboxRaw[2]))
    let y1 = min(abs(bboxRaw[1]), abs(bboxRaw[3]))
    let x2 = max(abs(bboxRaw[0]), abs(bboxRaw[2]))
    let y2 = max(abs(bboxRaw[1]), abs(bboxRaw[3]))
    let maxVal = max(x1, y1, x2, y2)

    if imageWidth > 0 && imageHeight > 0 && maxVal > 1.0 {
      bboxNormalized = [x1 / imageWidth, y1 / imageHeight, x2 / imageWidth, y2 / imageHeight]
      NSLog("📦 [ReachingVC] Bbox [%.0f,%.0f,%.0f,%.0f] ÷ actual image %.0f×%.0f → norm %@",
            x1, y1, x2, y2, imageWidth, imageHeight, "\(bboxNormalized)")
    } else if maxVal <= 1.0 {
      bboxNormalized = [x1, y1, x2, y2]
    } else {
      let guessW: CGFloat = max(x2 * 1.1, 1152)
      let guessH: CGFloat = max(y2 * 1.1, 2048)
      bboxNormalized = [x1 / guessW, y1 / guessH, x2 / guessW, y2 / guessH]
    }

    bboxNormalized = bboxNormalized.map { min(max($0, 0), 1) }

    let bw = bboxNormalized[2] - bboxNormalized[0]
    let bh = bboxNormalized[3] - bboxNormalized[1]
    if bw < 0.01 || bh < 0.01 {
      bboxNormalized = [0.35, 0.35, 0.65, 0.65]
    }

    NSLog("📦 [ReachingVC] Final normalized: [%.3f, %.3f, %.3f, %.3f]  center=(%.3f, %.3f)",
          bboxNormalized[0], bboxNormalized[1], bboxNormalized[2], bboxNormalized[3],
          (bboxNormalized[0]+bboxNormalized[2])/2, (bboxNormalized[1]+bboxNormalized[3])/2)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - ARKit Setup
  // ═══════════════════════════════════════════════════════════════════════════

  private func setupARView() {
    sceneView = ARSCNView(frame: view.bounds)
    sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    sceneView.session.delegate = self
    sceneView.showsStatistics = false
    sceneView.automaticallyUpdatesLighting = false
    view.addSubview(sceneView)
  }

  private func startAR() {
    let config = ARWorldTrackingConfiguration()
    config.planeDetection = []
    // Enable scene depth if available (LiDAR devices)
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      config.frameSemantics.insert(.sceneDepth)
      NSLog("📷 [ReachingVC] Scene depth ENABLED (LiDAR)")
    } else {
      NSLog("📷 [ReachingVC] No LiDAR — using backend depth + hand size heuristic")
    }
    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    startBeepLoop()
    NSLog("📷 [ReachingVC] AR session started")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - v6: Place 3D World Anchor from screen-space bbox
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   * Strategy: compute where the bbox SHOULD be on screen (same as v5),
   * then use the CURRENT AR camera to shoot a ray through that screen point
   * and place a world anchor at the backend depth along that ray.
   *
   * Because this uses the camera pose at frame 15 (when the phone is still
   * roughly pointed at the scene), the 3D position is much better than
   * doing it at frame 0.
   *
   * The bbox then gets REPROJECTED each frame via projectPoint, so it
   * stays locked in world space as the camera moves.
   */
  private func placeWorldAnchor(frame: ARFrame) {
    let sw = cachedSW
    let sh = cachedSH

    // Step 1: Compute screen-space bbox center (same math as v5 — KNOWN CORRECT)
    let photoAspect = imageWidth / imageHeight
    let screenAspect = sw / sh

    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
    var offsetX: CGFloat = 0.0
    var offsetY: CGFloat = 0.0

    if photoAspect > screenAspect {
      scaleY = 1.0
      scaleX = (photoAspect / screenAspect)
      offsetX = (scaleX - 1.0) / 2.0
    } else {
      scaleX = 1.0
      scaleY = (screenAspect / photoAspect)
      offsetY = (scaleY - 1.0) / 2.0
    }

    let bx1 = (bboxNormalized[0] * scaleX - offsetX) * sw
    let by1 = (bboxNormalized[1] * scaleY - offsetY) * sh
    let bx2 = (bboxNormalized[2] * scaleX - offsetX) * sw
    let by2 = (bboxNormalized[3] * scaleY - offsetY) * sh

    let screenCenter = CGPoint(x: (bx1 + bx2) / 2, y: (by1 + by2) / 2)
    let screenHalfW = max((bx2 - bx1) / 2, 15)
    let screenHalfH = max((by2 - by1) / 2, 15)

    NSLog("🎯 [ReachingVC] Screen target: center=(%.1f, %.1f) size=%.0f×%.0f",
          screenCenter.x, screenCenter.y, screenHalfW * 2, screenHalfH * 2)

    // Step 2: Unproject screen point to 3D ray using current camera
    let camera = frame.camera
    let viewSize = CGSize(width: sw, height: sh)

    // Use the camera intrinsics via projectPoint inverse:
    // We create a point at known depth and unproject
    let depth = backendDepth ?? 0.5
    anchorDepth = depth

    // Shoot ray: place a virtual point at screen position and unproject
    // ARCamera doesn't have unprojectPoint on iOS 14, so we compute manually
    let intrinsics = camera.intrinsics
    let imageRes = camera.imageResolution  // landscape: 1920×1440

    // Convert screen point to AR camera image pixel
    // The AR camera image fills the screen with aspect-fill.
    // Screen is portrait, AR image is landscape.
    let arW = imageRes.width   // 1920
    let arH = imageRes.height  // 1440

    // Portrait screen → landscape AR image mapping
    // AR image is rotated 90° CW to become portrait on screen
    // Screen Y maps to AR image X, Screen X maps to AR image (H - Y)
    let arPixelX = (screenCenter.y / sh) * arW   // screen Y → AR X
    let arPixelY = (1.0 - screenCenter.x / sw) * arH  // screen X → AR Y (inverted)

    let fx = CGFloat(intrinsics[0][0])
    let fy = CGFloat(intrinsics[1][1])
    let cx = CGFloat(intrinsics[2][0])
    let cy = CGFloat(intrinsics[2][1])

    // Ray in camera space (landscape, Y-down pixel convention)
    let rawRayX = Float((arPixelX - cx) / fx)
    let rawRayY = Float((arPixelY - cy) / fy)
    let rawRayZ: Float = 1.0

    // Convert to ARKit camera space (Y-up, Z-backward)
    let rayCamera = simd_normalize(simd_float3(rawRayX, -rawRayY, -rawRayZ))

    // Transform to world space using camera transform
    let camTransform = camera.transform
    let worldRay = simd_normalize(simd_make_float3(camTransform * simd_float4(rayCamera, 0)))
    let camPos = simd_make_float3(camTransform.columns.3)

    // Place anchor at depth along ray
    let worldPos = camPos + worldRay * depth
    objectWorldPosition = worldPos

    // Compute world-space bbox extents for reprojection
    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = depth * Float(bboxNormW) * 0.5
    objectWorldHalfH = depth * Float(bboxNormH) * 0.8  // slightly larger for safety

    anchorPlaced = true

    NSLog("🎯 [ReachingVC] AR pixel: (%.1f, %.1f) in %.0f×%.0f", arPixelX, arPixelY, arW, arH)
    NSLog("🎯 [ReachingVC] Camera ray: (%.4f, %.4f, %.4f)", rayCamera.x, rayCamera.y, rayCamera.z)
    NSLog("🎯 [ReachingVC] World ray: (%.4f, %.4f, %.4f)", worldRay.x, worldRay.y, worldRay.z)
    NSLog("🎯 [ReachingVC] ✅ Anchor at world: (%.3f, %.3f, %.3f) depth=%.2f",
          worldPos.x, worldPos.y, worldPos.z, depth)

    // Verify by projecting back
    let verify = camera.projectPoint(worldPos, orientation: .portrait, viewportSize: viewSize)
    NSLog("🎯 [ReachingVC] Verify: projects to screen (%.1f, %.1f) = norm (%.3f, %.3f)",
          verify.x, verify.y, verify.x / sw, verify.y / sh)

    // Initial UI update
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if let depth = self.backendDepth {
        self.distanceLabel.text = "\(Int(depth * 100)) cm"
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - v6: Reproject world anchor to screen each frame
  // ═══════════════════════════════════════════════════════════════════════════

  private func reprojectBbox(frame: ARFrame) {
    guard let center3D = objectWorldPosition else { return }
    let sw = cachedSW, sh = cachedSH
    let camera = frame.camera
    let viewSize = CGSize(width: sw, height: sh)

    // Check if object is behind camera
    let camPos = simd_make_float3(camera.transform.columns.3)
    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    if simd_dot(center3D - camPos, camFwd) < 0 {
      DispatchQueue.main.async { [weak self] in
        self?.bboxLayer.isHidden = true
        self?.innerBboxLayer.isHidden = true
        self?.directionLabel.text = "Turn back"
      }
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastSpeechTime > 3.0 { say("Object is behind you."); lastSpeechTime = now }
      return
    }

    // Project center to screen
    let centerScreen = camera.projectPoint(center3D, orientation: .portrait, viewportSize: viewSize)

    // Project corners to get screen-space size
    // Use camera right and up vectors for world-space offsets
    let camRight = simd_normalize(simd_make_float3(camera.transform.columns.0))
    let camUp = simd_normalize(simd_make_float3(camera.transform.columns.1))

    let cornerTR = center3D + camRight * objectWorldHalfW + camUp * objectWorldHalfH
    let cornerBL = center3D - camRight * objectWorldHalfW - camUp * objectWorldHalfH
    let trScreen = camera.projectPoint(cornerTR, orientation: .portrait, viewportSize: viewSize)
    let blScreen = camera.projectPoint(cornerBL, orientation: .portrait, viewportSize: viewSize)

    let screenW = max(abs(trScreen.x - blScreen.x), 20)
    let screenH = max(abs(trScreen.y - blScreen.y), 20)

    let dist = simd_length(center3D - camPos)

    // v6.1: Update LIVE distance — this is the real AR-measured distance
    liveDistanceToObject = dist

    projectedBboxCenter = centerScreen
    projectedBboxW = screenW
    projectedBboxH = screenH

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.bboxLayer.isHidden = false
      self.innerBboxLayer.isHidden = false

      let innerRect = CGRect(x: centerScreen.x - screenW/2,
                              y: centerScreen.y - screenH/2,
                              width: screenW, height: screenH)
      let tolX = max(screenW * 0.25, 15)
      let tolY = max(screenH * 0.25, 15)
      let outerRect = innerRect.insetBy(dx: -tolX, dy: -tolY)

      self.innerBboxLayer.path = UIBezierPath(roundedRect: innerRect, cornerRadius: 8).cgPath
      self.bboxLayer.path = UIBezierPath(roundedRect: outerRect, cornerRadius: 12).cgPath

      self.distanceLabel.text = "\(Int(dist * 100)) cm"
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - v6: Depth Gating
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   * Check if the hand is close enough in depth to the target object.
   *
   * v6.1: Uses LIVE AR distance (camera→anchor) instead of initial backend depth.
   * The anchor moves in world space as you walk toward it, so liveDistanceToObject
   * decreases. The hand depth estimate must be close to this LIVE value.
   *
   * Strategy (in priority order):
   * 1. LiDAR scene depth (most accurate) — sample depth at hand screen position
   * 2. Hand apparent size heuristic — larger hand = closer to camera
   * 3. Simple distance check — if camera is within reach distance of anchor, pass
   */
  private func checkHandDepth(
    frame: ARFrame,
    handScreenPt: CGPoint,
    handObs: VNHumanHandPoseObservation
  ) -> Bool {
    // Use LIVE distance, not initial backend depth
    let objectDist = liveDistanceToObject

    // ── Method 1: LiDAR scene depth ──────────────────────────────────────
    if let sceneDepth = frame.sceneDepth {
      let depthMap = sceneDepth.depthMap
      let depthW = CVPixelBufferGetWidth(depthMap)
      let depthH = CVPixelBufferGetHeight(depthMap)

      let normX = handScreenPt.x / cachedSW
      let normY = handScreenPt.y / cachedSH

      let depthPixelX = Int(normY * CGFloat(depthW))
      let depthPixelY = Int((1.0 - normX) * CGFloat(depthH))

      let clampedX = max(0, min(depthPixelX, depthW - 1))
      let clampedY = max(0, min(depthPixelY, depthH - 1))

      CVPixelBufferLockBaseAddress(depthMap, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

      if let baseAddr = CVPixelBufferGetBaseAddress(depthMap) {
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr = baseAddr.advanced(by: clampedY * bytesPerRow + clampedX * MemoryLayout<Float32>.size)
        let handDepth = ptr.load(as: Float32.self)

        if handDepth > 0 && handDepth < 10 {
          let depthDiff = abs(handDepth - objectDist)
          let isClose = depthDiff < depthReachThreshold
          if arFrameCount % 30 == 0 {
            NSLog("📏 [Depth-LiDAR] hand=%.2fm obj=%.2fm(live) diff=%.2fm close=%d",
                  handDepth, objectDist, depthDiff, isClose ? 1 : 0)
          }
          return isClose
        }
      }
    }

    // ── Method 2: Hand apparent size heuristic ───────────────────────────
    if let wrist = try? handObs.recognizedPoint(.wrist),
       let middleTip = try? handObs.recognizedPoint(.middleTip),
       wrist.confidence > 0.3 && middleTip.confidence > 0.3 {

      let handSpan = sqrt(pow(wrist.location.x - middleTip.location.x, 2) +
                          pow(wrist.location.y - middleTip.location.y, 2))

      let k: CGFloat = 0.11
      let estimatedHandDist = Float(k / max(handSpan, 0.01))

      // Compare hand distance to LIVE object distance
      let depthDiff = abs(estimatedHandDist - objectDist)
      let isClose = depthDiff < depthReachThreshold

      if arFrameCount % 30 == 0 {
        NSLog("📏 [Depth-Heuristic] handSpan=%.3f est=%.2fm obj=%.2fm(live) diff=%.2fm close=%d",
              handSpan, estimatedHandDist, objectDist, depthDiff, isClose ? 1 : 0)
      }
      return isClose
    }

    // ── Method 3: Camera proximity fallback ──────────────────────────────
    // If hand detection can't estimate depth, but the camera itself is
    // very close to the anchor, the user is likely at the object
    if objectDist < 0.5 {
      if arFrameCount % 30 == 0 {
        NSLog("📏 [Depth-Proximity] Camera %.2fm from anchor — close enough", objectDist)
      }
      return true
    }

    return false
  }

  // ── Aspect-fill crop ────────────────────────────────────────────────────

  private func computeAspectFillCrop(imageW: CGFloat, imageH: CGFloat) {
    guard !cropComputed else { return }
    let sw = cachedSW, sh = cachedSH
    guard sw > 0, sh > 0, imageW > 0, imageH > 0 else { return }
    let rotW = imageH, rotH = imageW
    let cameraAspect = rotW / rotH, screenAspect = sw / sh
    if cameraAspect > screenAspect {
      let scaleToFillH = sh / rotH
      let displayedW = rotW * scaleToFillH
      cropFracX = ((displayedW - sw) / 2) / displayedW
    }
    cropComputed = true
    NSLog("📐 [ReachingVC] cropFracX=%.4f", cropFracX)
  }

  private func visionToScreen(_ pt: CGPoint) -> CGPoint {
    let sw = cachedSW, sh = cachedSH
    let adjustedX = cropFracX > 0
      ? ((pt.x - cropFracX) / (1.0 - 2 * cropFracX)) * sw
      : pt.x * sw
    return CGPoint(x: adjustedX, y: (1 - pt.y) * sh)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Process AR Frame
  // ═══════════════════════════════════════════════════════════════════════════

  private func processARFrame(_ frame: ARFrame) {
    guard running else { return }
    arFrameCount += 1

    // Wait for AR to stabilize, then place world anchor
    if !anchorPlaced {
      if arFrameCount >= anchorWaitFrames {
        placeWorldAnchor(frame: frame)
        say("Target locked.")
      }
      return
    }

    // Reproject world anchor to screen (LOCKED IN SPACE)
    reprojectBbox(frame: frame)

    // Aspect-fill crop for hand detection
    let pb = frame.capturedImage
    computeAspectFillCrop(imageW: CGFloat(CVPixelBufferGetWidth(pb)),
                          imageH: CGFloat(CVPixelBufferGetHeight(pb)))

    // Detect hand
    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
    do { try handler.perform([handReq]) } catch { return }

    guard projectedBboxW > 0 else { return }
    let bboxCx = projectedBboxCenter.x
    let bboxCy = projectedBboxCenter.y
    let bboxHalfW = projectedBboxW / 2
    let bboxHalfH = projectedBboxH / 2

    // No hand detected
    guard let obs = handReq.results?.first else {
      noHandFrames += 1; successFrames = 0; handIsCloseEnoughInDepth = false
      if noHandFrames == noHandLimit {
        DispatchQueue.main.async { [weak self] in self?.say("Show your hand to the camera.") }
      }
      if noHandFrames > noHandLimit + noHandRepeatCycle { noHandFrames = 0 }
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
        self?.depthHintLabel.isHidden = true
        self?.updateDirectionUI(.searching)
      }
      proximityZone = .searching; return
    }

    noHandFrames = 0
    guard let visionPt = handCenter(obs) else {
      successFrames = 0; handIsCloseEnoughInDepth = false
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
      }
      return
    }

    let handScreen = visionToScreen(visionPt)
    let screenX = handScreen.x, screenY = handScreen.y
    let dx = screenX - bboxCx, dy = screenY - bboxCy
    let dist = sqrt(dx * dx + dy * dy)

    // 2D overlap checks
    let innerOverlap = abs(dx) < bboxHalfW && abs(dy) < bboxHalfH
    let tolX = max(bboxHalfW * 0.3, 20), tolY = max(bboxHalfH * 0.3, 20)
    let nearOverlap = CGRect(x: bboxCx - bboxHalfW - tolX, y: bboxCy - bboxHalfH - tolY,
                             width: bboxHalfW*2 + tolX*2, height: bboxHalfH*2 + tolY*2)
      .contains(CGPoint(x: screenX, y: screenY))

    // v6: Depth check
    let depthOk = checkHandDepth(frame: frame, handScreenPt: handScreen, handObs: obs)
    handIsCloseEnoughInDepth = depthOk

    // Proximity zones (2D-based for audio feedback)
    let sw = cachedSW, sh = cachedSH
    let normDist = dist / max(sw, sh)
    let newProx: ProximityZone
    if innerOverlap && depthOk { newProx = .centered }
    else if innerOverlap       { newProx = .veryClose }  // 2D aligned but not deep enough
    else if nearOverlap        { newProx = .close }
    else if normDist < 0.15    { newProx = .close }
    else if normDist < 0.30    { newProx = .medium }
    else                       { newProx = .far }
    proximityZone = newProx

    let direction = computeDirection(handX: screenX, handY: screenY,
                                     bboxCx: bboxCx, bboxCy: bboxCy,
                                     bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH)
    speakDirectionIfNeeded(direction)

    // UI update
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let dotR: CGFloat = 12
      self.handDot.isHidden = false; self.handDotGlow.isHidden = false
      self.handDot.path = UIBezierPath(ovalIn: CGRect(x: screenX-dotR, y: screenY-dotR,
                                                       width: dotR*2, height: dotR*2)).cgPath
      self.handDotGlow.path = UIBezierPath(ovalIn: CGRect(x: screenX-dotR*2, y: screenY-dotR*2,
                                                           width: dotR*4, height: dotR*4)).cgPath

      let color: UIColor = {
        switch newProx {
        case .centered:            return .systemGreen
        case .veryClose:           return .systemYellow  // 2D aligned, need depth
        case .close:               return .systemYellow
        case .medium:              return .systemOrange
        default:                   return .systemRed
        }
      }()
      self.handDot.fillColor = color.cgColor
      self.handDotGlow.fillColor = color.withAlphaComponent(0.2).cgColor
      self.updateDirectionUI(direction)

      // v6: Show depth hint when 2D aligned but depth not met
      if innerOverlap && !depthOk {
        self.depthHintLabel.isHidden = false
        self.depthHintLabel.text = "Move hand closer to the object"
      } else {
        self.depthHintLabel.isHidden = true
      }

      // Progress ring (only counts when BOTH 2D and depth are satisfied)
      if self.successFrames > 0 {
        self.progressRing.isHidden = false
        let progress = CGFloat(self.successFrames) / CGFloat(self.successThreshold)
        self.progressRing.strokeEnd = progress
        let ringR: CGFloat = dotR + 8
        let ringPath = UIBezierPath(arcCenter: CGPoint(x: screenX, y: screenY),
                                    radius: ringR, startAngle: -.pi/2,
                                    endAngle: -.pi/2 + .pi*2, clockwise: true)
        self.progressRing.path = ringPath.cgPath
      } else {
        self.progressRing.isHidden = true
        self.progressRing.strokeEnd = 0
      }
    }

    // v6: Success requires BOTH 2D overlap AND depth proximity
    if innerOverlap && depthOk {
      successFrames += 1
      if successFrames >= successThreshold { handleSuccess() }
    } else {
      successFrames = 0
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Apple-Quality UI
  // ═══════════════════════════════════════════════════════════════════════════

  private func setupAppleUI() {
    bboxLayer.strokeColor = UIColor.systemCyan.cgColor
    bboxLayer.fillColor = UIColor.systemCyan.withAlphaComponent(0.06).cgColor
    bboxLayer.lineWidth = 2.5
    bboxLayer.lineDashPattern = [8, 4]
    bboxLayer.isHidden = true
    view.layer.addSublayer(bboxLayer)

    innerBboxLayer.strokeColor = UIColor.white.cgColor
    innerBboxLayer.fillColor = UIColor.clear.cgColor
    innerBboxLayer.lineWidth = 2
    innerBboxLayer.isHidden = true
    view.layer.addSublayer(innerBboxLayer)

    handDotGlow.fillColor = UIColor.systemGreen.withAlphaComponent(0.3).cgColor
    handDotGlow.isHidden = true
    view.layer.addSublayer(handDotGlow)

    handDot.fillColor = UIColor.systemGreen.cgColor
    handDot.strokeColor = UIColor.white.cgColor
    handDot.lineWidth = 2.5
    handDot.shadowColor = UIColor.black.cgColor
    handDot.shadowOffset = .zero
    handDot.shadowRadius = 4
    handDot.shadowOpacity = 0.5
    handDot.isHidden = true
    view.layer.addSublayer(handDot)

    let topBlur = UIBlurEffect(style: .systemThinMaterialDark)
    topBar = UIVisualEffectView(effect: topBlur)
    topBar.translatesAutoresizingMaskIntoConstraints = false
    topBar.layer.cornerRadius = 20
    topBar.clipsToBounds = true
    view.addSubview(topBar)

    objectNameLabel = UILabel()
    objectNameLabel.text = "🎯  \(objectName)"
    objectNameLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
    objectNameLabel.textColor = .white
    objectNameLabel.textAlignment = .center
    objectNameLabel.translatesAutoresizingMaskIntoConstraints = false
    topBar.contentView.addSubview(objectNameLabel)

    distanceLabel = UILabel()
    distanceLabel.text = "—"
    distanceLabel.font = UIFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    distanceLabel.textColor = UIColor.white.withAlphaComponent(0.7)
    distanceLabel.textAlignment = .center
    distanceLabel.translatesAutoresizingMaskIntoConstraints = false
    topBar.contentView.addSubview(distanceLabel)

    let bottomBlur = UIBlurEffect(style: .systemThinMaterialDark)
    bottomBar = UIVisualEffectView(effect: bottomBlur)
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.layer.cornerRadius = 24
    bottomBar.clipsToBounds = true
    view.addSubview(bottomBar)

    directionLabel = UILabel()
    directionLabel.text = "Show your hand…"
    directionLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
    directionLabel.textColor = .white
    directionLabel.textAlignment = .center
    directionLabel.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.contentView.addSubview(directionLabel)

    // v6: Depth hint label
    depthHintLabel = UILabel()
    depthHintLabel.text = "Move hand closer to the object"
    depthHintLabel.font = UIFont.systemFont(ofSize: 15, weight: .medium)
    depthHintLabel.textColor = .systemYellow
    depthHintLabel.textAlignment = .center
    depthHintLabel.isHidden = true
    depthHintLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(depthHintLabel)

    progressRing = CAShapeLayer()
    progressRing.strokeColor = UIColor.systemGreen.cgColor
    progressRing.fillColor = UIColor.clear.cgColor
    progressRing.lineWidth = 3
    progressRing.lineCap = .round
    progressRing.strokeEnd = 0
    progressRing.isHidden = true
    view.layer.addSublayer(progressRing)

    cancelButton = UIButton(type: .system)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.setTitleColor(.white, for: .normal)
    cancelButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
    cancelButton.backgroundColor = UIColor.white.withAlphaComponent(0.15)
    cancelButton.layer.cornerRadius = 22
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    view.addSubview(cancelButton)

    NSLayoutConstraint.activate([
      topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
      topBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      topBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.7),
      topBar.heightAnchor.constraint(equalToConstant: 56),

      objectNameLabel.topAnchor.constraint(equalTo: topBar.contentView.topAnchor, constant: 6),
      objectNameLabel.centerXAnchor.constraint(equalTo: topBar.contentView.centerXAnchor),
      objectNameLabel.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 16),
      objectNameLabel.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -16),

      distanceLabel.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor, constant: -6),
      distanceLabel.centerXAnchor.constraint(equalTo: topBar.contentView.centerXAnchor),

      bottomBar.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),
      bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      bottomBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
      bottomBar.heightAnchor.constraint(equalToConstant: 56),

      directionLabel.centerYAnchor.constraint(equalTo: bottomBar.contentView.centerYAnchor),
      directionLabel.centerXAnchor.constraint(equalTo: bottomBar.contentView.centerXAnchor),
      directionLabel.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 24),
      directionLabel.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -24),

      // v6: depth hint between bottom bar and cancel
      depthHintLabel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),
      depthHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

      cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancelButton.widthAnchor.constraint(equalToConstant: 120),
      cancelButton.heightAnchor.constraint(equalToConstant: 44),
    ])

    view.accessibilityLabel = "Reaching guidance for \(objectName). Tap Cancel to stop."
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Audio
  // ═══════════════════════════════════════════════════════════════════════════

  private func setupAudio() {
    do {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try s.setActive(true)
      let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
      engine.attach(player)
      let sr: Double = 44100; let dur: Double = 0.06; let freq: Double = 1000
      let fc = AVAudioFrameCount(sr * dur)
      guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
      audioFmt = fmt; engine.connect(player, to: engine.mainMixerNode, format: fmt)
      guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
      buf.frameLength = fc; let d = buf.floatChannelData![0]
      for i in 0..<Int(fc) {
        let t = Double(i) / sr
        let env = min(t / 0.005, 1) * min((dur - t) / 0.005, 1)
        d[i] = Float(sin(2 * .pi * freq * t) * 0.5 * env)
      }
      beepBuf = buf; playerNode = player; audioEngine = engine
      try engine.start()
    } catch { NSLog("⚠️ Audio: %@", error.localizedDescription) }
  }

  private func setupHaptics() {
    guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
    hapticEngine = try? CHHapticEngine()
    try? hapticEngine?.start()
  }

  private func startBeepLoop() {
    let t = DispatchSource.makeTimerSource(queue: audioQ)
    t.schedule(deadline: .now(), repeating: .milliseconds(50))
    t.setEventHandler { [weak self] in self?.tickBeep() }
    beepTimer = t; t.resume()
  }

  private func tickBeep() {
    guard running, proximityZone != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let iv: TimeInterval = {
      switch proximityZone {
      case .searching: return 99
      case .far:       return 0.7
      case .medium:    return 0.4
      case .close:     return 0.2
      case .veryClose: return 0.08
      case .centered:  return 0.04
      }
    }()
    if now - lastBeep >= iv {
      if let p = playerNode, let b = beepBuf {
        switch currentDirection {
        case .left, .topLeft, .downLeft: p.pan = -0.8
        case .right, .topRight, .downRight: p.pan = 0.8
        default: p.pan = 0.0
        }
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        if !p.isPlaying { p.play() }
      }
      lastBeep = now
    }
  }

  private func triggerHaptic(_ intensity: Float) {
    guard let engine = hapticEngine else { return }
    let event = CHHapticEvent(eventType: .hapticTransient,
                              parameters: [
                                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                              ],
                              relativeTime: 0)
    try? engine.makePlayer(with: CHHapticPattern(events: [event], parameters: [])).start(atTime: 0)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Cancel / Success / Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  @objc private func cancelTapped() {
    say("Cancelled"); finishWith(success: false, reason: "user_cancelled")
  }

  private func handleSuccess() {
    guard running, !hasCompleted else { return }
    running = false; hasCompleted = true
    NSLog("🎉 [ReachingVC] SUCCESS – reached %@", objectName)
    beepTimer?.cancel(); beepTimer = nil
    playSuccessTone()
    triggerHaptic(1.0)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.directionLabel.text = "✅  \(self.objectName) reached!"
      self.directionLabel.textColor = .systemGreen
      self.depthHintLabel.isHidden = true

      let flash = UIView(frame: self.view.bounds)
      flash.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
      self.view.addSubview(flash)
      UIView.animate(withDuration: 1.0) { flash.alpha = 0 } completion: { _ in flash.removeFromSuperview() }
    }
    say("\(objectName) reached!")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      self?.finishWith(success: true, reason: "reached")
    }
  }

  private func playSuccessTone() {
    guard let player = playerNode, let fmt = audioFmt else { return }
    let sr: Double = 44100; let dur: Double = 0.5; let fc = AVAudioFrameCount(sr * dur)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
    buf.frameLength = fc; let d = buf.floatChannelData![0]
    for i in 0..<Int(fc) {
      let t = Double(i) / sr; let f = 523.25 * pow(2, t / dur)
      d[i] = Float(sin(2 * .pi * f * t) * 0.6 * min(t / 0.01, 1) * min((dur - t) / 0.08, 1))
    }
    player.pan = 0; player.scheduleBuffer(buf, at: nil, options: .interrupts)
    if !player.isPlaying { player.play() }
  }

  private func finishWith(success: Bool, reason: String) {
    guard !hasCompleted || success else { return }
    hasCompleted = true; running = false; cleanup()
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.dismiss(animated: true) {
        self.onDone(["success": success, "object": self.objectName,
                     "reason": reason,
                     "message": success ? "\(self.objectName) reached!" : "Cancelled"])
      }
    }
  }

  private func cleanup() {
    running = false; beepTimer?.cancel(); beepTimer = nil
    playerNode?.stop(); audioEngine?.stop(); audioEngine = nil
    hapticEngine?.stop(); hapticEngine = nil
    synth.stopSpeaking(at: .immediate); sceneView.session.pause()
  }

  // ── Speech ──────────────────────────────────────────────────────────────

  private func say(_ text: String) {
    synth.stopSpeaking(at: .immediate)
    let u = AVSpeechUtterance(string: text)
    u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
    u.voice = AVSpeechSynthesisVoice(language: "en-US")
    synth.speak(u); NSLog("🗣 [ReachingVC] %@", text)
  }

  private func speakDirectionIfNeeded(_ direction: Direction) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime
    if direction == currentDirection { directionStableFrames += 1 } else { directionStableFrames = 1 }

    // v6: When 2D aligned but depth wrong, speak depth hint
    if direction == .centered && !handIsCloseEnoughInDepth {
      if now - lastSpeechTime > 2.5 {
        say("Move your hand forward to reach the object")
        lastSpeechTime = now
      }
      return
    }

    if direction == lastSpokenDirection {
      if direction == .centered && (now - lastSpeechTime) > 3.0 { say("Centered!"); lastSpeechTime = now }
      return
    }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      say(direction == .centered ? "Centered!" : direction.rawValue)
      lastSpokenDirection = direction; lastSpeechTime = now
      if direction != .centered && direction != .searching { triggerHaptic(0.4) }
    }
  }

  // ── Direction computation ───────────────────────────────────────────────

  private func computeDirection(handX: CGFloat, handY: CGFloat,
                                bboxCx: CGFloat, bboxCy: CGFloat,
                                bboxHalfW: CGFloat, bboxHalfH: CGFloat) -> Direction {
    let dx = handX - bboxCx, dy = handY - bboxCy
    if abs(dx) < bboxHalfW && abs(dy) < bboxHalfH { return .centered }
    let angleRad = atan2(-(bboxCy - handY), bboxCx - handX)
    var angleDeg = angleRad * 180.0 / .pi
    if angleDeg < 0 { angleDeg += 360 }
    switch angleDeg {
    case 0..<22.5, 337.5...360: return .right
    case 22.5..<67.5:    return .topRight
    case 67.5..<112.5:   return .top
    case 112.5..<157.5:  return .topLeft
    case 157.5..<202.5:  return .left
    case 202.5..<247.5:  return .downLeft
    case 247.5..<292.5:  return .down
    case 292.5..<337.5:  return .downRight
    default: return .right
    }
  }

  private func handCenter(_ obs: VNHumanHandPoseObservation) -> CGPoint? {
    if let tip = try? obs.recognizedPoint(.indexTip), tip.confidence > 0.3 { return tip.location }
    if let mcp = try? obs.recognizedPoint(.middleMCP), mcp.confidence > 0.3 { return mcp.location }
    if let w = try? obs.recognizedPoint(.wrist), w.confidence > 0.3 { return w.location }
    return nil
  }

  private func updateDirectionUI(_ newDir: Direction) {
    guard newDir != currentDirection else { return }
    currentDirection = newDir
    directionLabel.text = newDir == .centered ? "✅  Centered!" : newDir.rawValue
    directionLabel.textColor = newDir == .centered ? .systemGreen : .white

    UIView.animate(withDuration: 0.15) {
      self.bottomBar.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
    } completion: { _ in
      UIView.animate(withDuration: 0.15) {
        self.bottomBar.transform = .identity
      }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ARSessionDelegate
// ═══════════════════════════════════════════════════════════════════════════════

extension ReachingViewController: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    visionQ.async { [weak self] in self?.processARFrame(frame) }
  }
  func session(_ session: ARSession, didFailWithError error: Error) {
    say("Tracking failed.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.finishWith(success: false, reason: "ar_error")
    }
  }
  func sessionWasInterrupted(_ session: ARSession) { say("Tracking paused") }
  func sessionInterruptionEnded(_ session: ARSession) { say("Tracking resumed") }
}
