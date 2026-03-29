//
//  Reachingviewcontroller+depth.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//  Refactored: 2026-03-28 — Shared utilities only.
//
//  Shared depth/spatial utilities used by both modes:
//    - LiDAR depth sampling (used by anchor placement)
//    - Aspect-fill crop math
//    - Vision-to-screen coordinate conversion
//
//  Mode-specific depth logic:
//    With-hand depth checking → +withHand.swift
//    Hand-free acquisition    → +handFree.swift

import ARKit
import Vision

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - LiDAR Depth Sampling
  // ═══════════════════════════════════════════════════════════════════════════
  //
  // Samples the LiDAR scene depth map at a given screen-space point.
  // Returns metric depth in meters, or nil if LiDAR unavailable/invalid.
  //
  // Used by placeWorldAnchor() for instant accurate depth seeding on
  // Pro devices, bypassing the slow ARKit raycast refinement loop.

  func sampleLiDARDepth(frame: ARFrame, screenCenter: CGPoint) -> Float? {
    guard hasLiDAR, let sceneDepth = frame.sceneDepth else { return nil }

    let depthMap = sceneDepth.depthMap
    let dW = CVPixelBufferGetWidth(depthMap)
    let dH = CVPixelBufferGetHeight(depthMap)

    // Screen (portrait) → depth map (landscape) coordinate mapping
    let normX = screenCenter.x / cachedSW
    let normY = screenCenter.y / cachedSH
    let dpX = Int(normY * CGFloat(dW))
    let dpY = Int((1.0 - normX) * CGFloat(dH))
    let clampedX = max(0, min(dpX, dW - 1))
    let clampedY = max(0, min(dpY, dH - 1))

    CVPixelBufferLockBaseAddress(depthMap, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

    guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
    let bpr = CVPixelBufferGetBytesPerRow(depthMap)
    let ptr = base.advanced(by: clampedY * bpr + clampedX * MemoryLayout<Float32>.size)
    let depth = ptr.load(as: Float32.self)

    // Reject invalid readings (too close or too far)
    guard depth > 0.15 && depth < 6.0 else {
      NSLog("🎯 [LiDAR] Rejected depth sample: %.2fm (out of valid range)", depth)
      return nil
    }

    return depth
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Aspect-Fill Crop
  // ═══════════════════════════════════════════════════════════════════════════

  func computeAspectFillCrop(imageW: CGFloat, imageH: CGFloat) {
    guard !cropComputed, cachedSW > 0, cachedSH > 0, imageW > 0, imageH > 0 else { return }
    let rotW = imageH, rotH = imageW
    if rotW / rotH > cachedSW / cachedSH {
      let dW = rotW * (cachedSH / rotH)
      cropFracX = ((dW - cachedSW) / 2) / dW
    }
    cropComputed = true
    NSLog("📐 [ReachingVC] cropFracX=%.4f", cropFracX)
  }

  func visionToScreen(_ pt: CGPoint) -> CGPoint {
    let adjX = cropFracX > 0
      ? ((pt.x - cropFracX) / (1.0 - 2 * cropFracX)) * cachedSW
      : pt.x * cachedSW
    return CGPoint(x: adjX, y: (1 - pt.y) * cachedSH)
  }
}
