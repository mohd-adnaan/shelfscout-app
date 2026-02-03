//
//  FeedbackProcessor.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//

import Foundation
import AVFoundation
import UIKit

class FeedbackProcessor {
    
    // MARK: - Properties
    var frameWidth: CGFloat = 0.0
    var frameHeight: CGFloat = 0.0
    
    var centeredAudioPlayer: AVAudioPlayer!
    var uncenteredAudioPlayer: AVAudioPlayer!
    //var targetLostAudioPlayer: AVAudioPlayer!
    
    var engine = AVAudioEngine()
    var playerNode = AVAudioPlayerNode()
    var pitchEffect = AVAudioUnitTimePitch()
    var buffer: AVAudioPCMBuffer? // Define buffer as a class property
    
    var defaultInterBipTime: TimeInterval = 1.0
    var minimumInterBipTime: TimeInterval = 0.1
    var interBipTime: TimeInterval = 1.0
    var foundTarget: Bool = false
    var handDetected: Bool = false
    var isCentered: Bool = false
    
    var targetHeight = 0.0
    var targetWidth = 0.0
    var handSize: CGFloat = 0.0
    var maxHandSize: CGFloat = 0.0
    
    
    //Relation function slopes
    var feedbackUsed: String = ""
    
    //Bracelet
    var braceletState: String = ""
    
    //Sonification
    var verticalType: String = ""
    var verticalSlope = 1.0
    var depthSlope = 1.0
    var oralFeedbackEnabled: Bool = false
    
    private let speechSynthesizer = AVSpeechSynthesizer()
    var indicationMessage: String = "Look around for a target object"
    var directionMessage: String = "Centered!"
    var speechUtterance = AVSpeechUtterance(string: "Look around for a target object")
    
    // MARK: - Initialization
    
    init() {
        // Initialize audio player or setup audio processing components
        setupAudio()
        indicateDirectionOrally()
    }
    
    // MARK: - Audio File Loading
    
    private func setupAudio(){
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Error setting up audio session: \(error.localizedDescription)")
        }
        
        //Load the sound files
        guard let soundURL = Bundle.main.url(forResource: "bip", withExtension: "wav") else {
            fatalError("Sound file not found: bip.wav")
        }
        
        guard let centeredURL = Bundle.main.url(forResource: "centered_sound", withExtension: "wav") else {
            fatalError("Sound file not found: centered_sound.wav")
        }
        
        guard let uncenteredURL = Bundle.main.url(forResource: "uncentered_sound", withExtension: "wav") else {
            fatalError("Sound file not found: uncentered_sound.wav")
        }
        
//        guard let targetLostURL = Bundle.main.url(forResource: "targetLost_sound", withExtension: "wav") else {
//            fatalError("Sound file not found: targetLost_sound.wav")
//        }
        
        do {
            // Load the audio file
            let audioFile = try AVAudioFile(forReading: soundURL)
            let audioFormat = audioFile.processingFormat
            let audioFrameCount = UInt32(audioFile.length)
            buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: audioFrameCount)
            try audioFile.read(into: buffer!)
            
            // Set up AVAudioEngine
            engine.attach(playerNode)
            engine.attach(pitchEffect)
            engine.connect(playerNode, to: pitchEffect, format: nil)
            engine.connect(pitchEffect, to: engine.mainMixerNode, format: nil)
            engine.prepare()
            try engine.start()
            
            // Schedule the buffer to be played
            playerNode.scheduleBuffer(buffer!, at: nil, options: .interrupts, completionHandler: nil)
                
            centeredAudioPlayer = try AVAudioPlayer(contentsOf: centeredURL)
            centeredAudioPlayer?.prepareToPlay()
            
            uncenteredAudioPlayer = try AVAudioPlayer(contentsOf: uncenteredURL)
            uncenteredAudioPlayer?.prepareToPlay()
            
//            targetLostAudioPlayer = try AVAudioPlayer(contentsOf: targetLostURL)
//            targetLostAudioPlayer?.prepareToPlay()
            
        } catch {
            print("Error setting up audio player: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Audio Playback
    
    func startBips() {
        DispatchQueue.global().async {
            while true {
                if self.foundTarget {
                    self.playerNode.play()
                    self.playerNode.scheduleBuffer(self.buffer!, at: nil, options: .interrupts, completionHandler: nil)
                }
                print("Sleep \(self.interBipTime)")
                Thread.sleep(forTimeInterval: self.interBipTime)
                
            }
        }
    }
    
    func playSound(audioPlayer: AVAudioPlayer) {
        audioPlayer.play()
    }
    
    func updateParameters(referencePoint: CGPoint?, objectLocation: CGPoint, depth: Float) {
        guard let referencePoint = referencePoint else {
            print("Error: referencePoint is nil")
            return
        }
        
        if objectLocation != CGPoint.zero {
            
            let verticalCenterDist = targetHeight/2
            let horizontalCenterDist = targetWidth/2
            
            let deltaX = referencePoint.x - objectLocation.x
            let deltaY = referencePoint.y - objectLocation.y
            
            if feedbackUsed == "Sonification" {
                let maxDist = CGFloat(960) // to be chaaaaaaaaaaaaaaaaaaaaaaaged
                let maxPitch = 2000.0
                
                // We set the region of interest as a circle around the frame center
                let factor = verticalSlope
                
                // VERTICAL AXIS
                    
                if self.verticalType == "Steps" {
                    
                    if abs(deltaY) < verticalCenterDist {
                        pitchEffect.pitch = Float(0)
                    } else {
                        pitchEffect.pitch = Float(factor * (deltaY / abs(deltaY)) * 2000)
                    }
                    
                } else if self.verticalType == "Parabol" {
                    
                    let slope = maxPitch/(maxDist * referencePoint.y)
                    pitchEffect.pitch = Float(factor * slope * (deltaY * deltaY))
                    
                } else if self.verticalType == "Cubic" {
                    
                    let slope = 32/(verticalCenterDist * verticalCenterDist * verticalCenterDist)
                    let newPitch = factor * slope * (deltaY * deltaY * deltaY)
                    if abs(newPitch) < maxPitch {
                        pitchEffect.pitch = Float(newPitch)
                    } else {
                        pitchEffect.pitch = Float(maxPitch) * Float(newPitch)/abs(Float(newPitch))
                    }
                } else {
                    print("Invalid selection of vertical function type")
                }
                
                //HORIZONTAL AXIS
                
                if abs(deltaX) < horizontalCenterDist {
                    self.playerNode.pan = 0
                } else {
                    if objectLocation.x > referencePoint.x {
                        self.playerNode.pan = 1.0
                    } else if objectLocation.x < referencePoint.x{
                        self.playerNode.pan = -1.0
                    } else {
                        print("Invalid object location values")
                    }
                }
            } else if self.feedbackUsed == "Bracelet" {
                
                let degrees = computeAngle(point1: objectLocation, point2: referencePoint)
                
                if abs(deltaX) < horizontalCenterDist && abs(deltaY) < verticalCenterDist {
                    self.braceletState = "0"
                } else if abs(deltaX) > horizontalCenterDist && deltaX > 0 {
                    self.braceletState = "1"
                } else if abs(deltaX) < horizontalCenterDist && deltaY > 0 {
                    self.braceletState = "3"
                } else if abs(deltaX) > horizontalCenterDist && deltaX < 0 {
                    self.braceletState = "5"
                } else if abs(deltaX) < horizontalCenterDist && deltaY < 0 {
                    self.braceletState = "7"
                } else {
                    //self.braceletState = self.determineState(for: degrees)
                }
                
                print("Bracelet state: \(self.braceletState)")
                
                //print("Degrees between the point: \(degrees), corresponding state is: \(self.braceletState)")
            }
            
            //Compute the interbip frequency describing the depth
            if depth != 0 {
                
                let factor = depthSlope
                
                let interBipOffset = self.minimumInterBipTime
                let interBipSlope = self.defaultInterBipTime - interBipOffset
                
                print("Interbip function f = \(interBipSlope)x + \(interBipOffset)")
                
                let newInterBipTime = factor * interBipSlope * Double(depth) + interBipOffset
                
                //Adjust the frequency in function of the hand size seen on the camera
                if self.handDetected {
                    if self.maxHandSize > 0 {
                        
                        //After calibration -> Introduce a calibration before using the app
                        let minHandSize: CGFloat =  300 //pixels
                        let reachingDistance = 0.5 //cm
                        let minDist = Double(depth) - reachingDistance
                        
                        let handSlope = (Double(depth) - minDist)/(self.maxHandSize - minHandSize)
                        let handOffset = minDist - handSlope * minHandSize
                        
                        self.interBipTime = handSlope * self.handSize + handOffset
                        if self.interBipTime < self.minimumInterBipTime {
                            self.interBipTime = self.minimumInterBipTime
                        }
                        
                        //Classique way
//                        let handOffset = self.minimumInterBipTime
//                        let handSlope = (newInterBipTime - handOffset)/self.maxHandSize
//                        self.interBipTime = handSlope*self.handSize + handOffset
                    }
                    
                } else {
                    self.interBipTime = newInterBipTime
                }
            }
            
        } else {
            self.interBipTime = 1.0
        }
        
        //Ensure that we are not below the minimum value
        self.interBipTime = self.interBipTime < self.minimumInterBipTime ? self.minimumInterBipTime : self.interBipTime
    
    }
    
    // MARK: - Bracelet function
    
    func computeAngle(point1: CGPoint, point2: CGPoint) -> Double {
        let deltaY = point2.y - point1.y
        let deltaX = point2.x - point1.x
        let radians = atan2(deltaY, deltaX)
        var degrees = radians * 180 / Double.pi
        if degrees < 0 {
            degrees += 360
        }
        return degrees
    }
    
    func determineState(for angle: Double) -> String {
        switch angle {
        case let x where (x >= 0 && x < 22.5) || (x > 337.5 && x <= 360):
            return "1"
        case let x where x >= 22.5 && x < 67.5:
            return "2"
        case let x where x >= 67.5 && x < 112.5:
            return "3"
        case let x where x >= 112.5 && x < 157.5:
            return "4"
        case let x where x >= 157.5 && x < 202.5:
            return "5"
        case let x where x >= 202.5 && x < 247.5:
            return "6"
        case let x where x >= 247.5 && x < 292.5:
            return "7"
        case let x where x >= 292.5 && x <= 337.5:
            return "8"
        default:
            fatalError("Angle out of range") // This should never happen
        }
    }
    
    func indicateDistanceFromTarget(depth: Float) {
        
        //Share the distance verbally
        var distanceIndication = ""
        if self.indicationMessage != "Look around for a target object" {
            distanceIndication = self.indicationMessage + ", Distance from target: \(Int(depth * 100)) centimeters"
        } else {
            distanceIndication = "Distance from target: \(Int(depth * 100)) centimeters"
        }
        
        self.speechSynthesizer.stopSpeaking(at: .immediate)
        self.speechUtterance = AVSpeechUtterance(string: distanceIndication)
        speechSynthesizer.speak(speechUtterance)
    }
    
    func playIndication(sentence: String){
        self.speechSynthesizer.stopSpeaking(at: .immediate)
        self.speechUtterance = AVSpeechUtterance(string: sentence)
        speechSynthesizer.speak(speechUtterance)
    }
    
    func assistUser(referencePoint: CGPoint?, objectLocation: CGPoint?) -> String {
        guard let objectLocation = objectLocation else {
            print("No object location available.")
            return ""
        }
        
        guard let referencePoint = referencePoint else {
            print("Error: referencePoint is nil")
            return ""
        }
        
        if objectLocation != CGPoint.zero {
            
            let deltaX = referencePoint.x - objectLocation.x
            let deltaY = referencePoint.y - objectLocation.y
            
            let angle = computeAngle(point1: objectLocation, point2: referencePoint)
            
            switch angle {
            case let x where (x >= 0 && x < 22.5) || (x > 337.5 && x <= 360):
                self.directionMessage = "left"
            case let x where x >= 22.5 && x < 67.5:
                self.directionMessage = "top left"
            case let x where x >= 67.5 && x < 112.5:
                self.directionMessage = "top"
            case let x where x >= 112.5 && x < 157.5:
                self.directionMessage = "top right"
            case let x where x >= 157.5 && x < 202.5:
                self.directionMessage = "right"
            case let x where x >= 202.5 && x < 247.5:
                self.directionMessage = "down right"
            case let x where x >= 247.5 && x < 292.5:
                self.directionMessage = "down"
            case let x where x >= 292.5 && x <= 337.5:
                self.directionMessage = "down left"
            default:
                fatalError("Angle out of range") // This should never happen
            }
            
            indicationMessage = self.directionMessage
            
            // Centering
            if abs(deltaX) < self.targetWidth/2  &&  abs(deltaY) < self.targetHeight/2 {
                indicationMessage = "Centered!"
                if !isCentered {
                    playSound(audioPlayer: centeredAudioPlayer)
                    self.playerNode.pan = 0.0
                    isCentered = true
                }
            } else if (abs(deltaX) < self.targetWidth/2 + 30 &&  abs(deltaY) < self.targetHeight/2 + 30) && isCentered {
                playSound(audioPlayer: uncenteredAudioPlayer)
                isCentered = false
                indicationMessage = self.directionMessage
            }
        }
        
        return indicationMessage
    }
    
    func indicateDirectionAfterLost() {
        
        //playSound(audioPlayer: targetLostAudioPlayer)
        
        self.indicationMessage = "Out of view, was " + self.directionMessage

        if oralFeedbackEnabled == true {
            self.speechSynthesizer.stopSpeaking(at: .immediate)
            let speechUtterance = AVSpeechUtterance(string: self.indicationMessage)
            speechSynthesizer.speak(speechUtterance)
        }
    }
    
    func indicateDirectionOrally() {
        if oralFeedbackEnabled == true {
            self.speechSynthesizer.stopSpeaking(at: .immediate)
            let speechUtterance = AVSpeechUtterance(string: self.indicationMessage)
            speechSynthesizer.speak(speechUtterance)
            print("Indicate direction")
        }
    }
    
    func triggerHapticFeedback() {
        let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)
        feedbackGenerator.prepare()
        feedbackGenerator.impactOccurred()
    }
    
    func resetAudio() {
        
        self.frameWidth = 0.0
        self.frameHeight = 0.0
        
        self.interBipTime = 1.0
        self.foundTarget = false
        self.handDetected = false
        self.isCentered = false
        
        self.targetHeight = 0.0
        self.targetWidth = 0.0
        self.handSize = 0.0
        self.maxHandSize = 0.0
    
        self.indicationMessage = "Look around for a target object"
        self.directionMessage = "Centered!"
    }
    
    // MARK: - Audio Processing
    
    // Implement audio processing methods as needed
    
}
