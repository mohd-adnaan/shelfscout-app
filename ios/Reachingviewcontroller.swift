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

  private static var dav2PrewarmRequested = false

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
  var backendDepth: Float?
  var imageWidth:   CGFloat          // var — updated by progressive re-detection
  var imageHeight:  CGFloat          // var — updated by progressive re-detection
  let onDone: ([String: Any]) -> Void
  var bboxNormalized: [CGFloat] = [0, 0, 0, 0]
  let mode: ReachingMode

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - LiDAR Detection
  // ═══════════════════════════════════════════════════════════════════════════

  /// true if device has LiDAR (iPhone Pro / iPad Pro) — set once in startAR()
  var hasLiDAR = false
  /// true after first LiDAR depth sample used for anchor seeding
  var lidarDepthSeeded = false

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - With-Hand Phase Control
  // ═══════════════════════════════════════════════════════════════════════════

  /// Distance (meters) at which with-hand switches from Phase 1 (navigation)
  /// to Phase 2 (hand guidance). 0.50m gives user time to raise hand before
  /// acquisition threshold (0.40m).
  let handGuidanceThreshold: Float = 0.50
  /// Hysteresis: must exceed this to drop BACK to Phase 1 (prevents oscillation)
  let handGuidanceExitThreshold: Float = 0.65
  /// Phase 2 is currently active — hand tracking running
  var handGuidanceActive = false
  /// Transition announcement has been made ("Raise your hand")
  var handGuidanceAnnounced = false

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Acquisition Validation (Auto-Exit — both modes)
  // ═══════════════════════════════════════════════════════════════════════════

  /// Backend endpoint for acquisition validation (e.g. /validate-acquisition)
  let acquisitionUrl: String?
  /// Workflow session ID passed from React Native; required by backend acquisition endpoint.
  let sessionId: String
  /// Camera-to-anchor distance that triggers acquisition polling (meters)
  let acquisitionDepthThreshold: Float = 0.40
  /// Seconds between acquisition poll requests
  let acquisitionPollInterval: TimeInterval = 2.0
  /// Max seconds of polling before falling back to manual exit
  let acquisitionTimeout: TimeInterval = 30.0
  /// Network request in flight — skip poll if true
  var isPollingAcquisition = false
  /// Timestamp when acquisition polling started (for timeout)
  var acquisitionPollStart: TimeInterval = 0
  /// Timestamp of last poll request (for rate limiting)
  var lastAcquisitionPollTime: TimeInterval = 0
  /// User has entered <40cm zone at least once this session
  var acquisitionTriggered = false
  /// 30s timeout expired — no more polling, manual exit only
  var acquisitionTimedOut = false
  /// Number of acquisition polls sent (for logging + first-failure speech)
  var acquisitionCheckCount = 0

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Progressive Re-detection
  // ═══════════════════════════════════════════════════════════════════════════

  let detectionUrl: String?
  let initialWorldMap: ARWorldMap?
  let spatialTargetWorldPosition: simd_float3?
  let spatialTargetMapName: String?
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

  // ── PROTOTYPE: place-and-hold (Reality-Composer style) ───────────────────
  // When true, the reaching pipeline is replaced by: raycast once against
  // ARKit geometry, place an anchor, then NEVER touch it. No tracker, no
  // re-detection, no refinement, no DAv2. Flip to false to restore the old
  // pipeline unchanged. See Reachingviewcontroller+placeAndHold.swift.
  var placeAndHoldPrototype = true
  // Absolute time the AR session started (set in startARSession). Used by
  // the prototype's placement deadline.
  var sessionStartTime: TimeInterval = 0
  var spatialTargetPlacementStartedAt: TimeInterval = 0
  var spatialTargetRelocalizationCueSpoken = false
  let spatialTargetPlacementTimeoutSec: TimeInterval = 18.0
  var handIsCloseEnoughInDepth = false
  /// Hand-free: lock anchor after first ARKit refinement converges.
  /// Re-detection still runs (for logging) but CANNOT move the anchor.
  var anchorLockedForHandFree = false

  // ── DAv2 parallel depth refinement (place-and-hold path) ─────────────────
  // Placement NO LONGER waits for DAv2. The anchor is placed IMMEDIATELY from
  // the fallback ladder (raycast → feature points → near default) so the box appears
  // the instant detection lands. DAv2 then runs IN PARALLEL; when it returns a
  // metric depth, the anchor is snapped to it along the original bbox ray.
  //
  // This is the fix for the "box appears a minute later" freeze: the old state
  // machine held EVERY frame until DAv2 got a scale anchor, and on a non-LiDAR
  // device that needs the user to walk around until ARKit builds planes.
  enum DAv2RefineState { case pending, done }
  var dav2RefineState: DAv2RefineState = .pending
  /// True while a DAv2 inference is in flight — prevents stacking requests.
  var dav2RequestInFlight = false
  /// Counter for throttling DAv2 "no scale anchor" log messages
  var dav2NoAnchorLogCount: Int = 0
  /// Wall-clock deadline; after this we stop retrying DAv2 and keep the
  /// fallback-ladder depth. Set at placement time.
  var dav2RefineDeadline: TimeInterval = 0
  /// How long after placement to keep retrying DAv2 before giving up.
  let dav2RefineWindowSec: TimeInterval = 45.0
  /// Placement ray captured at anchor time so a late DAv2 result can re-place
  /// the anchor at the corrected depth along the exact same bearing.
  var placementRayOrigin: simd_float3 = .zero
  var placementRayDir: simd_float3 = .zero
  var placementHorizScale: CGFloat = 1.0
  /// Place-and-hold: true after ARKit has approved a stable depth along the
  /// original placement ray. DAv2 can seed depth, but does not get to move the
  /// anchor laterally or permanently lock the target by itself.
  var placeAndHoldDepthLocked = false
  /// Place-and-hold depth refinement buffer. Unlike the legacy refinement
  /// buffer, these samples are measured only on the original placement ray,
  /// so they cannot drag the target toward the live phone reticle.
  var placeAndHoldRefinementHits: [Float] = []
  /// Default scene-distance seed when ARKit has not formed geometry yet.
  /// 1.5m is a safer non-LiDAR cold-start prior than desk-reach 0.9m because
  /// it lets the locked-ray consensus accept real mid-room evidence.
  let placeAndHoldDefaultDepth: Float = 1.5
  /// Large-jump candidates are not trusted individually, but a stable cluster
  /// means the current seed is wrong and the anchor should be rebased.
  var placeAndHoldAlternateDepthHits: [Float] = []
  let placeAndHoldRefinementMinHits = 7
  let placeAndHoldRefinementMaxHits = 12
  let placeAndHoldRefinementIQR: Float = 0.08
  let placeAndHoldRefinementHardJump: Float = 1.25
  let placeAndHoldAlternateDepthMinHits = 6
  let placeAndHoldAlternateDepthMaxHits = 14
  let placeAndHoldAlternateDepthIQR: Float = 0.18
  var placeAndHoldLastDepthSource = "none"

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - ARKit
  // ═══════════════════════════════════════════════════════════════════════════

  var sceneView: ARSCNView!
  var arFrameCount = 0
  let anchorWaitFrames = 15
  var meshReconstructionEnabled = false
  var lastFrameProcessedAt: TimeInterval = 0
  let frameProcessInterval: TimeInterval = 0.05
  /// Prevents ARFrame retention: skip new frames while visionQ is still processing
  var isProcessingFrame = false
  var anchorRefinementFrames = 0
  let anchorRefinementLimit = 600
  var refinementHits: [Float] = []
  let refinementMinHits = 5
  let refinementConvergeThreshold: Float = 0.05
  var lastRefinementAppliedDepth: Float = 0
  /// Hand-free: max allowed first refinement jump from seeded anchor depth.
  /// Prevents early wall-plane hijack before anchor is stable.
  let handFreeInitialRefineMaxJump: Float = 1.2
  /// Hand-free: after first refinement lock, per-update depth jumps above this
  /// are considered implausible and rejected as wrong-surface grabs.
  let handFreePerUpdateMaxJump: Float = 0.7

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Vision
  // ═══════════════════════════════════════════════════════════════════════════

  let handReq = VNDetectHumanHandPoseRequest()
  let visionQ = DispatchQueue(label: "reach.vision", qos: .userInitiated)
  let depthAnythingQ = DispatchQueue(label: "reach.depth", qos: .userInitiated)

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Visual Tracking (VNTrackObjectRequest)
  // ═══════════════════════════════════════════════════════════════════════════

  // Master feature flag. false → original behavior, true → tracker drives refinement.
  var trackerEnabled: Bool { return !placeAndHoldPrototype }

  var trackerSequenceHandler = VNSequenceRequestHandler()
  var activeTrackerRequest: VNTrackObjectRequest?
  var lastTrackedObservation: VNDetectedObjectObservation?
  var lastTrackedConfidence: VNConfidence = 0
  var trackingActive: Bool = false
  var consecutiveLowConfFrames: Int = 0
  let trackerLowConfThreshold: Float = 0.40
  let trackerLowConfFramesNeeded: Int = 12
  let trackerReseedCooldown: TimeInterval = 4.0
  var lastTrackerReseedTime: TimeInterval = 0
  var isTrackerReseeding: Bool = false

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Initial Bbox Refresh (with detection-frame pose)
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // The bbox passed into this VC was computed from a photo VisionCamera took
  // SECONDS before the AR session started (Qwen processing + VisionCamera
  // teardown + ARKit boot = 5–15s typical). Even when the user holds still,
  // 2° of unintended rotation over that window puts the bbox ~7 cm off the
  // object at 2 m depth — bad enough that the indicator lands on the floor
  // or back wall instead of the target.
  //
  // The fix has TWO halves:
  //
  //   A. Re-detect the object on a LIVE AR frame before initial placement,
  //      so the bbox lives in AR-camera coordinates instead of stale photo
  //      coordinates.
  //
  //   B. Save the AR camera's WORLD-SPACE TRANSFORM at the moment we capture
  //      the AR frame for detection, and use that saved transform for the
  //      unprojection in placeWorldAnchor. Otherwise the bbox (T_detect)
  //      would still be unprojected through transform(T_place), and the
  //      ~3–5 s of residual drift between request and response would put
  //      the anchor a few cm off the object on its first frame.
  //
  // After successful placement the saved transform is cleared, and ARKit
  // refinement uses live-frame transforms as before.

  enum InitialReseedStatus {
    case pending      // not yet started
    case inFlight     // request out, waiting for response
    case succeeded    // fresh bbox + saved pose available, proceed to placement
    case failed       // backend gave nothing / timed out — fall back to photo bbox
    case skipped      // no detectionUrl available — fall back to photo bbox
  }
  var initialReseedStatus: InitialReseedStatus = .pending
  var initialReseedStartTime: TimeInterval = 0
  /// Deadline for the initial reseed request — beyond this we give up
  /// and place from the photo bbox (broken-but-no-worse-than-before).
  let initialReseedTimeoutSec: TimeInterval = 6.0
  /// Wait at least this many AR frames before firing the request, so the
  /// AR camera buffer has produced something stable to send to the backend.
  let initialReseedFrameWait: Int = 2
  /// World-space camera transform AT THE MOMENT the detection AR frame was
  /// captured. Set inside requestInitialBboxFromAR. Read by placeWorldAnchor
  /// to unproject the bbox through the SAME pose that produced the image
  /// that produced the bbox. Cleared after successful placement and on
  /// any failure path so the live frame's transform is used as fallback.
  var detectionFrameCameraTransform: simd_float4x4? = nil

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
  /// Cached premium voice — mirrors iOSTtsClient.ts PREFERRED_VOICES exactly
  /// Premium (Neural TTS) > Enhanced > Compact > system default
  lazy var premiumVoice: AVSpeechSynthesisVoice? = {
    // Ordered by quality — MUST match iOSTtsClient.ts PREFERRED_VOICES list
    let candidates: [(id: String, label: String)] = [
      ("com.apple.voice.premium.en-US.Zoe",              "Zoe PREMIUM"),
      ("com.apple.voice.premium.en-US.Samantha",          "Samantha PREMIUM"),
      ("com.apple.voice.enhanced.en-US.Samantha",         "Samantha ENHANCED"),
      ("com.apple.voice.enhanced.en-US.Ava",              "Ava ENHANCED"),
      ("com.apple.voice.enhanced.en-AU.Karen",            "Karen ENHANCED"),
      ("com.apple.voice.enhanced.en-GB.Serena",           "Serena ENHANCED"),
      ("com.apple.voice.compact.en-US.Samantha",          "Samantha COMPACT"),
    ]
    for c in candidates {
      if let voice = AVSpeechSynthesisVoice(identifier: c.id) {
        NSLog("🎤 [ReachingVC] Selected voice: %@ [%@]", c.id, c.label)
        return voice
      }
    }
    NSLog("⚠️ [ReachingVC] No preferred voice found — using system default en-US")
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
  var voiceOverSpeechSuppressed = false
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
  /// If true, ARKit boots silently until JS enables guidance audio.
  var startupSilent: Bool = false
  /// Runtime gate for all AR guidance audio output.
  var guidanceAudioEnabled: Bool = true

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
       acquisitionUrl: String? = nil,
      sessionId: String? = nil,
       initialWorldMap: ARWorldMap? = nil,
       spatialTargetWorldPosition: simd_float3? = nil,
       spatialTargetMapName: String? = nil,
       mode: ReachingMode = .handFree,
      startupSilent: Bool = false,
       voiceOverEnabled: Bool = false,
       ttsRate: Float = 0.5,
       distanceUnit: String = "steps",
       onDone: @escaping ([String: Any]) -> Void) {
    self.bboxRaw      = bboxRaw
    self.objectName   = objectName
    self.backendDepth = backendDepth
    self.imageWidth   = imageWidth
    self.imageHeight  = imageHeight
    self.detectionUrl = detectionUrl
    self.initialWorldMap = initialWorldMap
    self.spatialTargetWorldPosition = spatialTargetWorldPosition
    self.spatialTargetMapName = spatialTargetMapName
    self.acquisitionUrl = acquisitionUrl
    let cleanedSessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.sessionId = cleanedSessionId.isEmpty ? UUID().uuidString : cleanedSessionId
    self.mode         = mode
    self.startupSilent = startupSilent
    self.guidanceAudioEnabled = !startupSilent
    self.voiceOverSpeechSuppressed = voiceOverEnabled
    self.ttsRate      = ttsRate
    self.distanceUnit = distanceUnit
    self.onDone       = onDone
    super.init(nibName: nil, bundle: nil)
    if mode == .withHand {
      handReq.maximumHandCount = 1
      // Phase 1 (navigation) uses the same walk-tolerant thresholds as hand-free.
      // Phase 2 (hand guidance) will use tighter thresholds locally.
      speechCooldown = 2.0
      directionStableThreshold = 8
    } else {
      // Hand-free: wider stability thresholds — user is walking, directions flicker
      speechCooldown = 2.0
      directionStableThreshold = 8
    }
        NSLog("🎯 [ReachingVC] Init — mode=%@ acquisitionUrl=%@ detectionUrl=%@ sessionId=%@",
          mode.rawValue, acquisitionUrl ?? "nil", detectionUrl ?? "nil", self.sessionId)
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

    // Keep this lightweight: the JS/native bridge prewarms DAv2 as soon as a
    // reaching-like command is heard. This is only a last-chance warmup if the
    // bridge did not get there first.
    if !Self.dav2PrewarmRequested {
      Self.dav2PrewarmRequested = true
      DispatchQueue.global(qos: .userInitiated).async {
        prewarmDepthAnythingV2Model()
      }
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
      guard let self = self, !self.hasCompleted else { return }
      self.startAR()
      self.running = true
      if self.guidanceAudioEnabled {
        if self.mode == .handFree {
          self.say("Guiding to \(self.objectName). Point phone toward it. Tap anywhere when you have it.")
        } else {
          self.say("Guiding to \(self.objectName). Point phone toward it. I'll tell you when to raise your hand.")
        }
      } else {
        NSLog("🔇 [ReachingVC] Silent bootstrap active — delaying AR guidance audio")
      }
    }
  }

  func enableGuidanceAudio() {
    if guidanceAudioEnabled {
      return
    }
    guidanceAudioEnabled = true
    NSLog("🔊 [ReachingVC] Guidance audio enabled by JS handoff")
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
    var bw = bboxNormalized[2] - bboxNormalized[0]
    var bh = bboxNormalized[3] - bboxNormalized[1]
    if bw > 0, bh > 0 {
      let minW: CGFloat = 0.05, minH: CGFloat = 0.05
      let maxW: CGFloat = 0.20, maxH: CGFloat = 0.28
      var scale: CGFloat = 1.0
      if bw < minW || bh < minH {
        scale = max(minW / bw, minH / bh)
      } else if bw > maxW || bh > maxH {
        scale = min(maxW / bw, maxH / bh)
      }
      if abs(scale - 1.0) > 0.001 {
        let cx = (bboxNormalized[0] + bboxNormalized[2]) * 0.5
        let cy = (bboxNormalized[1] + bboxNormalized[3]) * 0.5
        let newW = bw * scale
        let newH = bh * scale
        bboxNormalized = [cx - newW * 0.5, cy - newH * 0.5, cx + newW * 0.5, cy + newH * 0.5]
        bboxNormalized = bboxNormalized.map { min(max($0, 0), 1) }
        bw = bboxNormalized[2] - bboxNormalized[0]
        bh = bboxNormalized[3] - bboxNormalized[1]
        NSLog("⚖️ [ReachingVC] Bbox size clamped to %.3f×%.3f (scale=%.2f)", bw, bh, scale)
      }
    }
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
                     "hasLiDAR": self.hasLiDAR,
                     "acquisitionChecks": self.acquisitionCheckCount,
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
                     "hasLiDAR": self.hasLiDAR,
                     "acquisitionChecks": self.acquisitionCheckCount,
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
    // Reset acquisition polling state
    isPollingAcquisition = false
    acquisitionTriggered = false
    // Reset with-hand phase state
    handGuidanceActive = false
    handGuidanceAnnounced = false
    // Reset tracker state — fresh handler on next session
    cancelTracker()
    trackingActive = false
    activeTrackerRequest = nil
    lastTrackedObservation = nil
    consecutiveLowConfFrames = 0
    isTrackerReseeding = false
    trackerSequenceHandler = VNSequenceRequestHandler()
    // Reset initial bbox refresh state
    initialReseedStatus = .pending
    initialReseedStartTime = 0
    detectionFrameCameraTransform = nil
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
    directionLabel.text = "Point camera…"
    directionLabel.font = .systemFont(ofSize: 24, weight: .bold)
    directionLabel.textColor = .white; directionLabel.textAlignment = .center
    directionLabel.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.contentView.addSubview(directionLabel)

    depthHintLabel = UILabel()
    depthHintLabel.text = "Move closer — tap anywhere when done"
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

    view.accessibilityLabel = "Reaching guidance for \(objectName). Point camera toward object. Tap anywhere to confirm."

    // ── VoiceOver Configuration ──────────────────────────────────────────────
    // Make the objectNameLabel (which gets initial VoiceOver focus) actionable.
    // UILabel doesn't respond to VoiceOver double-tap by default — we need
    // userInteractionEnabled + a tap gesture so VoiceOver's synthetic tap fires.
    objectNameLabel.isAccessibilityElement = true
    objectNameLabel.accessibilityLabel = "Guiding to \(objectName). Point camera toward it. Double tap to confirm."
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
