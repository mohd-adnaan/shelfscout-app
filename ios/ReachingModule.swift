/**
 * ReachingModule.swift — ARKit World-Anchored Reaching (v4)
 *
 * iOS 14+ | ARKit World Tracking | No LiDAR required
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
        // Backend sends depth in centimeters — convert to meters
        if v > 10 { v = v / 100.0 }
        // Clamp to reasonable range (10cm to 5m)
        if v >= 0.1 && v <= 5.0 {
          backendDepth = v
        }
      }
    }
    NSLog("🎯 [ReachingModule] depth from backend: %@", backendDepth.map { "\($0)m" } ?? "nil")

    // Parse actual image dimensions from fixImageOrientation
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

  // ── Direction ───────────────────────────────────────────────────────────

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
  private let imageWidth: CGFloat   // Actual corrected image width in pixels
  private let imageHeight: CGFloat  // Actual corrected image height in pixels
  private let onDone: ([String: Any]) -> Void
  private var bboxNormalized: [CGFloat] = [0, 0, 0, 0]

  // ── ARKit ───────────────────────────────────────────────────────────────

  private var sceneView: ARSCNView!
  private var objectWorldPosition: simd_float3?
  private var objectWorldRight: simd_float3 = .zero
  private var objectWorldUp: simd_float3 = .zero
  private var objectWorldHalfW: Float = 0
  private var objectWorldHalfH: Float = 0
  private var anchorPlaced = false
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

  // ── UI (Apple-quality) ──────────────────────────────────────────────────

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

  // ── Projected bbox ──────────────────────────────────────────────────────

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

  // ── Cached screen bounds (thread-safe) ────────────────────────────────

  private var cachedSW: CGFloat = 393
  private var cachedSH: CGFloat = 852

  // ── Aspect-fill crop ───────────────────────────────────────────────────

  private var cropFracX: CGFloat = 0
  private var cropComputed = false
  
  // Screen-space target (set once at start, in screen points)──────────────
  private var targetScreenCenter: CGPoint = .zero
  private var targetScreenHalfW: CGFloat = 0
  private var targetScreenHalfH: CGFloat = 0
  private var targetPlaced = false

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
    let sorted: [CGFloat] = [x1, y1, x2, y2]

    let maxVal = max(x1, y1, x2, y2)

    // PRIORITY 1: Use actual image dimensions if provided
    if imageWidth > 0 && imageHeight > 0 && maxVal > 1.0 {
      bboxNormalized = [x1 / imageWidth, y1 / imageHeight, x2 / imageWidth, y2 / imageHeight]
      NSLog("📦 [ReachingVC] Bbox [%.0f,%.0f,%.0f,%.0f] ÷ actual image %.0f×%.0f → norm %@",
            x1, y1, x2, y2, imageWidth, imageHeight, "\(bboxNormalized)")

    // FALLBACK: Already normalized 0-1
    } else if maxVal <= 1.0 {
      bboxNormalized = sorted

    // FALLBACK: No image dimensions
    } else {
      NSLog("⚠️ [ReachingVC] No image dimensions! Falling back to heuristic normalization")
      let guessW: CGFloat = max(x2 * 1.1, 1152)
      let guessH: CGFloat = max(y2 * 1.1, 2048)
      bboxNormalized = [x1 / guessW, y1 / guessH, x2 / guessW, y2 / guessH]
    }

    bboxNormalized = bboxNormalized.map { min(max($0, 0), 1) }

    let bw = bboxNormalized[2] - bboxNormalized[0]
    let bh = bboxNormalized[3] - bboxNormalized[1]
    if bw < 0.01 || bh < 0.01 {
      NSLog("⚠️ [ReachingVC] Bbox too small (%.3f×%.3f), using center default", bw, bh)
      bboxNormalized = [0.35, 0.35, 0.65, 0.65]
    }

    NSLog("📦 [ReachingVC] Final normalized: [%.3f, %.3f, %.3f, %.3f]  center=(%.3f, %.3f)",
          bboxNormalized[0], bboxNormalized[1], bboxNormalized[2], bboxNormalized[3],
          (bboxNormalized[0]+bboxNormalized[2])/2, (bboxNormalized[1]+bboxNormalized[3])/2)
  }

  // ── ARKit ───────────────────────────────────────────────────────────────

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
    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    startBeepLoop()
    NSLog("📷 [ReachingVC] AR session started")
  }

  private func placeScreenTarget() {
    let sw = cachedSW
    let sh = cachedSH

    // The bbox is normalized to the PORTRAIT photo dimensions.
    // We need to map it to the screen, accounting for the aspect-fill
    // crop that the AR camera preview applies.
    //
    // The AR camera preview uses aspect-fill:
    // - AR camera is 4:3 (landscape) = 3:4 (portrait)
    // - Screen is ~9:19.5 (portrait)
    // - The camera image is scaled to fill the screen height,
    //   then the sides are cropped.
    //
    // But we're NOT mapping from the AR camera image — we're mapping
    // from the PHOTO, which has its own aspect ratio.
    //
    // Photo is 9:16 portrait (1152×2048).
    // Screen is ~9:19.5 (393×852).
    //
    // If we assume the photo was taken from roughly the same position
    // and the user hasn't moved, the photo's normalized coordinates
    // map directly to the screen with aspect-fill scaling.

    let photoAspect = imageWidth / imageHeight  // 1152/2048 = 0.5625
    let screenAspect = sw / sh                   // 393/852 = 0.4613

    var scaleX: CGFloat = 1.0
    var scaleY: CGFloat = 1.0
    var offsetX: CGFloat = 0.0
    var offsetY: CGFloat = 0.0

    if photoAspect > screenAspect {
      // Photo is wider than screen — fit height, crop sides
      scaleY = 1.0
      scaleX = (photoAspect / screenAspect)
      offsetX = (scaleX - 1.0) / 2.0  // cropped from each side
    } else {
      // Photo is taller than screen — fit width, crop top/bottom
      scaleX = 1.0
      scaleY = (screenAspect / photoAspect)
      offsetY = (scaleY - 1.0) / 2.0  // cropped from top/bottom
    }

    // Map normalized bbox to screen coordinates
    // The photo coords need to be adjusted for the crop
    let bx1 = (bboxNormalized[0] * scaleX - offsetX) * sw
    let by1 = (bboxNormalized[1] * scaleY - offsetY) * sh
    let bx2 = (bboxNormalized[2] * scaleX - offsetX) * sw
    let by2 = (bboxNormalized[3] * scaleY - offsetY) * sh

    targetScreenCenter = CGPoint(x: (bx1 + bx2) / 2, y: (by1 + by2) / 2)
    targetScreenHalfW = max((bx2 - bx1) / 2, 15)
    targetScreenHalfH = max((by2 - by1) / 2, 15)
    targetPlaced = true

    // Also set the projected bbox vars so the rest of the code works unchanged
    projectedBboxCenter = targetScreenCenter
    projectedBboxW = targetScreenHalfW * 2
    projectedBboxH = targetScreenHalfH * 2

    NSLog("🎯 [ReachingVC] Screen target placed: center=(%.1f, %.1f) size=%.0f×%.0f",
          targetScreenCenter.x, targetScreenCenter.y,
          targetScreenHalfW * 2, targetScreenHalfH * 2)
    NSLog("🎯 [ReachingVC] Screen normalized: center=(%.3f, %.3f)",
          targetScreenCenter.x / sw, targetScreenCenter.y / sh)

    // Draw the bbox immediately
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.bboxLayer.isHidden = false
      self.innerBboxLayer.isHidden = false

      let innerRect = CGRect(x: self.targetScreenCenter.x - self.targetScreenHalfW,
                              y: self.targetScreenCenter.y - self.targetScreenHalfH,
                              width: self.targetScreenHalfW * 2,
                              height: self.targetScreenHalfH * 2)
      let tolX = max(self.targetScreenHalfW * 0.25, 15)
      let tolY = max(self.targetScreenHalfH * 0.25, 15)
      let outerRect = innerRect.insetBy(dx: -tolX, dy: -tolY)

      self.innerBboxLayer.path = UIBezierPath(roundedRect: innerRect, cornerRadius: 8).cgPath
      self.bboxLayer.path = UIBezierPath(roundedRect: outerRect, cornerRadius: 12).cgPath

      // Show distance from backend
      if let depth = self.backendDepth {
        self.distanceLabel.text = "\(Int(depth * 100)) cm"
      }
    }
  }


  // ── Project bbox to screen ──────────────────────────────────────────────

  private func projectBboxToScreen(frame: ARFrame) {
    guard let center3D = objectWorldPosition else { return }
    let viewSize = CGSize(width: cachedSW, height: cachedSH)
    let camera = frame.camera

    let centerScreen = camera.projectPoint(center3D, orientation: .portrait, viewportSize: viewSize)
    let cornerTR = center3D + objectWorldRight * objectWorldHalfW + objectWorldUp * objectWorldHalfH
    let cornerBL = center3D - objectWorldRight * objectWorldHalfW - objectWorldUp * objectWorldHalfH
    let trScreen = camera.projectPoint(cornerTR, orientation: .portrait, viewportSize: viewSize)
    let blScreen = camera.projectPoint(cornerBL, orientation: .portrait, viewportSize: viewSize)

    let screenW = abs(trScreen.x - blScreen.x)
    let screenH = abs(trScreen.y - blScreen.y)

    // Check behind camera
    let camPos = simd_float3(camera.transform.columns.3.x, camera.transform.columns.3.y, camera.transform.columns.3.z)
    let camFwd = -simd_normalize(simd_float3(camera.transform.columns.2.x, camera.transform.columns.2.y, camera.transform.columns.2.z))
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

    let dist = simd_length(center3D - camPos)

    projectedBboxCenter = centerScreen
    projectedBboxW = max(screenW, 20)
    projectedBboxH = max(screenH, 20)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.bboxLayer.isHidden = false
      self.innerBboxLayer.isHidden = false

      let innerRect = CGRect(x: centerScreen.x - self.projectedBboxW/2,
                              y: centerScreen.y - self.projectedBboxH/2,
                              width: self.projectedBboxW, height: self.projectedBboxH)
      let tolX = max(self.projectedBboxW * 0.25, 15)
      let tolY = max(self.projectedBboxH * 0.25, 15)
      let outerRect = innerRect.insetBy(dx: -tolX, dy: -tolY)

      self.innerBboxLayer.path = UIBezierPath(roundedRect: innerRect, cornerRadius: 8).cgPath
      self.bboxLayer.path = UIBezierPath(roundedRect: outerRect, cornerRadius: 12).cgPath

      let distCm = Int(dist * 100)
      self.distanceLabel.text = "\(distCm) cm"
    }
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

      cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
      cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancelButton.widthAnchor.constraint(equalToConstant: 120),
      cancelButton.heightAnchor.constraint(equalToConstant: 44),
    ])

    view.accessibilityLabel = "Reaching guidance for \(objectName). Tap Cancel to stop."
  }

  // ── Audio ───────────────────────────────────────────────────────────────

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

  // ── Cancel / Success / Cleanup ──────────────────────────────────────────

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

  // ── Process AR Frame ────────────────────────────────────────────────────

  private func processARFrame(_ frame: ARFrame) {
    guard running else { return }
    arFrameCount += 1

    if !targetPlaced {
      if arFrameCount >= anchorWaitFrames {
        placeScreenTarget()
        say("Target locked.")
      }
      return
    }

    // No need to call projectBboxToScreen — target is fixed in screen space

    let pb = frame.capturedImage
    computeAspectFillCrop(imageW: CGFloat(CVPixelBufferGetWidth(pb)),
                          imageH: CGFloat(CVPixelBufferGetHeight(pb)))

    let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .right, options: [:])
    do { try handler.perform([handReq]) } catch { return }

    guard targetScreenHalfW > 0 else { return }
    let bboxCx = targetScreenCenter.x
    let bboxCy = targetScreenCenter.y
    let bboxHalfW = targetScreenHalfW
    let bboxHalfH = targetScreenHalfH

    guard let obs = handReq.results?.first else {
      noHandFrames += 1; successFrames = 0
      if noHandFrames == noHandLimit {
        DispatchQueue.main.async { [weak self] in self?.say("Show your hand to the camera.") }
      }
      if noHandFrames > noHandLimit + noHandRepeatCycle { noHandFrames = 0 }
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true
        self?.updateDirectionUI(.searching)
      }
      proximityZone = .searching; return
    }

    noHandFrames = 0
    guard let visionPt = handCenter(obs) else {
      successFrames = 0
      DispatchQueue.main.async { [weak self] in self?.handDot.isHidden = true; self?.handDotGlow.isHidden = true }
      return
    }

    let handScreen = visionToScreen(visionPt)
    let screenX = handScreen.x, screenY = handScreen.y
    let dx = screenX - bboxCx, dy = screenY - bboxCy
    let dist = sqrt(dx * dx + dy * dy)

    let innerOverlap = abs(dx) < bboxHalfW && abs(dy) < bboxHalfH
    let tolX = max(targetScreenHalfW * 0.3, 20), tolY = max(targetScreenHalfH * 0.3, 20)
    let nearOverlap = CGRect(x: bboxCx - bboxHalfW - tolX, y: bboxCy - bboxHalfH - tolY,
                             width: bboxHalfW*2 + tolX*2, height: bboxHalfH*2 + tolY*2)
      .contains(CGPoint(x: screenX, y: screenY))

    let sw = cachedSW, sh = cachedSH
    let normDist = dist / max(sw, sh)
    let newProx: ProximityZone
    if innerOverlap       { newProx = .centered }
    else if nearOverlap   { newProx = .veryClose }
    else if normDist < 0.15 { newProx = .close }
    else if normDist < 0.30 { newProx = .medium }
    else                    { newProx = .far }
    proximityZone = newProx

    let direction = computeDirection(handX: screenX, handY: screenY,
                                     bboxCx: bboxCx, bboxCy: bboxCy,
                                     bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH)
    speakDirectionIfNeeded(direction)

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
        case .centered, .veryClose: return .systemGreen
        case .close: return .systemYellow
        case .medium: return .systemOrange
        default: return .systemRed
        }
      }()
      self.handDot.fillColor = color.cgColor
      self.handDotGlow.fillColor = color.withAlphaComponent(0.2).cgColor
      self.updateDirectionUI(direction)

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

    if innerOverlap {
      successFrames += 1
      if successFrames >= successThreshold { handleSuccess() }
    } else { successFrames = 0 }
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
