//ReachingModule.swift — ARKit Reaching v7 (Depth Overhaul)

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

  // ── Depth thresholds ─────────────────────────────────────────────────────
  // NOTE: No depthForwardBias. Tighter, accurate thresholds.
  private let raycastDepthThreshold: Float = 0.18   // 18 cm — raycast vs anchor
  private let lidarDepthThreshold:   Float = 0.12   // 12 cm — LiDAR is very accurate
  private let heuristicDepthThreshold: Float = 0.22 // 22 cm — hand span heuristic
  // Camera-to-anchor proximity gate for success.
  // Average adult reach is ~65cm. User must be within this distance AND 2D-centered.
  // This is device-agnostic: the phone itself moves, no hand-depth sensing needed.
  private let reachProximityThreshold: Float = 0.70  // 70cm — must walk to object

  // ── Config ───────────────────────────────────────────────────────────────
  private let bboxRaw: [CGFloat]
  private let objectName: String
  private let backendDepth: Float?
  private let imageWidth:   CGFloat
  private let imageHeight:  CGFloat
  private let onDone: ([String: Any]) -> Void
  private var bboxNormalized: [CGFloat] = [0, 0, 0, 0]

  // ── 3D World Anchor (fixed world-space corners, from v6.1) ───────────────
  private var objectWorldPosition: simd_float3?
  private var objectWorldCornerTR: simd_float3 = .zero
  private var objectWorldCornerBL: simd_float3 = .zero
  private var objectWorldHalfW: Float = 0
  private var objectWorldHalfH: Float = 0
  private var anchorPlaced = false
  private var anchorDepth: Float = 0.5
  private var liveDistanceToObject: Float = 0.5

  private var handIsCloseEnoughInDepth = false

  // ── ARKit ────────────────────────────────────────────────────────────────
  private var sceneView: ARSCNView!
  private var arFrameCount = 0
  private let anchorWaitFrames = 15
  private var meshReconstructionEnabled = false
  private var lastFrameProcessedAt: TimeInterval = 0   // timestamp throttle (fixes ARFrame retention)
  private let frameProcessInterval: TimeInterval = 0.05 // max 20fps vision processing
  private var anchorRefinementFrames = 0           // counts from 1 after anchor placed
  private let anchorRefinementLimit = 90           // try raycast refinement for ~3s post-placement

  // ── Vision ───────────────────────────────────────────────────────────────
  private let handReq = VNDetectHumanHandPoseRequest()
  private let visionQ = DispatchQueue(label: "reach.vision", qos: .userInitiated)

  // ── Audio ────────────────────────────────────────────────────────────────
  private var audioEngine: AVAudioEngine?
  private var playerNode: AVAudioPlayerNode?
  private var beepBuf: AVAudioPCMBuffer?
  private var audioFmt: AVAudioFormat?
  private var beepTimer: DispatchSourceTimer?
  private let audioQ = DispatchQueue(label: "reach.audio", qos: .userInitiated)
  private var lastBeep: TimeInterval = 0

  // ── Speech ───────────────────────────────────────────────────────────────
  private let synth = AVSpeechSynthesizer()
  private var lastSpokenDirection: Direction = .searching
  private var lastSpeechTime: TimeInterval = 0
  private let speechCooldown: TimeInterval = 1.2
  private var directionStableFrames = 0
  private let directionStableThreshold = 4

  // ── Haptics ──────────────────────────────────────────────────────────────
  private var hapticEngine: CHHapticEngine?

  // ── UI ───────────────────────────────────────────────────────────────────
  private let bboxLayer      = CAShapeLayer()
  private let innerBboxLayer = CAShapeLayer()
  private let handDot        = CAShapeLayer()
  private let handDotGlow    = CAShapeLayer()
  private var topBar: UIVisualEffectView!
  private var bottomBar: UIVisualEffectView!
  private var directionLabel: UILabel!
  private var objectNameLabel: UILabel!
  private var cancelButton: UIButton!
  private var progressRing: CAShapeLayer!
  private var distanceLabel: UILabel!
  private var depthHintLabel: UILabel!
  private var depthMethodLabel: UILabel!   // debug: shows which depth method fired

  // ── Projected bbox ────────────────────────────────────────────────────────
  private var projectedBboxCenter = CGPoint.zero
  private var projectedBboxW: CGFloat = 0
  private var projectedBboxH: CGFloat = 0

  // ── State ─────────────────────────────────────────────────────────────────
  private var running = false
  private var currentDirection: Direction = .searching
  private var proximityZone: ProximityZone = .searching
  private var noHandFrames = 0
  private var successFrames = 0
  private var hasCompleted = false

  private let successThreshold = 35   // ~1.2s sustained 2D overlap at 30fps
  private let noHandLimit = 50
  private let noHandRepeatCycle = 120

  // ── Cached screen bounds ──────────────────────────────────────────────────
  private var cachedSW: CGFloat = 393
  private var cachedSH: CGFloat = 852

  // ── Aspect-fill crop ──────────────────────────────────────────────────────
  private var cropFracX: CGFloat = 0
  private var cropComputed = false

  // ── Init ──────────────────────────────────────────────────────────────────
  init(bboxRaw: [CGFloat], objectName: String, backendDepth: Float?,
       imageWidth: CGFloat, imageHeight: CGFloat,
       onDone: @escaping ([String: Any]) -> Void) {
    self.bboxRaw      = bboxRaw
    self.objectName   = objectName
    self.backendDepth = backendDepth
    self.imageWidth   = imageWidth
    self.imageHeight  = imageHeight
    self.onDone       = onDone
    super.init(nibName: nil, bundle: nil)
    handReq.maximumHandCount = 1
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    cachedSW = UIScreen.main.bounds.width
    cachedSH = UIScreen.main.bounds.height
    NSLog("📐 [ReachingVC] Screen: %.0f×%.0f", cachedSW, cachedSH)
    normalizeBbox()
    setupARView()
    setupAppleUI()
    setupAudio()
    setupHaptics()
    setupTapToDismiss()
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

  // ── Tap anywhere to dismiss ───────────────────────────────────────────────
  private func setupTapToDismiss() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
    tap.cancelsTouchesInView = false
    view.addGestureRecognizer(tap)
  }

  @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
    guard !hasCompleted else { return }
    let pt = gesture.location(in: view)
    if cancelButton.frame.contains(pt) { return }
    if topBar.frame.contains(pt)       { return }
    if bottomBar.frame.contains(pt)    { return }
    cancelTapped()
  }

  // ── Normalize bbox ────────────────────────────────────────────────────────
  private func normalizeBbox() {
    let x1 = min(abs(bboxRaw[0]), abs(bboxRaw[2]))
    let y1 = min(abs(bboxRaw[1]), abs(bboxRaw[3]))
    let x2 = max(abs(bboxRaw[0]), abs(bboxRaw[2]))
    let y2 = max(abs(bboxRaw[1]), abs(bboxRaw[3]))
    let maxVal = max(x1, y1, x2, y2)

    if imageWidth > 0 && imageHeight > 0 && maxVal > 1.0 {
      bboxNormalized = [x1/imageWidth, y1/imageHeight, x2/imageWidth, y2/imageHeight]
    } else if maxVal <= 1.0 {
      bboxNormalized = [x1, y1, x2, y2]
    } else {
      let gW: CGFloat = max(x2 * 1.1, 1152), gH: CGFloat = max(y2 * 1.1, 2048)
      bboxNormalized = [x1/gW, y1/gH, x2/gW, y2/gH]
    }
    bboxNormalized = bboxNormalized.map { min(max($0, 0), 1) }
    let bw = bboxNormalized[2] - bboxNormalized[0]
    let bh = bboxNormalized[3] - bboxNormalized[1]
    if bw < 0.01 || bh < 0.01 { bboxNormalized = [0.35, 0.35, 0.65, 0.65] }
    NSLog("📦 [ReachingVC] Normalized bbox: [%.3f, %.3f, %.3f, %.3f]",
          bboxNormalized[0], bboxNormalized[1], bboxNormalized[2], bboxNormalized[3])
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

    // ── Enable plane detection — feeds raycasting on ALL devices ──────────
    // Without this, estimatedPlane raycasts have nothing to hit.
    config.planeDetection = [.horizontal, .vertical]

    // ── Enable LiDAR scene depth (Pro/Max devices) ────────────────────────
    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      config.frameSemantics.insert(.sceneDepth)
      NSLog("📷 [ReachingVC] LiDAR scene depth ENABLED")
    }

    // ── Enable mesh reconstruction (A12+ without LiDAR, iPhone 12+) ──────
    // This is the same capability the Measure app uses for accurate depth.
    // ARKit builds a 3D mesh of the environment from motion parallax.
    // Raycasting against this mesh is accurate to ~2-5 cm.
    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      config.sceneReconstruction = .mesh
      meshReconstructionEnabled = true
      NSLog("📷 [ReachingVC] Mesh reconstruction ENABLED — Measure-quality depth")
    } else {
      NSLog("📷 [ReachingVC] No mesh — using plane estimation + LiDAR fallback")
    }

    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    startBeepLoop()
    NSLog("📷 [ReachingVC] AR session started")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Place World Anchor (fixed world-space corners)
  // ═══════════════════════════════════════════════════════════════════════════

  private func placeWorldAnchor(frame: ARFrame) {
    let sw = cachedSW, sh = cachedSH
    let photoAspect = imageWidth / imageHeight
    let screenAspect = sw / sh

    var scaleX: CGFloat = 1, scaleY: CGFloat = 1
    var offsetX: CGFloat = 0, offsetY: CGFloat = 0
    if photoAspect > screenAspect {
      scaleX  = photoAspect / screenAspect; offsetX = (scaleX - 1) / 2
    } else {
      scaleY  = screenAspect / photoAspect; offsetY = (scaleY - 1) / 2
    }

    let bx1 = (bboxNormalized[0] * scaleX - offsetX) * sw
    let by1 = (bboxNormalized[1] * scaleY - offsetY) * sh
    let bx2 = (bboxNormalized[2] * scaleX - offsetX) * sw
    let by2 = (bboxNormalized[3] * scaleY - offsetY) * sh
    let screenCenter = CGPoint(x: (bx1+bx2)/2, y: (by1+by2)/2)

    let camera = frame.camera
    let depth  = backendDepth ?? 0.5
    anchorDepth = depth

    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution
    let arW = imgRes.width, arH = imgRes.height

    let arPxX = (screenCenter.y / sh) * arW
    let arPxY = (1.0 - screenCenter.x / sw) * arH

    let fx = CGFloat(intrinsics[0][0]), fy = CGFloat(intrinsics[1][1])
    let cx = CGFloat(intrinsics[2][0]), cy = CGFloat(intrinsics[2][1])

    let rX = Float((arPxX - cx) / fx)
    let rY = Float((arPxY - cy) / fy)

    let camT    = camera.transform
    let rayCam  = simd_normalize(simd_float3(rX, -rY, -1.0))
    let worldRay = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos  = simd_make_float3(camT.columns.3)
    let worldPos = camPos + worldRay * depth

    objectWorldPosition = worldPos

    let bboxNormW = bboxNormalized[2] - bboxNormalized[0]
    let bboxNormH = bboxNormalized[3] - bboxNormalized[1]
    objectWorldHalfW = depth * Float(bboxNormW) * 0.5
    objectWorldHalfH = depth * Float(bboxNormH) * 0.8

    // Store fixed world-space corners using PLACEMENT-TIME camera axes
    let placementRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let placementUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = worldPos + placementRight * objectWorldHalfW + placementUp * objectWorldHalfH
    objectWorldCornerBL = worldPos - placementRight * objectWorldHalfW - placementUp * objectWorldHalfH

    anchorPlaced = true
    anchorRefinementFrames = 1   // immediately begin ARKit raycast refinement
    NSLog("🎯 [ReachingVC] ✅ Anchor SEEDED at (%.3f, %.3f, %.3f) depth=%.2fm (Qwen — refining with ARKit...)",
          worldPos.x, worldPos.y, worldPos.z, depth)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if let d = self.backendDepth { self.distanceLabel.text = "\(Int(d*100)) cm" }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Refine Anchor Depth with ARKit Raycast (THE CORE FIX)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // THE PROBLEM: Qwen AI estimates object depth from a single image (monocular).
  // This is inherently imprecise (±10-30cm). The bbox X,Y are accurate because
  // they come from pixel detection, but placing the 3D anchor at the WRONG depth
  // causes the box to float in mid-air when the user moves or approaches — even
  // though it looks correct head-on.
  //
  // THE FIX: Objects like bottles, cups, food sit ON SURFACES (desks, shelves).
  // ARKit detects these surfaces via plane estimation (works on ALL devices, even
  // iPhone SE with no LiDAR). Shooting a ray at the bbox center will HIT the
  // desk/shelf surface, giving us the true depth — exactly what Measure app does.
  //
  // We keep Qwen's estimate as the seed (so bbox is visible immediately), then
  // replace it with the ARKit measurement within the first ~3 seconds.

  private func tryRefineAnchorDepth(frame: ARFrame) {
    guard let currentPos = objectWorldPosition else { return }

    let sw = cachedSW, sh = cachedSH
    let camera = frame.camera
    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution

    // ── Compute bbox center screen point ─────────────────────────────────
    let photoAspect = imageWidth / imageHeight
    let screenAspect = sw / sh
    var scaleX: CGFloat = 1, scaleY: CGFloat = 1
    var offsetX: CGFloat = 0, offsetY: CGFloat = 0
    if photoAspect > screenAspect {
      scaleX  = photoAspect / screenAspect; offsetX = (scaleX - 1) / 2
    } else {
      scaleY  = screenAspect / photoAspect; offsetY = (scaleY - 1) / 2
    }
    let bx1 = (bboxNormalized[0] * scaleX - offsetX) * sw
    let by1 = (bboxNormalized[1] * scaleY - offsetY) * sh
    let bx2 = (bboxNormalized[2] * scaleX - offsetX) * sw
    let by2 = (bboxNormalized[3] * scaleY - offsetY) * sh
    let screenCenter = CGPoint(x: (bx1+bx2)/2, y: (by1+by2)/2)

    // ── Build world-space ray direction from camera intrinsics ────────────
    let arPxX = (screenCenter.y / sh) * imgRes.width
    let arPxY = (1.0 - screenCenter.x / sw) * imgRes.height
    let fx = Float(intrinsics[0][0]), fy = Float(intrinsics[1][1])
    let cx = Float(intrinsics[2][0]), cy = Float(intrinsics[2][1])
    let rX = (Float(arPxX) - cx) / fx
    let rY = (Float(arPxY) - cy) / fy
    let rayCam   = simd_normalize(simd_float3(rX, -rY, -1.0))
    let camT     = camera.transform
    let worldDir = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos   = simd_make_float3(camT.columns.3)

    // ── Fire raycast — existingPlaneGeometry first, then estimatedPlane ───
    // Note: we're raycasting at the OBJECT LOCATION (not through the hand).
    // The object rests on a physical surface that ARKit has detected.
    var hitPos: simd_float3? = nil
    for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
      let query = ARRaycastQuery(origin: camPos, direction: worldDir,
                                 allowing: target, alignment: .any)
      if let hit = sceneView.session.raycast(query).first {
        hitPos = simd_make_float3(hit.worldTransform.columns.3)
        break
      }
    }

    guard let hp = hitPos else {
      if anchorRefinementFrames % 30 == 0 {
        NSLog("🎯 [Refine] No plane hit yet (frame %d) — planes still forming", anchorRefinementFrames)
      }
      return
    }

    let newDepth = simd_length(hp - camPos)

    // Sanity check: must be a plausible object distance
    guard newDepth > 0.08 && newDepth < 3.0 else {
      NSLog("🎯 [Refine] Rejected hit at %.2fm (out of range)", newDepth)
      return
    }

    let currentDepth = simd_length(currentPos - camPos)

    // If already within 3cm of current estimate, it's converged — stop
    if abs(newDepth - currentDepth) < 0.03 {
      NSLog("🎯 [Refine] ✅ Converged at %.2fm (diff=%.1fcm) — stopping", newDepth, abs(newDepth-currentDepth)*100)
      anchorRefinementFrames = anchorRefinementLimit
      return
    }

    // ── Update anchor to ARKit-measured depth ─────────────────────────────
    // Recompute position along the ORIGINAL camera ray (direction at placement time)
    // so X,Y stay locked to the detection result, only Z (depth) changes.
    let newWorldPos   = camPos + worldDir * newDepth
    objectWorldPosition = newWorldPos

    // Recompute fixed world-space corners at new depth
    let placementRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let placementUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = newWorldPos + placementRight * objectWorldHalfW + placementUp * objectWorldHalfH
    objectWorldCornerBL = newWorldPos - placementRight * objectWorldHalfW - placementUp * objectWorldHalfH
    anchorDepth        = newDepth
    liveDistanceToObject = newDepth

    NSLog("🎯 [Refine] ✅ DEPTH CORRECTED: Qwen=%.2fm → ARKit=%.2fm (Δ=%.1fcm)",
          currentDepth, newDepth, abs(newDepth - currentDepth) * 100)

    DispatchQueue.main.async { [weak self] in
      self?.distanceLabel.text = "\(Int(newDepth * 100)) cm"
    }

    // Stop refining — one clean ARKit hit is enough
    anchorRefinementFrames = anchorRefinementLimit
  }


  // ═══════════════════════════════════════════════════════════════════════════

  private func reprojectBbox(frame: ARFrame) {
    guard let center3D = objectWorldPosition else { return }
    let sw = cachedSW, sh = cachedSH
    let camera = frame.camera
    let viewSize = CGSize(width: sw, height: sh)

    let camPos = simd_make_float3(camera.transform.columns.3)
    let camFwd = -simd_normalize(simd_make_float3(camera.transform.columns.2))
    let camToAnchorDist = simd_length(center3D - camPos)
    if simd_dot(center3D - camPos, camFwd) < 0 {
      // Anchor is behind the camera. Two cases:
      // (a) User is close (< 55cm): they've physically passed through the object → success.
      // (b) User is far: they turned around → tell them to turn back.
      if camToAnchorDist < 0.55 {
        // Case (a): user overshot by a few cm — they've reached the object.
        NSLog("🎯 [ReachingVC] Anchor behind camera at %.2fm — auto-success (user at object)", camToAnchorDist)
        DispatchQueue.main.async { [weak self] in self?.handleSuccess() }
        return
      }
      // Case (b): genuinely turned the wrong way
      DispatchQueue.main.async { [weak self] in
        self?.bboxLayer.isHidden = true; self?.innerBboxLayer.isHidden = true
        self?.directionLabel.text = "Turn back"
      }
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastSpeechTime > 3 { say("Object is behind you."); lastSpeechTime = now }
      return
    }

    let centerScreen = camera.projectPoint(center3D, orientation: .portrait, viewportSize: viewSize)
    let trScreen     = camera.projectPoint(objectWorldCornerTR, orientation: .portrait, viewportSize: viewSize)
    let blScreen     = camera.projectPoint(objectWorldCornerBL, orientation: .portrait, viewportSize: viewSize)

    let screenW = max(abs(trScreen.x - blScreen.x), 20)
    let screenH = max(abs(trScreen.y - blScreen.y), 20)
    let dist    = simd_length(center3D - camPos)

    liveDistanceToObject = dist
    projectedBboxCenter  = centerScreen
    projectedBboxW = screenW
    projectedBboxH = screenH

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.bboxLayer.isHidden = false; self.innerBboxLayer.isHidden = false
      let innerRect = CGRect(x: centerScreen.x - screenW/2, y: centerScreen.y - screenH/2,
                             width: screenW, height: screenH)
      let tolX = max(screenW * 0.25, 15), tolY = max(screenH * 0.25, 15)
      self.innerBboxLayer.path = UIBezierPath(roundedRect: innerRect, cornerRadius: 8).cgPath
      self.bboxLayer.path      = UIBezierPath(roundedRect: innerRect.insetBy(dx: -tolX, dy: -tolY),
                                              cornerRadius: 12).cgPath
      self.distanceLabel.text  = "\(Int(dist*100)) cm"
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - v7 DEPTH CHECK — ARKit Raycast (Measure-app approach)
  // ═══════════════════════════════════════════════════════════════════════════

  /**
   Determines whether the hand is at the same depth as the target object.

   Method 1 — ARKit raycasting (primary, all devices):
     Compute a 3D ray from the camera through the hand's screen position,
     then call ARSession.raycast() against the scene geometry ARKit has built
     from motion parallax and/or LiDAR. This is exactly how the Measure app
     works. Returns a real-world intersection point whose distance we compare
     to the anchor distance. Accurate to ~3-8 cm.

   Method 2 — LiDAR depth map (secondary, Pro devices only):
     Sample the raw depth map at the hand's screen position. Accurate to ~2 cm
     but requires correct coordinate mapping (portrait screen ↔ landscape depth map).

   Method 3 — Hand span heuristic (last resort):
     Estimate depth from the apparent size of the hand in the image.
     k constant calibrated from typical 18-20 cm hand spans at known distances.

   REMOVED: camera-proximity fallback that caused false positives.
  */
  private func checkHandDepth(
    frame: ARFrame,
    handScreenPt: CGPoint,
    handObs: VNHumanHandPoseObservation
  ) -> (isClose: Bool, method: String) {

    let objectDist = liveDistanceToObject  // NO forward bias

    // ── Method 1: ARKit Raycast ────────────────────────────────────────────
    // Build the ray direction from camera intrinsics (same math as anchor placement)
    let camera     = frame.camera
    let intrinsics = camera.intrinsics
    let imgRes     = camera.imageResolution

    // Map portrait screen point → landscape AR camera image pixel
    let arPxX = (handScreenPt.y / cachedSH) * imgRes.width
    let arPxY = (1.0 - handScreenPt.x / cachedSW) * imgRes.height

    let fx = Float(intrinsics[0][0]), fy = Float(intrinsics[1][1])
    let cx = Float(intrinsics[2][0]), cy = Float(intrinsics[2][1])

    let rX = (Float(arPxX) - cx) / fx
    let rY = (Float(arPxY) - cy) / fy
    let rayCam   = simd_normalize(simd_float3(rX, -rY, -1.0))
    let camT     = camera.transform
    let worldDir = simd_normalize(simd_make_float3(camT * simd_float4(rayCam, 0)))
    let camPos   = simd_make_float3(camT.columns.3)

    // Fire the raycast against ARKit's world model
    // ARSession.raycast() is thread-safe and can be called from background queues.
    // Use .estimatedPlane so it works on all devices (mesh when available,
    // estimated planes as fallback).
    let query = ARRaycastQuery(
      origin: camPos,
      direction: worldDir,
      allowing: .estimatedPlane,
      alignment: .any
    )
    let rayResults = sceneView.session.raycast(query)

    if let hit = rayResults.first {
      let hitPos  = simd_make_float3(hit.worldTransform.columns.3)
      let handDist = simd_length(hitPos - camPos)
      let diff    = abs(handDist - objectDist)
      let isClose = diff < raycastDepthThreshold

      if arFrameCount % 20 == 0 {
        NSLog("📏 [Depth-Raycast] hand=%.2fm obj=%.2fm diff=%.2fm close=%d",
              handDist, objectDist, diff, isClose ? 1 : 0)
      }
      return (isClose, isClose ? "raycast ✅" : "raycast ❌ \(Int(diff*100))cm off")
    }

    // ── Method 2: LiDAR depth map ──────────────────────────────────────────
    if let sceneDepth = frame.sceneDepth {
      let depthMap = sceneDepth.depthMap
      let dW = CVPixelBufferGetWidth(depthMap)   // typically 256 (landscape)
      let dH = CVPixelBufferGetHeight(depthMap)  // typically 192 (landscape)

      // Portrait screen → landscape LiDAR depth map mapping:
      // The depth map is in landscape orientation (same as camera image).
      // Portrait screen X → landscape depth Y (inverted)
      // Portrait screen Y → landscape depth X
      let normScreenX = handScreenPt.x / cachedSW  // 0..1 left→right
      let normScreenY = handScreenPt.y / cachedSH  // 0..1 top→bottom

      // In landscape depth map: X axis is left→right (portrait bottom→top)
      //                          Y axis is top→bottom (portrait left→right)
      let dpX = Int(normScreenY * CGFloat(dW))          // portrait Y → depth X
      let dpY = Int((1.0 - normScreenX) * CGFloat(dH))  // portrait X → depth Y (inverted)

      let clampedX = max(0, min(dpX, dW - 1))
      let clampedY = max(0, min(dpY, dH - 1))

      CVPixelBufferLockBaseAddress(depthMap, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

      if let base = CVPixelBufferGetBaseAddress(depthMap) {
        let bpr       = CVPixelBufferGetBytesPerRow(depthMap)
        let ptr       = base.advanced(by: clampedY * bpr + clampedX * MemoryLayout<Float32>.size)
        let handDepth = ptr.load(as: Float32.self)

        if handDepth > 0.05 && handDepth < 8.0 {
          let diff    = abs(handDepth - objectDist)
          let isClose = diff < lidarDepthThreshold

          if arFrameCount % 20 == 0 {
            NSLog("📏 [Depth-LiDAR] hand=%.2fm obj=%.2fm diff=%.2fm close=%d",
                  handDepth, objectDist, diff, isClose ? 1 : 0)
          }
          return (isClose, isClose ? "LiDAR ✅" : "LiDAR ❌ \(Int(diff*100))cm off")
        }
      }
    }

    // ── Method 3: Hand span heuristic ─────────────────────────────────────
    // k = apparent_span_meters × actual_distance. Calibrated for an average
    // adult hand (~20 cm palm width) viewed from 0.3–1.5 m range.
    if let wrist = try? handObs.recognizedPoint(.wrist),
       let mTip  = try? handObs.recognizedPoint(.middleTip),
       wrist.confidence > 0.4, mTip.confidence > 0.4 {

      let span = hypot(wrist.location.x - mTip.location.x,
                       wrist.location.y - mTip.location.y)
      let k: CGFloat = 0.09   // calibrated: 9 cm × normalized units
      let est  = Float(k / max(span, 0.01))
      let diff = abs(est - objectDist)
      let isClose = diff < heuristicDepthThreshold

      if arFrameCount % 20 == 0 {
        NSLog("📏 [Depth-Heuristic] span=%.3f est=%.2fm obj=%.2fm diff=%.2fm close=%d",
              span, est, objectDist, diff, isClose ? 1 : 0)
      }
      return (isClose, isClose ? "heuristic ✅" : "heuristic ❌ \(Int(diff*100))cm off")
    }

    // ── No depth info available — FAIL SAFE (never auto-pass) ─────────────
    // Previous code returned `true` here as a "proximity fallback".
    // That was the primary false-positive source. Now we return false:
    // the user sees the "Move hand closer" hint and must physically
    // complete the reach for the 2D overlap to sustain.
    NSLog("📏 [Depth] No depth method succeeded — failing safe (no auto-pass)")
    return (false, "no data")
  }

  // ── Aspect-fill crop ──────────────────────────────────────────────────────
  private func computeAspectFillCrop(imageW: CGFloat, imageH: CGFloat) {
    guard !cropComputed, cachedSW > 0, cachedSH > 0, imageW > 0, imageH > 0 else { return }
    let rotW = imageH, rotH = imageW
    if rotW / rotH > cachedSW / cachedSH {
      let dW = rotW * (cachedSH / rotH)
      cropFracX = ((dW - cachedSW) / 2) / dW
    }
    cropComputed = true
    NSLog("📐 [ReachingVC] cropFracX=%.4f", cropFracX)
  }

  private func visionToScreen(_ pt: CGPoint) -> CGPoint {
    let adjX = cropFracX > 0
      ? ((pt.x - cropFracX) / (1.0 - 2 * cropFracX)) * cachedSW
      : pt.x * cachedSW
    return CGPoint(x: adjX, y: (1 - pt.y) * cachedSH)
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Process AR Frame
  // ═══════════════════════════════════════════════════════════════════════════

  private func processARFrame(_ frame: ARFrame) {
    guard running else { return }
    arFrameCount += 1

    if !anchorPlaced {
      if arFrameCount >= anchorWaitFrames { placeWorldAnchor(frame: frame); say("Target locked.") }
      return
    }

    if anchorRefinementFrames > 0 && anchorRefinementFrames < anchorRefinementLimit {
      anchorRefinementFrames += 1
      tryRefineAnchorDepth(frame: frame)
    }

    reprojectBbox(frame: frame)

    let pb = frame.capturedImage
    computeAspectFillCrop(imageW: CGFloat(CVPixelBufferGetWidth(pb)),
                          imageH: CGFloat(CVPixelBufferGetHeight(pb)))

    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
    do { try handler.perform([handReq]) } catch { return }

    guard projectedBboxW > 0 else { return }

    let bboxCx    = projectedBboxCenter.x
    let bboxCy    = projectedBboxCenter.y
    let bboxHalfW = projectedBboxW / 2
    let bboxHalfH = projectedBboxH / 2

    guard let obs = handReq.results?.first else {
      noHandFrames += 1; successFrames = 0; handIsCloseEnoughInDepth = false
      proximityZone = .searching
      return
    }

    noHandFrames = 0

    guard let visionPt = handCenter(obs) else {
      successFrames = 0; handIsCloseEnoughInDepth = false
      return
    }

    let handScreen = visionToScreen(visionPt)
    let screenX = handScreen.x, screenY = handScreen.y
    let dx = screenX - bboxCx, dy = screenY - bboxCy
    let dist2D = sqrt(dx*dx + dy*dy)

    let innerOverlap = abs(dx) < bboxHalfW && abs(dy) < bboxHalfH
    let tolX = max(bboxHalfW * 0.3, 20)
    let tolY = max(bboxHalfH * 0.3, 20)

    let nearOverlap = CGRect(
      x: bboxCx - bboxHalfW - tolX,
      y: bboxCy - bboxHalfH - tolY,
      width: bboxHalfW*2 + tolX*2,
      height: bboxHalfH*2 + tolY*2
    ).contains(CGPoint(x: screenX, y: screenY))

    let (depthOk, depthMethodStr) =
      checkHandDepth(frame: frame, handScreenPt: handScreen, handObs: obs)

    handIsCloseEnoughInDepth = depthOk

    let normDist = dist2D / max(cachedSW, cachedSH)

    let newProx: ProximityZone
    if innerOverlap && depthOk { newProx = .centered }
    else if innerOverlap       { newProx = .veryClose }
    else if nearOverlap        { newProx = .close }
    else if normDist < 0.15    { newProx = .close }
    else if normDist < 0.30    { newProx = .medium }
    else                       { newProx = .far }

    proximityZone = newProx

    let direction = computeDirection(
      handX: screenX, handY: screenY,
      bboxCx: bboxCx, bboxCy: bboxCy,
      bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH
    )

    speakDirectionIfNeeded(direction)

    // ✅ FIX: declare BEFORE closure
    let cameraIsClose = liveDistanceToObject < reachProximityThreshold

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      self.updateDirectionUI(direction)

      // Depth hint logic now safely captures cameraIsClose
      self.depthHintLabel.isHidden = !(innerOverlap && !cameraIsClose)
      if innerOverlap && !cameraIsClose {
        let remaining = Int((self.liveDistanceToObject - self.reachProximityThreshold) * 100)
        self.depthHintLabel.text = "Walk closer — \(remaining)cm more"
      }

      self.depthMethodLabel.text = depthMethodStr
    }

    // SUCCESS GATE
    if innerOverlap && cameraIsClose {
      successFrames += 1
      if successFrames >= successThreshold {
        handleSuccess()
      }
    } else {
      successFrames = 0
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - UI Setup
  // ═══════════════════════════════════════════════════════════════════════════

  private func setupAppleUI() {
    bboxLayer.strokeColor = UIColor.systemCyan.cgColor
    bboxLayer.fillColor   = UIColor.systemCyan.withAlphaComponent(0.06).cgColor
    bboxLayer.lineWidth = 2.5; bboxLayer.lineDashPattern = [8, 4]; bboxLayer.isHidden = true
    view.layer.addSublayer(bboxLayer)

    innerBboxLayer.strokeColor = UIColor.white.cgColor
    innerBboxLayer.fillColor = UIColor.clear.cgColor
    innerBboxLayer.lineWidth = 2; innerBboxLayer.isHidden = true
    view.layer.addSublayer(innerBboxLayer)

    handDotGlow.fillColor = UIColor.systemGreen.withAlphaComponent(0.3).cgColor
    handDotGlow.isHidden = true
    view.layer.addSublayer(handDotGlow)

    handDot.fillColor = UIColor.systemGreen.cgColor; handDot.strokeColor = UIColor.white.cgColor
    handDot.lineWidth = 2.5; handDot.shadowColor = UIColor.black.cgColor
    handDot.shadowOffset = .zero; handDot.shadowRadius = 4; handDot.shadowOpacity = 0.5
    handDot.isHidden = true
    view.layer.addSublayer(handDot)

    topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    topBar.translatesAutoresizingMaskIntoConstraints = false
    topBar.layer.cornerRadius = 20; topBar.clipsToBounds = true
    view.addSubview(topBar)

    objectNameLabel = UILabel()
    objectNameLabel.text = "🎯  \(objectName)"
    objectNameLabel.font = .systemFont(ofSize: 17, weight: .semibold)
    objectNameLabel.textColor = .white; objectNameLabel.textAlignment = .center
    objectNameLabel.translatesAutoresizingMaskIntoConstraints = false
    topBar.contentView.addSubview(objectNameLabel)

    distanceLabel = UILabel()
    distanceLabel.text = "—"
    distanceLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .medium)
    distanceLabel.textColor = UIColor.white.withAlphaComponent(0.7)
    distanceLabel.textAlignment = .center
    distanceLabel.translatesAutoresizingMaskIntoConstraints = false
    topBar.contentView.addSubview(distanceLabel)

    bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.layer.cornerRadius = 24; bottomBar.clipsToBounds = true
    view.addSubview(bottomBar)

    directionLabel = UILabel()
    directionLabel.text = "Show your hand…"
    directionLabel.font = .systemFont(ofSize: 24, weight: .bold)
    directionLabel.textColor = .white; directionLabel.textAlignment = .center
    directionLabel.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.contentView.addSubview(directionLabel)

    depthHintLabel = UILabel()
    depthHintLabel.text = "Reach further — extend your arm"
    depthHintLabel.font = .systemFont(ofSize: 15, weight: .medium)
    depthHintLabel.textColor = .systemYellow; depthHintLabel.textAlignment = .center
    depthHintLabel.isHidden = true
    depthHintLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(depthHintLabel)

    // Small debug label in top-right corner (shows which depth method fired)
    depthMethodLabel = UILabel()
    depthMethodLabel.text = ""
    depthMethodLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    depthMethodLabel.textColor = UIColor.white.withAlphaComponent(0.55)
    depthMethodLabel.textAlignment = .right
    depthMethodLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(depthMethodLabel)

    progressRing = CAShapeLayer()
    progressRing.strokeColor = UIColor.systemGreen.cgColor
    progressRing.fillColor = UIColor.clear.cgColor
    progressRing.lineWidth = 3; progressRing.lineCap = .round
    progressRing.strokeEnd = 0; progressRing.isHidden = true
    view.layer.addSublayer(progressRing)

    cancelButton = UIButton(type: .system)
    cancelButton.setTitle("Cancel", for: .normal)
    cancelButton.setTitleColor(.white, for: .normal)
    cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
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

      // Debug depth method label — top-right corner
      depthMethodLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      depthMethodLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
      depthMethodLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),

      bottomBar.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -16),
      bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      bottomBar.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.85),
      bottomBar.heightAnchor.constraint(equalToConstant: 56),

      directionLabel.centerYAnchor.constraint(equalTo: bottomBar.contentView.centerYAnchor),
      directionLabel.centerXAnchor.constraint(equalTo: bottomBar.contentView.centerXAnchor),
      directionLabel.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 24),
      directionLabel.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -24),

      depthHintLabel.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -8),
      depthHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

      cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancelButton.widthAnchor.constraint(equalToConstant: 120),
      cancelButton.heightAnchor.constraint(equalToConstant: 44),
    ])

    view.accessibilityLabel = "Reaching guidance for \(objectName). Tap anywhere to stop."
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
        let t = Double(i)/sr
        let env = min(t/0.005, 1) * min((dur-t)/0.005, 1)
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
        case .left, .topLeft, .downLeft:    p.pan = -0.8
        case .right, .topRight, .downRight: p.pan =  0.8
        default:                            p.pan =  0.0
        }
        p.scheduleBuffer(b, at: nil, options: .interrupts)
        if !p.isPlaying { p.play() }
      }
      lastBeep = now
    }
  }

  private func triggerHaptic(_ intensity: Float) {
    guard let engine = hapticEngine else { return }
    let event = CHHapticEvent(
      eventType: .hapticTransient,
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
    guard !hasCompleted else { return }
    say("Cancelled"); finishWith(success: false, reason: "user_cancelled")
  }

  private func handleSuccess() {
    guard running, !hasCompleted else { return }
    running = false; hasCompleted = true
    NSLog("🎉 [ReachingVC] SUCCESS – reached %@", objectName)
    beepTimer?.cancel(); beepTimer = nil
    playSuccessTone(); triggerHaptic(1.0)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.directionLabel.text = "✅  \(self.objectName) reached!"
      self.directionLabel.textColor = .systemGreen
      self.depthHintLabel.isHidden = true

      let flash = UIView(frame: self.view.bounds)
      flash.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
      self.view.addSubview(flash)
      UIView.animate(withDuration: 1.0) { flash.alpha = 0 } completion: { _ in
        flash.removeFromSuperview()
      }
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
      let t = Double(i)/sr; let f = 523.25 * pow(2, t/dur)
      d[i] = Float(sin(2 * .pi * f * t) * 0.6 * min(t/0.01, 1) * min((dur-t)/0.08, 1))
    }
    player.pan = 0; player.scheduleBuffer(buf, at: nil, options: .interrupts)
    if !player.isPlaying { player.play() }
  }

  // Single idempotent guard — no double-fire on success path
  private func finishWith(success: Bool, reason: String) {
    guard !hasCompleted else { return }
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

  // ── Speech ────────────────────────────────────────────────────────────────
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

    if direction == .centered && liveDistanceToObject >= reachProximityThreshold {
      if now - lastSpeechTime > 2.5 {
        let remaining = Int((liveDistanceToObject - reachProximityThreshold) * 100)
        say("Walk closer — \(remaining) centimeters more")
        lastSpeechTime = now
      }
      return
    }

    if direction == lastSpokenDirection {
      if direction == .centered && (now - lastSpeechTime) > 3.0 {
        say("Centered!"); lastSpeechTime = now
      }
      return
    }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      say(direction == .centered ? "Centered!" : direction.rawValue)
      lastSpokenDirection = direction; lastSpeechTime = now
      if direction != .centered && direction != .searching { triggerHaptic(0.4) }
    }
  }

  // ── Direction computation ─────────────────────────────────────────────────
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
    if let w   = try? obs.recognizedPoint(.wrist),     w.confidence   > 0.3 { return w.location }
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
      UIView.animate(withDuration: 0.15) { self.bottomBar.transform = .identity }
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════════════
// MARK: - ARSessionDelegate
// ═══════════════════════════════════════════════════════════════════════════════

extension ReachingViewController: ARSessionDelegate {
  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    guard running else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard now - lastFrameProcessedAt >= frameProcessInterval else { return }
    lastFrameProcessedAt = now
    visionQ.async { [weak self] in self?.processARFrame(frame) }
  }
  func session(_ session: ARSession, didFailWithError error: Error) {
    say("Tracking failed.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
      self?.finishWith(success: false, reason: "ar_error")
    }
  }
  func sessionWasInterrupted(_ session: ARSession)   { say("Tracking paused") }
  func sessionInterruptionEnded(_ session: ARSession) { say("Tracking resumed") }
}
