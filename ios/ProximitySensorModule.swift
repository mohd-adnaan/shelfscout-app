import Foundation
import UIKit
import React

@objc(ProximitySensorModule)
class ProximitySensorModule: RCTEventEmitter {
  private var hasListeners = false
  private var isMonitoring = false

  @objc override static func requiresMainQueueSetup() -> Bool { true }

  override func supportedEvents() -> [String]! {
    return ["onProximityChange"]
  }

  override func startObserving() {
    hasListeners = true
    startMonitoring()
  }

  override func stopObserving() {
    hasListeners = false
    stopMonitoring()
  }

  @objc func start() {
    startMonitoring()
  }

  @objc func stop() {
    stopMonitoring()
  }

  @objc private func proximityChanged() {
    emitCurrentState()
  }

  private func startMonitoring() {
    DispatchQueue.main.async {
      if self.isMonitoring { return }
      self.isMonitoring = true
      UIDevice.current.isProximityMonitoringEnabled = true
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(self.proximityChanged),
        name: UIDevice.proximityStateDidChangeNotification,
        object: nil
      )
      self.emitCurrentState()
    }
  }

  private func stopMonitoring() {
    DispatchQueue.main.async {
      if !self.isMonitoring { return }
      NotificationCenter.default.removeObserver(
        self,
        name: UIDevice.proximityStateDidChangeNotification,
        object: nil
      )
      UIDevice.current.isProximityMonitoringEnabled = false
      self.isMonitoring = false
    }
  }

  private func emitCurrentState() {
    guard hasListeners else { return }
    let isNear = UIDevice.current.proximityState
    sendEvent(withName: "onProximityChange", body: ["near": isNear])
  }
}
