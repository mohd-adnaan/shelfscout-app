//
//  ReachingModule.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-02-03.
//

import Foundation
import ARKit
import Vision
import React

@objc(ReachingModule)
class ReachingModule: RCTEventEmitter {
    
    private var reachingViewController: ReachingViewController?
    private var currentState: String = "idle"
    
    override static func moduleName() -> String! {
        return "ReachingModule"
    }
    
    override func supportedEvents() -> [String]! {
        return [
            "onTrackingStarted",
            "onTargetLocked",
            "onTargetReached",
            "onTargetLost",
            "onError"
        ]
    }
    
    @objc
    func startReaching(_ config: NSDictionary,
                       resolver resolve: @escaping RCTPromiseResolveBlock,
                       rejecter reject: @escaping RCTPromiseRejectBlock) {
        
        guard let objectName = config["objectName"] as? String,
              let bboxArray = config["bbox"] as? [NSNumber],
              let imageWidth = config["imageWidth"] as? Int,
              let imageHeight = config["imageHeight"] as? Int,
              bboxArray.count == 4 else {
            reject("INVALID_CONFIG", "Invalid configuration provided", nil)
            return
        }
        
        let bbox = bboxArray.map { CGFloat($0.floatValue) }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            // Convert pixel bbox to normalized coordinates (0-1)
            let normalizedBbox = CGRect(
                x: bbox[0] / CGFloat(imageWidth),
                y: bbox[1] / CGFloat(imageHeight),
                width: (bbox[2] - bbox[0]) / CGFloat(imageWidth),
                height: (bbox[3] - bbox[1]) / CGFloat(imageHeight)
            )
            
            // Initialize reaching view controller
            self.reachingViewController = ReachingViewController()
            self.reachingViewController?.delegate = self
            self.reachingViewController?.configure(
                objectName: objectName,
                initialBbox: normalizedBbox
            )
            
            // Present as overlay
            if let rootVC = UIApplication.shared.keyWindow?.rootViewController {
                self.reachingViewController?.modalPresentationStyle = .fullScreen
                rootVC.present(self.reachingViewController!, animated: true)
            }
            
            self.currentState = "tracking"
            self.sendEvent(withName: "onTrackingStarted", body: ["object": objectName])
            resolve(nil)
        }
    }
    
    @objc
    func stopReaching(_ resolve: @escaping RCTPromiseResolveBlock,
                      rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.main.async { [weak self] in
            self?.reachingViewController?.dismiss(animated: true)
            self?.reachingViewController = nil
            self?.currentState = "idle"
            resolve(nil)
        }
    }
    
    @objc
    func isAvailable(_ resolve: @escaping RCTPromiseResolveBlock,
                     rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(ARWorldTrackingConfiguration.isSupported)
    }
    
    @objc
    func getState(_ resolve: @escaping RCTPromiseResolveBlock,
                  rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(currentState)
    }
    
    @objc
    override static func requiresMainQueueSetup() -> Bool {
        return true
    }
}

// MARK: - ReachingViewControllerDelegate
extension ReachingModule: ReachingViewControllerDelegate {
    func didLockTarget() {
        currentState = "locked"
        sendEvent(withName: "onTargetLocked", body: nil)
    }
    
    func didReachTarget() {
        currentState = "reached"
        sendEvent(withName: "onTargetReached", body: nil)
    }
    
    func didLoseTarget() {
        currentState = "lost"
        sendEvent(withName: "onTargetLost", body: nil)
    }
    
    func didEncounterError(_ error: Error) {
        sendEvent(withName: "onError", body: ["message": error.localizedDescription])
    }
}
