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
    case centered = "Centered!", searching = "Show your hand"
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
  let imageWidth:   CGFloat
  let imageHeight:  CGFloat
  let onDone: ([String: Any]) -> Void
  var bboxNormalized: [CGFloat] = [0, 0, 0, 0]

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
  let speechCooldown: TimeInterval = 1.2
  var directionStableFrames = 0
  let directionStableThreshold = 4

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

  /// Two-finger scrub (VoiceOver "back" gesture) → cancel reaching
  override func accessibilityPerformEscape() -> Bool {
    guard !hasCompleted else { return true }
    NSLog("♿ [ReachingVC] VoiceOver escape gesture — cancelling")
    cancelTapped()
    return true
  }

  /// Two-finger double-tap (VoiceOver "magic tap") → cancel reaching
  override func accessibilityPerformMagicTap() -> Bool {
    guard !hasCompleted else { return true }
    NSLog("♿ [ReachingVC] VoiceOver magic tap — cancelling")
    cancelTapped()
    return true
  }

  /// VoiceOver double-tap on any focused element → cancel reaching
  /// This propagates up the responder chain from any child element.
  override func accessibilityActivate() -> Bool {
    guard !hasCompleted else { return true }
    NSLog("♿ [ReachingVC] VoiceOver activate (double-tap) — cancelling")
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
  // MARK: - Cancel / Success / Cleanup
  // ═══════════════════════════════════════════════════════════════════════════

  @objc func cancelTapped() {
    guard !hasCompleted else { return }
    say("Cancelled"); finishWith(success: false, reason: "user_cancelled")
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
                     "reason": "reached", "message": "\(self.objectName) reached!"])
      }
    }
  }

  func finishWith(success: Bool, reason: String) {
    guard !hasDismissed else { return }
    hasDismissed = true; running = false
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

  func cleanup() {
    running = false; beepTimer?.cancel(); beepTimer = nil
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

    view.accessibilityLabel = "Reaching guidance for \(objectName). Double tap to stop."

    // ── VoiceOver Configuration ──────────────────────────────────────────────
    // Make the objectNameLabel (which gets initial VoiceOver focus) actionable.
    // UILabel doesn't respond to VoiceOver double-tap by default — we need
    // userInteractionEnabled + a tap gesture so VoiceOver's synthetic tap fires.
    objectNameLabel.isAccessibilityElement = true
    objectNameLabel.accessibilityLabel = "Guiding to \(objectName). Double tap to stop."
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

    // Cancel button — proper accessibility
    cancelButton.isAccessibilityElement = true
    cancelButton.accessibilityLabel = "Cancel reaching"
    cancelButton.accessibilityHint = "Double tap to stop reaching guidance"

    // Add custom accessibility action on the view so ANY focused element
    // can trigger cancel via the actions rotor
    view.accessibilityCustomActions = [
      UIAccessibilityCustomAction(
        name: "Stop reaching",
        target: self,
        selector: #selector(cancelTapped)
      )
    ]
  }

  func updateDirectionUI(_ newDir: Direction) {
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