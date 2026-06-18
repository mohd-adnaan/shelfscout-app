/**
 * src/services/useContinuousMode.ts
 *
 * ARCHITECTURE: Fire-and-forget capture loop, decoupled TTS queue
 *
 * BEFORE (broken — sequential blocking):
 *   while(navigating) {
 *     await capture()
 *     await backend()     ← 5–7 s
 *     await speakTTS()    ← 3–7 s  ← THIS blocked the next backend call
 *     await cooldown()
 *   }
 *   → backend called every ~11 s (matches 7–10 s log gaps)
 *
 * AFTER v2 (setTimeout chain — eliminates wasted interval gap):
 *
 *   Problem with v1 (setInterval):
 *     setInterval fires at fixed T=0, 2, 4, 6… regardless of when response arrives.
 *     Response arrives at T=4.5s → isProcessingFrame clears → next tick T=6s.
 *     Up to 2s wasted every cycle. Actual gap = RTT + up to 2s = 6-8s.
 *
 *   Fix (setTimeout chain):
 *     capture → POST → response arrives → setTimeout(MIN_DELAY) → capture
 *     Next call fires MIN_DELAY ms after response, not at the next fixed tick.
 *     Actual gap = RTT + MIN_DELAY (no wasted interval).
 *
 *   ttsQueue (independent, plays responses as they arrive):
 *     plays one response at a time — never blocks the capture chain
 *
 *   → backend called every RTT + 300ms ≈ 4-5s (vs 6-8s before)
 */

import { useState, useRef, useCallback, useEffect } from 'react';
import { AccessibilityInfo } from 'react-native';
import { sendToWorkflow } from '../services/WorkflowService';
import { speachesSentenceChunker } from '../services/SpeachesSentenceChunker';
import { audioFeedback } from '../services/AudioFeedbackService';
import { useDeviceOrientation } from '../hooks/useDeviceOrientation';
import { cameraIntrinsicsForUploadedImage } from './CameraIntrinsics';

// ============================================================================
// Configuration
// ============================================================================

const NAV_CONFIG = {
  /**
   * Minimum delay (ms) after a response arrives before the next capture fires.
   *
   * This is NOT a poll interval. The next call fires MIN_DELAY_AFTER_RESPONSE ms
   * after the previous response returns — not on a fixed wall-clock tick.
   * Eliminates the up-to-2s "missed tick" waste that setInterval caused.
   *
   * Gap = client RTT (upload + n8n + download) + MIN_DELAY_AFTER_RESPONSE
   * At ~4s RTT this gives ~4.3s between n8n calls (vs ~7-8s before).
   */
  MIN_DELAY_AFTER_RESPONSE: 300,

  /** Maximum retries before pausing navigation */
  MAX_CONSECUTIVE_ERRORS: 3,

  /** Delay before retry after hitting max errors (ms) */
  ERROR_RETRY_DELAY: 3000,

  /** Request timeout (ms) */
  REQUEST_TIMEOUT: 15000,

  DEBUG: __DEV__ || true,
};

const TTS_REPEAT_SUPPRESSION_MS = 10_000;

const normalizeGuidanceText = (text: string): string =>
  (text || '')
    .toLowerCase()
    .replace(/[^a-z0-9.\s-]/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

const guidanceKey = (text: string): string =>
  normalizeGuidanceText(text)
    .replace(/\b\d+(?:\.\d+)?\s*(centimeters?|cm|meters?|metres?|m|feet|foot|ft|steps?)\b/g, '<distance>')
    .replace(/\b(please|now|slowly|carefully|about|approximately|roughly|just)\b/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

const guidanceIntent = (text: string): string => {
  const normalized = normalizeGuidanceText(text);
  if (/\b(arrived|arrival|destination|reached)\b/.test(normalized)) return 'arrival';
  if (/\b(hold|upright|straight up|phone|camera sees forward|facing forward)\b/.test(normalized)) return 'orientation';
  if (/\b(left)\b/.test(normalized)) return 'left';
  if (/\b(right)\b/.test(normalized)) return 'right';
  if (/\b(straight|forward|continue|ahead|walk)\b/.test(normalized)) return 'straight';
  if (/\b(stop|wait|pause|error|failed|unavailable)\b/.test(normalized)) return 'urgent';
  return 'general';
};

const guidanceSimilarity = (a: string, b: string): number => {
  const aTokens = new Set(guidanceKey(a).split(/\s+/).filter(token => token.length > 2 && token !== '<distance>'));
  const bTokens = new Set(guidanceKey(b).split(/\s+/).filter(token => token.length > 2 && token !== '<distance>'));
  if (aTokens.size === 0 || bTokens.size === 0) return 0;
  let shared = 0;
  aTokens.forEach(token => {
    if (bTokens.has(token)) shared++;
  });
  return shared / Math.max(aTokens.size, bTokens.size);
};

const isNearDuplicateGuidance = (next: string, previous?: string): boolean => {
  if (!previous) return false;
  if (normalizeGuidanceText(next) === normalizeGuidanceText(previous)) return true;
  if (guidanceKey(next) === guidanceKey(previous)) return true;
  return guidanceIntent(next) === guidanceIntent(previous) &&
    guidanceIntent(next) !== 'general' &&
    guidanceSimilarity(next, previous) >= 0.65;
};

const isResponsiveGuidanceChange = (next: string, current?: string): boolean => {
  if (!current || isNearDuplicateGuidance(next, current)) return false;
  const nextIntent = guidanceIntent(next);
  const currentIntent = guidanceIntent(current);
  return ['arrival', 'orientation', 'urgent'].includes(nextIntent) ||
    (nextIntent !== 'general' && currentIntent !== 'general' && nextIntent !== currentIntent);
};

// ============================================================================
// Types
// ============================================================================

interface ContinuousNavigationOptions {
  cameraRef: React.RefObject<any>;
  sessionId?: string;
  onInstructionAnnounced?: (text: string) => void;
  onStateChange?: (state: NavigationCycleState) => void;
  onError?: (error: Error) => void;
}

type NavigationCycleState =
  | 'idle'
  | 'capturing'
  | 'processing'
  | 'speaking'
  | 'cooldown';

interface NavigationStats {
  cyclesCompleted: number;
  totalRequestTime: number;
  avgRequestTime: number;
  errorsEncountered: number;
  photosCaputred: number;
}

interface LastQueuedGuidance {
  text: string;
  at: number;
}

// ============================================================================
// Hook Implementation
// ============================================================================

export const useContinuousNavigation = (options: ContinuousNavigationOptions) => {
  const { cameraRef, onInstructionAnnounced, onStateChange, onError } = options;

  // ---- State ----
  const [isNavigating, setIsNavigating] = useState(false);
  const [cycleState, setCycleState] = useState<NavigationCycleState>('idle');
  const [lastInstruction, setLastInstruction] = useState('');
  const [stats, setStats] = useState<NavigationStats>({
    cyclesCompleted: 0,
    totalRequestTime: 0,
    avgRequestTime: 0,
    errorsEncountered: 0,
    photosCaputred: 0,
  });

  const { isStraightRef, orientationSnapshotRef, maxForwardTiltDegrees } = useDeviceOrientation();

  // ---- Refs ----
  const isNavigatingRef = useRef(false);
  const lastOrientationWarningTimeRef = useRef(0);

  /**
   * isProcessingFrameRef — mirrors the same flag in Swift reaching acquisition.
   * Prevents concurrent backend calls. Set true before POST, false when response
   * returns (or on error). The poll loop checks this before firing.
   */
  const isProcessingFrameRef = useRef(false);

  const abortControllerRef = useRef<AbortController | null>(null);
  const consecutiveErrorsRef = useRef(0);
  // setTimeout handle for the self-chaining capture loop (replaces setInterval)
  const nextCaptureTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  /**
   * ttsQueueRef — responses waiting to be spoken.
   * The TTS drain loop reads from this queue independently of capture.
   */
  const ttsQueueRef = useRef<string[]>([]);
  const isSpeakingRef = useRef(false);
  const currentSpeechTextRef = useRef('');
  const lastQueuedGuidanceRef = useRef<LastQueuedGuidance | null>(null);

  const statsRef = useRef<NavigationStats>({
    cyclesCompleted: 0,
    totalRequestTime: 0,
    avgRequestTime: 0,
    errorsEncountered: 0,
    photosCaputred: 0,
  });

  // ---- Helpers ----
  const log = useCallback((msg: string) => {
    if (NAV_CONFIG.DEBUG) console.log(`🧭 [NavLoop] ${msg}`);
  }, []);

  const updateCycleState = useCallback(
    (state: NavigationCycleState) => {
      setCycleState(state);
      onStateChange?.(state);
    },
    [onStateChange],
  );

  // ============================================================================
  // TTS DRAIN LOOP
  // Runs independently. Plays queued responses one at a time.
  // Never blocks the capture loop.
  // ============================================================================
  const drainTTSQueue = useCallback(async () => {
    if (isSpeakingRef.current) return; // already draining
    isSpeakingRef.current = true;

    while (isNavigatingRef.current && ttsQueueRef.current.length > 0) {
      // Always take the LATEST response — discard stale ones if queue piled up
      const text = ttsQueueRef.current.pop()!;
      ttsQueueRef.current = []; // discard any others that queued while we were processing

      currentSpeechTextRef.current = text;
      log(`🔊 Speaking: "${text.substring(0, 60)}…"`);
      updateCycleState('speaking');
      setLastInstruction(text);
      onInstructionAnnounced?.(text);

      audioFeedback.playEarcon('speaking');

      try {
        await speachesSentenceChunker.synthesizeSpeechChunked(text);
      } catch (e: any) {
        if (!e.message?.includes('cancel') && !e.message?.includes('stop')) {
          log(`⚠️ TTS error (non-fatal): ${e.message}`);
        }
      }

      log('🔊 TTS done');
    }

    isSpeakingRef.current = false;
    currentSpeechTextRef.current = '';

    // Return to 'processing' state indicator so UI reflects capture loop state
    if (isNavigatingRef.current) {
      updateCycleState('processing');
    }
  }, [log, updateCycleState, onInstructionAnnounced]);

  const enqueueGuidanceSpeech = useCallback((text: string, source: string) => {
    const spoken = (text || '').trim();
    if (!spoken) return false;

    const now = Date.now();
    const pending = ttsQueueRef.current;
    const currentSpeech = currentSpeechTextRef.current;
    const pendingSpeech = pending.length > 0 ? pending[pending.length - 1] : '';
    const lastQueued = lastQueuedGuidanceRef.current;

    if (isNearDuplicateGuidance(spoken, currentSpeech)) {
      log(`🔇 TTS coalesced (${source}) — already speaking near-duplicate: "${spoken.substring(0, 60)}"`);
      return false;
    }

    if (isNearDuplicateGuidance(spoken, pendingSpeech)) {
      log(`🔇 TTS coalesced (${source}) — already pending near-duplicate: "${spoken.substring(0, 60)}"`);
      return false;
    }

    if (
      lastQueued &&
      now - lastQueued.at < TTS_REPEAT_SUPPRESSION_MS &&
      isNearDuplicateGuidance(spoken, lastQueued.text)
    ) {
      log(`🔇 TTS coalesced (${source}) — recently queued near-duplicate: "${spoken.substring(0, 60)}"`);
      return false;
    }

    if (isSpeakingRef.current && isResponsiveGuidanceChange(spoken, currentSpeech)) {
      log(`⚡ TTS guidance changed (${source}) — keeping newest pending speech: "${spoken.substring(0, 60)}"`);
    } else {
      log(`🔊 TTS queued (${source}/${guidanceIntent(spoken)}): "${spoken.substring(0, 60)}"`);
    }

    ttsQueueRef.current = [spoken];
    lastQueuedGuidanceRef.current = { text: spoken, at: now };
    drainTTSQueue();
    return true;
  }, [drainTTSQueue, log]);

  // ============================================================================
  // SINGLE CAPTURE + SEND  (self-chaining via setTimeout in finally)
  //
  // Pattern:
  //   captureAndSend() runs once, completes (success or error), then schedules
  //   itself again via setTimeout(captureAndSend, MIN_DELAY_AFTER_RESPONSE).
  //   This means the next call fires exactly MIN_DELAY ms after the response
  //   arrives — NOT on a fixed wall-clock tick the way setInterval would.
  // ============================================================================
  const captureAndSend = useCallback(async () => {
    if (!isNavigatingRef.current) return;
    if (isProcessingFrameRef.current) {
      log('⏭️ Frame skipped — previous request still in-flight');
      return;
    }

    if (!isStraightRef.current) {
      const tilt = orientationSnapshotRef.current.tiltFromUprightDegrees;
      log(
        `⚠️ Phone orientation incorrect. Skipping capture cycle. ` +
        `tilt=${tilt.toFixed(1)}deg max=${maxForwardTiltDegrees}deg`
      );
      
      const now = Date.now();
      if (now - lastOrientationWarningTimeRef.current > 5000) {
        enqueueGuidanceSpeech(
          'Hold the phone upright so the camera sees forward.',
          `posture tilt=${tilt.toFixed(1)}deg`
        );
        lastOrientationWarningTimeRef.current = now;
      }
      
      if (isNavigatingRef.current) {
        nextCaptureTimeoutRef.current = setTimeout(
          captureAndSend,
          NAV_CONFIG.MIN_DELAY_AFTER_RESPONSE
        );
      }
      return;
    }

    isProcessingFrameRef.current = true;
    updateCycleState('capturing');

    let photoPath: string | null = null;
    let photoWidth = 0;
    let photoHeight = 0;
    let cameraIntrinsics: ReturnType<typeof cameraIntrinsicsForUploadedImage>;

    // ── Capture ──────────────────────────────────────────────────────────────
    try {
      if (!cameraRef.current) {
        log('⚠️ No camera ref');
        isProcessingFrameRef.current = false;
        return;
      }

      const photo = await cameraRef.current.takePhoto({
        qualityPrioritization: 'speed',
        enableShutterSound: false,
      });
      photoPath = photo.path;
      photoWidth = photo.width || 0;
      photoHeight = photo.height || 0;
      cameraIntrinsics = cameraIntrinsicsForUploadedImage(
        (photo as any).cameraCalibrationData,
        { width: photoWidth, height: photoHeight },
      );
      statsRef.current.photosCaputred++;
      log(`📸 Captured: ${photoPath}`);
    } catch (err) {
      log(`❌ Capture failed: ${err}`);
      isProcessingFrameRef.current = false;
      return;
    }

    if (!isNavigatingRef.current) {
      isProcessingFrameRef.current = false;
      return;
    }

    updateCycleState('processing');

    // ── Backend POST ──────────────────────────────────────────────────────────
    const startTime = Date.now();
    const abort = new AbortController();
    abortControllerRef.current = abort;

    try {
      log('📤 POSTing to backend…');

      const result = await sendToWorkflow(
        {
          text: 'navigation',
          imageUri: photoPath || '',
          imageWidth: photoWidth,
          imageHeight: photoHeight,
          cameraIntrinsics,
          navigation: true,
        },
        abort.signal,
      );

      if (!isNavigatingRef.current) {
        isProcessingFrameRef.current = false;
        return;
      }

      const elapsed = Date.now() - startTime;
      statsRef.current.totalRequestTime += elapsed;
      statsRef.current.cyclesCompleted++;
      statsRef.current.avgRequestTime =
        statsRef.current.totalRequestTime / statsRef.current.cyclesCompleted;

      log(`✅ Response in ${elapsed}ms: "${(result.text || '').substring(0, 60)}…"`);

      consecutiveErrorsRef.current = 0;

      // Push to TTS queue and drain (non-blocking)
      if (result.text?.trim()) {
        enqueueGuidanceSpeech(result.text, 'backend'); // fire-and-forget — does not block the next poll
      }
    } catch (err: any) {
      if (
        !isNavigatingRef.current ||
        abort.signal.aborted ||
        err.message?.includes('cancel')
      ) {
        isProcessingFrameRef.current = false;
        return;
      }

      consecutiveErrorsRef.current++;
      statsRef.current.errorsEncountered++;
      log(`❌ Request error: ${err.message}`);
      onError?.(err);

      if (consecutiveErrorsRef.current >= NAV_CONFIG.MAX_CONSECUTIVE_ERRORS) {
        log(`🚨 ${NAV_CONFIG.MAX_CONSECUTIVE_ERRORS} consecutive errors — pausing ${NAV_CONFIG.ERROR_RETRY_DELAY}ms`);
        AccessibilityInfo.announceForAccessibility(
          'Navigation paused due to errors. Retrying shortly.',
        );
        await new Promise<void>(resolve => setTimeout(resolve, NAV_CONFIG.ERROR_RETRY_DELAY));
        consecutiveErrorsRef.current = 0;
      }
    } finally {
      // Clear the in-flight flag regardless of outcome.
      isProcessingFrameRef.current = false;

      // ── Self-chain: schedule next capture ──────────────────────────────────
      // Fires MIN_DELAY_AFTER_RESPONSE ms after THIS response returned.
      // Because we schedule here (not from a fixed-tick setInterval), there is
      // no "missed interval" waste — the next call is always exactly MIN_DELAY
      // after we're done, not at the next arbitrary wall-clock boundary.
      if (isNavigatingRef.current) {
        nextCaptureTimeoutRef.current = setTimeout(
          captureAndSend,
          NAV_CONFIG.MIN_DELAY_AFTER_RESPONSE,
        );
      }
    }
  }, [cameraRef, enqueueGuidanceSpeech, updateCycleState, onError, log, maxForwardTiltDegrees]);

  // ============================================================================
  // PUBLIC API: startNavigation
  // Kicks off the first captureAndSend(); the chain is self-perpetuating.
  // ============================================================================
  const startNavigation = useCallback(async () => {
    if (isNavigatingRef.current) {
      log('⚠️ Already navigating');
      return;
    }

    log(`🟢 Starting navigation — min delay after response: ${NAV_CONFIG.MIN_DELAY_AFTER_RESPONSE}ms`);
    isNavigatingRef.current = true;
    isProcessingFrameRef.current = false;
    isSpeakingRef.current = false;
    currentSpeechTextRef.current = '';
    ttsQueueRef.current = [];
    lastQueuedGuidanceRef.current = null;
    consecutiveErrorsRef.current = 0;

    statsRef.current = {
      cyclesCompleted: 0,
      totalRequestTime: 0,
      avgRequestTime: 0,
      errorsEncountered: 0,
      photosCaputred: 0,
    };

    setIsNavigating(true);
    updateCycleState('capturing');
    // Brief settle delay (camera/audio)
    await new Promise<void>(resolve => setTimeout(resolve, 500));

    AccessibilityInfo.announceForAccessibility(
      'Continuous navigation started. Walk slowly and listen for guidance.',
    );

    // Kick off the first cycle — the finally block schedules subsequent ones
    captureAndSend();
  }, [captureAndSend, updateCycleState, log]);

  // ============================================================================
  // PUBLIC API: stopNavigation
  // ============================================================================
  const stopNavigation = useCallback(async () => {
    log('🔴 Stopping navigation');
    isNavigatingRef.current = false;
    ttsQueueRef.current = [];
    currentSpeechTextRef.current = '';
    lastQueuedGuidanceRef.current = null;

    // Cancel any pending next-capture timeout
    if (nextCaptureTimeoutRef.current) {
      clearTimeout(nextCaptureTimeoutRef.current);
      nextCaptureTimeoutRef.current = null;
    }

    abortControllerRef.current?.abort();
    abortControllerRef.current = null;

    try {
      await speachesSentenceChunker.stop();
    } catch (e) {
      log(`⚠️ TTS stop error: ${e}`);
    }

    setIsNavigating(false);
    updateCycleState('idle');
    setStats({ ...statsRef.current });

    AccessibilityInfo.announceForAccessibility('Navigation stopped. CyberSight is ready.');
    audioFeedback.playEarcon('ready');
  }, [updateCycleState, log]);

  // ============================================================================
  // Cleanup on unmount
  // ============================================================================
  useEffect(() => {
    return () => {
      if (nextCaptureTimeoutRef.current) clearTimeout(nextCaptureTimeoutRef.current);
      if (isNavigatingRef.current) {
        isNavigatingRef.current = false;
        abortControllerRef.current?.abort();
      }
    };
  }, []);

  return {
    startNavigation,
    stopNavigation,
    isNavigating,
    cycleState,
    lastInstruction,
    stats,
  };
};

export default useContinuousNavigation;
