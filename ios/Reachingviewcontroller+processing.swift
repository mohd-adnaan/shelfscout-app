//
//  Reachingviewcontroller+processing.swift
//  shelfscout
//
//  Created by Mohammad Adnaan on 2026-03-04.
//  Refactored: 2026-03-28 — Simplified to router only.
//
//  Frame processing ROUTER. Dispatches to mode-specific handlers:
//    Hand-free → +handFree.swift
//    With-hand → +withHand.swift
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

    if anchorRefinementFrames > 0 && anchorRefinementFrames < anchorRefinementLimit {
      anchorRefinementFrames += 1
      tryRefineAnchorDepth(frame: frame)
    }
    // Hand-free: refinement NEVER stops — keep raycasting for the entire session.
    // As user walks closer, ARKit plane estimates improve dramatically.
    if mode == .handFree && anchorRefinementFrames >= anchorRefinementLimit {
      anchorRefinementFrames = 1
    }

    // Route to mode-specific processing
    if mode == .handFree {
      processARFrameHandFree(frame)
    } else {
      reprojectBbox(frame: frame)
      processARFrameWithHand(frame)
    }
  }
}
