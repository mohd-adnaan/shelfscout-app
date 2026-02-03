//
//  ReachingViewController.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//
//
//  ReachingViewController.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//

import UIKit
import SceneKit
import ARKit
import Vision
import AVFoundation

// MARK: - Delegate Protocol
protocol ReachingViewControllerDelegate: AnyObject {
    func didLockTarget()
    func didReachTarget()
    func didLoseTarget()
    func didEncounterError(_ error: Error)
}

// MARK: - ReachingViewController
class ReachingViewController: UIViewController, ARSCNViewDelegate, ARSessionDelegate {
    
    // MARK: - Tracking State
    enum TrackingState {
        case detection
        case tracking
        case reached
        case stopped
    }
    
    // MARK: - UI Components
    private var sceneView: ARSCNView!
    private var trackingView: TrackingImageView!
    private var closeButton: UIButton!
    private var statusLabel: UILabel!
    
    // MARK: - Delegate
    weak var delegate: ReachingViewControllerDelegate?
    
    // MARK: - Configuration (from Qwen backend)
    private var objectName: String = ""
    private var initialBbox: CGRect = .zero
    
    // MARK: - Tracking State
    private var trackingState: TrackingState = .detection
    private var isTracking: Bool = true
    
    // MARK: - Vision & Position
    private var currentPixelBuffer: CVPixelBuffer?
    private var targetPositionModel: CGPoint = .zero
    private var targetPositionProjection: CGPoint = .zero
    private var currentTargetWidth: CGFloat = 0
    private var currentTargetHeight: CGFloat = 0
    private var referencePoint: CGPoint = .zero
    private var focalLength: Float = 0.0
    
    // MARK: - Distance Tracking
    private var distanceTargetFromDimensions: Float = 0
    private var distanceTargetFromAnchor: Float = 0
    private var previousDistance: Float = 0
    
    // MARK: - Detection Flags
    private var objectInView: Bool = false
    private var isHandDetected: Bool = false
    private var handPosition: CGPoint?
    private var handSize: CGFloat = 0
    
    // MARK: - Processors
    private var feedbackProcessor: FeedbackProcessor!
    private var visionProcessor: VisionTrackerProcessor!
    
    // MARK: - Queues
    private let handDetectionQueue = DispatchQueue(label: "com.shelfscout.handdetection", qos: .userInitiated)
    private let positionCheckQueue = DispatchQueue(label: "com.shelfscout.positioncheck", qos: .userInitiated)
    
    // MARK: - Timing
    private var callHandInterval: TimeInterval = 1.0
    private let callHandIntervalIfDetected: TimeInterval = 0.2
    
    // MARK: - 3D Tracking
    private var targetNode: SCNNode?
    
    // MARK: - Reaching Threshold (in meters)
    private let reachingThreshold: Float = 0.15 // 15cm
    
    // MARK: - Lifecycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupGestures()
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Notify React Native to pause camera
        NotificationCenter.default.post(
            name: NSNotification.Name("ReachingModeStarted"),
            object: nil
        )
        
        // Initialize processors
        initializeProcessors()
        
        // Start ARKit session
        startARSession()
        
        // Start tracking loops
        startTracking()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // Stop tracking
        stopTracking()
        
        // Pause ARKit
        sceneView.session.pause()
        
        // Notify React Native to resume camera
        NotificationCenter.default.post(
            name: NSNotification.Name("ReachingModeEnded"),
            object: nil
        )
    }
    
    // MARK: - Configuration
    
    func configure(objectName: String, initialBbox: CGRect) {
        self.objectName = objectName
        self.initialBbox = initialBbox
        
        // Set initial target position from backend bbox (normalized 0-1)
        let centerX = initialBbox.midX
        let centerY = initialBbox.midY
        self.targetPositionModel = CGPoint(x: centerX, y: centerY)
        self.currentTargetWidth = initialBbox.width
        self.currentTargetHeight = initialBbox.height
        
        print("📍 [Reaching] Configured for object: \(objectName)")
        print("📍 [Reaching] Initial bbox: \(initialBbox)")
        print("📍 [Reaching] Target center: \(targetPositionModel)")
    }
    
    // MARK: - UI Setup
    
    private func setupUI() {
        view.backgroundColor = .black
        
        // ARSCNView
        sceneView = ARSCNView(frame: view.bounds)
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.showsStatistics = false
        view.addSubview(sceneView)
        
        // Tracking overlay view
        trackingView = TrackingImageView()
        trackingView.frame = view.bounds
        trackingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        trackingView.backgroundColor = .clear
        trackingView.isUserInteractionEnabled = false
        view.addSubview(trackingView)
        
        // Close button (accessibility)
        closeButton = UIButton(type: .system)
        closeButton.setTitle("✕ Cancel", for: .normal)
        closeButton.titleLabel?.font = .boldSystemFont(ofSize: 18)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        closeButton.layer.cornerRadius = 8
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)
        closeButton.accessibilityLabel = "Cancel reaching mode"
        closeButton.accessibilityHint = "Double tap to stop reaching and return to main screen"
        view.addSubview(closeButton)
        
        // Status label
        statusLabel = UILabel()
        statusLabel.text = "Guiding to: \(objectName)"
        statusLabel.textColor = .white
        statusLabel.font = .boldSystemFont(ofSize: 20)
        statusLabel.textAlignment = .center
        statusLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.accessibilityTraits = .updatesFrequently
        view.addSubview(statusLabel)
        
        // Constraints
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 100),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -16),
            statusLabel.heightAnchor.constraint(equalToConstant: 44),
        ])
    }
    
    private func setupGestures() {
        // Tap to announce distance
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        view.addGestureRecognizer(tapGesture)
        
        // Long press to cancel
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        longPressGesture.minimumPressDuration = 1.0
        view.addGestureRecognizer(longPressGesture)
    }
    
    // MARK: - Processors Initialization
    
    private func initializeProcessors() {
        // FeedbackProcessor for audio guidance
        feedbackProcessor = FeedbackProcessor()
        feedbackProcessor.feedbackUsed = "Sonification"
        feedbackProcessor.verticalType = "Steps"
        feedbackProcessor.oralFeedbackEnabled = true
        feedbackProcessor.targetWidth = currentTargetWidth * view.bounds.width
        feedbackProcessor.targetHeight = currentTargetHeight * view.bounds.height
        
        // VisionProcessor for hand detection only (no object detection - Qwen handles that)
        visionProcessor = VisionTrackerProcessor(modelType: "QRCode") // Model type doesn't matter - we only use hand detection
        
        // Announce start
        feedbackProcessor.playIndication(sentence: "Guiding you to the \(objectName). Follow the audio cues.")
    }
    
    // MARK: - AR Session
    
    private func startARSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [] // No plane detection needed
        sceneView.session.run(configuration)
    }
    
    // MARK: - Tracking Control
    
    private func startTracking() {
        isTracking = true
        trackingState = .detection
        
        // Set initial target position in tracking view
        trackingView.targetPoint = targetPositionModel
        trackingView.targetWidth = currentTargetWidth * view.bounds.width
        trackingView.targetHeight = currentTargetHeight * view.bounds.height
        
        // Start hand detection loop
        startHandTracking()
        
        // Start position checking loop
        startPositionChecking()
        
        // Start audio feedback
        feedbackProcessor.startBips()
        
        // Lock target after brief delay (allows AR to stabilize)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.lockTarget()
        }
    }
    
    private func stopTracking() {
        isTracking = false
        trackingState = .stopped
        feedbackProcessor.resetAudio()
    }
    
    // MARK: - Target Locking
    
    private func lockTarget() {
        guard trackingState == .detection else { return }
        
        // Create 3D anchor at estimated position
        // Use the center of the screen as depth reference since we have bbox from Qwen
        let screenCenter = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        
        // Estimate depth based on bbox size (larger bbox = closer object)
        let avgSize = (currentTargetWidth + currentTargetHeight) / 2
        let estimatedDepth: Float = Float(1.0 / max(avgSize, 0.1)) * 0.5 // Rough estimate
        
        // Create 3D position
        if let query = sceneView.raycastQuery(from: screenCenter, allowing: .estimatedPlane, alignment: .any),
           let result = sceneView.session.raycast(query).first {
            // Use raycast result
            create3DAnchor(at: result.worldTransform)
        } else {
            // Fallback: create anchor at estimated position in front of camera
            guard let frame = sceneView.session.currentFrame else { return }
            var translation = matrix_identity_float4x4
            translation.columns.3.z = -estimatedDepth // In front of camera
            let worldTransform = simd_mul(frame.camera.transform, translation)
            create3DAnchor(at: worldTransform)
        }
        
        trackingState = .tracking
        feedbackProcessor.foundTarget = true
        
        delegate?.didLockTarget()
        feedbackProcessor.playIndication(sentence: "Target locked. Move your hand toward the beeps.")
        
        print("🎯 [Reaching] Target locked at estimated depth: \(estimatedDepth)m")
    }
    
    private func create3DAnchor(at transform: simd_float4x4) {
        // Create invisible anchor node (visual feedback optional)
        let sphere = SCNSphere(radius: 0.02)
        sphere.firstMaterial?.diffuse.contents = UIColor.green.withAlphaComponent(0.5)
        
        targetNode = SCNNode(geometry: sphere)
        targetNode?.simdWorldTransform = transform
        targetNode?.name = "reachingTarget"
        
        sceneView.scene.rootNode.addChildNode(targetNode!)
        
        // Store initial distance
        if let cameraTransform = sceneView.session.currentFrame?.camera.transform {
            let cameraPosition = SCNVector3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            let targetPosition = SCNVector3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
            distanceTargetFromAnchor = distance(from: cameraPosition, to: targetPosition)
            previousDistance = distanceTargetFromAnchor
        }
    }
    
    private func distance(from: SCNVector3, to: SCNVector3) -> Float {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let dz = to.z - from.z
        return sqrt(dx*dx + dy*dy + dz*dz)
    }
    
    // MARK: - Hand Tracking Loop
    
    private func startHandTracking() {
        handDetectionQueue.async { [weak self] in
            while self?.isTracking == true {
                guard let self = self,
                      let frame = self.currentPixelBuffer else {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                
                do {
                    let (handPos, detected, size) = try self.visionProcessor.detectHand(
                        image: frame,
                        imageWidth: CGFloat(CVPixelBufferGetWidth(frame)),
                        imageHeight: CGFloat(CVPixelBufferGetHeight(frame))
                    )
                    
                    DispatchQueue.main.async {
                        if let handPos = handPos, detected {
                            // Hand detected
                            if self.callHandInterval == 1.0 {
                                self.feedbackProcessor.playIndication(sentence: "Hand detected")
                            }
                            self.callHandInterval = self.callHandIntervalIfDetected
                            
                            self.isHandDetected = true
                            self.handPosition = handPos
                            self.handSize = size
                            
                            // Update tracking view
                            self.trackingView.handPoint = handPos
                            self.referencePoint = self.trackingView.scale(cornerPoint: handPos)
                            
                            // Update feedback processor
                            if size > self.feedbackProcessor.maxHandSize {
                                self.feedbackProcessor.maxHandSize = size
                            }
                            self.feedbackProcessor.handSize = size
                            self.feedbackProcessor.handDetected = true
                            
                            // Update guidance
                            self.updateGuidance()
                            
                        } else {
                            // Hand not detected
                            if self.callHandInterval == self.callHandIntervalIfDetected {
                                self.feedbackProcessor.playIndication(sentence: "Use frame center")
                            }
                            
                            self.callHandInterval = 1.0
                            self.isHandDetected = false
                            self.trackingView.handPoint = .zero
                            self.feedbackProcessor.handDetected = false
                            
                            // Use frame center as reference
                            self.referencePoint = CGPoint(x: self.view.bounds.midX, y: self.view.bounds.midY)
                            self.updateGuidance()
                        }
                    }
                    
                } catch {
                    print("❌ Hand detection error: \(error)")
                }
                
                Thread.sleep(forTimeInterval: self.callHandInterval)
            }
        }
    }
    
    // MARK: - Position Checking Loop
    
    private func startPositionChecking() {
        positionCheckQueue.async { [weak self] in
            while self?.isTracking == true {
                guard let self = self,
                      self.trackingState == .tracking,
                      let targetNode = self.targetNode,
                      let frame = self.sceneView.session.currentFrame else {
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
                
                // Get current camera position
                let cameraPosition = SCNVector3(
                    frame.camera.transform.columns.3.x,
                    frame.camera.transform.columns.3.y,
                    frame.camera.transform.columns.3.z
                )
                
                // Get target position
                let targetPosition = targetNode.worldPosition
                
                // Calculate distance
                let currentDistance = self.distance(from: cameraPosition, to: targetPosition)
                
                DispatchQueue.main.async {
                    self.distanceTargetFromDimensions = currentDistance
                    
                    // Project target to screen
                    let projected = self.sceneView.projectPoint(targetPosition)
                    self.targetPositionProjection = CGPoint(x: CGFloat(projected.x), y: CGFloat(projected.y))
                    
                    // Update tracking view
                    self.trackingView.targetPoint = self.targetPositionProjection
                    self.trackingView.setNeedsDisplay()
                    
                    // Check if reached
                    if currentDistance < self.reachingThreshold {
                        self.handleTargetReached()
                    }
                    
                    // Check if hand is close to target (2D proximity)
                    if self.isHandDetected, let handPos = self.handPosition {
                        let scaledHand = self.trackingView.scale(cornerPoint: handPos)
                        let dx = abs(scaledHand.x - self.targetPositionProjection.x)
                        let dy = abs(scaledHand.y - self.targetPositionProjection.y)
                        
                        let targetW = self.currentTargetWidth * self.view.bounds.width
                        let targetH = self.currentTargetHeight * self.view.bounds.height
                        
                        if dx < targetW / 2 && dy < targetH / 2 {
                            // Hand is over target - check depth
                            if currentDistance < self.reachingThreshold * 2 {
                                self.handleTargetReached()
                            }
                        }
                    }
                    
                    self.previousDistance = currentDistance
                }
                
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }
    
    // MARK: - Guidance Update
    
    private func updateGuidance() {
        guard trackingState == .tracking else { return }
        
        // Scale target position to screen coordinates
        let scaledTarget: CGPoint
        if targetPositionProjection != .zero {
            scaledTarget = targetPositionProjection
        } else {
            scaledTarget = trackingView.scale(cornerPoint: targetPositionModel)
        }
        
        // Update feedback
        feedbackProcessor.updateParameters(
            referencePoint: referencePoint,
            objectLocation: scaledTarget,
            depth: distanceTargetFromDimensions
        )
        
        // Update indication message
        let message = feedbackProcessor.assistUser(
            referencePoint: referencePoint,
            objectLocation: scaledTarget
        )
        trackingView.indicationMessage = message
        trackingView.setNeedsDisplay()
        
        // Update status label
        let distanceCm = Int(distanceTargetFromDimensions * 100)
        statusLabel.text = "\(objectName): \(distanceCm)cm - \(message)"
    }
    
    // MARK: - Target Reached
    
    private func handleTargetReached() {
        guard trackingState == .tracking else { return }
        
        trackingState = .reached
        isTracking = false
        
        // Success feedback
        feedbackProcessor.playIndication(sentence: "You have reached the \(objectName)!")
        feedbackProcessor.triggerHapticFeedback()
        
        // Visual feedback
        UIView.animate(withDuration: 0.3) {
            self.view.backgroundColor = UIColor.green.withAlphaComponent(0.3)
        }
        
        // Notify delegate
        delegate?.didReachTarget()
        
        // Auto dismiss after delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismiss(animated: true)
        }
    }
    
    // MARK: - Gesture Handlers
    
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // Announce current distance
        feedbackProcessor.indicateDistanceFromTarget(depth: distanceTargetFromDimensions)
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            feedbackProcessor.playIndication(sentence: "Canceling reaching mode")
            
            delegate?.didLoseTarget()
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.dismiss(animated: true)
            }
        }
    }
    
    @objc private func handleClose() {
        feedbackProcessor.playIndication(sentence: "Canceling")
        delegate?.didLoseTarget()
        dismiss(animated: true)
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        currentPixelBuffer = frame.capturedImage
        
        // Update focal length
        focalLength = frame.camera.intrinsics[0][0]
        
        // Update tracking view pixel size
        trackingView.CVpixelSize = CGSize(
            width: CGFloat(CVPixelBufferGetWidth(frame.capturedImage)),
            height: CGFloat(CVPixelBufferGetHeight(frame.capturedImage))
        )
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        print("❌ ARSession error: \(error)")
        delegate?.didEncounterError(error)
        
        feedbackProcessor.playIndication(sentence: "AR tracking failed. Please try again.")
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.dismiss(animated: true)
        }
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        feedbackProcessor.playIndication(sentence: "Tracking interrupted")
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        feedbackProcessor.playIndication(sentence: "Tracking resumed")
        startARSession()
    }
}
