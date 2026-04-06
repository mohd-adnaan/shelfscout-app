//
//  Reachingviewcontroller+processing.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//  Refactored: 2026-03-28 — Simplified to router only.
//  Updated: 2026-04-05 — Continuous refinement for both modes.
//
//  Frame processing ROUTER. Dispatches to mode-specific handlers:
//    Hand-free → +handFree.swift
//    With-hand → +withHand.swift
//
//  Continuous ARKit refinement runs for BOTH modes (one-shot detection,
//  no re-detection — refinement is the only depth correction).
//
//  All mode-specific logic lives in its own file.
//  This file should stay tiny.

import ARKit

extension ReachingViewController {

  // ═══════════════════════════════════════════════════════════════════════════
  // MARK: - Process AR Frame (router)
  // ═══════════════════════════════════════════════════════════════════════════

  func processARFrame(_ frame: ARFrame) {
    guard running else { return }
    arFrameCount += 1

    if !anchorPlaced {
      if arFrameCount >= anchorWaitFrames { placeWorldAnchor(frame: frame); say("Target locked.") }
      return
    }

    // ── Continuous ARKit refinement — BOTH modes ────────────────────────
    // One-shot Qwen detection seeds the anchor. ARKit raycasts continuously
    // refine depth as the user walks closer and planes are detected.
    // Refinement NEVER stops — as user walks, plane estimates improve.
    if anchorRefinementFrames > 0 && anchorRefinementFrames < anchorRefinementLimit {
      anchorRefinementFrames += 1
      tryRefineAnchorDepth(frame: frame)
    }
    if anchorRefinementFrames >= anchorRefinementLimit {
      anchorRefinementFrames = 1  // restart — keep refining forever
    }

    // ── Route to mode-specific processing ────────────────────────────────
    if mode == .handFree {
      processARFrameHandFree(frame)
    } else {
      // With-hand: reprojectBbox is called inside processARFrameWithHand
      // (it needs to happen AFTER phase routing, not before)
      processARFrameWithHand(frame)
    }
  }
}
