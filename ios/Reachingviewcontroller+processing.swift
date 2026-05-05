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
      // ── INITIAL BBOX REFRESH GATE ─────────────────────────────────────
      // The bbox passed in came from a VisionCamera photo seconds ago.
      // Hand tremor over that delay puts it off the actual object in
      // the current AR camera view. Refresh it from a live AR frame
      // before placement. State machine:
      //   .pending  → wait initialReseedFrameWait frames, then fire request
      //                (also saves frame.camera.transform for placement)
      //   .inFlight → wait for response (or timeout)
      //   .succeeded / .failed / .skipped → proceed with placement
      switch initialReseedStatus {
      case .pending:
        if arFrameCount >= initialReseedFrameWait {
          initialReseedStatus = .inFlight
          requestInitialBboxFromAR(frame: frame)
        }
        return
      case .inFlight:
        let elapsed = ProcessInfo.processInfo.systemUptime - initialReseedStartTime
        if elapsed > initialReseedTimeoutSec {
          NSLog("🎯 [InitialReseed] timed out after %.1fs — falling back to photo bbox + live pose", elapsed)
          initialReseedStatus = .failed
          detectionFrameCameraTransform = nil
        }
        return
      case .succeeded, .failed, .skipped:
        break  // fall through to placement gate below
      }

      if arFrameCount >= anchorWaitFrames {
        let usingFresh = (initialReseedStatus == .succeeded)
        let usingSavedPose = (detectionFrameCameraTransform != nil)
        NSLog("🎯 [Placement] Using %@ bbox + %@ pose",
              usingFresh ? "FRESH AR-frame" : "stale photo",
              usingSavedPose ? "SAVED detection-time" : "live")
        placeWorldAnchor(frame: frame); say("Target locked.")
      }
      return
    }

    // ── Visual tracker update — runs every frame after anchor placement ──
    // The tracker locks onto the object's 2D pixels in the live AR feed.
    // Subsequent depth refinement uses the tracker's bbox center as the
    // ray target, so the anchor stays accurate even if the initial depth
    // was wrong. When tracker confidence drops for ~12 frames straight,
    // we ask the backend for a fresh bbox and re-seed.
    if trackerEnabled && trackingActive {
      _ = updateTracker(frame: frame)
      if shouldReseedTracker() {
        reseedTrackerFromBackend(frame: frame)
      }
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