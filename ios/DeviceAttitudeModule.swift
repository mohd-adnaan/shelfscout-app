//
//  DeviceAttitudeModule.swift
//  shelfscout
//
//  Phone orientation (CMDeviceMotion.attitude) for the standard reaching
//  tracker.
//
//  Melody's tracker consumes yaw/pitch/roll alongside each frame so the
//  server-side sonification can reason about how the phone was pointed when
//  the frame was taken. The JS loop samples this immediately after the photo
//  capture returns and posts it inside the smartguidance payload.
//
//  Why a dedicated module rather than reusing IMUSensorManager:
//  IMUSensorManager is the ARKit navigation pipeline's dead-reckoning stack —
//  it owns step detection, bearing correction and position integration, and it
//  applies app-specific conventions to yaw (it negates CoreMotion's
//  counter-clockwise yaw to get a clockwise compass bearing). The tracker
//  wants RAW attitude, and it runs in a pipeline where the navigation IMU
//  stack is not necessarily running at all. Keeping them separate means
//  neither can perturb the other's CMMotionManager configuration.
//
//  Angle conventions (straight from CMAttitude, converted rad → deg, no
//  app-specific sign flips):
//    yaw_deg    rotation about the gravity axis, [-180, 180], CCW-positive
//    pitch_deg  nose up/down, [-90, 90], positive = top of phone tilted back
//    roll_deg   rotation about the phone's long axis, [-180, 180]
//
//  Reference frame — this decides what yaw 0 MEANS, so it is reported in the
//  payload rather than left implicit:
//    "gravity" (default) → .xArbitraryZVertical. Z is pinned to gravity, so
//        pitch/roll are absolute, but yaw 0 is wherever the phone happened to
//        be pointing when updates started, and it drifts (no magnetometer).
//    "magneticNorth"     → .xMagneticNorthZVertical, yaw referenced to
//        magnetic north. Absolute, but needs magnetometer calibration and is
//        unreliable indoors near steel shelving — which is exactly where this
//        pipeline runs.
//    "trueNorth"         → .xTrueNorthZVertical (also needs location).
//
//  .xArbitraryZVertical is Melody's confirmed choice (Aug 2026), for the same
//  reason the ARKit pipeline avoids .gravityAndHeading indoors: a
//  heading-referenced frame in a grocery aisle stalls and swings. The other
//  frames stay reachable from JS, but switching mid-study invalidates
//  previously collected runs — yaw would no longer mean the same thing.
//

import Foundation
import CoreMotion
import React

@objc(DeviceAttitudeModule)
class DeviceAttitudeModule: NSObject {

  private let motionManager = CMMotionManager()
  private let lock = NSLock()
  private var isRunning = false
  private var referenceFrameName = "gravity"

  /// Sampling rate for device motion. The tracker loop reads at ~5 Hz, but a
  /// faster sensor rate keeps the newest sample close to the capture instant.
  private static let defaultUpdateInterval: TimeInterval = 1.0 / 50.0

  @objc static func requiresMainQueueSetup() -> Bool { false }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Lifecycle
  // ═══════════════════════════════════════════════════════════════════════════

  /// options:
  ///   referenceFrame: "gravity" | "magneticNorth" | "trueNorth"
  ///   updateIntervalMs: Double
  @objc func start(
    _ options: NSDictionary?,
    resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    guard motionManager.isDeviceMotionAvailable else {
      NSLog("⚠️ [DeviceAttitude] Device motion unavailable on this hardware")
      resolver(["success": false, "error": "device_motion_unavailable"])
      return
    }

    let requestedFrame = (options?["referenceFrame"] as? String) ?? "gravity"
    // `resolvedName` is what actually got applied — it differs from the
    // request when the hardware can't supply a north-referenced frame. The
    // payload reports the resolved name so Melody never interprets a
    // drifting arbitrary yaw as a compass heading.
    let (frame, resolvedName) = Self.referenceFrame(for: requestedFrame)
    let intervalMs = (options?["updateIntervalMs"] as? NSNumber)?.doubleValue

    lock.lock()
    let alreadyRunning = isRunning
    let sameFrame = referenceFrameName == resolvedName
    lock.unlock()

    // Restarting with the same frame would reset the arbitrary-yaw origin for
    // no reason, which would show up on Melody's side as a yaw discontinuity
    // mid-session. Only restart when the requested frame actually changed.
    if alreadyRunning && sameFrame {
      resolver(["success": true, "reference_frame": resolvedName, "restarted": false])
      return
    }

    if alreadyRunning {
      motionManager.stopDeviceMotionUpdates()
    }

    motionManager.deviceMotionUpdateInterval = intervalMs.map { $0 / 1000.0 }
      ?? Self.defaultUpdateInterval
    // Pull model: start updates without a handler and read
    // `motionManager.deviceMotion` on demand. The tracker wants the newest
    // sample at capture time, not a stream.
    motionManager.startDeviceMotionUpdates(using: frame)

    lock.lock()
    isRunning = true
    referenceFrameName = resolvedName
    lock.unlock()

    NSLog("🧭 [DeviceAttitude] Started (frame=%@, interval=%.1fms)",
          resolvedName, motionManager.deviceMotionUpdateInterval * 1000)
    resolver(["success": true, "reference_frame": resolvedName, "restarted": alreadyRunning])
  }

  @objc func stop(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    lock.lock()
    let wasRunning = isRunning
    isRunning = false
    lock.unlock()

    if wasRunning {
      motionManager.stopDeviceMotionUpdates()
      NSLog("🧭 [DeviceAttitude] Stopped")
    }
    resolver(["success": true])
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Read
  // ═══════════════════════════════════════════════════════════════════════════

  /// Resolves the newest attitude sample, or null when motion updates are not
  /// running / no sample has landed yet. Null (rather than a reject) so the
  /// caller can post the frame without orientation instead of dropping it —
  /// a missing pose degrades the sonification, a dropped frame stalls guidance.
  @objc func getAttitude(
    _ resolver: @escaping RCTPromiseResolveBlock,
    rejecter: @escaping RCTPromiseRejectBlock
  ) {
    guard let motion = motionManager.deviceMotion else {
      resolver(nil)
      return
    }

    let attitude = motion.attitude
    let radToDeg = 180.0 / Double.pi
    // Same rotation as the Euler angles, in the form that survives gimbal
    // lock and interpolates cleanly — the tracker consumes both.
    let q = attitude.quaternion

    // CMDeviceMotion.timestamp is seconds since last boot (same clock as
    // ProcessInfo.systemUptime), so shift it onto the Unix epoch. Recomputed
    // per read rather than cached at start: a cached boot instant silently
    // absorbs any wall-clock adjustment that happens mid-session.
    let bootEpoch = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime
    let captureTs = bootEpoch + motion.timestamp
    let ageMs = (ProcessInfo.processInfo.systemUptime - motion.timestamp) * 1000.0

    lock.lock()
    let frameName = referenceFrameName
    lock.unlock()

    resolver([
      "yaw_deg": attitude.yaw * radToDeg,
      "pitch_deg": attitude.pitch * radToDeg,
      "roll_deg": attitude.roll * radToDeg,
      "capture_ts": captureTs,
      // Diagnostics — the tracker can ignore these, they exist so a stale or
      // differently-referenced pose is visible rather than silently wrong.
      "reference_frame": frameName,
      "age_ms": ageMs,
      "quaternion": ["x": q.x, "y": q.y, "z": q.z, "w": q.w],
    ])
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Helpers
  // ═══════════════════════════════════════════════════════════════════════════

  /// Returns the frame to apply along with the name that describes what was
  /// actually applied (they diverge when the requested frame is unavailable).
  private static func referenceFrame(
    for name: String
  ) -> (CMAttitudeReferenceFrame, String) {
    let available = CMMotionManager.availableAttitudeReferenceFrames()

    switch name {
    case "trueNorth":
      if available.contains(.xTrueNorthZVertical) { return (.xTrueNorthZVertical, name) }
      NSLog("⚠️ [DeviceAttitude] trueNorth unavailable — falling back to gravity")
      return (.xArbitraryZVertical, "gravity")
    case "magneticNorth":
      if available.contains(.xMagneticNorthZVertical) { return (.xMagneticNorthZVertical, name) }
      NSLog("⚠️ [DeviceAttitude] magneticNorth unavailable — falling back to gravity")
      return (.xArbitraryZVertical, "gravity")
    default:
      return (.xArbitraryZVertical, "gravity")
    }
  }
}
