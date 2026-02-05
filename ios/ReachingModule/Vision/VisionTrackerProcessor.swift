//
//  VisionTrackerProcessor.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//

import AVFoundation
import UIKit
import Vision

enum VisionTrackerProcessorError: Error {
    case readerInitializationFailed
    case firstFrameReadFailed
    case detectionFailed
    case objectTrackingFailed
    case rectangleDetectionFailed
}

protocol VisionTrackerProcessorDelegate: class {
    func displayFrame(_ targetPoint: CGPoint?)
}

class VisionTrackerProcessor {
    
    var trackingLevel = VNRequestTrackingLevel.accurate
    weak var delegate: VisionTrackerProcessorDelegate?
    var centerDetectedObservation: CGPoint = CGPoint.zero // Keep this updated to indicate the center of our detected observation
    var centerDetectionActive: Bool = false // Indicates when detected observation has been updated initially
    
    // Declare initial observations
    private var inputObservations = [UUID: VNDetectedObjectObservation]()
    private var requestHandler: VNSequenceRequestHandler!
    private var detectionFailed = false
    private var trackingFailedForAtLeastOneObject = false
    private var didInitialize = false
    
    var objectToDetect: String = ""
    private var handPoseRequest = VNDetectHumanHandPoseRequest()
        
    var objectDetectionModel: VNCoreMLModel!
    var orientation: CGImagePropertyOrientation? = .up
    var detectedObject: VNDetectedObjectObservation?

    init(modelType: String) {
        handPoseRequest.maximumHandCount = 1

        switch modelType {
        case "QRCode":
            do {
                let modelURL = Bundle.main.url(forResource: "QRcodeDetector", withExtension: "mlmodelc")!
                objectDetectionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            } catch {
                // Handle the error if needed
                print("Error initializing YOLOv8n model: \(error)")
            }
        case "Groceries":
            do {
                let modelURL = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc")!
                objectDetectionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            } catch {
                // Handle the error if needed
                print("Error initializing YOLOv8n model: \(error)")
            }
        default:
            // Default to some other model if the input string doesn't match expected cases
            do {
                let modelURL = Bundle.main.url(forResource: "QRCodeDetector", withExtension: "mlmodelc")!
                objectDetectionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            } catch {
                // Handle the error if needed
                print("Error initializing YOLOv8n model: \(error)")
            }
        }
    }
    
    func detectObject(image: CVPixelBuffer?, minimumConfidence: Float) throws -> VNDetectedObjectObservation? {
        
        if let currentBuffer = image, let orientation = self.orientation   {
            
            let requestHandler = VNImageRequestHandler(cvPixelBuffer: currentBuffer, orientation: orientation)
            do {
                try requestHandler.perform([self.detectionRequest])
            } catch {
                print("Error: Vision request failed with error \"\(error)\"")
            }
        } else {
            self.detectedObject = nil
        }
        
        return self.detectedObject
    }
    
    // Vision detection request and model
    /// - Tag: DetectionRequest
    private lazy var detectionRequest: VNCoreMLRequest = {
        do {
            let request = VNCoreMLRequest(model: objectDetectionModel, completionHandler: { [weak self] request, error in
                self?.processDetections(for: request, error: error)
            })
            
            // Crop input images to square area at center, matching the way the ML model was trained.
            //request.imageCropAndScaleOption = .centerCrop
            
            return request
        } catch {
            fatalError("Failed to create Vision ML request: \(error)")
        }
    }()
    
    // Handle completion of the Vision request and choose results to display.
    /// - Tag: ProcessDetections
    func processDetections(for request: VNRequest, error: Error?) {
        guard let results = request.results else {
            print("Unable to detect objects.\n\(error?.localizedDescription ?? "Unknown error")")
            return
        }
        
        let detections = results as! [VNRecognizedObjectObservation]
        var maxConfidence: Float = 0.0
        var isObjectDetected: Bool = false
        
        for detection in detections {
            for label in detection.labels {
                if label.identifier == self.objectToDetect && label.confidence > 0.3 && label.confidence > maxConfidence {
                    maxConfidence = label.confidence
                    isObjectDetected = true
                    self.detectedObject = detection
                }
            }
        }
        
        if !isObjectDetected {
            self.detectedObject = nil
        }
    }
    
    func detectHand(image: CVPixelBuffer, imageWidth: CGFloat, imageHeight: CGFloat) throws -> (CGPoint?, Bool, CGFloat) {
        
        let request = VNDetectHumanHandPoseRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .left, options: [:])
        
        var handDetected: Bool = false
        var handSize = 0.0
        
        try handler.perform([request])
        
        // Continue only when a hand was detected in the frame.
        // Since we set the maximumHandCount property of the request to 1, there will be at most one observation.
        guard let observation = request.results?.first as? VNHumanHandPoseObservation else {
            //print("No hand detected")
            return (nil, handDetected, handSize)
        }
        
        // Get points for thumb and index finger.
        let thumbPoints = try observation.recognizedPoints(.thumb)
        let indexFingerPoints = try observation.recognizedPoints(.indexFinger)
        
        //Retrieve the middle finger tip point and the wrist to have an idea of the size of the hand
        let wristPoint = try observation.recognizedPoint(.wrist)
        let middleFingerPoints = try observation.recognizedPoints(.middleFinger)
       
        // Check if both points are available
        guard let middleTipPoint = middleFingerPoints[.middleTip], let middleBasePoint = middleFingerPoints[.middlePIP] else {
            print("Thumb or index finger tip not found")
            return (nil, handDetected, handSize)
        }
        
        // Look for tip points.
        guard let thumbTipPoint = thumbPoints[.thumbTip], let indexTipPoint = indexFingerPoints[.indexTip] else {
            print("Thumb or index finger tip not found")
            return (nil, handDetected, handSize)
        }
        
        // Ignore low confidence points.
        guard thumbTipPoint.confidence > 0.3 && indexTipPoint.confidence > 0.3 else {
            print("Low confidence in thumb or index finger tip")
            return (nil, handDetected, handSize)
        }
        
        handSize = distanceBetween(wristPoint.location, middleTipPoint.location, imageWidth: imageWidth, imageHeight: imageHeight)
        let sizeMiddle = distanceBetween(middleTipPoint.location, middleBasePoint.location, imageWidth: imageWidth, imageHeight: imageHeight)
        
        // Convert points from Vision coordinates to AVFoundation coordinates.
        //let thumbTip = CGPoint(x: thumbTipPoint.location.x, y: 1 - thumbTipPoint.location.y)
        handDetected = true
        let indexTip = CGPoint(x: indexTipPoint.location.x, y: indexTipPoint.location.y)
        
        return (indexTip, handDetected, handSize)
    }
    
    // Calculate the distance between two points using Euclidean distance formula
    func distanceBetween(_ point1: CGPoint, _ point2: CGPoint, imageWidth: CGFloat, imageHeight: CGFloat) -> CGFloat {
        let deltaX = (point2.x - point1.x) * imageWidth
        let deltaY = (point2.y - point1.y) * imageHeight
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }
    
    func calculateDetectedObservationCenter(_ rect: CGRect) {
        centerDetectionActive = true
        centerDetectedObservation = CGPoint(x: rect.midX, y: rect.midY)
    }
    
    // MARK: Reset initial conditions
    func reset() {
        didInitialize = false
        centerDetectionActive = false
    }
} 
