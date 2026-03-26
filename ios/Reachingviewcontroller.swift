
//
//  Reachingviewcontroller.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//
//  Core VC, Properties, UI, Lifecycle
//

import Foundation
import AVFoundation
import Vision
import UIKit
import ARKit
import SceneKit
import CoreHaptics

class ReachingViewController: UIViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Enums
  // ═══════════════════════════════════════════════════════════════════════════

  enum Direction: String {
    case left = "left", topLeft = "top left", top = "up", topRight = "top right"
    case right = "right", downRight = "down right", down = "down", downLeft = "down left"
    case centered = "Aligned", searching = "Searching"
  }

  enum ProximityZone: String {
    case searching, far, medium, close, veryClose, centered
  }

  // 3-state depth result: YES (hand at object), NO (hand confirmed far), NO_DATA (nothing measured)
  enum DepthResult {
    case close      // depth method confirms hand is at object
    case far        // depth method confirms hand is NOT at object
    case noData     // no method could measure — inconclusive
  }

  /// Reaching mode: hand-free uses camera center as reference; withHand uses Vision hand tracking
  enum ReachingMode: String {
    case handFree = "handFree"
    case withHand = "withHand"
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Depth Thresholds
  // ═══════════════════════════════════════════════════════════════════════════

  let raycastDepthThreshold: Float = 0.18
  let lidarDepthThreshold:   Float = 0.12
  let heuristicDepthThreshold: Float = 0.12
  let reachProximityThreshold: Float = 0.70

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Config (set at init, never change)
  // ═══════════════════════════════════════════════════════════════════════════

  let bboxRaw: [CGFloat]
  let objectName: String
  let backendDepth: Float?
  var imageWidth:   CGFloat          // var — updated by progressive re-detection
  var imageHeight:  CGFloat          // var — updated by progressive re-detection
  let onDone: ([String: Any]) -> Void
  var bboxNormalized: [CGFloat] = [0, 0, 0, 0]
  let mode: ReachingMode

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Progressive Re-detection
  // ═══════════════════════════════════════════════════════════════════════════

  let detectionUrl: String?
  var bboxUpdateCount = 0
  var redetectTimer: Timer?
  let redetectInterval: TimeInterval = 8.0   // seconds between re-detections (Qwen takes ~10-20s)
  var isRedetecting = false
  var lastARFrame: ARFrame?                   // latest frame for capture

  // Spatial Consistency Gate — prevent re-detection from jumping to wrong object
  var initialBboxCenter: (cx: CGFloat, cy: CGFloat) = (0.5, 0.5)
  var initialBboxSize: (w: CGFloat, h: CGFloat) = (0.05, 0.06)
  var consecutiveRejects = 0

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - 3D World Anchor
  // ═══════════════════════════════════════════════════════════════════════════

  var objectWorldPosition: simd_float3?
  var objectWorldCornerTR: simd_float3 = .zero
  var objectWorldCornerBL: simd_float3 = .zero
  var objectWorldHalfW: Float = 0
  var objectWorldHalfH: Float = 0
  var anchorPlaced = false
  var anchorDepth: Float = 0.5
  var liveDistanceToObject: Float = 0.5
  var handIsCloseEnoughInDepth = false
  /// Hand-free: lock anchor after first ARKit refinement converges.
  /// Re-detection still runs (for logging) but CANNOT move the anchor.
  var anchorLockedForHandFree = false

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - ARKit
  // ═══════════════════════════════════════════════════════════════════════════

  var sceneView: ARSCNView!
  var arFrameCount = 0
  let anchorWaitFrames = 15
  var meshReconstructionEnabled = false
  var lastFrameProcessedAt: TimeInterval = 0
  let frameProcessInterval: TimeInterval = 0.05
  var anchorRefinementFrames = 0
  let anchorRefinementLimit = 600
  var refinementHits: [Float] = []
  let refinementMinHits = 5
  let refinementConvergeThreshold: Float = 0.05
  var lastRefinementAppliedDepth: Float = 0

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Vision
  // ═══════════════════════════════════════════════════════════════════════════

  let handReq = VNDetectHumanHandPoseRequest()
  let visionQ = DispatchQueue(label: "reach.vision", qos: .userInitiated)

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Audio / Speech / Haptics
  // ═══════════════════════════════════════════════════════════════════════════

  var audioEngine: AVAudioEngine?
  var playerNode: AVAudioPlayerNode?
  var beepBuf: AVAudioPCMBuffer?
  var audioFmt: AVAudioFormat?
  var beepTimer: DispatchSourceTimer?
  let audioQ = DispatchQueue(label: "reach.audio", qos: .userInitiated)
  var lastBeep: TimeInterval = 0

  let synth = AVSpeechSynthesizer()
  var lastSpokenDirection: Direction = .searching
  var lastSpeechTime: TimeInterval = 0
  var speechCooldown: TimeInterval = 1.2
  var directionStableFrames = 0
  var directionStableThreshold = 4
  /// TTS rate passed from React Native (matches user's app-wide setting)
  var ttsRate: Float = 0.5
  /// Cached premium voice (Zoe if available, else best English US)
  lazy var premiumVoice: AVSpeechSynthesisVoice? = {
    // Try premium Zoe first (matches the rest of the app)
    if let zoe = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe") { return zoe }
    // Fallback: enhanced Samantha
    if let sam = AVSpeechSynthesisVoice(identifier: "com.apple.voice.enhanced.en-US.Samantha") { return sam }
    return AVSpeechSynthesisVoice(language: "en-US")
  }()

  var hapticEngine: CHHapticEngine?

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - UI Elements
  // ═══════════════════════════════════════════════════════════════════════════

  let bboxLayer      = CAShapeLayer()
  let innerBboxLayer = CAShapeLayer()
  let handDot        = CAShapeLayer()
  let handDotGlow    = CAShapeLayer()
  var topBar: UIVisualEffectView!
  var bottomBar: UIVisualEffectView!
  var directionLabel: UILabel!
  var objectNameLabel: UILabel!
  var cancelButton: UIButton!
  var progressRing: CAShapeLayer!
  var distanceLabel: UILabel!
  var depthHintLabel: UILabel!
  var depthMethodLabel: UILabel!

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Projected Bbox
  // ═══════════════════════════════════════════════════════════════════════════

  var projectedBboxCenter = CGPoint.zero
  var projectedBboxW: CGFloat = 0
  var projectedBboxH: CGFloat = 0

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - State
  // ═══════════════════════════════════════════════════════════════════════════

  var running = false
  var currentDirection: Direction = .searching
  var proximityZone: ProximityZone = .searching
  var noHandFrames = 0
  var successFrames = 0
  var depthConfirmedFrames = 0
  var hasCompleted = false
  var hasDismissed = false

  // ── Hand-free state ────────────────────────────────────────────────────
  /// Initial distance when anchor locks — used to compute step progress
  var initialLockedDistance: Float = 0
  /// Last announced step count — used to confirm "going the right way"
  var lastAnnouncedSteps: Int = -1
  /// How many times we've confirmed direction progress (cap at 2)
  var progressConfirmations: Int = 0
  /// Whether the object is currently off-screen (behind or far off-axis)
  /// Drives beep behavior: slow + panned when true
  var objectOffScreen: Bool = false
  /// Last known horizontal direction of object (for beep panning when off-screen)
  var lastKnownHorizontalSign: Float = 0  // +1 = right, -1 = left
  /// Continuous right-dot value for grab guidance ("slightly left/right")
  var lastRightDot: Float = 0
  /// Whether camera is currently aligned with object (for state-change sounds)
  var isCenteredState: Bool = false
  /// Human-readable label of last known direction ("to your right", "to your left")
  /// Used for "Out of view, was to your right" memory
  var lastKnownDirectionLabel: String = ""
  /// Distance unit: "steps" or "cm"
  var distanceUnit: String = "steps"

  // ── Nicolas-style state-change audio players ───────────────────────────
  var centeredPlayer: AVAudioPlayer?
  var uncenteredPlayer: AVAudioPlayer?
  var targetLostPlayer: AVAudioPlayer?

  let successThreshold = 35
  let noHandLimit = 50
  let noHandRepeatCycle = 120

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Screen / Crop
  // ═══════════════════════════════════════════════════════════════════════════

  var cachedSW: CGFloat = 393
  var cachedSH: CGFloat = 852
  var cropFracX: CGFloat = 0
  var cropComputed = false

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Init
  // ═══════════════════════════════════════════════════════════════════════════

  init(bboxRaw: [CGFloat], objectName: String, backendDepth: Float?,
       imageWidth: CGFloat, imageHeight: CGFloat,
       detectionUrl: String? = nil,
       mode: ReachingMode = .handFree,
       ttsRate: Float = 0.5,
       distanceUnit: String = "steps",
       onDone: @escaping ([String: Any]) -> Void) {
    self.bboxRaw      = bboxRaw
    self.objectName   = objectName
    self.backendDepth = backendDepth
    self.imageWidth   = imageWidth
    self.imageHeight  = imageHeight
    self.detectionUrl = detectionUrl
    self.mode         = mode
    self.ttsRate      = ttsRate
    self.distanceUnit = distanceUnit
    self.onDone       = onDone
    super.init(nibName: nil, bundle: nil)
    if mode == .withHand {
      handReq.maximumHandCount = 1
    } else {
      // Hand-free: wider stability thresholds — user is walking, directions flicker
      speechCooldown = 2.0
      directionStableThreshold = 8
    }
  }
  required init?(coder: NSCoder) { fatalError() }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    cachedSW = UIScreen.main.bounds.width
    cachedSH = UIScreen.main.bounds.height
    NSLog("📐 [ReachingVC] Screen: %.0f×%.0f", cachedSW, cachedSH)
    normalizeBbox()

    // Store the initial bbox center as the reference for spatial consistency gate.
    // All subsequent re-detections are compared against this to prevent drift.
    initialBboxCenter = (
      cx: (bboxNormalized[0] + bboxNormalized[2]) / 2,
      cy: (bboxNormalized[1] + bboxNormalized[3]) / 2
    )
    initialBboxSize = (
      w: bboxNormalized[2] - bboxNormalized[0],
      h: bboxNormalized[3] - bboxNormalized[1]
    )
    NSLog("📦 [ReachingVC] Initial center=(%.3f,%.3f) size=%.3f×%.3f — spatial gate reference locked",
          initialBboxCenter.cx, initialBboxCenter.cy, initialBboxSize.w, initialBboxSize.h)

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
      if self.mode == .handFree {
        self.say("Guiding to \(self.objectName). Point phone toward it. Tap anywhere when you have it.")
      } else {
        self.say("Guiding to \(self.objectName). Show your hand. Tap anywhere when you have it.")
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cleanup()
  }

  override var prefersStatusBarHidden: Bool { true }
  override var prefersHomeIndicatorAutoHidden: Bool { true }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Tap to Dismiss
  // ═══════════════════════════════════════════════════════════════════════════

  private func setupTapToDismiss() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap(_:)))
    tap.cancelsTouchesInView = false
    view.addGestureRecognizer(tap)
  }

  @objc private func handleBackgroundTap(_ gesture: UITapGestureRecognizer) {
    guard !hasCompleted else { return }
    let pt = gesture.location(in: view)
    if cancelButton.frame.contains(pt) { return }
    // NOTE: Removed topBar/bottomBar exclusions — tapping anywhere should cancel.
    // With VoiceOver, these exclusions prevented exit since VoiceOver focuses
    // on topBar elements and double-tap triggers within their frame.
    cancelTapped()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - VoiceOver Accessibility Overrides
  // ═══════════════════════════════════════════════════════════════════════════

  /// Two-finger scrub (VoiceOver "back" gesture) → done reaching
  override func accessibilityPerformEscape() -> Bool {
    guard !hasCompleted else { return true }
    NSLog("♿ [ReachingVC] VoiceOver escape gesture — done")
    cancelTapped()
    return true
  }

  /// Two-finger double-tap (VoiceOver "magic tap") → done reaching
  override func accessibilityPerformMagicTap() -> Bool {
    guard !hasCompleted else { return true }
    NSLog("♿ [ReachingVC] VoiceOver magic tap — done")
    cancelTapped()
    return true
  }

  /// VoiceOver double-tap on any focused element → done reaching
  /// This propagates up the responder chain from any child element.
  override func accessibilityActivate() -> Bool {
    guard !hasCompleted else { return true }
    NSLog("♿ [ReachingVC] VoiceOver activate (double-tap) — done")
    cancelTapped()
    return true
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Normalize Bbox
  // ═══════════════════════════════════════════════════════════════════════════

  func normalizeBbox() {
    let x1 = min(abs(bboxRaw[0]), abs(bboxRaw[2]))
    let y1 = min(abs(bboxRaw[1]), abs(bboxRaw[3]))
    let x2 = max(abs(bboxRaw[0]), abs(bboxRaw[2]))
    let y2 = max(abs(bboxRaw[1]), abs(bboxRaw[3]))
    let maxVal = max(x1, y1, x2, y2)

    NSLog("📦 [ReachingVC] Raw bbox: [%.1f, %.1f, %.1f, %.1f] imgDims=%.0f×%.0f maxVal=%.1f",
          x1, y1, x2, y2, imageWidth, imageHeight, maxVal)

    if maxVal <= 1.0 {
      // Already normalized [0..1]
      bboxNormalized = [x1, y1, x2, y2]
      NSLog("📦 [ReachingVC] Bbox already normalized [0..1]")
    } else if imageWidth > 0 && imageHeight > 0 {
      // Have real dimensions — normalize directly
      bboxNormalized = [x1/imageWidth, y1/imageHeight, x2/imageWidth, y2/imageHeight]
      NSLog("📦 [ReachingVC] Normalized with real dims: %.0f×%.0f", imageWidth, imageHeight)
    } else if maxVal <= 1000 {
      // Qwen normalized-to-1000 format (backend Scale bbox should have converted,
      // but if imageWidth/imageHeight were 0, the scaled values may still be 0-1000)
      bboxNormalized = [x1/1000, y1/1000, x2/1000, y2/1000]
      NSLog("⚠️ [ReachingVC] imgDims=0×0 but maxVal<=1000 — assuming Qwen 1000-scale")
    } else {
      // Last resort: estimate from bbox values themselves
      let gW: CGFloat = max(x2 * 1.1, 1536), gH: CGFloat = max(y2 * 1.1, 2048)
      bboxNormalized = [x1/gW, y1/gH, x2/gW, y2/gH]
      NSLog("⚠️ [ReachingVC] imgDims=0×0, guessing %.0f×%.0f from bbox extents", gW, gH)
    }

    bboxNormalized = bboxNormalized.map { min(max($0, 0), 1) }
    let bw = bboxNormalized[2] - bboxNormalized[0]
    let bh = bboxNormalized[3] - bboxNormalized[1]
    if bw < 0.01 || bh < 0.01 {
      bboxNormalized = [0.35, 0.35, 0.65, 0.65]
      NSLog("⚠️ [ReachingVC] Bbox degenerate (%.3f×%.3f) — using center fallback", bw, bh)
    }
    NSLog("📦 [ReachingVC] Final normalized bbox: [%.3f, %.3f, %.3f, %.3f]",
          bboxNormalized[0], bboxNormalized[1], bboxNormalized[2], bboxNormalized[3])
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Cancel / Success / Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  @objc func cancelTapped() {
    guard !hasCompleted else { return }
    // Manual exit = user confirms they have the object (or wants to stop)
    // Always treat as success since auto-detection is unreliable
    say("Done"); finishWith(success: true, reason: "user_confirmed")
  }

  func handleSuccess() {
    guard running, !hasCompleted else { return }
    running = false; hasCompleted = true
    NSLog("🎉 [ReachingVC] SUCCESS – reached %@", objectName)

    sceneView.session.pause()
    beepTimer?.cancel(); beepTimer = nil
    playSuccessTone(); triggerHaptic(1.0)

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.directionLabel.text = "✅  \(self.objectName) reached!"
      self.directionLabel.textColor = .systemGreen
      self.depthHintLabel.isHidden = true
      self.handDot.isHidden = true; self.handDotGlow.isHidden = true
      self.progressRing.isHidden = true

      let flash = UIView(frame: self.view.bounds)
      flash.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
      self.view.addSubview(flash)
      UIView.animate(withDuration: 1.0) { flash.alpha = 0 } completion: { _ in flash.removeFromSuperview() }
    }
    say("\(objectName) reached!")

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      guard let self = self, !self.hasDismissed else { return }
      self.hasDismissed = true
      self.cleanup()
      self.dismiss(animated: true) {
        self.onDone(["success": true, "object": self.objectName,
                     "reason": "reached", "mode": self.mode.rawValue,
                     "message": "\(self.objectName) reached!"])
      }
    }
  }

  func finishWith(success: Bool, reason: String) {
    guard !hasDismissed else { return }
    hasDismissed = true; running = false
    sceneView.session.pause()
    cleanup()
    let msg = reason == "user_confirmed"
      ? "Reaching complete."
      : (success ? "\(objectName) reached!" : "Reaching ended.")
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.dismiss(animated: true) {
        self.onDone(["success": success, "object": self.objectName,
                     "reason": reason,
                     "mode": self.mode.rawValue,
                     "message": msg])
      }
    }
  }

  func cleanup() {
    running = false; beepTimer?.cancel(); beepTimer = nil
    redetectTimer?.invalidate(); redetectTimer = nil
    lastARFrame = nil  // release to avoid ARFrame retention warning
    playerNode?.stop(); audioEngine?.stop(); audioEngine = nil
    hapticEngine?.stop(); hapticEngine = nil
    synth.stopSpeaking(at: .immediate)
    sceneView?.session.pause()
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - UI Setup
  // ═══════════════════════════════════════════════════════════════════════════

  func setupAppleUI() {
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
    directionLabel.text = mode == .handFree ? "Point camera…" : "Show your hand…"
    directionLabel.font = .systemFont(ofSize: 24, weight: .bold)
    directionLabel.textColor = .white; directionLabel.textAlignment = .center
    directionLabel.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.contentView.addSubview(directionLabel)

    depthHintLabel = UILabel()
    depthHintLabel.text = mode == .handFree
      ? "Move closer — tap anywhere when done"
      : "Move hand forward — tap anywhere when done"
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
    cancelButton.setTitle("Done", for: .normal)
    cancelButton.setTitleColor(.white, for: .normal)
    cancelButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
    cancelButton.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.25)
    cancelButton.layer.cornerRadius = 22
    cancelButton.layer.borderWidth = 1.5
    cancelButton.layer.borderColor = UIColor.systemGreen.withAlphaComponent(0.6).cgColor
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

    view.accessibilityLabel = mode == .handFree
      ? "Reaching guidance for \(objectName). Point camera toward object. Tap anywhere to confirm."
      : "Reaching guidance for \(objectName). Double tap anywhere to confirm."

    // ── VoiceOver Configuration ──────────────────────────────────────────────
    // Make the objectNameLabel (which gets initial VoiceOver focus) actionable.
    // UILabel doesn't respond to VoiceOver double-tap by default — we need
    // userInteractionEnabled + a tap gesture so VoiceOver's synthetic tap fires.
    objectNameLabel.isAccessibilityElement = true
    objectNameLabel.accessibilityLabel = mode == .handFree
      ? "Guiding to \(objectName). Point camera toward it. Double tap to confirm."
      : "Guiding to \(objectName). Double tap anywhere to confirm."
    objectNameLabel.accessibilityTraits = .button
    objectNameLabel.isUserInteractionEnabled = true
    let nameTap = UITapGestureRecognizer(target: self, action: #selector(cancelTapped))
    objectNameLabel.addGestureRecognizer(nameTap)

    // Same for topBar and bottomBar — VoiceOver may focus on them
    topBar.isUserInteractionEnabled = true
    let topTap = UITapGestureRecognizer(target: self, action: #selector(cancelTapped))
    topBar.addGestureRecognizer(topTap)
    topBar.isAccessibilityElement = false // children are the elements

    bottomBar.isUserInteractionEnabled = true
    let botTap = UITapGestureRecognizer(target: self, action: #selector(cancelTapped))
    bottomBar.addGestureRecognizer(botTap)
    bottomBar.isAccessibilityElement = false

    // Make direction label readable but not actionable
    directionLabel.isAccessibilityElement = true
    directionLabel.accessibilityLabel = "Direction guidance"
    directionLabel.accessibilityTraits = .updatesFrequently
    directionLabel.isUserInteractionEnabled = true
    let dirTap = UITapGestureRecognizer(target: self, action: #selector(cancelTapped))
    directionLabel.addGestureRecognizer(dirTap)

    // Cancel button — proper accessibility (also reachable via full-screen tap)
    cancelButton.isAccessibilityElement = true
    cancelButton.accessibilityLabel = "Confirm. I have the object."
    cancelButton.accessibilityHint = "Double tap to exit reaching guidance"

    // Add custom accessibility action on the view so ANY focused element
    // can trigger exit via the actions rotor
    view.accessibilityCustomActions = [
      UIAccessibilityCustomAction(
        name: "I have it",
        target: self,
        selector: #selector(cancelTapped)
      )
    ]
  }

  func updateDirectionUI(_ newDir: Direction) {
    guard newDir != currentDirection else { return }
    currentDirection = newDir
    directionLabel.text = newDir == .centered ? "✅  Aligned" : newDir.rawValue
    directionLabel.textColor = newDir == .centered ? .systemGreen : .white
    UIView.animate(withDuration: 0.15) {
      self.bottomBar.transform = CGAffineTransform(scaleX: 1.05, y: 1.05)
    } completion: { _ in
      UIView.animate(withDuration: 0.15) { self.bottomBar.transform = .identity }
    }
  }
}
