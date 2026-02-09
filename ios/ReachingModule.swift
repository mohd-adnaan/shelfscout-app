/**
 * ReachingModule.swift — ARKit World-Anchored Reaching
 *
 */

import Foundation
import AVFoundation
import Vision
import UIKit
import ARKit
import SceneKit

// =============================================================================
// MARK: - ReachingModule (React Native Bridge)
// =============================================================================

@objc(ReachingModule)
class ReachingModule: NSObject {

  @objc static func requiresMainQueueSetup() -> Bool { return false }

  @objc func startReaching(
    _ params: NSDictionary,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    NSLog(" [ReachingModule] startReaching params: %@", params)

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

    let status = AVCaptureDevice.authorizationStatus(for: .video)
    let launch = { [weak self] in
      self?.presentReachingVC(bbox: bbox, objectName: objectName,
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
    bbox: [CGFloat], objectName: String,
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
            self.presentReachingVC(bbox: bbox, objectName: objectName,
                                   resolver: resolver, rejecter: rejecter)
          }
        }
        return
      }
      let vc = ReachingViewController(
        bboxRaw: bbox, objectName: objectName,
        onDone: { result in resolver(result) }
      )
      vc.modalPresentationStyle = .fullScreen
      top.present(vc, animated: true)
    }
  }
}

// =============================================================================
// MARK: - ReachingViewController (ARKit World-Anchored)
// =============================================================================

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
  private let onDone: ([String: Any]) -> Void
  private var bboxNormalized: [CGFloat] = [0, 0, 0, 0]

  // ── ARKit ───────────────────────────────────────────────────────────────

  private var sceneView: ARSCNView!
  private var objectWorldPosition: simd_float3?
  private var objectWorldRight: simd_float3 = .zero     // right direction at placement
  private var objectWorldUp: simd_float3 = .zero         // up direction at placement
  private var objectWorldHalfW: Float = 0                // half-width in meters
  private var objectWorldHalfH: Float = 0                // half-height in meters
  private var anchorPlaced = false
  private var arFrameCount = 0
  private let anchorWaitFrames = 15                      // wait for AR to stabilize
  private var initialEstimatedDepth: Float = 0.6

  // ── Vision ──────────────────────────────────────────────────────────────

  private let handReq = VNDetectHumanHandPoseRequest()
  private let visionQ = DispatchQueue(label: "reach.vision", qos: .userInitiated)

  // ── Audio (beeps) ───────────────────────────────────────────────────────

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

  // ── UI ──────────────────────────────────────────────────────────────────

  private let bboxLayer = CAShapeLayer()
  private let innerBboxLayer = CAShapeLayer()
  private let handDot = CAShapeLayer()
  private let statusLabel = UILabel()
  private let objectLabel = UILabel()
  private let cancelButton = UIButton(type: .system)

  // ── Current projected bbox (updated every AR frame) ─────────────────────

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

  private let successThreshold = 20            // Must overlap inner bbox for 20 frames (~0.7s)
  private let noHandLimit = 50
  private let noHandRepeatCycle = 120

  // ── Aspect-fill crop cache ──────────────────────────────────────────────

  private var cropFracX: CGFloat = 0           // fraction of camera width cropped on each side
  private var cropComputed = false

  // ── Init ────────────────────────────────────────────────────────────────

  init(bboxRaw: [CGFloat], objectName: String,
       onDone: @escaping ([String: Any]) -> Void) {
    self.bboxRaw = bboxRaw
    self.objectName = objectName
    self.onDone = onDone
    super.init(nibName: nil, bundle: nil)
    handReq.maximumHandCount = 1
  }
  required init?(coder: NSCoder) { fatalError() }

  // ── Lifecycle ───────────────────────────────────────────────────────────

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    normalizeBbox()
    setupARView()
    setupOverlayUI()
    setupAudio()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    // Delay AR start to let RN camera fully release
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

  // ── Normalize bbox ──────────────────────────────────────────────────────

  private func normalizeBbox() {
    let maxVal = max(bboxRaw[0], bboxRaw[1], bboxRaw[2], bboxRaw[3])
    if maxVal <= 1.0 {
      bboxNormalized = bboxRaw
    } else if maxVal <= 1000 {
      bboxNormalized = bboxRaw.map { $0 / 1000.0 }
    } else {
      let candidateW: [CGFloat] = [3024, 4032, 2048, 1920, 1080]
      let candidateH: [CGFloat] = [4032, 3024, 2732, 2560, 1920]
      var imgW: CGFloat = bboxRaw[2] * 1.15
      var imgH: CGFloat = bboxRaw[3] * 1.15
      for w in candidateW { if w >= bboxRaw[2] { imgW = w; break } }
      for h in candidateH { if h >= bboxRaw[3] { imgH = h; break } }
      bboxNormalized = [bboxRaw[0]/imgW, bboxRaw[1]/imgH, bboxRaw[2]/imgW, bboxRaw[3]/imgH]
      NSLog("📦 [ReachingVC] Bbox pixel → norm %@ (img=%.0fx%.0f)", "\(bboxNormalized)", imgW, imgH)
    }
    bboxNormalized = bboxNormalized.map { min(max($0, 0), 1) }
  }

  // ── ARKit Setup ─────────────────────────────────────────────────────────

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
    config.planeDetection = []   // we don't need planes
    sceneView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
    startBeepLoop()
    NSLog("📷 [ReachingVC] AR session started")
  }

  // ── Place 3D Anchor ─────────────────────────────────────────────────────

  private func placeObjectAnchor(frame: ARFrame) {
    let sw = view.bounds.width
    let sh = view.bounds.height

    // Bbox center on screen
    let bboxCx = ((bboxNormalized[0] + bboxNormalized[2]) / 2) * sw
    let bboxCy = ((bboxNormalized[1] + bboxNormalized[3]) / 2) * sh
    let bboxWidthFrac = bboxNormalized[2] - bboxNormalized[0]
    let bboxHeightFrac = bboxNormalized[3] - bboxNormalized[1]

    // Estimate depth from bbox size
    // Heuristic: object filling ~20% of screen is ~0.5m away
    // depth ≈ 0.10 / bboxWidthFrac, clamped to reasonable range
    let depth = max(Float(0.3), min(Float(1.5), Float(0.10 / bboxWidthFrac)))
    initialEstimatedDepth = depth

    // Camera basis vectors
    let cam = frame.camera.transform
    let forward = -simd_normalize(simd_float3(cam.columns.2.x, cam.columns.2.y, cam.columns.2.z))
    let right   =  simd_normalize(simd_float3(cam.columns.0.x, cam.columns.0.y, cam.columns.0.z))
    let up      =  simd_normalize(simd_float3(cam.columns.1.x, cam.columns.1.y, cam.columns.1.z))
    let camPos  =  simd_float3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)

    // Offset from screen center based on bbox position
    // Screen center is (0.5, 0.5) in normalized coords
    // FOV approximation: at depth d, horizontal extent ≈ d * tan(fovH/2) * 2
    let fovH: Float = 1.0   // ~60° horizontal FOV → tan(30°) ≈ 0.577, * 2 ≈ 1.15
    let fovV: Float = 1.4   // vertical FOV is larger in portrait

    let offsetX = (Float(bboxCx / sw) - 0.5) * depth * fovH
    let offsetY = (0.5 - Float(bboxCy / sh)) * depth * fovV

    // Place object in world space
    let worldPos = camPos + forward * depth + right * offsetX + up * offsetY
    objectWorldPosition = worldPos
    objectWorldRight = right
    objectWorldUp = up

    // Store world-space half-extents for bbox projection
    objectWorldHalfW = Float(bboxWidthFrac) * depth * fovH / 2
    objectWorldHalfH = Float(bboxHeightFrac) * depth * fovV / 2

    // Create visual anchor node (small, mostly invisible)
    let sphere = SCNSphere(radius: 0.005)
    sphere.firstMaterial?.diffuse.contents = UIColor.green.withAlphaComponent(0.3)
    let node = SCNNode(geometry: sphere)
    node.simdWorldPosition = worldPos
    sceneView.scene.rootNode.addChildNode(node)

    anchorPlaced = true
    NSLog("🎯 [ReachingVC] Anchor placed at depth=%.2f offset=(%.2f, %.2f) world=(%@)",
          depth, offsetX, offsetY, "\(worldPos)")
  }

  // ── Project 3D Bbox to Screen (called every frame) ──────────────────────

  private func projectBboxToScreen(frame: ARFrame) {
    guard let center3D = objectWorldPosition else { return }

    let viewSize = view.bounds.size
    let camera = frame.camera

    // Project center
    let centerScreen = camera.projectPoint(center3D,
                                           orientation: .portrait,
                                           viewportSize: viewSize)

    // Project corners to get perspective-correct bbox size
    let cornerTR = center3D + objectWorldRight * objectWorldHalfW + objectWorldUp * objectWorldHalfH
    let cornerBL = center3D - objectWorldRight * objectWorldHalfW - objectWorldUp * objectWorldHalfH

    let trScreen = camera.projectPoint(cornerTR, orientation: .portrait, viewportSize: viewSize)
    let blScreen = camera.projectPoint(cornerBL, orientation: .portrait, viewportSize: viewSize)

    let screenW = abs(trScreen.x - blScreen.x)
    let screenH = abs(trScreen.y - blScreen.y)

    // Check if object is behind camera (z < 0 in camera space)
    let camPos = simd_float3(camera.transform.columns.3.x,
                             camera.transform.columns.3.y,
                             camera.transform.columns.3.z)
    let camFwd = -simd_normalize(simd_float3(camera.transform.columns.2.x,
                                              camera.transform.columns.2.y,
                                              camera.transform.columns.2.z))
    let toObj = center3D - camPos
    let dotFwd = simd_dot(toObj, camFwd)

    if dotFwd < 0 {
      // Object is behind camera — tell user to turn around
      DispatchQueue.main.async { [weak self] in
        self?.bboxLayer.isHidden = true
        self?.innerBboxLayer.isHidden = true
        self?.statusLabel.text = "  Turn around  "
      }
      // Speak it
      let now = ProcessInfo.processInfo.systemUptime
      if now - lastSpeechTime > 3.0 {
        say("Object is behind you. Turn the phone back.")
        lastSpeechTime = now
      }
      return
    }

    // Update stored values
    projectedBboxCenter = centerScreen
    projectedBboxW = max(screenW, 20)  // minimum visible size
    projectedBboxH = max(screenH, 20)

    // Update overlay on main thread
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.bboxLayer.isHidden = false
      self.innerBboxLayer.isHidden = false

      let innerRect = CGRect(x: centerScreen.x - self.projectedBboxW/2,
                              y: centerScreen.y - self.projectedBboxH/2,
                              width: self.projectedBboxW,
                              height: self.projectedBboxH)
      let tolX = max(self.projectedBboxW * 0.25, 15)
      let tolY = max(self.projectedBboxH * 0.25, 15)
      let outerRect = innerRect.insetBy(dx: -tolX, dy: -tolY)

      self.innerBboxLayer.path = UIBezierPath(rect: innerRect).cgPath
      self.bboxLayer.path = UIBezierPath(roundedRect: outerRect, cornerRadius: 4).cgPath
    }
  }

  // ── Compute Aspect-Fill Crop ────────────────────────────────────────────

  private func computeAspectFillCrop(imageW: CGFloat, imageH: CGFloat) {
    guard !cropComputed else { return }
    let sw = view.bounds.width
    let sh = view.bounds.height
    guard sw > 0, sh > 0, imageW > 0, imageH > 0 else { return }

    // Camera image is landscape (e.g., 1920x1440)
    // After rotation to portrait: rotW = imageH, rotH = imageW
    let rotW = imageH
    let rotH = imageW

    let cameraAspect = rotW / rotH   // e.g., 0.75
    let screenAspect = sw / sh       // e.g., 0.461

    if cameraAspect > screenAspect {
      // Camera is wider → crop sides (x axis)
      let scaleToFillH = sh / rotH
      let displayedW = rotW * scaleToFillH
      let cropPx = (displayedW - sw) / 2
      cropFracX = cropPx / displayedW
    } else {
      cropFracX = 0
    }

    cropComputed = true
    NSLog("📐 [ReachingVC] Aspect-fill cropFracX=%.4f (cam=%@, screen=%@)",
          cropFracX, "\(Int(imageW))x\(Int(imageH))", "\(Int(sw))x\(Int(sh))")
  }

  // ── Map hand Vision coords → screen coords (aspect-fill corrected) ────

  private func visionToScreen(_ visionPt: CGPoint) -> CGPoint {
    let sw = view.bounds.width
    let sh = view.bounds.height

    // Vision with .right orientation:
    // x = 0..1 left-to-right in portrait (maps to screen x)
    // y = 0..1 bottom-to-top in portrait (maps to inverted screen y)

    // Correct for aspect-fill horizontal crop:
    let adjustedX: CGFloat
    if cropFracX > 0 {
      adjustedX = ((visionPt.x - cropFracX) / (1.0 - 2 * cropFracX)) * sw
    } else {
      adjustedX = visionPt.x * sw
    }

    let screenY = (1 - visionPt.y) * sh

    return CGPoint(x: adjustedX, y: screenY)
  }

  // ── Overlay UI Setup ────────────────────────────────────────────────────

  private func setupOverlayUI() {
    bboxLayer.strokeColor = UIColor.cyan.cgColor
    bboxLayer.fillColor = UIColor.cyan.withAlphaComponent(0.08).cgColor
    bboxLayer.lineWidth = 3
    bboxLayer.isHidden = true
    view.layer.addSublayer(bboxLayer)

    innerBboxLayer.strokeColor = UIColor.blue.cgColor
    innerBboxLayer.fillColor = UIColor.clear.cgColor
    innerBboxLayer.lineWidth = 2
    innerBboxLayer.isHidden = true
    view.layer.addSublayer(innerBboxLayer)

    handDot.fillColor = UIColor.green.cgColor
    handDot.strokeColor = UIColor.white.cgColor
    handDot.lineWidth = 2
    handDot.isHidden = true
    view.layer.addSublayer(handDot)

    statusLabel.font = UIFont.boldSystemFont(ofSize: 22)
    statusLabel.textColor = .white
    statusLabel.textAlignment = .center
    statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    statusLabel.layer.cornerRadius = 10
    statusLabel.clipsToBounds = true
    statusLabel.text = "  Show your hand…  "
    statusLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statusLabel)

    objectLabel.font = UIFont.systemFont(ofSize: 18, weight: .medium)
    objectLabel.textColor = .white
    objectLabel.textAlignment = .center
    objectLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
    objectLabel.layer.cornerRadius = 12
    objectLabel.clipsToBounds = true
    objectLabel.text = "  Reaching: \(objectName)  "
    objectLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(objectLabel)

    cancelButton.setTitle("  ✕  Cancel  ", for: .normal)
    cancelButton.titleLabel?.font = UIFont.boldSystemFont(ofSize: 18)
    cancelButton.setTitleColor(.white, for: .normal)
    cancelButton.backgroundColor = UIColor.red.withAlphaComponent(0.7)
    cancelButton.layer.cornerRadius = 20
    cancelButton.translatesAutoresizingMaskIntoConstraints = false
    cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    view.addSubview(cancelButton)

    NSLayoutConstraint.activate([
      objectLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      objectLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      objectLabel.heightAnchor.constraint(equalToConstant: 40),
      statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      statusLabel.bottomAnchor.constraint(equalTo: cancelButton.topAnchor, constant: -20),
      statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
      statusLabel.heightAnchor.constraint(equalToConstant: 44),
      cancelButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancelButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -30),
      cancelButton.heightAnchor.constraint(equalToConstant: 44),
      cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),
    ])
  }

  // ── Audio ───────────────────────────────────────────────────────────────

  private func setupAudio() {
    do {
      let s = AVAudioSession.sharedInstance()
      try s.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try s.setActive(true)

      let engine = AVAudioEngine()
      let player = AVAudioPlayerNode()
      engine.attach(player)

      let sr: Double = 44100; let dur: Double = 0.08; let freq: Double = 880
      let fc = AVAudioFrameCount(sr * dur)
      guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }
      self.audioFmt = fmt
      engine.connect(player, to: engine.mainMixerNode, format: fmt)

      guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
      buf.frameLength = fc
      let d = buf.floatChannelData![0]
      for i in 0..<Int(fc) {
        let t = Double(i) / sr
        let env = min(t / 0.01, 1) * min((dur - t) / 0.01, 1)
        d[i] = Float(sin(2 * .pi * freq * t) * 0.6 * env)
      }
      self.beepBuf = buf; self.playerNode = player; self.audioEngine = engine
      try engine.start()
      NSLog("🔊 [ReachingVC] Audio ready")
    } catch {
      NSLog("⚠️ [ReachingVC] Audio error: %@", error.localizedDescription)
    }
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
      case .far:       return 0.8
      case .medium:    return 0.45
      case .close:     return 0.22
      case .veryClose: return 0.10
      case .centered:  return 0.05
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

  // ── Cancel / Success / Cleanup ──────────────────────────────────────────

  @objc private func cancelTapped() {
    say("Cancelled")
    finishWith(success: false, reason: "user_cancelled")
  }

  private func handleSuccess() {
    guard running, !hasCompleted else { return }
    running = false; hasCompleted = true
    NSLog(" [ReachingVC] SUCCESS – reached %@", objectName)
    beepTimer?.cancel(); beepTimer = nil
    playSuccessTone()

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.statusLabel.text = "  ✅ \(self.objectName) reached!  "
      self.statusLabel.textColor = .green
      self.statusLabel.font = UIFont.boldSystemFont(ofSize: 26)
      let flash = UIView(frame: self.view.bounds)
      flash.backgroundColor = UIColor.green.withAlphaComponent(0.3)
      self.view.addSubview(flash)
      UIView.animate(withDuration: 0.8) { flash.alpha = 0 } completion: { _ in flash.removeFromSuperview() }
    }
    say("\(objectName) reached! You got it!")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      self?.finishWith(success: true, reason: "reached")
    }
  }

  private func playSuccessTone() {
    guard let player = playerNode, let fmt = audioFmt else { return }
    let sr: Double = 44100; let dur: Double = 0.6
    let fc = AVAudioFrameCount(sr * dur)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: fc) else { return }
    buf.frameLength = fc; let d = buf.floatChannelData![0]
    for i in 0..<Int(fc) {
      let t = Double(i) / sr; let f = 440.0 + 880.0 * t / dur
      let env = min(t / 0.02, 1) * min((dur - t) / 0.1, 1)
      d[i] = Float(sin(2 * .pi * f * t) * 0.7 * env)
    }
    player.pan = 0.0
    player.scheduleBuffer(buf, at: nil, options: .interrupts)
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
    running = false
    beepTimer?.cancel(); beepTimer = nil
    playerNode?.stop()
    audioEngine?.stop(); audioEngine = nil
    synth.stopSpeaking(at: .immediate)
    sceneView.session.pause()
  }

  // ── Speech ──────────────────────────────────────────────────────────────

  private func say(_ text: String) {
    synth.stopSpeaking(at: .immediate)
    let u = AVSpeechUtterance(string: text)
    u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
    u.voice = AVSpeechSynthesisVoice(language: "en-US")
    synth.speak(u)
    NSLog("🗣 [ReachingVC] %@", text)
  }

  private func speakDirectionIfNeeded(_ direction: Direction) {
    guard direction != .searching else { return }
    let now = ProcessInfo.processInfo.systemUptime

    if direction == currentDirection { directionStableFrames += 1 }
    else { directionStableFrames = 1 }

    if direction == lastSpokenDirection {
      if direction == .centered && (now - lastSpeechTime) > 3.0 {
        say("Centered!"); lastSpeechTime = now
      }
      return
    }
    if directionStableFrames >= directionStableThreshold && (now - lastSpeechTime) >= speechCooldown {
      say(direction == .centered ? "Centered!" : direction.rawValue)
      lastSpokenDirection = direction; lastSpeechTime = now
    }
  }

  // ── Direction computation ───────────────────────────────────────────────

  private func computeDirection(handX: CGFloat, handY: CGFloat,
                                bboxCx: CGFloat, bboxCy: CGFloat,
                                bboxHalfW: CGFloat, bboxHalfH: CGFloat) -> Direction {
    let deltaX = handX - bboxCx
    let deltaY = handY - bboxCy
    if abs(deltaX) < bboxHalfW && abs(deltaY) < bboxHalfH { return .centered }

    // Angle FROM hand TO bbox (direction user needs to move)
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

  // ── Hand center ─────────────────────────────────────────────────────────

  private func handCenter(_ obs: VNHumanHandPoseObservation) -> CGPoint? {
    if let tip = try? obs.recognizedPoint(.indexTip), tip.confidence > 0.3 { return tip.location }
    if let mcp = try? obs.recognizedPoint(.middleMCP), mcp.confidence > 0.3 { return mcp.location }
    if let w = try? obs.recognizedPoint(.wrist),
       let i = try? obs.recognizedPoint(.indexTip),
       w.confidence > 0.3, i.confidence > 0.3 {
      return CGPoint(x: (w.location.x+i.location.x)/2, y: (w.location.y+i.location.y)/2)
    }
    if let w = try? obs.recognizedPoint(.wrist), w.confidence > 0.3 { return w.location }
    return nil
  }

  // ── Process AR Frame ────────────────────────────────────────────────────

  private func processARFrame(_ frame: ARFrame) {
    guard running else { return }

    arFrameCount += 1

    // Wait for AR to stabilize before placing anchor
    if !anchorPlaced {
      if arFrameCount >= anchorWaitFrames {
        placeObjectAnchor(frame: frame)
        say("Target locked.")
      }
      return
    }

    // ── 1. Project bbox to screen (world-anchored) ───────────────────────
    projectBboxToScreen(frame: frame)

    // ── 2. Compute aspect-fill crop (once) ───────────────────────────────
    let pixelBuffer = frame.capturedImage
    let imageW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
    let imageH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
    computeAspectFillCrop(imageW: imageW, imageH: imageH)

    // ── 3. Run hand detection ────────────────────────────────────────────
    let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
    do { try handler.perform([handReq]) } catch { return }

    let sw = view.bounds.width
    let sh = view.bounds.height
    guard sw > 0, sh > 0, projectedBboxW > 0 else { return }

    let bboxCx = projectedBboxCenter.x
    let bboxCy = projectedBboxCenter.y
    let bboxHalfW = projectedBboxW / 2
    let bboxHalfH = projectedBboxH / 2

    // ── No hand detected ─────────────────────────────────────────────────
    guard let obs = handReq.results?.first else {
      noHandFrames += 1; successFrames = 0
      if noHandFrames == noHandLimit {
        DispatchQueue.main.async { [weak self] in
          self?.say("Hand not detected. Show your hand to the camera.")
        }
      }
      if noHandFrames > noHandLimit + noHandRepeatCycle { noHandFrames = 0 }
      DispatchQueue.main.async { [weak self] in
        self?.handDot.isHidden = true
        self?.updateDirectionUI(.searching)
      }
      proximityZone = .searching
      return
    }

    noHandFrames = 0
    guard let visionPt = handCenter(obs) else {
      successFrames = 0
      DispatchQueue.main.async { [weak self] in self?.handDot.isHidden = true }
      return
    }

    // ── 4. Map hand to screen (aspect-fill corrected) ────────────────────
    let handScreen = visionToScreen(visionPt)
    let screenX = handScreen.x
    let screenY = handScreen.y

    // ── 5. Distance & overlap check ──────────────────────────────────────
    let dx = screenX - bboxCx
    let dy = screenY - bboxCy
    let dist = sqrt(dx * dx + dy * dy)

    // Overlap: hand inside INNER bbox (strict — no tolerance expansion)
    let innerOverlap = abs(dx) < bboxHalfW && abs(dy) < bboxHalfH

    // Tolerance overlap: hand inside outer bbox (for proximity/direction)
    let tolX = max(projectedBboxW * 0.3, 20)
    let tolY = max(projectedBboxH * 0.3, 20)
    let expandedRect = CGRect(x: bboxCx - bboxHalfW - tolX,
                              y: bboxCy - bboxHalfH - tolY,
                              width: projectedBboxW + tolX*2,
                              height: projectedBboxH + tolY*2)
    let nearOverlap = expandedRect.contains(CGPoint(x: screenX, y: screenY))

    // ── 6. Proximity zone ────────────────────────────────────────────────
    let maxDim = max(sw, sh)
    let normDist = dist / maxDim
    let newProx: ProximityZone
    if innerOverlap       { newProx = .centered }
    else if nearOverlap   { newProx = .veryClose }
    else if normDist < 0.15 { newProx = .close }
    else if normDist < 0.30 { newProx = .medium }
    else                    { newProx = .far }
    proximityZone = newProx

    // ── 7. Direction ─────────────────────────────────────────────────────
    let direction = computeDirection(
      handX: screenX, handY: screenY,
      bboxCx: bboxCx, bboxCy: bboxCy,
      bboxHalfW: bboxHalfW, bboxHalfH: bboxHalfH
    )
    speakDirectionIfNeeded(direction)

    // ── 8. UI update ─────────────────────────────────────────────────────
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      let dotSize: CGFloat = 20
      self.handDot.isHidden = false
      self.handDot.path = UIBezierPath(ovalIn: CGRect(
        x: screenX - dotSize/2, y: screenY - dotSize/2,
        width: dotSize, height: dotSize)).cgPath

      switch newProx {
      case .centered:  self.handDot.fillColor = UIColor.green.cgColor
      case .veryClose: self.handDot.fillColor = UIColor.green.withAlphaComponent(0.8).cgColor
      case .close:     self.handDot.fillColor = UIColor.yellow.cgColor
      case .medium:    self.handDot.fillColor = UIColor.orange.cgColor
      default:         self.handDot.fillColor = UIColor.red.cgColor
      }
      self.updateDirectionUI(direction)
    }

    // ── 9. Success (hand inside INNER bbox for 20 frames) ────────────────
    if innerOverlap {
      successFrames += 1
      if successFrames % 5 == 0 {
        NSLog("🎯 [ReachingVC] Overlap frame %d/%d", successFrames, successThreshold)
      }
      if successFrames >= successThreshold { handleSuccess() }
    } else {
      if successFrames > 3 {
        NSLog("📍 [ReachingVC] Overlap broken at %d frames", successFrames)
      }
      successFrames = 0
    }
  }

  private func updateDirectionUI(_ newDir: Direction) {
    guard newDir != currentDirection else { return }
    currentDirection = newDir
    statusLabel.text = "  \(newDir.rawValue)  "
    statusLabel.textColor = newDir == .centered ? .green : .white
    statusLabel.font = UIFont.boldSystemFont(ofSize: newDir == .centered ? 26 : 22)
  }
}

// =============================================================================
// MARK: - ARSessionDelegate
// =============================================================================

extension ReachingViewController: ARSessionDelegate {

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    // Process on vision queue to avoid blocking AR
    visionQ.async { [weak self] in
      self?.processARFrame(frame)
    }
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    NSLog("❌ [ReachingVC] AR failed: %@", error.localizedDescription)
    say("Tracking failed. Please try again.")
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      self?.finishWith(success: false, reason: "ar_error")
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    say("Tracking interrupted")
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    say("Tracking resumed")
  }
}
