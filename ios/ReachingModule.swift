//ReachingModule.swift — ARKit Reaching v11 (Hardened Success Gate)
//
// CHANGELOG v9 → v10:
//
//  FIX 13: Bound refinement to reject hits beyond 2x backend, Identified messaging locations for object-grabbing interaction refinement
//  FIX 14a:  UI labels "Grab it now" when remaining <= 5cm:Devised sed command to replace calculation lines conditionally
//  FIX 14b: Speech cue:Prepared version update and header modification
//

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
  private let raycastDepthThreshold: Float = 0.18
  private let lidarDepthThreshold:   Float = 0.12
  private let heuristicDepthThreshold: Float = 0.25  // FIX 4: relaxed from 0.22
  // Camera-to-anchor proximity gate for success.
  private let reachProximityThreshold: Float = 0.70

  // ── Config ───────────────────────────────────────────────────────────────
  private let bboxRaw: [CGFloat]
  private let objectName: String
  private let backendDepth: Float?
  private let imageWidth:   CGFloat
  private let imageHeight:  CGFloat
  private let onDone: ([String: Any]) -> Void
  private var bboxNormalized: [CGFloat] = [0, 0, 0, 0]

  // ── 3D World Anchor ──────────────────────────────────────────────────────
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
  private var lastFrameProcessedAt: TimeInterval = 0
  private let frameProcessInterval: TimeInterval = 0.05
  private var anchorRefinementFrames = 0
  private let anchorRefinementLimit = 600   // FIX 4: was 90 (~3s), now 600 (~20s)
  // FIX 6: Accumulate multiple raycast hits, use median — don't lock on first noisy hit
  private var refinementHits: [Float] = []
  private let refinementMinHits = 5         // need 5 consistent hits before updating anchor
  private let refinementConvergeThreshold: Float = 0.05  // 5cm spread = converged
  private var lastRefinementAppliedDepth: Float = 0

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
  private var depthMethodLabel: UILabel!

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
  private var depthConfirmedFrames = 0  // FIX 9: tracks how many frames depth was confirmed
  private var hasCompleted = false
  private var hasDismissed = false       // FIX 1: separate flag for dismiss guard

  private let successThreshold = 35
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
      self.say("Guiding to \(self.objectName). Show your hand to the camera.")
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
    config.planeDetection = [.horizontal, .vertical]

    if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
      config.frameSemantics.insert(.sceneDepth)
      NSLog("📷 [ReachingVC] LiDAR scene depth ENABLED")
    }

    if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
      config.sceneReconstruction = .mesh
      meshReconstructionEnabled = true
      NSLog("📷 [ReachingVC] Mesh reconstruction ENABLED")
    } else {
      NSLog("📷 [ReachingVC] No mesh — using plane estimation + LiDAR fallback")
    }

    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    startBeepLoop()
    NSLog("📷 [ReachingVC] AR session started")
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Place World Anchor
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

    let placementRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let placementUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = worldPos + placementRight * objectWorldHalfW + placementUp * objectWorldHalfH
    objectWorldCornerBL = worldPos - placementRight * objectWorldHalfW - placementUp * objectWorldHalfH

    anchorPlaced = true
    anchorRefinementFrames = 1
    NSLog("🎯 [ReachingVC] ✅ Anchor SEEDED at (%.3f, %.3f, %.3f) depth=%.2fm (refining with ARKit...)",
          worldPos.x, worldPos.y, worldPos.z, depth)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if let d = self.backendDepth { self.distanceLabel.text = "\(Int(d*100)) cm" }
    }
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Refine Anchor Depth with ARKit Raycast
  // ═══════════════════════════════════════════════════════════════════════════

  private func tryRefineAnchorDepth(frame: ARFrame) {
    guard let currentPos = objectWorldPosition else { return }

    let sw = cachedSW, sh = cachedSH
    let camera = frame.camera
    let intrinsics = camera.intrinsics
    let imgRes = camera.imageResolution

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

    // ── FIX 6: Try existingPlaneGeometry FIRST (most accurate), then estimatedPlane ──
    var hitPos: simd_float3? = nil
    var hitSource = ""
    for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .estimatedPlane] {
      let query = ARRaycastQuery(origin: camPos, direction: worldDir,
                                 allowing: target, alignment: .any)
      if let hit = sceneView.session.raycast(query).first {
        hitPos = simd_make_float3(hit.worldTransform.columns.3)
        hitSource = target == .existingPlaneGeometry ? "existingPlane" : "estimatedPlane"
        break
      }
    }

    guard let hp = hitPos else {
      if anchorRefinementFrames % 60 == 0 {
        NSLog("🎯 [Refine] No plane hit yet (frame %d, %d hits buffered) — planes still forming",
              anchorRefinementFrames, refinementHits.count)
      }
      return
    }

    let hitDepth = simd_length(hp - camPos)

    // Sanity check: must be a plausible object distance
    guard hitDepth > 0.15 && hitDepth < 4.0 else {
      NSLog("🎯 [Refine] Rejected hit at %.2fm (out of range)", hitDepth)
      return
    }

    // FIX 13: Reject raycasts beyond 2x backend estimate.
    // Ray passes through shelf and hits BACK WALL (backend=0.6m->raycast=1.96m).
    if let bd = backendDepth, hitDepth > bd * 2.0 {
      NSLog("🎯 [Refine] Rejected hit at %.2fm (>2x backend %.2fm)", hitDepth, bd)
      return
    }

    // ── FIX 6: Accumulate hits, use median ────────────────────────────────
    // Don't lock on first noisy hit. ARKit plane estimates improve over time.
    // Keep last 20 hits (sliding window), apply median when we have enough.
    refinementHits.append(hitDepth)
    if refinementHits.count > 20 { refinementHits.removeFirst() }

    NSLog("🎯 [Refine] Hit #%d: %.2fm (%@) | buffer: %d hits",
          refinementHits.count, hitDepth, hitSource, refinementHits.count)

    // Need minimum hits before applying
    guard refinementHits.count >= refinementMinHits else { return }

    // Compute median of accumulated hits
    let sorted = refinementHits.sorted()
    let median: Float
    let n = sorted.count
    if n % 2 == 0 {
      median = (sorted[n/2 - 1] + sorted[n/2]) / 2.0
    } else {
      median = sorted[n/2]
    }

    // Check spread (IQR) — if hits are noisy, keep accumulating
    let q1 = sorted[n/4]
    let q3 = sorted[3*n/4]
    let iqr = q3 - q1

    NSLog("🎯 [Refine] Median=%.2fm IQR=%.2fm (need <%.2fm) hits=%d",
          median, iqr, refinementConvergeThreshold, n)

    // Only apply when spread is tight enough (consistent readings)
    guard iqr < refinementConvergeThreshold else {
      NSLog("🎯 [Refine] IQR too wide (%.2fm) — still accumulating", iqr)
      return
    }

    // Don't re-apply if median hasn't changed meaningfully
    if lastRefinementAppliedDepth > 0 && abs(median - lastRefinementAppliedDepth) < 0.02 {
      // Converged — stop refining
      NSLog("🎯 [Refine] ✅ CONVERGED at %.2fm (Δ=%.1fcm from last) — stopping",
            median, abs(median - lastRefinementAppliedDepth) * 100)
      anchorRefinementFrames = anchorRefinementLimit
      return
    }

    // ── Apply median depth to anchor ──────────────────────────────────────
    let prevDepth = simd_length(currentPos - camPos)
    let newWorldPos = camPos + worldDir * median
    objectWorldPosition = newWorldPos

    let placementRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let placementUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    objectWorldCornerTR = newWorldPos + placementRight * objectWorldHalfW + placementUp * objectWorldHalfH
    objectWorldCornerBL = newWorldPos - placementRight * objectWorldHalfW - placementUp * objectWorldHalfH
    anchorDepth        = median
    liveDistanceToObject = median
    lastRefinementAppliedDepth = median

    NSLog("🎯 [Refine] ✅ DEPTH UPDATED: was=%.2fm → median=%.2fm (Δ=%.1fcm, %d hits, IQR=%.2f)",
          prevDepth, median, abs(prevDepth - median) * 100, n, iqr)

    DispatchQueue.main.async { [weak self] in
      self?.distanceLabel.text = "\(Int(median * 100)) cm"
    }
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
      // FIX 11: Tightened from 0.55m to 0.25m. At 0.55m a drifted anchor could
      // trigger auto-success when user hasn't reached the real object.
      // 0.25m = user physically walked through the anchor position.
      if camToAnchorDist < 0.25 {
        NSLog("🎯 [ReachingVC] Anchor behind camera at %.2fm — auto-success (user at object)", camToAnchorDist)
        DispatchQueue.main.async { [weak self] in self?.handleSuccess() }
        return
      }
      DispatchQueue.main.async { [weak self] in
        self?.bboxLayer.isHidden = true; self?.innerBboxLayer.isHidden = true
        self?.directionLabel.text = "Turn back"
        // FIX 2: hide hand dot when object is behind
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
      }
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastSpeechTime > 3 { say("Object is behind you. Turn back."); lastSpeechTime = now }
      return
    }

    let centerScreen = camera.projectPoint(center3D, orientation: .portrait, viewportSize: viewSize)

    // FIX 10: Recompute billboard corners from CURRENT camera orientation every frame.
    // Previously corners were frozen from seeding/refinement moment — as camera angle
    // changed while walking, the fixed-orientation billboard projected with distortion,
    // causing the bbox to shrink or warp. Now we always face the camera.
    let camT = camera.transform
    let billboardRight = -simd_normalize(simd_make_float3(camT.columns.1))
    let billboardUp    =  simd_normalize(simd_make_float3(camT.columns.0))
    let liveTR = center3D + billboardRight * objectWorldHalfW + billboardUp * objectWorldHalfH
    let liveBL = center3D - billboardRight * objectWorldHalfW - billboardUp * objectWorldHalfH

    let trScreen     = camera.projectPoint(liveTR, orientation: .portrait, viewportSize: viewSize)
    let blScreen     = camera.projectPoint(liveBL, orientation: .portrait, viewportSize: viewSize)

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
  // MARK: - v7.1 DEPTH CHECK — Fixed: Heuristic primary, Raycast secondary
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // v7.0 BUG: Raycast fires through the hand's screen position, but the ray
  // passes THROUGH the hand and hits the wall/shelf BEHIND it. Result: hand
  // always reads 1.2m+ when the actual hand is at 0.5m. This is fundamentally
  // wrong for hand depth — raycast measures surfaces, not floating objects.
  //
  // v7.1 FIX: Reorder methods. Use hand span heuristic as PRIMARY (works on
  // all devices, measures the hand itself). Use LiDAR as secondary (accurate
  // but Pro-only). Use raycast only as LAST RESORT and with a much wider
  // threshold since it's measuring the surface behind the hand.

  private func checkHandDepth(
    frame: ARFrame,
    handScreenPt: CGPoint,
    handObs: VNHumanHandPoseObservation
  ) -> (isClose: Bool, method: String) {

    let objectDist = liveDistanceToObject

    // ── Method 1 (PRIMARY): Hand span heuristic ────────────────────────────
    // This measures the HAND ITSELF, not the surface behind it.
    // Works on ALL devices. Calibrated for average adult hand.
    //
    // MATH DERIVATION (FIX 7 — k was 0.09, completely wrong):
    //   iPhone wide camera FOV ≈ 75° horizontal
    //   At distance D, visible width ≈ 2*D*tan(37.5°) ≈ 1.53*D
    //   Adult hand wrist→middleTip ≈ 19-22cm ≈ 0.20m
    //   Normalized span = hand_real / visible_width = 0.20 / (1.53*D)
    //   So: D = 0.20 / (1.53 * span) = 0.13 / span
    //   But Vision points span BOTH x and y (hypot), and portrait mode
    //   changes the effective FOV. Empirical calibration from your logs:
    //     span=0.67 at ~40cm → k = 0.40 * 0.67 = 0.27
    //     span=0.50 at ~50cm → k = 0.50 * 0.50 = 0.25
    //   Using k=0.25 (was 0.09 — that gave 13cm estimate for a 40cm hand!)
    //
    if let wrist = try? handObs.recognizedPoint(.wrist),
       let mTip  = try? handObs.recognizedPoint(.middleTip),
       wrist.confidence > 0.15, mTip.confidence > 0.15 {

      let span = hypot(wrist.location.x - mTip.location.x,
                       wrist.location.y - mTip.location.y)
      let k: CGFloat = 0.25   // FIX 7: was 0.09, corrected from FOV math + empirical
      let est  = Float(k / max(span, 0.01))
      let diff = abs(est - objectDist)
      let isClose = diff < heuristicDepthThreshold

      if arFrameCount % 20 == 0 {
        NSLog("📏 [Depth-Heuristic] span=%.3f est=%.2fm obj=%.2fm diff=%.2fm close=%d",
              span, est, objectDist, diff, isClose ? 1 : 0)
      }
      return (isClose, isClose ? "heuristic ✅" : "heuristic ❌ \(Int(diff*100))cm")
    }

    // ── Method 2: LiDAR depth map (Pro devices only) ───────────────────────
    if let sceneDepth = frame.sceneDepth {
      let depthMap = sceneDepth.depthMap
      let dW = CVPixelBufferGetWidth(depthMap)
      let dH = CVPixelBufferGetHeight(depthMap)

      let normScreenX = handScreenPt.x / cachedSW
      let normScreenY = handScreenPt.y / cachedSH

      let dpX = Int(normScreenY * CGFloat(dW))
      let dpY = Int((1.0 - normScreenX) * CGFloat(dH))

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
          return (isClose, isClose ? "LiDAR ✅" : "LiDAR ❌ \(Int(diff*100))cm")
        }
      }
    }

    // ── Method 3 (LAST RESORT): ARKit Raycast ──────────────────────────────
    // NOTE: This hits the surface BEHIND the hand, not the hand itself.
    // Use a much wider threshold (30cm) since we're comparing surface depth
    // to object depth — if they're on the same surface, the hand is close.
    let camera     = frame.camera
    let intrinsics = camera.intrinsics
    let imgRes     = camera.imageResolution

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

    let query = ARRaycastQuery(
      origin: camPos,
      direction: worldDir,
      allowing: .estimatedPlane,
      alignment: .any
    )
    let rayResults = sceneView.session.raycast(query)

    if let hit = rayResults.first {
      let hitPos  = simd_make_float3(hit.worldTransform.columns.3)
      let surfaceDist = simd_length(hitPos - camPos)
      let diff    = abs(surfaceDist - objectDist)
      // FIX 4: Wider threshold — ray hits surface behind hand, not hand itself.
      // If surface behind hand is within 30cm of object surface, hand is near object.
      let isClose = diff < 0.30

      if arFrameCount % 20 == 0 {
        NSLog("📏 [Depth-Raycast] surface=%.2fm obj=%.2fm diff=%.2fm close=%d (surface behind hand)",
              surfaceDist, objectDist, diff, isClose ? 1 : 0)
      }
      return (isClose, isClose ? "raycast ✅" : "raycast ❌ \(Int(diff*100))cm")
    }

    // ── No depth info — rely on camera proximity for success gate ──────────
    // Don't auto-pass. The success gate uses cameraIsClose independently.
    NSLog("📏 [Depth] No depth method succeeded — camera proximity will gate success")
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
      noHandFrames += 1; successFrames = 0; depthConfirmedFrames = 0; handIsCloseEnoughInDepth = false
      proximityZone = .searching

      // ═══ FIX 3: Speech cue when no hand detected ═══════════════════════
      if noHandFrames == noHandLimit {
        say("Show your hand to the camera.")
      } else if noHandFrames > 0 && noHandFrames % noHandRepeatCycle == 0 {
        say("I can't see your hand. Hold it up in front of the camera.")
      }

      // FIX 2: Hide hand dot when no hand
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true
        self?.handDotGlow.isHidden = true
      }
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

    // ═══ FIX 2: Update hand dot position ═════════════════════════════════
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let dotRadius: CGFloat = 10
      let glowRadius: CGFloat = 20
      self.handDot.isHidden = false
      self.handDotGlow.isHidden = false
      self.handDot.path = UIBezierPath(
        ovalIn: CGRect(x: screenX - dotRadius, y: screenY - dotRadius,
                       width: dotRadius * 2, height: dotRadius * 2)
      ).cgPath
      self.handDotGlow.path = UIBezierPath(
        ovalIn: CGRect(x: screenX - glowRadius, y: screenY - glowRadius,
                       width: glowRadius * 2, height: glowRadius * 2)
      ).cgPath

      // Color the dot based on proximity
      let dotColor: UIColor
      let dist = sqrt(dx*dx + dy*dy)
      if abs(dx) < bboxHalfW && abs(dy) < bboxHalfH {
        dotColor = .systemGreen   // inside bbox
      } else if dist < max(bboxHalfW, bboxHalfH) * 2 {
        dotColor = .systemYellow  // close
      } else {
        dotColor = .systemRed     // far
      }
      self.handDot.fillColor = dotColor.cgColor
      self.handDotGlow.fillColor = dotColor.withAlphaComponent(0.3).cgColor
    }

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

    let cameraIsClose = liveDistanceToObject < reachProximityThreshold

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }

      self.updateDirectionUI(direction)

      self.depthHintLabel.isHidden = !(innerOverlap && !cameraIsClose)
      if innerOverlap && !cameraIsClose {
        // FIX 8: Show REMAINING distance consistently (was: top showed total, bottom showed remaining)
        let remaining = max(0, Int((self.liveDistanceToObject - self.reachProximityThreshold) * 100))
        if remaining <= 5 {
          self.depthHintLabel.text = "Grab it now!"
          self.distanceLabel.text = "Within reach"
        } else {
          self.depthHintLabel.text = "Move \(remaining)cm closer"
          self.distanceLabel.text = "\(remaining)cm to go"
        }
      }

      self.depthMethodLabel.text = depthMethodStr

      // FIX 2: Show progress ring when accumulating success frames
      if innerOverlap && cameraIsClose {
        self.progressRing.isHidden = false
        let progress = CGFloat(self.successFrames) / CGFloat(self.successThreshold)
        self.progressRing.strokeEnd = min(progress, 1.0)
        // Position progress ring around the hand dot
        let ringRadius: CGFloat = 25
        let ringRect = CGRect(x: screenX - ringRadius, y: screenY - ringRadius,
                              width: ringRadius * 2, height: ringRadius * 2)
        self.progressRing.path = UIBezierPath(ovalIn: ringRect).cgPath
      } else {
        self.progressRing.isHidden = true
        self.progressRing.strokeEnd = 0
      }
    }

    // ═══ SUCCESS GATE — FIX 9: REQUIRE DEPTH EVIDENCE ═══════════════════════
    // Previously: innerOverlap && cameraIsClose was enough → false "reached"
    // Now: must also have depth confirmation OR be extremely close (30cm fallback)
    if depthOk {
      depthConfirmedFrames = min(depthConfirmedFrames + 1, 15) // FIX 12: cap
    } else {
      depthConfirmedFrames = max(0, depthConfirmedFrames - 2) // FIX 12: ALWAYS decay
    }

    let depthGateOk: Bool
    if depthOk {
      depthGateOk = true  // real-time depth says hand is at object
    } else if depthConfirmedFrames >= 8 {
      depthGateOk = true  // accumulated enough recent depth evidence
    } else if liveDistanceToObject < 0.30 {
      depthGateOk = true  // camera physically within 30cm — must be there
    } else {
      depthGateOk = false
    }

    if innerOverlap && cameraIsClose && depthGateOk {
      successFrames += 1
      if arFrameCount % 10 == 0 {
        NSLog("✅ [Gate] progress=%d/%d depth=%@ confirmed=%d dist=%.2fm",
              successFrames, successThreshold,
              depthOk ? "YES" : "no", depthConfirmedFrames, liveDistanceToObject)
      }
      if successFrames >= successThreshold {
        handleSuccess()
      }
    } else {
      if successFrames > 0 && arFrameCount % 30 == 0 {
        NSLog("❌ [Gate] RESET — overlap=%@ close=%@ depthGate=%@ (confirmed=%d dist=%.2f)",
              innerOverlap ? "Y" : "N", cameraIsClose ? "Y" : "N",
              depthGateOk ? "Y" : "N", depthConfirmedFrames, liveDistanceToObject)
      }
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

    // FIX 5: Pause AR session IMMEDIATELY to stop frame delivery & prevent leak
    sceneView.session.pause()

    beepTimer?.cancel(); beepTimer = nil
    playSuccessTone(); triggerHaptic(1.0)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.directionLabel.text = "✅  \(self.objectName) reached!"
      self.directionLabel.textColor = .systemGreen
      self.depthHintLabel.isHidden = true
      self.handDot.isHidden = true
      self.handDotGlow.isHidden = true
      self.progressRing.isHidden = true

      let flash = UIView(frame: self.view.bounds)
      flash.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
      self.view.addSubview(flash)
      UIView.animate(withDuration: 1.0) { flash.alpha = 0 } completion: { _ in
        flash.removeFromSuperview()
      }
    }
    say("\(objectName) reached!")

    // FIX 1: Dismiss directly instead of going through finishWith
    // (finishWith guards on hasDismissed which is separate from hasCompleted)
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      guard let self = self, !self.hasDismissed else { return }
      self.hasDismissed = true
      self.cleanup()
      self.dismiss(animated: true) {
        self.onDone(["success": true, "object": self.objectName,
                     "reason": "reached",
                     "message": "\(self.objectName) reached!"])
      }
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

  // FIX 1: Use hasDismissed (not hasCompleted) so cancel path still works
  private func finishWith(success: Bool, reason: String) {
    guard !hasDismissed else { return }
    hasDismissed = true; running = false

    // FIX 5: Pause AR session immediately
    sceneView.session.pause()

    cleanup()
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
    synth.stopSpeaking(at: .immediate)
    // FIX 5: Always pause session in cleanup
    sceneView?.session.pause()
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
        let remaining = max(0, Int((liveDistanceToObject - reachProximityThreshold) * 100))
        if remaining <= 5 {
          say("You can grab it now")
        } else {
          say("Move \(remaining) centimeters closer")
        }
        lastSpeechTime = now
      }
      return
    }

    if direction == lastSpokenDirection {
      if direction == .centered && (now - lastSpeechTime) > 3.0 {
        say("Centered! Hold steady."); lastSpeechTime = now
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
    // FIX 5: Early return if completed — don't even touch the frame
    guard running, !hasCompleted else { return }
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
