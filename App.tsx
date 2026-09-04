// App.tsx - CyberSight Mobile Application

import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  StyleSheet,
  View,
  TouchableWithoutFeedback,
  TouchableOpacity,
  Text,
  Platform,
  PermissionsAndroid,
  Alert,
  Animated,
  Dimensions,
  StatusBar,
  AccessibilityInfo,
  NativeModules,
  AppState,
} from 'react-native';
import {
  Camera,
  useCameraDevice,
  useCameraPermission,
  useMicrophonePermission,
} from 'react-native-vision-camera';
import Video from 'react-native-video';
import { useTTS } from './src/hooks/useTTS';
import { strings, getAppLanguage } from './src/i18n';
import { useSTT } from './src/hooks/useSTT_Enhanced';
import { useWakeWordSTT } from './src/hooks/useWakeWordSTT';
import { useDeviceOrientation } from './src/hooks/useDeviceOrientation';
import { useProximitySensor } from './src/hooks/useProximitySensor';
import {
  sendToWorkflow,
  sendToSmartGuidance,
  isContinuousModeActive,
  getCurrentMode,
  startContinuousMode,
  stopContinuousMode,
  incrementContinuousMode,
  getCurrentLoopDelay,
  getContinuousModeRateLimitDelay,
  shouldPreventInfiniteLoop,
  updateLoopDelay,
  getSessionId,
  resetSessionId,
  determineActionMode,
} from './src/services/WorkflowService';
import { sendToRtabGuidance } from './src/services/RtabGuidanceService';
import {
  startDeviceAttitude,
  stopDeviceAttitude,
  getDeviceAttitude,
} from './src/native/DeviceAttitude';
import {
  startSpatialAudio,
  updateSpatialAudio,
  silenceSpatialAudio,
  stopSpatialAudio,
} from './src/native/SpatialAudio';
import { VoiceVisualizer } from './src/components/VoiceVisualizer';
import { ActionMenu, MenuActionId } from './src/components/ActionMenu';
import { ActivityOverlay } from './src/components/ActivityOverlay';
import { GearIcon } from './src/components/MenuIcons';
import { DestinationPicker } from './src/components/DestinationPicker';
import Announcer from './src/a11y/Announcer';
import earcons from './src/a11y/earcons';
import { canonicalizeMenuCommand } from './src/a11y/menuCommands';
import {
  initSounds,
  releaseSounds,
  stopListenSound,
  playThinkingStarted,
  stopLatencyLoop,
  playErrorSound,
  prepareForRecording,
  configurePlaybackSession,
  setWearablesMode,
  setScreenReaderMode,
  playStopReachingSound,
} from './src/utils/soundEffects';
import { speachesSentenceChunker } from './src/services/SpeachesSentenceChunker';
import { CONFIG, NAVIGATION_CONFIG, DETECTION_URL, ACQUISITION_URL } from './src/utils/constants';
import { WATCHDOG_TIMEOUTS, nativeCall, withTimeout } from './src/utils/asyncWatchdog';
import { fixImageOrientation } from './src/services/fixImageOrientation';
import {
  CameraIntrinsicsPayload,
  cameraIntrinsicsForUploadedImage,
} from './src/services/CameraIntrinsics';
import { SettingsProvider, useSettings } from './src/context/SettingsContext';
import SettingsScreen from './src/screens/SettingsScreen';
import { debugLogger } from './src/services/DebugLogger';
import { DebugOverlay } from './src/components/DebugOverlay';
import { wearablesCamera } from './src/services/WearablesCamera';
import { ARKitNavigationBridge, ARKitNavigationResult } from './src/native/ARKitNavigationModule';
import { groundNavigationTarget } from './src/services/TargetGroundingService';
import RNFS from 'react-native-fs';

const { width, height } = Dimensions.get('window');

// =============================================================================
// TIMING CONSTANTS
// =============================================================================
const CAMERA_REACTIVATION_DELAY_MS = 800;
const AUDIO_SESSION_RELEASE_DELAY_MS = 300;
const TTS_COMPLETION_BUFFER_MS = 500;
const STARTUP_LOADER_MIN_MS = 1800;
const VOICEOVER_LISTENING_ANNOUNCE_DELAY_MS = 800;
const VOICEOVER_LISTENING_GRACE_MS = 600;
const POSTURE_WARNING_COOLDOWN_MS = 6000;
const POSTURE_MAX_WAIT_MS = 6500;
const POSTURE_POLL_INTERVAL_MS = 250;
const POSTURE_LOG_THROTTLE_MS = 1500;
const CONTINUOUS_TTS_REPEAT_SUPPRESSION_MS = 10_000;
const CONTINUOUS_TTS_DISTANCE_REFRESH_METERS = 3;
const WEARABLES_PREWARM_RETRY_DELAYS_MS = [1500, 3000, 6000, 10000, 15000, 20000];

// =============================================================================
// PIPELINE PRE-FETCH CONFIGURATION
// =============================================================================
const PREFETCH_CONFIG = {
  ENABLED: true,
  MIN_TTS_TIME_BEFORE_PREFETCH: 3000,
  PREFETCH_TRIGGER_PERCENT: 75,
  PROGRESS_POLL_INTERVAL: 500,
  MIN_CYCLE_COOLDOWN: 300,
};

const SMART_GUIDANCE_MIN_CYCLE_MS = 200; // 5fps
const RTAB_FEED_INTERVAL_MS = 500;

let dav2PrewarmStarted = false;

type ContinuousSpeechIntent =
  | 'arrival'
  | 'orientation'
  | 'left'
  | 'right'
  | 'uturn'
  | 'straight'
  | 'up'
  | 'down'
  | 'stop'
  | 'error'
  | 'handoff'
  | 'reaching'
  | 'distance'
  | 'general';

interface ContinuousSpeechSignature {
  normalized: string;
  comparable: string;
  intent: ContinuousSpeechIntent;
  distanceMeters?: number;
}

interface ContinuousSpeechRecord {
  text: string;
  signature: ContinuousSpeechSignature;
  acceptedAt: number;
  source: string;
}

interface ContinuousSpeechEnqueueOptions {
  source?: string;
  force?: boolean;
  allowPreempt?: boolean;
  ignoreAbort?: boolean;
  /** Override CONTINUOUS_TTS_REPEAT_SUPPRESSION_MS for this call only.
   *  Use a shorter value for real-time feedback (e.g. reaching guidance)
   *  so repeated updates are spoken every ~N ms instead of every 10 s. */
  suppressionMs?: number;
}

type EnqueueContinuousSpeech = (
  text: string,
  options?: ContinuousSpeechEnqueueOptions,
) => boolean;

const looksLikeReachingCommand = (text: string): boolean => {
  const normalized = text.toLowerCase();
  return /\b(take|guide|lead|walk|navigate|bring)\s+(me\s+)?to\b/.test(normalized)
    || /\b(reach|grab|get)\b/.test(normalized);
};

const looksLikeARKitDestinationCommand = (text: string): boolean => {
  const normalized = text.toLowerCase().trim();
  if (!normalized) return false;

  if (/\b(take|guide|lead|walk|navigate|bring)\s+(me\s+)?to\b/.test(normalized) ||
      /\b(go\s+to|find|locate|where\s+is)\b/.test(normalized)) {
    return true;
  }

  if (/\b(reach|grab|get|pick|touch|press|read|describe|what|who|how|why|when|scan|look)\b/.test(normalized)) {
    return false;
  }

  const words = normalized
    .replace(/[?.!,]+/g, ' ')
    .split(/\s+/)
    .filter(Boolean);

  return words.length > 0 &&
    words.length <= 5 &&
    /\b(\d+|room|rm|door\s*knob|doorknob|door\s*handle|stove|sink|fridge|shelf|cabinet|counter|table|chair)\b/.test(normalized);
};

const inferNavigationTargetFromCommand = (text?: string | null): string => {
  const source = (text || '').trim();
  if (!source) return '';

  const patterns = [
    /\b(?:take|guide|lead|walk|navigate|bring)\s+(?:me\s+)?to\s+(?:the\s+)?(.+)$/i,
    /\b(?:go\s+to|find|locate|where\s+is)\s+(?:the\s+)?(.+)$/i,
  ];

  for (const pattern of patterns) {
    const match = source.match(pattern);
    const target = match?.[1]
      ?.replace(/[?.!]+$/g, '')
      .replace(/\b(?:please|for me)\b$/i, '')
      .trim();
    if (target) return target;
  }

  return '';
};

const normalizeInstructionText = (text: string): string => {
  return (text || '')
    .toLowerCase()
    .replace(/[’‘]/g, "'")
    .replace(/[“”]/g, '"')
    .replace(/[^a-z0-9.'"\s-]/g, ' ')
    .replace(/-/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
};

const extractDistanceMeters = (normalized: string): number | undefined => {
  const numeric = normalized.match(/\b(\d+(?:\.\d+)?)\s*(centimeters?|cm|meters?|metres?|m|feet|foot|ft|steps?)\b/);
  if (!numeric) return undefined;

  const value = Number(numeric[1]);
  if (!Number.isFinite(value)) return undefined;

  const unit = numeric[2];
  if (unit === 'cm' || unit.startsWith('centimeter')) return value / 100;
  if (unit === 'feet' || unit === 'foot' || unit === 'ft') return value * 0.3048;
  if (unit.startsWith('step')) return value * 0.75;
  return value;
};

const extractInstructionIntent = (normalized: string): ContinuousSpeechIntent => {
  if (/\b(arrived|arrival|destination|you are here|reached)\b/.test(normalized)) return 'arrival';
  if (/\b(hold|raise|upright|straight up|camera sees forward|facing forward|phone)\b/.test(normalized)) return 'orientation';
  if (/\b(switching|handoff|starting arkit|route guidance|object guidance)\b/.test(normalized)) return 'handoff';
  if (/\b(unavailable|not available|could not|cannot|error|failed|try again)\b/.test(normalized)) return 'error';
  if (/\b(stop|wait|pause|stay)\b/.test(normalized)) return 'stop';
  if (/\b(u turn|turn around|around)\b/.test(normalized)) return 'uturn';
  if (/\b(left)\b/.test(normalized)) return 'left';
  if (/\b(right)\b/.test(normalized)) return 'right';
  if (/\b(straight|forward|continue|ahead|walk)\b/.test(normalized)) return 'straight';
  if (/\b(up|raise|tilt up)\b/.test(normalized)) return 'up';
  if (/\b(down|lower|tilt down)\b/.test(normalized)) return 'down';
  if (/\b(reach(?:ing)?|hand|object|target|closer|approach|grab|grasp)\b/.test(normalized)) return 'reaching';
  if (extractDistanceMeters(normalized) !== undefined) return 'distance';
  return 'general';
};

const buildInstructionSignature = (text: string): ContinuousSpeechSignature => {
  const normalized = normalizeInstructionText(text);
  const distanceMeters = extractDistanceMeters(normalized);
  const comparable = normalized
    .replace(/\b\d+(?:\.\d+)?\s*(centimeters?|cm|meters?|metres?|m|feet|foot|ft|steps?)\b/g, '<distance>')
    .replace(/\b(one|two|three|four|five|six|seven|eight|nine|ten)\s+(meters?|metres?|steps?|feet|foot)\b/g, '<distance>')
    .replace(/\b(please|now|slowly|carefully|about|approximately|roughly|just)\b/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();

  return {
    normalized,
    comparable,
    intent: extractInstructionIntent(normalized),
    distanceMeters,
  };
};

const tokenSimilarity = (a: string, b: string): number => {
  const aTokens = new Set(a.split(/\s+/).filter(token => token.length > 2 && token !== '<distance>'));
  const bTokens = new Set(b.split(/\s+/).filter(token => token.length > 2 && token !== '<distance>'));
  if (aTokens.size === 0 || bTokens.size === 0) return 0;

  let shared = 0;
  aTokens.forEach(token => {
    if (bTokens.has(token)) shared++;
  });
  return shared / Math.max(aTokens.size, bTokens.size);
};

const areInstructionsNearDuplicate = (
  next: ContinuousSpeechSignature,
  previous?: ContinuousSpeechSignature | null,
): boolean => {
  if (!previous) return false;
  if (next.normalized === previous.normalized) return true;

  const distanceDelta =
    next.distanceMeters !== undefined && previous.distanceMeters !== undefined
      ? Math.abs(next.distanceMeters - previous.distanceMeters)
      : undefined;

  if (next.comparable === previous.comparable) {
    return distanceDelta === undefined || distanceDelta < CONTINUOUS_TTS_DISTANCE_REFRESH_METERS;
  }

  const sameIntent = next.intent === previous.intent && next.intent !== 'general';
  const similarity = tokenSimilarity(next.comparable, previous.comparable);

  if (sameIntent && similarity >= 0.65) {
    return distanceDelta === undefined || distanceDelta < CONTINUOUS_TTS_DISTANCE_REFRESH_METERS;
  }

  return similarity >= 0.86;
};

const isResponsiveSpeechChange = (
  next: ContinuousSpeechSignature,
  current?: ContinuousSpeechSignature | null,
): boolean => {
  if (!current || areInstructionsNearDuplicate(next, current)) return false;

  if (['arrival', 'orientation', 'stop', 'error', 'handoff'].includes(next.intent)) {
    return true;
  }

  return next.intent !== 'general' && current.intent !== 'general' && next.intent !== current.intent;
};

const prewarmDAv2InBackground = (reason: string) => {
  if (Platform.OS !== 'ios' || dav2PrewarmStarted) return;
  const { ReachingModule } = NativeModules;
  if (!ReachingModule?.prewarmDAv2) return;

  dav2PrewarmStarted = true;
  console.log(`🔥 [DAv2] Pre-warming model (${reason})`);
  ReachingModule.prewarmDAv2()
    .then(() => console.log('✅ [DAv2] Prewarm complete'))
    .catch((e: any) => {
      dav2PrewarmStarted = false;
      console.warn('⚠️ [DAv2] Prewarm failed:', e?.message || e);
    });
};

// =============================================================================
// AppInner
// =============================================================================
function AppInner(): React.JSX.Element {

  // ── State ──────────────────────────────────────────────────────────────────
  const [isProcessing, setIsProcessing] = useState(false);
  const [isSpeaking, setIsSpeaking] = useState(false);
  const [isNavigation, setIsNavigation] = useState(false);
  const [isReaching, setIsReaching] = useState(false);
  const [screenReaderEnabled, setScreenReaderEnabled] = useState(false);
  const [reduceMotionEnabled, setReduceMotionEnabled] = useState(false);
  const [isCameraActive, setIsCameraActive] = useState(true);
  const [showSettings, setShowSettings] = useState(false);
  const [showStartupLoader, setShowStartupLoader] = useState(true);

  // ── Menu-driven interaction ────────────────────────────────────────────
  //
  // `homeView` is only meaningful while the app is idle; once a turn starts,
  // the active view takes over regardless. Keeping it separate from the
  // busy-state flags means returning to idle always lands the user back on
  // the surface they left, which is what makes the app feel like it has
  // places rather than modes.
  const [homeView, setHomeView] = useState<'menu' | 'destinations'>('menu');
  /**
   * Which menu row opened the microphone, or null when the user started
   * listening without choosing an action first.
   *
   * This is the whole reliability story for the two voice-driven rows. When
   * the user has already said "Find an object" by pressing a button, the
   * transcript no longer has to carry that intent — it only has to carry the
   * object name. So the transcript is wrapped in a canonical command before
   * it reaches the pipeline, and the classifier sees an unambiguous sentence
   * built around a single unknown word instead of having to infer the whole
   * request from speech.
   */
  const [pendingAction, setPendingAction] = useState<MenuActionId | null>(null);
  /** Latest spoken answer, so "Repeat that" needs neither network nor model. */
  const [lastAnswer, setLastAnswer] = useState<string | null>(null);
  /** Human-readable description of the running turn, shown in ActivityOverlay. */
  const [activityStatus, setActivityStatus] = useState<string>('');

  // ── Settings ───────────────────────────────────────────────────────────────
  const { settings, resolveReachingPipeline, resolveNavigationPipeline } = useSettings();
  // Ref always holds the latest settings — avoids stale closure in useCallback
  const settingsRef = useRef(settings);
  useEffect(() => { settingsRef.current = settings; }, [settings]);

  // ── Posture sensing (orientation + proximity) ───────────────────────────
  const {
    isStraightRef,
    isAvailableRef: orientationAvailableRef,
    orientationSnapshotRef,
    maxForwardTiltDegrees,
  } = useDeviceOrientation();
  const { isNearRef, isAvailableRef: proximityAvailableRef } = useProximitySensor(
    Platform.OS === 'ios' && !settings.useWearablesCamera
  );
  const lastPostureWarningRef = useRef(0);
  const lastPostureLogRef = useRef(0);

  // Keep SFX wearables-mode flag in sync with settings
  useEffect(() => {
    setWearablesMode(settings.useWearablesCamera);
  }, [settings.useWearablesCamera]);

  // ── Camera / Permissions ───────────────────────────────────────────────────
  const device = useCameraDevice('back');
  const { hasPermission: hasCameraPermission, requestPermission: requestCameraPermission } = useCameraPermission();
  const { hasPermission: hasMicPermission, requestPermission: requestMicPermission } = useMicrophonePermission();
  const cameraRef = useRef<Camera>(null);
  const isCapturingRef = useRef(false);
  const containerRef = useRef<View>(null);

  // ── Audio / Speech ─────────────────────────────────────────────────────────
  const { speak, stop: stopTTS } = useTTS();

  // ── Internal Refs ──────────────────────────────────────────────────────────
  const isEmergencyStopped = useRef(false);
  const isProcessingRef = useRef(false);
  const finalTranscriptRef = useRef('');
  const abortControllerRef = useRef<AbortController | null>(null);
  const isCapturingPhotoRef = useRef(false);
  const isNavigationLoopRunning = useRef(false);
  const navigationLoopAbortRef = useRef(false);
  const isContinuousModeRunning = useRef(false);
  const continuousModeAbortRef = useRef(false);
  const continuousBackendInFlightRef = useRef(false);
  const continuousTtsSpeakingRef = useRef(false);
  const continuousTtsGenerationRef = useRef(0);
  const continuousSpeechQueueRef = useRef<string[]>([]);
  const continuousSpeechDrainingRef = useRef(false);
  const continuousSpeechCurrentTextRef = useRef('');
  const continuousLastAcceptedSpeechRef = useRef<ContinuousSpeechRecord | null>(null);
  const enqueueContinuousSpeechRef = useRef<EnqueueContinuousSpeech>(() => false);
  const lastImageDimensions = useRef<{ width: number; height: number }>({ width: 0, height: 0 });
  const lastCameraIntrinsics = useRef<CameraIntrinsicsPayload | undefined>(undefined);
  const prefetchedPhotoRef = useRef<string | null>(null);
  const activeCapturePromiseRef = useRef<Promise<string> | null>(null);
  const wearablesPrewarmAttemptedRef = useRef(false);
  const smartGuidanceActiveRef = useRef(false);
  const smartGuidanceResumeMainRef = useRef(false);
  const smartGuidanceCacheRef = useRef<{
    object?: string;
    bbox?: any;
    annotatedImage?: string;
    confidence?: number;
  } | null>(null);
  // Issue 5: the Qwen seed bbox is handed to the tracker container ONLY on the
  // first smart-guidance call after the tracker locks. While tracking is
  // active the container owns the box, so subsequent calls send no bbox.
  const smartGuidanceSeededRef = useRef(false);
  // Issue 4: true while tracking has been lost and the loop is re-requesting
  // Qwen detection to reacquire the target. Keeps the loop alive instead of
  // exiting on bothInactive.
  const reacquiringRef = useRef(false);
  // Orientation sensor + HRTF renderer that back the standard tracker. Started
  // lazily on the first smart-guidance send (starting them at loop entry would
  // run CoreMotion and an audio engine through every navigation cycle that
  // never reaches the tracker) and torn down in the loop's cleanup block.
  const trackerSensorsStartedRef = useRef(false);
  const spatialAudioReadyRef = useRef(false);
  const spatialAudioAttemptsRef = useRef(0);
  const rtabFeedIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const rtabLastSentFrameRef = useRef<string>('');
  const rtabLastObjectRef = useRef<string>('');
  const rtabIsSendingRef = useRef(false);
  const rtabFrameSeqRef = useRef(0);
  const rtabSubmittedFrameUrisRef = useRef<Set<string>>(new Set());
  const rtabSubmittedFrameQueueRef = useRef<string[]>([]);
  /** The native ARKit navigation screen is still mounted and localized, so
   *  the next destination can continue on it instead of relocalizing. */
  const arSessionAliveRef = useRef(false);
  // Ref so handleAutoSubmit can call handleVoiceCommand without circular dep
  const handleVoiceCommandRef = useRef<(command: string, photoPath: string) => Promise<void>>(async () => { });
  // Ref so handleAutoSubmit (stable [] deps) can check screen reader state
  const screenReaderEnabledRef = useRef(false);
  // handleVoiceCommand and handleAutoSubmit are []-memoized and read
  // everything through refs, so the menu state needs mirrors too.
  const pendingActionRef = useRef<MenuActionId | null>(null);
  const lastAnswerRef = useRef<string | null>(null);

  // ── Turn watchdog ──────────────────────────────────────────────────────────
  // `isProcessingRef` and `isCapturingPhotoRef` gate ALL user input: while
  // either is true every tap and every auto-submit returns early. They are
  // cleared in `finally` blocks, which is correct right up until an `await`
  // never settles — then the `finally` never runs, the latch stays true, and
  // the app is silently deaf until it is force-quit. That is the pilot
  // "unresponsive, closing and reopening fixes it" report, and it showed up in
  // scene description and navigation alike because many different awaits can
  // strand.
  //
  // Individual fixes (bounded native calls, per-utterance TTS resolvers, the
  // native ARKit watchdogs) each remove one cause. This is the backstop that
  // covers the ones nobody has found yet: if a turn holds the input gate with
  // no forward progress for long enough, it is unwound and the app is handed
  // back to the user, out loud.
  const isNavigationRef = useRef(false);
  const isReachingRef = useRef(false);
  // Seeded with "now", not 0: a turn that gates within the first watchdog tick
  // would otherwise measure its staleness against the epoch and be recovered
  // instantly.
  const lastTurnProgressAtRef = useRef(Date.now());
  const turnWatchdogRecoveringRef = useRef(false);

  useEffect(() => { isNavigationRef.current = isNavigation; }, [isNavigation]);
  useEffect(() => { isReachingRef.current = isReaching; }, [isReaching]);

  /**
   * Record forward progress on the current turn.
   *
   * Called at every step that proves the pipeline is still moving. The
   * watchdog measures silence since the last call, not total turn duration,
   * so a genuinely slow-but-working turn is never interrupted.
   */
  const markTurnProgress = useCallback((label: string) => {
    lastTurnProgressAtRef.current = Date.now();
    if (__DEV__) console.log(`⏳ [turn] ${label}`);
  }, []);

  // handleAutoSubmit is intentionally []-memoized and reads everything through
  // refs, so it needs one for this too.
  const markTurnProgressRef = useRef(markTurnProgress);
  useEffect(() => { markTurnProgressRef.current = markTurnProgress; }, [markTurnProgress]);

  /**
   * Drop every latch that gates user input. Synchronous and await-free by
   * design — this must be safe to call from a wedged state, so it may never
   * depend on a native module answering.
   *
   * Deliberately covers the loop-ownership flags too. They are not input
   * gates themselves, but a loop flag left set makes the *next* turn refuse to
   * start its loop, which reads to the user as the same silent unresponsiveness.
   */
  const releaseInputGates = useCallback((reason: string) => {
    console.log(`🔓 Releasing input gates: ${reason}`);

    // Primary input gates.
    isProcessingRef.current = false;
    isCapturingPhotoRef.current = false;
    isCapturingRef.current = false;
    finalTranscriptRef.current = '';

    // Loop ownership.
    isContinuousModeRunning.current = false;
    isNavigationLoopRunning.current = false;
    continuousBackendInFlightRef.current = false;
    continuousTtsSpeakingRef.current = false;
    continuousSpeechDrainingRef.current = false;

    // Smart-guidance / tracker bookkeeping.
    smartGuidanceActiveRef.current = false;
    smartGuidanceResumeMainRef.current = false;
    smartGuidanceSeededRef.current = false;
    reacquiringRef.current = false;
    rtabIsSendingRef.current = false;

    lastTurnProgressAtRef.current = Date.now();
  }, []);

  // ── Animation ──────────────────────────────────────────────────────────────
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

  // ── Bug 2 fix: Debounced accessibility label ──────────────────────────────
  // When VoiceOver is on, rapid state changes (Ready→Listening→Thinking→Speaking)
  // cause VoiceOver to re-read the label each time, resetting the double-tap
  // gesture. We debounce label updates so VoiceOver only sees the label AFTER
  // the state has been stable for 300ms.
  const [debouncedLabel, setDebouncedLabel] = useState('');
  const labelTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // ── Debug native modules on mount ──────────────────────────────────────────
  useEffect(() => {
    const { ReachingModule } = NativeModules;
    console.log('🔍 NativeModules keys:', Object.keys(NativeModules));
    console.log('🔍 ReachingModule:', ReachingModule);
    console.log('🔍 ReachingModule.startReaching:', ReachingModule?.startReaching);
  }, []);

  // ── Session / config log ───────────────────────────────────────────────────
  useEffect(() => {
    debugLogger.init(); // Install console interceptors for debug overlay
    console.log('🚀 CyberSight App Started');
    console.log('🆔 Session ID:', getSessionId());
    console.log('🔄 Navigation loop enabled:', NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP);
  }, []);

  // ── Pre-warm TTS ───────────────────────────────────────────────────────────
  useEffect(() => {
    const timer = setTimeout(async () => {
      try {
        await speachesSentenceChunker.synthesizeSpeechChunked('');
        console.log('✅ TTS pre-warmed');
      } catch (e) {
        console.warn('⚠️ TTS pre-warm failed (non-critical):', e);
      }
    }, 1000);
    return () => clearTimeout(timer);
  }, []);

  // ── Menu-state mirrors ─────────────────────────────────────────────────
  useEffect(() => { pendingActionRef.current = pendingAction; }, [pendingAction]);
  useEffect(() => { lastAnswerRef.current = lastAnswer; }, [lastAnswer]);

  // ── Accessibility ──────────────────────────────────────────────────────────
  //
  // Screen-reader state is now published to three places, not one:
  //   • React state / ref, as before, for render and gating decisions;
  //   • Announcer, which switches to queued announcements so speech never
  //     interrupts VoiceOver or eats the user's next double-tap;
  //   • soundEffects, which switches the audio session from exclusive to
  //     mixable so sound cues can play *alongside* VoiceOver rather than
  //     being suppressed.
  //
  // All three must move together. A VoiceOver toggle mid-session that updated
  // only some of them would leave the app in the state this work exists to
  // remove: a blind user with the cues turned off.
  const applyScreenReaderState = useCallback((enabled: boolean) => {
    setScreenReaderEnabled(enabled);
    screenReaderEnabledRef.current = enabled;
    Announcer.setScreenReaderEnabled(enabled);
    setScreenReaderMode(enabled);
  }, []);

  useEffect(() => {
    Announcer.initialize();

    (async () => {
      try {
        const [sr, rm] = await Promise.all([
          AccessibilityInfo.isScreenReaderEnabled(),
          AccessibilityInfo.isReduceMotionEnabled(),
        ]);
        applyScreenReaderState(sr);
        setReduceMotionEnabled(rm);
        // NOTE: Do NOT announce here — VoiceOver will read the focused
        // element's accessibilityLabel automatically. A programmatic
        // announcement on top of that is the double-speech the Announcer's
        // `duplicatesFocusedLabel` option exists to suppress.
      } catch (e) { console.error('❌ Accessibility check:', e); }
    })();

    const srSub = AccessibilityInfo.addEventListener('screenReaderChanged', (enabled: boolean) => {
      applyScreenReaderState(enabled);
    });
    const rmSub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotionEnabled);
    return () => { srSub?.remove(); rmSub?.remove(); Announcer.teardown(); };
  }, [applyScreenReaderState]);

  // ── Sound cue preferences ──────────────────────────────────────────────
  useEffect(() => {
    earcons.setHapticsEnabled(settings.soundCues);
    earcons.setWearablesMode(settings.useWearablesCamera || !settings.soundCues);
  }, [settings.soundCues, settings.useWearablesCamera]);

  // ── Sound Check ──────────────────────────────────────────────────────────
  useEffect(() => {
    // Set wearables mode BEFORE loading sounds so the category isn't set
    // to Playback when glasses are connected (would corrupt BT-HFP session)
    setWearablesMode(settings.useWearablesCamera);
    initSounds().then(() => {
      console.log('✅ [App] Sound effects loaded');
    }).catch((err) => {
      console.error('❌ [App] Sound load failed:', err);
    });
  }, []);

  // ── Android permissions ────────────────────────────────────────────────────
  useEffect(() => {
    if (Platform.OS === 'android') {
      PermissionsAndroid.requestMultiple([
        PermissionsAndroid.PERMISSIONS.RECORD_AUDIO,
        PermissionsAndroid.PERMISSIONS.CAMERA,
      ]).then(results => {
        const ok =
          results['android.permission.RECORD_AUDIO'] === 'granted' &&
          results['android.permission.CAMERA'] === 'granted';
        if (!ok) Alert.alert('Permissions Required', 'Please enable camera and microphone permissions.');
      }).catch(e => console.warn('Permission error:', e));
    }
  }, []);

  useEffect(() => {
    if (settings.useWearablesCamera) {
      if (!hasMicPermission) requestMicPermission();
      return;
    }

    if (!hasCameraPermission) requestCameraPermission();
    if (!hasMicPermission) requestMicPermission();
  }, [hasCameraPermission, hasMicPermission, requestCameraPermission, requestMicPermission, settings.useWearablesCamera]);

  // Auto-prewarm wearables on app start when toggle is already ON.
  useEffect(() => {
    if (!settings.useWearablesCamera || Platform.OS !== 'ios') {
      wearablesPrewarmAttemptedRef.current = false;
      return;
    }
    if (wearablesPrewarmAttemptedRef.current) return;

    let sub: { remove: () => void } | null = null;
    let cancelled = false;
    let cancelWait: (() => void) | null = null;

    const wait = (delayMs: number) =>
      new Promise<void>((resolve) => {
        const timeoutId = setTimeout(() => {
          cancelWait = null;
          resolve();
        }, delayMs);
        cancelWait = () => {
          clearTimeout(timeoutId);
          cancelWait = null;
          resolve();
        };
      });

    const runPrewarmWithRetry = async () => {
      wearablesPrewarmAttemptedRef.current = true;

      for (let i = 0; i < WEARABLES_PREWARM_RETRY_DELAYS_MS.length; i += 1) {
        await wait(WEARABLES_PREWARM_RETRY_DELAYS_MS[i]);
        if (cancelled || !settingsRef.current.useWearablesCamera) return;

        try {
          await wearablesCamera.startRegistration();
          await wearablesCamera.preWarm();
          console.log(`[Wearables] Auto-prewarm connected on attempt ${i + 1}`);
          return;
        } catch (error) {
          console.warn(
            `[Wearables] Auto-prewarm attempt ${i + 1}/${WEARABLES_PREWARM_RETRY_DELAYS_MS.length} failed:`,
            error,
          );
        }
      }

      console.warn('[Wearables] Auto-prewarm exhausted retries. Keeping glasses mode enabled so capture or the settings toggle can retry.');
    };

    if (AppState.currentState === 'active') {
      runPrewarmWithRetry().catch((error) => {
        console.warn('[Wearables] Auto-prewarm failed:', error);
      });
    } else {
      sub = AppState.addEventListener('change', (state) => {
        if (state === 'active' && !wearablesPrewarmAttemptedRef.current) {
          runPrewarmWithRetry().catch((error) => {
            console.warn('[Wearables] Auto-prewarm failed:', error);
          });
          sub?.remove();
        }
      });
    }

    return () => {
      cancelled = true;
      cancelWait?.();
      sub?.remove();
    };
  }, [settings.useWearablesCamera]);

  // Keep a short branded startup loader visible so users can see the animated logo.
  useEffect(() => {
    const timer = setTimeout(() => {
      setShowStartupLoader(false);
    }, STARTUP_LOADER_MIN_MS);

    return () => clearTimeout(timer);
  }, []);

  // ============================================================================
  // Camera capture helper
  // ============================================================================
  const isWearablesCaptureError = (err: any): boolean => {
    // The native WearablesCameraModule rejects with code "CAPTURE",
    // "PREWARM", or "PERMISSION" — and only when wearables is the source.
    // We also gate on the live setting to be safe in case error shapes drift.
    if (!settingsRef.current.useWearablesCamera) return false;
    const msg = String(err?.message || err || '').toLowerCase();
    return (
      err?.code === 'CAPTURE' ||
      err?.code === 'PREWARM' ||
      err?.code === 'PERMISSION' ||
      msg.includes('stream did not reach streaming state') ||
      msg.includes('device session stopped') ||
      msg.includes('activitymanagererror') ||
      msg.includes('internalerror') ||
      msg.includes('glasses') ||
      msg.includes('wearables') ||
      msg.includes('eligible device')
    );
  };

  const speakWearablesError = async (err: any): Promise<void> => {
    // Pull the most useful sentence out of the native error message.
    // Native error messages are written for end users (we authored them
    // in WearablesCameraModule.swift), so we can speak them verbatim.
    const raw = String(err?.message || '').trim();
    const fallback =
      'The glasses camera did not respond. Please toggle glasses camera off and on, ' +
      'or restart the Meta AI app and try again.';
    const spoken = raw && raw.length < 200 ? raw : fallback;

    // Unconditional: this is a hard failure, and the user who cannot see the
    // "glasses disconnected" state on screen is the one who most needs to hear
    // that something broke rather than that nothing happened.
    await earcons.playAndWait('error');
    Announcer.announceStatus(spoken);
    if (screenReaderEnabledRef.current) {
      return;
    }
    await speachesSentenceChunker.synthesizeSpeechChunked(spoken);
  };
  // ────────────────────────────────────────────────────────────────────────
  // VoiceOver-aware announcement helper.
  //
  // When VoiceOver is ON, the button's accessibilityLabel is automatically
  // read aloud on every state change (Ready → Listening → Thinking → ...).
  // Calling Announcer.announceStatus() with text that
  // duplicates the label produces two simultaneous utterances → user hears
  // double voice / echo / cut-off.
  //
  // More damaging: every redundant announcement also restarts VoiceOver's
  // announcement queue, which CONSUMES the user's next double-tap gesture
  // (VoiceOver uses the tap to dismiss the announcement instead of routing
  // to handleScreenTap). That's why VoiceOver users need many taps to act.
  //
  // Use this helper everywhere the announcement duplicates the label.
  // For genuinely-new info (errors, guidance text) use Announcer directly —
  // VoiceOver SHOULD speak those, and Announcer now queues them so they no
  // longer reset VoiceOver's queue or consume the next gesture.
  //
  // Both helpers now delegate rather than branching locally, so there is a
  // single output channel with a single set of rules. `duplicatesFocusedLabel`
  // is precisely what they were expressing by hand.
  // ────────────────────────────────────────────────────────────────────────
  const announceIfNoVoiceOver = useCallback((message: string) => {
    Announcer.announce(message, { duplicatesFocusedLabel: true });
  }, []);

  const announceTapToStart = useCallback((prefix: string) => {
    const suffix = 'Tap to speak.';
    const trimmedPrefix = prefix.trim();
    Announcer.announce(trimmedPrefix ? `${trimmedPrefix} ${suffix}` : suffix, {
      duplicatesFocusedLabel: true,
    });
  }, []);

  // ────────────────────────────────────────────────────────────────────────
  // Posture gating (orientation + proximity)
  // ────────────────────────────────────────────────────────────────────────
  const getPostureStatus = useCallback(() => {
    if (settingsRef.current.useWearablesCamera) {
      return {
        ok: true,
        isNear: false,
        isStraight: true,
        hasSignal: false,
        tiltFromUprightDegrees: 0,
        maxForwardTiltDegrees,
      };
    }

    const hasOrientation = orientationAvailableRef.current;
    const hasProximity = proximityAvailableRef.current;

    if (!hasOrientation && !hasProximity) {
      return {
        ok: true,
        isNear: false,
        isStraight: true,
        hasSignal: false,
        tiltFromUprightDegrees: 0,
        maxForwardTiltDegrees,
      };
    }

    const isNear = hasProximity ? isNearRef.current : false;
    const isStraight = hasOrientation ? isStraightRef.current : true;
    const tiltFromUprightDegrees = hasOrientation
      ? orientationSnapshotRef.current.tiltFromUprightDegrees
      : 0;
    const ok = !isNear && isStraight;

    return {
      ok,
      isNear,
      isStraight,
      hasSignal: true,
      tiltFromUprightDegrees,
      maxForwardTiltDegrees,
    };
  }, []);

  const buildPostureMessage = useCallback((status: {
    isNear: boolean;
    isStraight: boolean;
  }): string => {
    if (status.isNear && !status.isStraight) {
      return 'Move the phone away from your face and hold it upright so the camera sees forward.';
    }
    if (status.isNear) {
      return 'Move the phone away from your face and hold it upright so the camera sees forward.';
    }
    if (!status.isStraight) {
      return 'Hold the phone upright so the camera sees forward.';
    }
    return '';
  }, []);

  const maybeAnnouncePosture = useCallback(async (
    context: 'capture' | 'continuous',
    options?: { force?: boolean },
  ) => {
    const status = getPostureStatus();
    if (status.ok) return false;

    const now = Date.now();
    const postureDetail =
      `context=${context} near=${status.isNear} straight=${status.isStraight} ` +
      `tilt=${status.tiltFromUprightDegrees.toFixed(1)}deg max=${status.maxForwardTiltDegrees}deg`;

    if (now - lastPostureLogRef.current >= POSTURE_LOG_THROTTLE_MS) {
      console.warn(`📐 [Posture] Blocking ${context}: ${postureDetail}`);
      debugLogger.logAPI('📐 Posture gate blocked capture', postureDetail);
      lastPostureLogRef.current = now;
    }

    if (!options?.force && now - lastPostureWarningRef.current < POSTURE_WARNING_COOLDOWN_MS) return false;

    const message = buildPostureMessage(status);
    if (!message) return false;

    lastPostureWarningRef.current = now;

    earcons.play('error');
    Announcer.announceStatus(message);

    if (!screenReaderEnabledRef.current) {
      if (context === 'continuous') {
        const queued = enqueueContinuousSpeechRef.current(message, {
          source: 'posture',
          allowPreempt: true,
        });
        console.log(`📐 [Posture] Warning ${queued ? 'queued' : 'coalesced'}: ${postureDetail}`);
      } else {
        try {
          await speachesSentenceChunker.synthesizeSpeechChunked(message);
        } catch (e: any) {
          if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
            console.warn('⚠️ Posture TTS error (non-fatal):', e?.message || e);
          }
        }
      }
    }

    return true;
  }, [buildPostureMessage, getPostureStatus]);

  const waitForGoodPosture = useCallback(async (context: 'capture' | 'continuous'): Promise<boolean> => {
    const status = getPostureStatus();
    if (status.ok) return true;

    await maybeAnnouncePosture(context);

    if (context === 'continuous') {
      return false;
    }

    const start = Date.now();
    while (Date.now() - start < POSTURE_MAX_WAIT_MS) {
      await new Promise<void>(resolve => setTimeout(() => resolve(), POSTURE_POLL_INTERVAL_MS));
      if (getPostureStatus().ok) return true;
    }

    if (getPostureStatus().ok) return true;

    // The capture is being abandoned and every caller drops straight to
    // "Ready. Tap to speak." The warning above is throttled to 6s, which is
    // shorter than this wait — so a second attempt inside that window said
    // nothing at all, and the user's query vanished with no explanation.
    // Force the reason on the way out; the throttle still covers repeats
    // during the wait itself.
    await maybeAnnouncePosture(context, { force: true });
    return false;
  }, [getPostureStatus, maybeAnnouncePosture]);

  // Keep a stable ref for callbacks that are intentionally []-memoized.
  const waitForGoodPostureRef = useRef(waitForGoodPosture);
  useEffect(() => {
    waitForGoodPostureRef.current = waitForGoodPosture;
  }, [waitForGoodPosture]);

  // ── Frame capture timestamps ──────────────────────────────────────────────
  // Melody's tracker differences the frame time against the orientation
  // sample time, so the stamp has to belong to the frame rather than to the
  // moment we happen to send it: the loop routinely posts a PREFETCHED photo
  // captured one or more cycles earlier, and stamping at send time would
  // report that frame as seconds fresher than it is. Keyed by photo URI so
  // the stamp travels with the image through the prefetch queue.
  const frameCaptureTsRef = useRef<Map<string, number>>(new Map());

  const rememberFrameCaptureTs = useCallback((uri: string, tsSeconds: number) => {
    if (!uri) return;
    const map = frameCaptureTsRef.current;
    map.set(uri, tsSeconds);
    // Only the in-flight and prefetched frames are ever looked up; the rest
    // are dead weight. Insertion order makes the oldest key the first one.
    while (map.size > 12) {
      const oldest = map.keys().next().value;
      if (oldest === undefined) break;
      map.delete(oldest);
    }
  }, []);

  // Non-destructive: the size cap already bounds the map, and consuming the
  // entry would make a re-sent frame report no timestamp at all.
  const getFrameCaptureTs = useCallback((uri: string): number | null => {
    if (!uri) return null;
    return frameCaptureTsRef.current.get(uri) ?? null;
  }, []);

  const reactivateCameraAndCapture = useCallback(async (options?: {
    enableShutterSound?: boolean;
    busyStrategy?: 'wait' | 'skip' | 'wait-new';
  }): Promise<string> => {
    if (isCapturingRef.current) {
      if (options?.busyStrategy === 'skip') {
        console.log('📷 Capture already in progress, skipping fresh-frame request...');
        return '';
      }

      if (options?.busyStrategy === 'wait-new') {
        if (activeCapturePromiseRef.current) {
          console.log('📷 Capture already in progress, waiting before fresh-frame request...');
          try {
            await activeCapturePromiseRef.current;
          } catch {
            // The follow-up capture below is the one the caller will use.
          }
        } else {
          await new Promise<void>(resolve => setTimeout(() => resolve(), 100));
        }

        if (isCapturingRef.current) {
          console.log('📷 Capture still in progress after wait; skipping fresh-frame request...');
          return '';
        }
      } else if (activeCapturePromiseRef.current) {
        console.log('📷 Capture already in progress, waiting for fresh frame...');
        return activeCapturePromiseRef.current;
      }

      if (isCapturingRef.current) {
        console.log('📷 Capture already in progress, no active promise to await.');
        return '';
      }
    }
    isCapturingRef.current = true;

    const captureBody = (async (): Promise<string> => {
      try {
        // An AR session left alive for the next navigation leg is holding the
        // camera. Whatever this capture is for, it is not that leg, so let the
        // session go before asking for the device — two owners means one of
        // them silently gets nothing, and it is always this one.
        if (arSessionAliveRef.current) {
          console.log('📷 Releasing the warm AR session before capture');
          earcons.setNativeSessionActive(false);
          arSessionAliveRef.current = false;
          try { await ARKitNavigationBridge.stopNavigation(); } catch { }
        }

        console.log('📷 Reactivating camera for capture...');
        setIsCameraActive(true);

        const useSystemShutterSound =
          options?.enableShutterSound === true &&
          Platform.OS === 'ios' &&
          !settingsRef.current.useWearablesCamera;

        if (settingsRef.current.useWearablesCamera) {
          try {
            const wearablesPhoto = await wearablesCamera.capturePhoto();
            // Glasses frames travel over Bluetooth before they land here, so
            // this stamp trails the shutter by more than the phone camera's
            // does. Still the closest instant we can observe.
            rememberFrameCaptureTs(wearablesPhoto, Date.now() / 1000);
            lastImageDimensions.current = { width: 0, height: 0 };
            lastCameraIntrinsics.current = undefined;
            return wearablesPhoto;
          } catch (error) {
            console.error('❌ Wearables capture failed:', error);
            throw error;
          }
        }

        await new Promise<void>(resolve => setTimeout(() => resolve(), CAMERA_REACTIVATION_DELAY_MS));

        if (!cameraRef.current) {
          console.error('❌ Camera ref not available after reactivation');
          return '';
        }

        try {
          if (useSystemShutterSound) {
            await configurePlaybackSession(!settingsRef.current.useWearablesCamera);
            const { ReachingModule } = NativeModules;
            if (ReachingModule?.playSystemShutter) {
              try {
                await ReachingModule.playSystemShutter();
              } catch (e: any) {
                console.warn('⚠️ System shutter sound failed:', e?.message || e);
              }
            } else {
              console.warn('⚠️ System shutter unavailable — rebuild iOS app');
            }
          }
          const photo = await cameraRef.current.takePhoto({
            enableShutterSound: useSystemShutterSound,
            flash: 'off',
          });
          // Stamped before the orientation fix-up, which rewrites the file and
          // would otherwise add its own latency to the frame's reported age.
          const capturedAtSeconds = Date.now() / 1000;
          const fixedImage = await fixImageOrientation(photo.path);
          rememberFrameCaptureTs(fixedImage.uri, capturedAtSeconds);
          lastImageDimensions.current = {
            width: fixedImage.width || 0,
            height: fixedImage.height || 0,
          };
          lastCameraIntrinsics.current = cameraIntrinsicsForUploadedImage(
            (photo as any).cameraCalibrationData,
            lastImageDimensions.current,
          );
          if (lastCameraIntrinsics.current) {
            console.log(
              '📐 Camera intrinsics:',
              `fx=${lastCameraIntrinsics.current.fx.toFixed(1)}`,
              `fy=${lastCameraIntrinsics.current.fy.toFixed(1)}`,
              `cx=${lastCameraIntrinsics.current.cx.toFixed(1)}`,
              `cy=${lastCameraIntrinsics.current.cy.toFixed(1)}`,
            );
          }
          console.log('✅ Photo captured & fixed:', fixedImage.uri,
            `(${fixedImage.width}×${fixedImage.height})`);
          return fixedImage.uri;
        } catch (error) {
          console.error('❌ Photo capture failed, retrying:', error);
          await new Promise<void>(resolve => setTimeout(() => resolve(), 500));
          try {
            if (useSystemShutterSound) {
              await configurePlaybackSession(!settingsRef.current.useWearablesCamera);
              const { ReachingModule } = NativeModules;
              if (ReachingModule?.playSystemShutter) {
                try {
                  await ReachingModule.playSystemShutter();
                } catch (e: any) {
                  console.warn('⚠️ System shutter sound failed (retry):', e?.message || e);
                }
              } else {
                console.warn('⚠️ System shutter unavailable (retry) — rebuild iOS app');
              }
            }
            const retry = await cameraRef.current.takePhoto({
              enableShutterSound: useSystemShutterSound,
            });
            rememberFrameCaptureTs(retry.path, Date.now() / 1000);
            lastCameraIntrinsics.current = cameraIntrinsicsForUploadedImage(
              (retry as any).cameraCalibrationData,
              { width: retry.width, height: retry.height },
            );
            return retry.path;
          } catch (e) {
            console.error('❌ Retry also failed:', e);
            return '';
          }
        }
      } finally {
        // Normal completion clears here; the outer `.finally` below is what
        // covers the case where this body never completes at all.
        isCapturingRef.current = false;
        activeCapturePromiseRef.current = null;
      }
    })();

    // Bound the capture, and do the bookkeeping outside the body.
    //
    // Neither VisionCamera's takePhoto nor the glasses' Bluetooth capture has
    // a timeout of its own, and either can be issued at a moment when it will
    // never call back — mid session-reconfiguration, or while the glasses link
    // is renegotiating. The cleanup used to live in the body's own `finally`,
    // so a capture that never returned left `activeCapturePromiseRef` pointing
    // at a dead promise forever — and the reuse path above hands that same
    // dead promise to every subsequent capture, so the camera stayed broken
    // for the rest of the process even after the turn that started it moved on.
    //
    // Racing here means the cleanup runs on time no matter what the body does.
    const capturePromise = withTimeout(
      captureBody,
      WATCHDOG_TIMEOUTS.CAMERA_CAPTURE,
      'reactivateCameraAndCapture',
    ).finally(() => {
      isCapturingRef.current = false;
      activeCapturePromiseRef.current = null;
    });

    activeCapturePromiseRef.current = capturePromise;
    return capturePromise;
  }, [rememberFrameCaptureTs]);
  const reactivateCameraAndCaptureRef = useRef(reactivateCameraAndCapture);
  useEffect(() => {
    reactivateCameraAndCaptureRef.current = reactivateCameraAndCapture;
  }, [reactivateCameraAndCapture]);

  const toDataUrl = (value: string): string => {
    if (!value) return '';
    return value.startsWith('data:') ? value : `data:image/jpeg;base64,${value}`;
  };

  const readImageAsDataUrl = async (uri: string): Promise<string | null> => {
    if (!uri) return null;
    const path = uri.startsWith('file://') ? uri.replace('file://', '') : uri;
    try {
      const base64 = await RNFS.readFile(path, 'base64');
      return toDataUrl(base64);
    } catch (e) {
      console.warn('⚠️ Failed to read image for smart guidance:', e);
      return null;
    }
  };

  const normalizeTextValue = (value?: string | null): string => {
    if (!value) return '';
    let s = String(value).trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.slice(1, -1).trim();
    }
    const lower = s.toLowerCase();
    if (lower === 'null' || lower === 'undefined' || lower === 'none' || lower === '') {
      return '';
    }
    return s;
  };

  const bboxToString = (bbox: any): string => {
    if (!bbox) return '';
    if (typeof bbox === 'string') {
      const trimmed = bbox.trim();
      const lower = trimmed.toLowerCase();
      if (lower === 'none' || lower === 'null' || lower === 'undefined') return '';
      return trimmed;
    }
    if (Array.isArray(bbox) && bbox.length === 4) {
      const parsed = bbox.map((v) => Number(v));
      if (parsed.some(Number.isNaN)) return '';
      return `[${parsed.join(',')}]`;
    }
    if (typeof bbox === 'object') {
      const x = Number(bbox.x);
      const y = Number(bbox.y);
      const w = Number(bbox.width);
      const h = Number(bbox.height);
      if (![x, y, w, h].some(Number.isNaN)) {
        return `[${x},${y},${x + w},${y + h}]`;
      }
    }
    return '';
  };

  const bboxToArray = (bbox: any): [number, number, number, number] | undefined => {
    if (!bbox) return undefined;
    if (Array.isArray(bbox) && bbox.length === 4) {
      const parsed = bbox.map((v) => Number(v));
      if (parsed.some(Number.isNaN)) return undefined;
      return parsed as [number, number, number, number];
    }
    if (typeof bbox === 'string') {
      const lower = bbox.trim().toLowerCase();
      if (lower === 'none' || lower === 'null' || lower === 'undefined') return undefined;
      const cleaned = bbox.replace(/[\[\]]/g, '');
      const parts = cleaned.split(',').map((v) => Number(v.trim()));
      if (parts.length === 4 && !parts.some(Number.isNaN)) {
        return parts as [number, number, number, number];
      }
    }
    if (typeof bbox === 'object') {
      const x = Number(bbox.x);
      const y = Number(bbox.y);
      const w = Number(bbox.width);
      const h = Number(bbox.height);
      if (![x, y, w, h].some(Number.isNaN)) {
        return [x, y, x + w, y + h];
      }
    }
    return undefined;
  };

  const rememberRtabSubmittedFrame = useCallback((photoPath: string) => {
    if (!photoPath || rtabSubmittedFrameUrisRef.current.has(photoPath)) return;

    rtabSubmittedFrameUrisRef.current.add(photoPath);
    rtabSubmittedFrameQueueRef.current.push(photoPath);

    while (rtabSubmittedFrameQueueRef.current.length > 120) {
      const oldest = rtabSubmittedFrameQueueRef.current.shift();
      if (oldest) {
        rtabSubmittedFrameUrisRef.current.delete(oldest);
      }
    }
  }, []);

  const hasSubmittedRtabFrame = useCallback((photoPath: string) => {
    return !!photoPath && rtabSubmittedFrameUrisRef.current.has(photoPath);
  }, []);

  // ============================================================================
  // Standard tracker sensors — phone orientation + HRTF spatial audio
  // ============================================================================
  //
  // Both back Melody's tracker specifically: orientation rides out with each
  // frame, and the sonification block in the response drives the spatial cue.
  // Neither is used by the on-device ARKit reaching pipeline, which does its
  // own sensing and its own audio in ReachingViewController.

  const startTrackerSensors = useCallback(async () => {
    if (!trackerSensorsStartedRef.current) {
      trackerSensorsStartedRef.current = true;
      await startDeviceAttitude({ referenceFrame: 'gravity' });
    }

    // The audio engine is retried separately from the orientation sensor. It
    // is the one that realistically fails on a first attempt — TTS and the
    // wake-word recognizer contend for the same audio session — and a single
    // transient failure must not silence the cue for the rest of the session.
    // Bounded so a genuinely unavailable engine doesn't retry every cycle.
    if (spatialAudioReadyRef.current || spatialAudioAttemptsRef.current >= 3) return;

    spatialAudioAttemptsRef.current += 1;
    const started = await startSpatialAudio({
      // A live glasses camera stream owns the Bluetooth radio on HFP;
      // re-categorising the session would tear the stream down.
      manageAudioSession: !settingsRef.current.useWearablesCamera,
    });
    spatialAudioReadyRef.current = started;

    if (!started && spatialAudioAttemptsRef.current >= 3) {
      console.warn('[SpatialAudio] giving up after 3 attempts — spoken guidance only');
    }
  }, []);

  const stopTrackerSensors = useCallback(async () => {
    if (!trackerSensorsStartedRef.current) return;
    trackerSensorsStartedRef.current = false;
    spatialAudioReadyRef.current = false;
    spatialAudioAttemptsRef.current = 0;
    await Promise.all([stopDeviceAttitude(), stopSpatialAudio()]);
  }, []);

  const stopRtabFeed = useCallback(() => {
    if (rtabFeedIntervalRef.current) {
      clearInterval(rtabFeedIntervalRef.current);
      rtabFeedIntervalRef.current = null;
    }
    rtabIsSendingRef.current = false;
    rtabLastSentFrameRef.current = '';
    rtabFrameSeqRef.current = 0;
  }, []);

  const startRtabFeed = useCallback(() => {
    if (rtabFeedIntervalRef.current) return;

    rtabFeedIntervalRef.current = setInterval(async () => {
      if (!isContinuousModeRunning.current || getCurrentMode() !== 'navigation') return;
      if (rtabIsSendingRef.current) return;

      const objectName = rtabLastObjectRef.current;
      if (!objectName) return;

      rtabIsSendingRef.current = true;
      try {
        // Capture a NEW frame here so RTAB gets a fresh image every interval,
        // rather than sending the exact same image multiple times.
        const photoPath = await reactivateCameraAndCapture({
          enableShutterSound: false,
          busyStrategy: 'skip',
        });
        if (photoPath) {
          if (hasSubmittedRtabFrame(photoPath)) {
            console.warn('[Rtab] Skipping frame already submitted to RTAB:', photoPath);
            return;
          }

          if (photoPath === rtabLastSentFrameRef.current) {
            console.warn('[Rtab] Skipping duplicate frame URI:', photoPath);
            return;
          }

          const capturedAtMs = Date.now();
          const frameId = `rtab-${capturedAtMs}-${++rtabFrameSeqRef.current}`;
          rtabLastSentFrameRef.current = photoPath;
          rememberRtabSubmittedFrame(photoPath);
          await sendToRtabGuidance({
            imageUri: photoPath,
            objectName,
            frameId,
            capturedAtMs,
          });
        }
      } catch (err: any) {
        console.warn('[Rtab] Guidance send failed:', err?.message || err);
      } finally {
        rtabIsSendingRef.current = false;
      }
    }, RTAB_FEED_INTERVAL_MS);
  }, [hasSubmittedRtabFrame, reactivateCameraAndCapture, rememberRtabSubmittedFrame]);

  const resetContinuousSpeechQueue = useCallback(() => {
    continuousSpeechQueueRef.current = [];
    continuousSpeechCurrentTextRef.current = '';
    continuousSpeechDrainingRef.current = false;
    continuousLastAcceptedSpeechRef.current = null;
  }, []);

  const drainContinuousSpeechQueue = useCallback(async () => {
    if (continuousSpeechDrainingRef.current) return;

    const drainGeneration = continuousTtsGenerationRef.current;
    continuousSpeechDrainingRef.current = true;
    continuousTtsSpeakingRef.current = true;
    setIsSpeaking(true);

    try {
      while (
        continuousTtsGenerationRef.current === drainGeneration &&
        !continuousModeAbortRef.current &&
        !isEmergencyStopped.current
      ) {
        const nextText = continuousSpeechQueueRef.current.shift();
        if (!nextText) break;

        continuousSpeechCurrentTextRef.current = nextText;
        try {
          await speachesSentenceChunker.synthesizeSpeechChunked(nextText);
        } catch (e: any) {
          if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
            console.warn('🔄 [ContinuousMode] Queued TTS error (non-fatal):', e?.message);
          }
        }

        if (
          continuousTtsGenerationRef.current === drainGeneration &&
          continuousBackendInFlightRef.current &&
          isContinuousModeRunning.current &&
          !continuousModeAbortRef.current &&
          !isEmergencyStopped.current &&
          !screenReaderEnabledRef.current &&
          !settingsRef.current.useWearablesCamera
        ) {
          playThinkingStarted();
        }
      }
    } finally {
      if (continuousTtsGenerationRef.current === drainGeneration) {
        continuousSpeechCurrentTextRef.current = '';
        continuousSpeechDrainingRef.current = false;
        continuousTtsSpeakingRef.current = false;
        setIsSpeaking(false);

        if (!isContinuousModeRunning.current) {
          stopLatencyLoop().catch(() => { });
        }
      }
    }
  }, []);

  const enqueueContinuousSpeech = useCallback((
    text: string,
    options?: ContinuousSpeechEnqueueOptions,
  ): boolean => {
    const spoken = (text || '').trim();
    if (
      !spoken ||
      (continuousModeAbortRef.current && options?.ignoreAbort !== true) ||
      isEmergencyStopped.current
    ) {
      return false;
    }

    const source = options?.source || 'backend';
    const force = options?.force === true;
    const nextSignature = buildInstructionSignature(spoken);
    const pending = continuousSpeechQueueRef.current;
    const currentText = continuousSpeechCurrentTextRef.current;
    const currentSignature = currentText ? buildInstructionSignature(currentText) : null;
    const pendingText = pending.length > 0 ? pending[pending.length - 1] : '';
    const pendingSignature = pendingText ? buildInstructionSignature(pendingText) : null;
    const lastAccepted = continuousLastAcceptedSpeechRef.current;
    const now = Date.now();

    const logCoalesced = (reason: string, matchedText?: string) => {
      const detail =
        `source=${source} reason=${reason} intent=${nextSignature.intent} ` +
        `text="${spoken.substring(0, 90)}"` +
        (matchedText ? ` matched="${matchedText.substring(0, 90)}"` : '');
      console.log(`🔇 [ContinuousMode/TTS] Coalesced ${reason}: "${spoken.substring(0, 70)}"`);
      debugLogger.logAPI('🔇 Continuous TTS coalesced', detail);
    };

    if (!force) {
      if (
        continuousSpeechDrainingRef.current &&
        currentSignature &&
        areInstructionsNearDuplicate(nextSignature, currentSignature)
      ) {
        logCoalesced('already-speaking-near-duplicate', currentText);
        return false;
      }

      if (pendingSignature && areInstructionsNearDuplicate(nextSignature, pendingSignature)) {
        logCoalesced('already-pending-near-duplicate', pendingText);
        return false;
      }

      if (
        lastAccepted &&
        now - lastAccepted.acceptedAt < (options?.suppressionMs ?? CONTINUOUS_TTS_REPEAT_SUPPRESSION_MS) &&
        areInstructionsNearDuplicate(nextSignature, lastAccepted.signature)
      ) {
        logCoalesced('recently-accepted-near-duplicate', lastAccepted.text);
        return false;
      }
    }

    const shouldPreempt =
      options?.allowPreempt !== false &&
      continuousSpeechDrainingRef.current &&
      currentSignature &&
      isResponsiveSpeechChange(nextSignature, currentSignature);

    continuousLastAcceptedSpeechRef.current = {
      text: spoken,
      signature: nextSignature,
      acceptedAt: now,
      source,
    };

    if (shouldPreempt) {
      const detail =
        `source=${source} from=${currentSignature?.intent || 'none'} to=${nextSignature.intent} ` +
        `old="${currentText.substring(0, 90)}" new="${spoken.substring(0, 90)}"`;
      console.log(`⚡ [ContinuousMode/TTS] Preempting speech: ${detail}`);
      debugLogger.logAPI('⚡ Continuous TTS preempted current guidance', detail);

      continuousTtsGenerationRef.current++;
      continuousSpeechQueueRef.current = [spoken];
      continuousSpeechCurrentTextRef.current = '';
      continuousSpeechDrainingRef.current = false;
      continuousTtsSpeakingRef.current = false;
      setIsSpeaking(false);
    } else {
      const detail =
        `source=${source} intent=${nextSignature.intent} ` +
        `distance=${nextSignature.distanceMeters?.toFixed(1) || 'n/a'} ` +
        `text="${spoken.substring(0, 90)}"`;
      console.log(`🔊 [ContinuousMode/TTS] Queued (${source}/${nextSignature.intent}): "${spoken.substring(0, 70)}"`);
      debugLogger.logAPI('🔊 Continuous TTS queued', detail);

      // Let the current instruction finish, but collapse any unsaid backlog into
      // the newest backend guidance so speech does not lag behind navigation.
      continuousSpeechQueueRef.current = [spoken];
    }

    drainContinuousSpeechQueue().catch((e: any) => {
      if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
        console.warn('🔄 [ContinuousMode] TTS queue drain failed:', e?.message);
      }
    });
    return true;
  }, [drainContinuousSpeechQueue]);

  enqueueContinuousSpeechRef.current = enqueueContinuousSpeech;

  const waitForContinuousSpeechQueueIdle = useCallback(async (options?: { ignoreAbort?: boolean }) => {
    while (
      continuousSpeechDrainingRef.current &&
      !isEmergencyStopped.current &&
      (options?.ignoreAbort === true || !continuousModeAbortRef.current)
    ) {
      await new Promise<void>(resolve => setTimeout(() => resolve(), 100));
    }
  }, []);

  const speakContinuousSpeechAndWait = useCallback(async (
    text: string,
    options?: { ignoreAbort?: boolean } & ContinuousSpeechEnqueueOptions
  ) => {
    const spoken = (text || '').trim();
    if (!spoken || isEmergencyStopped.current) return;

    if (screenReaderEnabledRef.current) {
      Announcer.announceStatus(spoken);
      const waitMs = Math.min(6500, Math.max(1200, spoken.length * 55));
      await new Promise<void>(resolve => setTimeout(() => resolve(), waitMs));
      return;
    }

    enqueueContinuousSpeech(spoken, options);
    await waitForContinuousSpeechQueueIdle(options);
  }, [enqueueContinuousSpeech, waitForContinuousSpeechQueueIdle]);

  // ============================================================================
  // iOS Reaching helper — shared by both reaching blocks
  // Accepts the full result + image dims, calls ReachingModule, resets state.
  // Returns true if reaching module was invoked.
  // ============================================================================
  const handleiOSReaching = useCallback(async (
    result: any,
    options?: {
      startupSilent?: boolean;
      introSpeechPromise?: Promise<void>;
      /**
       * Bypass the reaching-pipeline preference and run in-device spatial
       * target reaching. Used by the navigation→reaching handoff when a
       * reaching object was explicitly marked on the arrived destination.
       */
      forceSpatialTarget?: boolean;
    }
  ): Promise<boolean> => {
    // ── Resolve user preference ───────────────────────────────────────────
    const pipeline = options?.forceSpatialTarget
      ? 'spatialTarget'
      : resolveReachingPipeline({
        reaching_ios: result.reaching_ios,
        reaching: result.reaching_flag,
      });

    if (pipeline !== 'arkit' && pipeline !== 'spatialTarget') {
      // User prefers standard pipeline or ARKit not available
      console.log(`🎯 [Reaching] Skipping ARKit — pipeline resolved to: ${pipeline}`);
      return false;
    }

    if (pipeline === 'spatialTarget') {
      const targetName =
        normalizeTextValue(result.object) ||
        normalizeTextValue(result.navigation_target) ||
        normalizeTextValue(result.targetName) ||
        rtabLastObjectRef.current ||
        'target';

      console.log('◎ [SpatialTarget] Launching native reaching for:', targetName);
      prewarmDAv2InBackground('spatial target reaching');

      Announcer.announceStatus(strings().reaching.guidingTo(targetName));

      // This is now what the session is about. An arrival handoff reaches this
      // point without ever passing through the orchestrator, so nothing else
      // would record it — and the next "is this the correct object?" would
      // have no subject.
      rtabLastObjectRef.current = targetName;

      setIsCameraActive(false);
      setIsReaching(true);
      await new Promise<void>(resolve => setTimeout(() => resolve(), 500));

      // Same reason as the navigation launch: the reaching screen owns all
      // feedback while it is up, so this layer must not buzz from behind it.
      earcons.setNativeSessionActive(true);
      try {
        const { ReachingModule } = NativeModules;
        if (ReachingModule?.startSpatialTargetReaching) {
          const reachingPromise = ReachingModule.startSpatialTargetReaching({
            targetName,
            routeMapId: normalizeTextValue(result.route_map_id) || undefined,
            routeMapName: normalizeTextValue(result.route_map_name) || undefined,
            targetWorldPosition: result.targetWorldPosition || result.target_world_position,
            sessionId: getSessionId(),
            mode: settingsRef.current.reachingMode,
            startupSilent: options?.startupSilent === true && !screenReaderEnabledRef.current,
            voiceOverEnabled: screenReaderEnabledRef.current,
            ttsRate: settingsRef.current.ttsRate,
            distanceUnit: settingsRef.current.distanceUnit,
          });

          if (options?.introSpeechPromise) {
            try {
              await options.introSpeechPromise;
            } catch (e: any) {
              console.warn('⚠️ [SpatialTarget] Intro TTS ended with warning:', e?.message || e);
            }

            if (ReachingModule?.enableGuidanceAudio) {
              try {
                await ReachingModule.enableGuidanceAudio();
                console.log('🔊 [SpatialTarget] Guidance audio enabled after intro TTS');
              } catch (e: any) {
                console.warn('⚠️ [SpatialTarget] Could not enable guidance audio:', e?.message || e);
              }
            }
          }

          const reachingResult = await reachingPromise;
          earcons.setNativeSessionActive(false);
          console.log('✅ [SpatialTarget] Native result:', reachingResult);

          if (
            (reachingResult?.reason === 'user_confirmed' || reachingResult?.reason === 'user_cancelled') &&
            !screenReaderEnabledRef.current
          ) {
            await playStopReachingSound();
          }

          // Reaching inherited the navigation session at arrival and, when it
          // is still tracking at the end, hands it back instead of pausing it.
          // That is what lets the NEXT destination skip relocalization — the
          // step that took 36.7 s and 39.1 s from a destination in the 25 Aug
          // 2026 lab test, longer than the automation was willing to wait, so
          // the return route was never built at all.
          //
          // It is also still holding the camera, so the RN camera has to stay
          // off until something releases it (see reactivateCameraAndCapture).
          arSessionAliveRef.current = reachingResult?.sessionAlive === true;

          const msg = reachingResult?.reason === 'user_confirmed'
            ? 'Reaching complete.'
            : reachingResult?.success
              ? `${targetName} reached!`
              : reachingResult?.reason === 'spatial_relocalization_timeout'
                ? strings().reaching.relocalizationTimeout
                : strings().reaching.ended;
          Announcer.announceStatus(msg);
        } else {
          console.warn('⚠️ startSpatialTargetReaching not available — native module not linked');
          Announcer.announceCritical(strings().reaching.spatialTargetUnavailable);
        }
      } catch (e: any) {
        console.error('❌ [SpatialTarget] Native module error:', e);
        const code = e?.code || e?.name;
        const message = code === 'TARGET_NOT_IN_MAP'
          ? `${targetName} is not pinned in the saved AR map. Add it as a POI and save the map first.`
          : code === 'MAP_NOT_FOUND'
            ? strings().reaching.mapNotFound
            : strings().reaching.error(e.message || strings().reaching.unknownError);
        Announcer.announceStatus(message);
      }

      earcons.setNativeSessionActive(false);
      resetSessionId();
      setIsReaching(false);
      // A live AR session handed back for the next leg is still on the camera.
      // Turning the RN camera on here would fight it for the device — the same
      // reason the no-reaching-object arrival leaves it off.
      setIsCameraActive(!arSessionAliveRef.current);
      setIsProcessing(false);
      earcons.play('ready');
      announceTapToStart('Ready.');
      return true;
    }

    // ── Parse bbox ────────────────────────────────────────────────────────
    let bbox: number[] | null = null;
    const rawBbox = result.bbox;

    if (rawBbox && rawBbox !== 'none' && rawBbox !== 'null' && rawBbox !== '') {
      if (Array.isArray(rawBbox)) {
        bbox = rawBbox as number[];
      } else if (typeof rawBbox === 'string') {
        try {
          const s = (rawBbox as string).replace(/[\[\]]/g, '');
          bbox = s.split(',').map((v: string) => Number(v.trim()));
          if (bbox.some(isNaN)) { bbox = null; }
        } catch { bbox = null; }
      }
    }

    if (!bbox || bbox.length !== 4) {
      // reaching_ios=true but no valid bbox — guard with isSpeaking so
      // a tap during TTS routes to emergencyStop, NOT startListening (dead-loop fix)
      console.log('⚠️ [ARKit] reaching_ios=true but no valid bbox:', rawBbox);
      setIsSpeaking(true);
      const noBboxMessage = strings().reaching.noPreciseCoordinates(
        result.object || strings().reaching.defaultObjectName,
      );
      if (screenReaderEnabledRef.current) {
        Announcer.announceCritical(noBboxMessage);
        await new Promise<void>(resolve => setTimeout(() => resolve(), 3500));
      } else {
        await speachesSentenceChunker.synthesizeSpeechChunked(noBboxMessage);
      }
      setIsSpeaking(false);                // ← release speaking guard
      // Clean transition to ready (matches the ARKit-success path below)
      setIsCameraActive(true);
      earcons.play('ready');
      announceTapToStart('Ready.');
      return true; // Handled (but without ARKit)
    }

    console.log('🎯 [ARKit] Launching native reaching for:', result.object, 'bbox:', bbox);
    prewarmDAv2InBackground('reaching_ios response');

    Announcer.announceStatus(strings().reaching.guidingTo(result.object || strings().reaching.defaultObjectName),);

    setIsCameraActive(false);
    setIsReaching(true);
    await new Promise<void>(resolve => setTimeout(() => resolve(), 500));

    // The native reaching screen owns feedback while it is up.
    earcons.setNativeSessionActive(true);
    try {
      const { ReachingModule } = NativeModules;
      if (ReachingModule?.startReaching) {
        const acquisitionUrl = settingsRef.current.enableAcquisitionAutoExit
          ? ACQUISITION_URL
          : undefined;
        const reachingPromise = ReachingModule.startReaching({
          bbox,
          object: result.object || 'object',
          sessionId: getSessionId(),
          depth: result.depth,
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          detectionUrl: DETECTION_URL,
          ...(acquisitionUrl ? { acquisitionUrl } : {}),
          mode: settingsRef.current.reachingMode,
          startupSilent: options?.startupSilent === true && !screenReaderEnabledRef.current,
          voiceOverEnabled: screenReaderEnabledRef.current,
          ttsRate: settingsRef.current.ttsRate,
          distanceUnit: settingsRef.current.distanceUnit,
        });

        // Parallel handoff: ARKit session boots silently while intro TTS plays.
        if (options?.introSpeechPromise) {
          try {
            await options.introSpeechPromise;
          } catch (e: any) {
            console.warn('⚠️ [ARKit] Intro TTS ended with warning:', e?.message || e);
          }

          if (ReachingModule?.enableGuidanceAudio) {
            try {
              await ReachingModule.enableGuidanceAudio();
              console.log('🔊 [ARKit] Guidance audio enabled after intro TTS');
            } catch (e: any) {
              console.warn('⚠️ [ARKit] Could not enable guidance audio:', e?.message || e);
            }
          }
        }

        const reachingResult = await reachingPromise;

        console.log('✅ [ARKit] Native result:', reachingResult);

        if (
          (reachingResult?.reason === 'user_confirmed' || reachingResult?.reason === 'user_cancelled') &&
          !screenReaderEnabledRef.current
        ) {
          await playStopReachingSound();
        }

        // Manual exit: reason will be "user_confirmed" or "ar_error"
        const msg = reachingResult?.reason === 'user_confirmed'
          ? 'Reaching complete.'
          : reachingResult?.success
            ? strings().reaching.reached(result.object || strings().reaching.defaultObjectName)
            : strings().reaching.ended;
        Announcer.announceStatus(msg);
      } else {
        console.warn('⚠️ ReachingModule not available — native module not linked');
        Announcer.announceCritical(strings().reaching.moduleUnavailable);
      }
    } catch (e: any) {
      console.error('❌ [ARKit] Native module error:', e);
      Announcer.announceCritical(strings().reaching.error(e.message || strings().reaching.unknownError));
    }

    earcons.setNativeSessionActive(false);
    resetSessionId();
    setIsReaching(false);
    setIsCameraActive(true);
    earcons.play('ready');
    announceTapToStart('Ready.');
    return true;
  }, [announceTapToStart, resolveReachingPipeline]);

  // ============================================================================
  // CONTINUOUS LOOP
  // ============================================================================
  const runContinuousLoop = useCallback(async () => {
    if (!NAVIGATION_CONFIG.ENABLE_NAVIGATION_LOOP) {
      console.log('🔄 [ContinuousMode] Disabled in config');
      return;
    }
    if (isContinuousModeRunning.current) {
      console.log('🔄 [ContinuousMode] Already running');
      return;
    }

    console.log('🔄 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🔄 [ContinuousMode] Starting EVENT-DRIVEN loop');
    console.log('🔄 [ContinuousMode] Pre-fetch:', PREFETCH_CONFIG.ENABLED ? 'ON' : 'OFF');

    isContinuousModeRunning.current = true;
    continuousModeAbortRef.current = false;
    continuousBackendInFlightRef.current = false;
    continuousTtsSpeakingRef.current = false;
    continuousTtsGenerationRef.current++;
    resetContinuousSpeechQueue();
    prefetchedPhotoRef.current = null;
    rtabLastSentFrameRef.current = '';
    rtabSubmittedFrameUrisRef.current.clear();
    rtabSubmittedFrameQueueRef.current = [];
    smartGuidanceSeededRef.current = false;
    reacquiringRef.current = false;
    let cycleCount = 0;

    const currentMode = getCurrentMode();
    // Label change to "Navigating. Tap to stop" / "Reaching ..." conveys this.
    announceIfNoVoiceOver(`${currentMode} started. Tap to stop.`);
    while (!continuousModeAbortRef.current && !isEmergencyStopped.current) {
      const intervalMode = getCurrentMode();
      if (intervalMode !== 'reaching' && smartGuidanceActiveRef.current) {
        smartGuidanceActiveRef.current = false;
        smartGuidanceResumeMainRef.current = false;
        smartGuidanceCacheRef.current = null;
        smartGuidanceSeededRef.current = false;
        reacquiringRef.current = false;
      }

      const fastReachingCycle =
        smartGuidanceActiveRef.current ||
        smartGuidanceResumeMainRef.current ||
        reacquiringRef.current;

      const minIntervalOverride = fastReachingCycle
        ? SMART_GUIDANCE_MIN_CYCLE_MS
        : Math.max(NAVIGATION_CONFIG.MIN_REQUEST_INTERVAL_MS, getCurrentLoopDelay());
      const rateLimitDelay = getContinuousModeRateLimitDelay(minIntervalOverride);
      if (rateLimitDelay > 0) {
        console.log(`🔄 [ContinuousMode] Rate-limit cooldown: ${rateLimitDelay}ms`);
        await new Promise<void>(resolve => setTimeout(resolve, rateLimitDelay));
        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;
      }

      if (shouldPreventInfiniteLoop()) {
        Announcer.announceCritical(strings().speech.stoppedTimeLimit);
        break;
      }

      cycleCount++;
      const cycleStart = Date.now();
      console.log(`\n🔄 ═══ CYCLE #${cycleCount} START ═══`);

      try {
        incrementContinuousMode();
        const loopMode = getCurrentMode();

        // ── Posture gate (skip cycles when phone is near face / tilted) ──
        if (!settingsRef.current.useWearablesCamera) {
          const postureOk = await waitForGoodPosture('continuous');
          if (!postureOk) {
            await new Promise<void>(resolve => setTimeout(() => resolve(), Math.max(300, PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN)));
            continue;
          }
        }

        // ── Capture ────────────────────────────────────────────────────────
        let photoPath = '';
        if (prefetchedPhotoRef.current) {
          photoPath = prefetchedPhotoRef.current;
          prefetchedPhotoRef.current = null;
          console.log('🔄 ✅ Using PRE-FETCHED photo');
        } else {
          photoPath = await reactivateCameraAndCaptureRef.current({
            enableShutterSound: false,
            // Navigation workflow and the direct Rtab feed both end up at RTAB.
            // Wait for an in-flight Rtab capture, then take our own frame so
            // the same local JPEG is never posted through both routes.
            busyStrategy: loopMode === 'navigation' ? 'wait-new' : 'wait',
          });
        }

        if (loopMode === 'navigation') {
          if (photoPath && hasSubmittedRtabFrame(photoPath)) {
            console.warn('🔄 [Navigation] Captured frame was already submitted to RTAB — recapturing once');
            photoPath = await reactivateCameraAndCaptureRef.current({
              enableShutterSound: false,
              busyStrategy: 'wait-new',
            });
          }

          if (photoPath && hasSubmittedRtabFrame(photoPath)) {
            console.warn('🔄 [Navigation] Recapture still matched an RTAB-submitted frame — skipping cycle');
            photoPath = '';
          }

          if (photoPath) {
            rememberRtabSubmittedFrame(photoPath);
          }
          startRtabFeed();
        } else {
          stopRtabFeed();
        }

        if (!photoPath && loopMode === 'navigation') {
          console.warn('🔄 [Navigation] Empty capture — skipping cycle, will retry');
          await new Promise<void>(resolve =>
            setTimeout(() => resolve(), Math.max(300, PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN))
          );
          continue;
        }

        // Issue 3: never POST a reaching request without an image. A failed
        // capture right after the navigation→reaching switch left Melody's
        // tracker container with no image (and no usable session) to
        // initialize from. Retry once, then skip the cycle rather than
        // sending an imageless request.
        if (!photoPath && loopMode === 'reaching') {
          console.warn('🔄 [Reaching] Empty capture — retrying once before send');
          photoPath = await reactivateCameraAndCaptureRef.current({ enableShutterSound: false });
          if (!photoPath) {
            console.warn('🔄 [Reaching] Still no image — skipping cycle, will retry');
            await new Promise<void>(resolve => setTimeout(() => resolve(), SMART_GUIDANCE_MIN_CYCLE_MS));
            continue;
          }
        }

        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

        // ── Send to backend ────────────────────────────────────────────────
        setIsProcessing(true);
        const abortCtrl = new AbortController();
        abortControllerRef.current = abortCtrl;

        continuousBackendInFlightRef.current = true;
        // Skip SFX when VoiceOver is on or in glasses mode (BluetoothHFP audio session conflict).
        // During navigation/RTAB, this fills the otherwise-silent wait between spoken responses.
        if (
          !continuousTtsSpeakingRef.current &&
          !screenReaderEnabledRef.current &&
          !settingsRef.current.useWearablesCamera
        ) {
          playThinkingStarted(); // ← start thinking SFX for this cycle
        }

        const shouldUseSmartGuidance = loopMode === 'reaching' && smartGuidanceActiveRef.current;
        let usedSmartGuidance = false;
        let result: any;

        if (shouldUseSmartGuidance) {
          const cached = smartGuidanceCacheRef.current;
          const imageDataUrl = await readImageAsDataUrl(photoPath || '');
          const seedBbox = bboxToString(cached?.bbox);
          const objectName = cached?.object || 'object';
          const annotatedImage = cached?.annotatedImage
            ? toDataUrl(cached.annotatedImage)
            : (imageDataUrl || '');

          // Issue 5: hand the Qwen seed bbox to the tracker container ONLY on
          // the first call after the tracker locks. While tracking is active
          // the container's tracker owns the box — echoing it back (or the
          // tracker's own normalized output) makes the container think Qwen
          // is still detecting.
          const needsSeed = !smartGuidanceSeededRef.current;
          const bboxToSend = needsSeed ? seedBbox : '';

          if (!imageDataUrl || (needsSeed && !seedBbox)) {
            // Issue 3: incomplete payload — don't send a partial request to
            // the container. Resume the main workflow; reacquiringRef keeps
            // the loop alive so Qwen detection retries.
            console.warn('⚠️ [SmartGuidance] Missing payload, resuming main workflow');
            // No frame goes out, so no sonification comes back — silence now
            // instead of letting the last cue ride the native stale timeout.
            await silenceSpatialAudio();
            smartGuidanceActiveRef.current = false;
            smartGuidanceResumeMainRef.current = true;
            smartGuidanceSeededRef.current = false;
            reacquiringRef.current = true;
          } else {
            usedSmartGuidance = true;
            await startTrackerSensors();

            // Sampled here rather than at capture time because this is the
            // first point where the frame is definitely going out. capture_ts
            // in the payload is the sensor sample's own timestamp, so the
            // tracker aligns on that, not on when we happened to read it.
            const orientation = await getDeviceAttitude();
            // Belongs to the frame itself, so a prefetched photo reports when
            // it was actually taken rather than when it was sent.
            const frameTs = getFrameCaptureTs(photoPath || '');

            const smartResponse = await sendToSmartGuidance(
              {
                object: objectName,
                bbox: bboxToSend,
                image: imageDataUrl,
                annotated_image: annotatedImage,
                success: true,
                session_id: getSessionId(),
                confidence: cached?.confidence,
                orientation,
                language: getAppLanguage(),
                frame_ts: frameTs,
              },
              abortCtrl.signal
            );

            // Spatial cue first, before any TTS work below — it is the
            // real-time channel, and the tracker already decided whether this
            // frame should sound at all via `emit`. A missing block (WAITING /
            // FULLY_LOST) silences rather than holding the last cue.
            await updateSpatialAudio(smartResponse?.sonification);
            // Seed has now gone out — every later call sends an empty bbox.
            if (needsSeed) {
              smartGuidanceSeededRef.current = true;
              console.log('🎯 [SmartGuidance] Seed bbox sent — tracker owns the box now');
            }

            const handDirection = normalizeTextValue(smartResponse?.hand_direction);
            const guidance = normalizeTextValue(smartResponse?.guidance);
            const trackingActive = smartResponse?.tracking_active === true;
            const reachingCompleted = smartResponse?.reaching_completed === true;
            const responseBbox = bboxToArray(smartResponse?.bbox) || bboxToArray(cached?.bbox);

            result = {
              text: handDirection || guidance,
              navigation: false,
              reaching_flag: false,
              reaching_ios: false,
              tracking_active: trackingActive,
              reaching_completed: reachingCompleted,
              bbox: responseBbox,
              object: smartResponse?.class_name || objectName,
              hand_direction: handDirection || undefined,
              loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
            };

            // Keep the ORIGINAL Qwen seed bbox in the cache — never overwrite
            // it with the tracker's normalized output. If tracking is lost the
            // cache is refreshed from a fresh Qwen detection (see below).
            smartGuidanceCacheRef.current = {
              object: smartResponse?.class_name || objectName,
              bbox: cached?.bbox,
              annotatedImage: cached?.annotatedImage || annotatedImage,
              confidence: cached?.confidence,
            };

            if (smartResponse?.tracking_active === false) {
              // Issue 4: tracking lost — resume the main workflow so the
              // backend re-runs Qwen detection to reacquire the target.
              // reacquiringRef keeps the loop alive instead of exiting.
              console.log('🔄 [SmartGuidance] tracking lost — reacquiring via Qwen detection');
              // The target's position is no longer known; a cue pointing at
              // the last one would be actively misleading during reacquisition.
              await silenceSpatialAudio();
              smartGuidanceActiveRef.current = false;
              smartGuidanceResumeMainRef.current = true;
              smartGuidanceSeededRef.current = false;
              reacquiringRef.current = true;
            }
          }
        }

        if (!usedSmartGuidance) {
          result = await sendToWorkflow(
            {
              text: '',
              imageUri: photoPath || '',
              imageWidth: lastImageDimensions.current.width,
              imageHeight: lastImageDimensions.current.height,
              cameraIntrinsics: lastCameraIntrinsics.current,
              navigation: loopMode === 'navigation',
              navigation_pipeline: settingsRef.current.navigationPipeline,
              navigation_ios_preferred: Platform.OS === 'ios' && settingsRef.current.navigationPipeline === 'arkit',
              reaching_flag: loopMode === 'reaching' && (Platform.OS !== 'ios' || settingsRef.current.reachingPipeline === 'standard'),
              reaching_ios: loopMode === 'reaching' && Platform.OS === 'ios' && settingsRef.current.reachingPipeline !== 'standard',
            },
            abortCtrl.signal
          );

          if (smartGuidanceResumeMainRef.current) {
            smartGuidanceResumeMainRef.current = false;
          }

          if (loopMode === 'reaching' && result?.tracking_active === true && result?.bbox && result?.object) {
            smartGuidanceActiveRef.current = true;
            // Fresh Qwen detection → fresh seed bbox to hand the tracker, and
            // reacquisition (if any was in progress) is now complete.
            smartGuidanceSeededRef.current = false;
            reacquiringRef.current = false;
            smartGuidanceCacheRef.current = {
              object: result?.object || smartGuidanceCacheRef.current?.object,
              bbox: result?.bbox || smartGuidanceCacheRef.current?.bbox,
              annotatedImage: result?.annotated_image || smartGuidanceCacheRef.current?.annotatedImage,
              confidence: result?.confidence || smartGuidanceCacheRef.current?.confidence,
            };
          }
        }

        continuousBackendInFlightRef.current = false;
        await stopLatencyLoop(); // ← stop thinking SFX when result arrives
        await stopLatencyLoop(); // Bug 3 defense: second stop for audio session race
        setIsProcessing(false);


        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

        if (loopMode === 'navigation' && result?.object) {
          rtabLastObjectRef.current = result.object;
        }

        console.log('🔄 Loop result:', {
          text: result.text?.substring(0, 50),
          navigation: result.navigation,
          reaching_flag: result.reaching_flag,
          reaching_ios: result.reaching_ios,
          bbox: result.bbox,
          loopDelay: result.loopDelay,
          smart_guidance: usedSmartGuidance,
        });

        if (!usedSmartGuidance && result.loopDelay) updateLoopDelay(result.loopDelay);

        // ── "Null" response detection ──────────────────────────────────────
        // The n8n synthesizer returns the literal string "Null" when Redis
        // fields are empty (e.g. guidance pipeline hasn't populated yet).
        // Detect it, log it, and clear text so downstream TTS blocks skip.
        const rawText = result.text;
        const isNullResponse =
          typeof rawText === 'string' &&
          rawText.trim().toLowerCase() === 'null';

        if (isNullResponse) {
          result.text = ''; // clear so every `if (result.text)` guard skips TTS
        }

        // ── Structured debug log (EVERY cycle) ────────────────────────────
        const cycleElapsed = Date.now() - cycleStart;
        debugLogger.logAPI(
          `🔄 Cycle #${cycleCount} | ${isNullResponse ? '⏭️ NULL' : result.text ? '🔊 QUEUE' : '🔇 NO_TTS'} | ${cycleElapsed}ms`,
          `mode=${loopMode} nav=${result.navigation} reach=${result.reaching_flag} ios=${result.reaching_ios} smart=${usedSmartGuidance} text="${(rawText || '').substring(0, 80)}"`,
        );

        if (isNullResponse) {
          console.log(`🔄 ⏭️ Cycle #${cycleCount} — "Null" response, skipping TTS, fast-polling…`);
        }

        // ── RTAB → Reaching auto-handoff (Rtab) ──────────────────────────
        //
        // When the navigation pipeline returns reached=true (text "You have
        // arrived"), force a transition into reaching mode regardless of how
        // the backend toggled navigation/reaching_flag in the same response.
        // This makes the handoff resilient to backend flag-routing glitches
        // that previously left the loop stuck or exited it via bothInactive.
        //
        // We:
        //   1. speak the arrival message (await — short and important),
        //   2. flip loopMode to 'reaching' so the next iteration polls the
        //      reaching pipeline,
        //   3. `continue` to the next iteration.
        //
        // Only triggers from navigation mode. If we're already in reaching
        // (e.g. a stale `reached=true` echoes), fall through to existing
        // logic so reaching_completed/bothInactive can finish the session.
        if (result.reached === true && loopMode === 'navigation') {
          console.log('🎯 [RTAB→Reaching] reached=true in navigation mode — handoff');
          debugLogger.logAPI('🎯 RTAB→Reaching handoff', `text="${(result.text || '').substring(0, 60)}"`);

          if (result.text && !continuousModeAbortRef.current && !isEmergencyStopped.current) {
            await speakContinuousSpeechAndWait(result.text);
          }

          if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

          // Flip the loop mode so the next iteration sends reaching_flag=true
          // even if the current response did not have it set.
          startContinuousMode('reaching', result.loopDelay);
          setIsNavigation(false);
          setIsReaching(true);
          announceIfNoVoiceOver('Arrived. Switching to object guidance.');

          // Cooldown before next capture (give user a moment to stabilize camera after arrival).
          await new Promise<void>(resolve => setTimeout(() => resolve(), Math.max(1200, PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN)));
          continue; // ★ next iteration runs with loopMode='reaching'
        }

        // ── iOS ARKit reaching check (respects user preference) ───────────
        if (Platform.OS === 'ios' && result.reaching_ios === true) {
          // Check pipeline FIRST — determines whether to kill the loop or continue it
          const loopPipeline = resolveReachingPipeline({
            reaching_ios: result.reaching_ios,
            reaching: result.reaching_flag,
          });

          if (loopPipeline === 'arkit') {
            const hasValidBbox = !!bboxToArray(result.bbox);
            if (!hasValidBbox) {
              console.log('🔄 [ARKit] Continuous mode: no valid bbox yet, continuing search...');
              if (result.text) {
                await speakContinuousSpeechAndWait(result.text);
              }
              continue;
            }

            // ── ARKit path: intro TTS + silent ARKit bootstrap in parallel ─
            let introSpeechPromise: Promise<void> | undefined;
            if (result.text) {
              introSpeechPromise = speakContinuousSpeechAndWait(result.text, { ignoreAbort: true })
                .then(() => {
                  // Bug 4 defense — see continuous-mode .then() above.
                  stopLatencyLoop().catch(() => { });
                })
                .catch((e: any) => {
                  stopLatencyLoop().catch(() => { });
                  if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
                    console.warn('⚠️ [ARKit] Intro TTS error (non-fatal):', e?.message);
                  }
                });
            }

            isContinuousModeRunning.current = true; // keep until handoff complete
            continuousModeAbortRef.current = true;
            stopContinuousMode('iOS reaching takeover', false);
            const handled = await handleiOSReaching(result, {
              startupSilent: !!introSpeechPromise,
              introSpeechPromise,
            });
            if (handled) {
              setIsNavigation(false);
              setIsReaching(false);
              setIsProcessing(false);
              isContinuousModeRunning.current = false;
              return; // ★ ARKit handled — clean exit
            }
            // ARKit path but module unavailable — loop is already aborted, exit
            break;

          } else {
            // ── Standard pipeline: use reaching_completed to gate the loop ─
            if (result.reaching_completed === true) {
              // Backend says object reached — speak final message and reset
              if (result.text) {
                await speakContinuousSpeechAndWait(result.text);
              }
              console.log('✅ [Reaching] reaching_completed=true — resetting session');
              resetSessionId();
              stopContinuousMode('reaching complete', true);
              break; // ★ Standard complete — clean exit
            }
            // reaching_completed=false → do NOT abort, fall through and loop again
            console.log('🔄 [Reaching] Standard mode — reaching_completed=false, continuing...');
          }
        }

        if (smartGuidanceActiveRef.current && result.reaching_completed === true) {
          if (result.text) {
            await speakContinuousSpeechAndWait(result.text);
          }
          console.log('✅ [SmartGuidance] reaching_completed=true — resetting session');
          smartGuidanceActiveRef.current = false;
          smartGuidanceResumeMainRef.current = false;
          resetSessionId();
          stopContinuousMode('smart guidance complete', true);
          break;
        }

        // ── Reacquisition completion guard ─────────────────────────────────
        // Issue 4: while reacquiring, the loop is kept alive (reachingActive
        // is forced true below) so the backend keeps re-running Qwen
        // detection. The ONLY clean ways out are an explicit completion
        // signal or the user stopping — never transiently-dropped flags.
        if (reacquiringRef.current && result.reaching_completed === true) {
          if (result.text) {
            await speakContinuousSpeechAndWait(result.text);
          }
          console.log('✅ [Reaching] reaching_completed during reacquisition — done');
          reacquiringRef.current = false;
          resetSessionId();
          stopContinuousMode('reaching complete', true);
          break;
        }

        // A genuine navigation handoff ends any in-progress reacquisition.
        if (result.navigation === true) reacquiringRef.current = false;

        // ── Flag check ─────────────────────────────────────────────────────
        const navigationActive = result.navigation === true;
        const smartGuidanceActive = smartGuidanceActiveRef.current;
        // Issue 4: reacquiringRef keeps reaching active across the transient
        // window where tracking is lost and the backend has not yet re-set
        // reaching_flag — otherwise bothInactive would exit the pipeline.
        const reachingActive = result.reaching_flag === true || smartGuidanceActive
          || smartGuidanceResumeMainRef.current || reacquiringRef.current;
        const bothInactive = !navigationActive && !reachingActive;

        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        if (bothInactive) {
          if (result.text) {
            await speakContinuousSpeechAndWait(result.text);
          }
          announceIfNoVoiceOver('Task complete.');
          stopContinuousMode('both flags false', true);
          break;
        }

        // ── Mode transitions ───────────────────────────────────────────────
        if (navigationActive && !reachingActive && loopMode !== 'navigation') {
          // Release the tracker's sensors on the way into navigation. The
          // ARKit navigation pipeline runs its own CMMotionManager via
          // IMUSensorManager, and leaving ours up would have two of them
          // sampling device motion for the whole route. Reaching restarts
          // them lazily on its next smart-guidance send.
          await stopTrackerSensors();
          startContinuousMode('navigation', result.loopDelay);
          announceIfNoVoiceOver('Switching to navigation.');
          result.text = ''; // Prevent downstream TTS from overlapping with transition speech
        } else if (reachingActive && !navigationActive && loopMode !== 'reaching') {
          startContinuousMode('reaching', result.loopDelay);
          announceIfNoVoiceOver('Switching to object guidance.');
          result.text = ''; // Prevent downstream TTS from overlapping with transition speech
        }

        // ── Speak sequentially while the loop keeps polling ────────────────
        //
        // Keep capture/backend cadence fast, but do not start a new TTS session
        // while another instruction is mid-sentence. The speech queue finishes
        // the current utterance and keeps only the newest pending guidance.
        if (result.text && !continuousModeAbortRef.current && !isEmergencyStopped.current) {
          enqueueContinuousSpeech(result.text, {
            source: loopMode || 'backend',
            allowPreempt: true,
            // Reaching guidance is real-time depth feedback that must repeat as
            // the user approaches the object. Use a short suppression window so
            // updates come through every ~3 s instead of the 10 s default that
            // is appropriate for navigation instructions.
            suppressionMs: loopMode === 'reaching' ? 3000 : CONTINUOUS_TTS_REPEAT_SUPPRESSION_MS,
          });
        } else if (isNullResponse) {
          // ── Fast-poll: "Null" text — skip TTS, rapid 500ms cycle ─────────
          const nullCooldown = fastReachingCycle
            ? SMART_GUIDANCE_MIN_CYCLE_MS
            : 500;
          console.log(`🔄 ⏭️ Null fast-poll — waiting ${nullCooldown}ms before next cycle`);
          await new Promise<void>(resolve => setTimeout(() => resolve(), nullCooldown));
        }

        // Brief cooldown before next capture — gives JS thread a breath and
        // prevents hammering the backend faster than it can handle.
        // TTS is already playing in background; this does NOT wait for it.
        if (!isNullResponse && !continuousModeAbortRef.current) {
          const minCycleMs = fastReachingCycle
            ? SMART_GUIDANCE_MIN_CYCLE_MS
            : Math.max(PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN, getCurrentLoopDelay());
          const elapsed = Date.now() - cycleStart;
          const cooldown = Math.max(0, minCycleMs - elapsed);
          if (cooldown > 0) {
            await new Promise<void>(resolve => setTimeout(() => resolve(), cooldown));
          }
        }

        const cycleMs = Date.now() - cycleStart;
        debugLogger.logAPI(
          `🔄 Cycle #${cycleCount} DONE | ${isNullResponse ? 'NULL→SKIP' : result.text ? 'QUEUED' : 'NO_TTS'} | ${(cycleMs / 1000).toFixed(1)}s`,
        );
        console.log(`🔄 ═══ CYCLE #${cycleCount} DONE (${(cycleMs / 1000).toFixed(1)}s) ${isNullResponse ? '[NULL-SKIP]' : ''} ═══`);

      } catch (error: any) {
        console.error('🔄 [ContinuousMode] Error:', error);
        if (error.message?.includes('cancel')) break;
        continuousBackendInFlightRef.current = false;
        continuousTtsSpeakingRef.current = false;
        continuousTtsGenerationRef.current++;
        await stopLatencyLoop();
        if (!settingsRef.current.useWearablesCamera) {
          await earcons.playAndWait('error');
        }
        Announcer.announceCritical(`Error: ${error.message}`);
        break;
      }
    }

    // ── Cleanup ────────────────────────────────────────────────────────────
    console.log('🔄 [ContinuousMode] Loop ended');
    await stopLatencyLoop();
    stopRtabFeed();
    await stopTrackerSensors();
    isContinuousModeRunning.current = false;
    continuousBackendInFlightRef.current = false;
    continuousTtsSpeakingRef.current = false;
    continuousTtsGenerationRef.current++;
    resetContinuousSpeechQueue();
    stopContinuousMode('loop ended', false);
    smartGuidanceActiveRef.current = false;
    smartGuidanceResumeMainRef.current = false;
    smartGuidanceCacheRef.current = null;
    smartGuidanceSeededRef.current = false;
    reacquiringRef.current = false;
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(true);
    earcons.play('ready');
    announceTapToStart('Ready.');

    // Resume wake word listening if in glasses mode
    if (settingsRef.current.useWearablesCamera) {
      wakeWordResumeRef.current?.();
    }
  }, [
    announceTapToStart,
    enqueueContinuousSpeech,
    handleiOSReaching,
    hasSubmittedRtabFrame,
    rememberRtabSubmittedFrame,
    resetContinuousSpeechQueue,
    resolveReachingPipeline,
    speakContinuousSpeechAndWait,
    startRtabFeed,
    startTrackerSensors,
    stopRtabFeed,
    stopTrackerSensors,
    getFrameCaptureTs,
    waitForGoodPosture,
  ]);

  // ============================================================================
  // ARKit Navigation helper — native on-device route guidance takeover
  // ============================================================================
  const handleARKitNavigation = useCallback(async (
    result: any,
    options?: { introSpeechPromise?: Promise<void>; requestedText?: string },
  ): Promise<boolean> => {
    const pipeline = resolveNavigationPipeline({
      navigation: result.navigation,
      navigation_ios: result.navigation_ios,
      navigation_arkit: result.navigation_arkit,
      navigation_pipeline: result.navigation_pipeline,
    });

    if (pipeline !== 'arkit') {
      return false;
    }

    let targetName = normalizeTextValue(result.navigation_target) ||
      normalizeTextValue(result.object) ||
      inferNavigationTargetFromCommand(options?.requestedText);

    if (!targetName) {
      if (options?.introSpeechPromise) {
        try { await options.introSpeechPromise; } catch { }
      }
      await speakContinuousSpeechAndWait(
        strings().navigation.targetUnclear,
        { ignoreAbort: true },
      );
      setIsNavigation(false);
      setIsProcessing(false);
      setIsCameraActive(true);
      earcons.play('ready');
      announceTapToStart('Ready.');
      return true;
    }

    // Ground the transcribed target against the saved map vocabulary before
    // opening AR: "serial" resolves to "cereal", and a genuine miss gets a
    // spoken listing of saved destinations instead of a silent dead end.
    let groundedRouteMapId: string | undefined;
    try {
      const grounding = await groundNavigationTarget(targetName);
      if (grounding.status === 'matched' && grounding.label) {
        if (grounding.label.toLowerCase() !== targetName.toLowerCase()) {
          console.log('🧭 [ARKitNavigation] Grounded target:', {
            requested: targetName,
            resolved: grounding.label,
            method: grounding.method,
          });
        }
        targetName = grounding.label;
        groundedRouteMapId = grounding.mapId;
      } else if (grounding.status === 'no_match') {
        if (options?.introSpeechPromise) {
          try { await options.introSpeechPromise; } catch { }
        }
        const known = grounding.availableTargets.slice(0, 6).join(', ');
        await speakContinuousSpeechAndWait(
          known
            ? strings().navigation.targetNotFoundWithList(targetName, known)
            : strings().navigation.targetNotFoundNoMap(targetName),
          { ignoreAbort: true },
        );
        setIsNavigation(false);
        setIsProcessing(false);
        setIsCameraActive(true);
        earcons.play('ready');
        announceTapToStart('Ready.');
        return true;
      }
      // 'no_vocabulary' falls through: native matching still applies.
    } catch {
      // Grounding is best-effort; the native layer has its own fuzzy match.
    }

    let arAvailable = false;
    try {
      arAvailable = await ARKitNavigationBridge.isAvailable();
    } catch {
      arAvailable = false;
    }

    if (!arAvailable) {
      if (options?.introSpeechPromise) {
        try { await options.introSpeechPromise; } catch { }
      }
      await speakContinuousSpeechAndWait(
        strings().navigation.unavailableFallback,
        { ignoreAbort: true },
      );
      result.navigation = true;
      result.navigation_ios = false;
      result.navigation_arkit = false;
      return false;
    }

    if (options?.introSpeechPromise) {
      try {
        await options.introSpeechPromise;
      } catch (e: any) {
        if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
          console.warn('⚠️ [ARKitNavigation] Intro TTS warning:', e?.message || e);
        }
      }
    }
    // No "Starting ARKit route guidance to X" here. It named the pipeline to
    // the one person who has no use for that word, and the native session
    // announces the route itself a moment later ("Onions is 21 meters away").

    if (isEmergencyStopped.current) return true;

    console.log('🧭 [ARKitNavigation] Launching native navigation:', {
      targetName,
      routeMapId: result.route_map_id,
      routeMapName: result.route_map_name,
    });

    stopRtabFeed();
    stopContinuousMode('ARKit navigation takeover', false);
    continuousModeAbortRef.current = true;
    continuousTtsGenerationRef.current++;
    resetContinuousSpeechQueue();
    setIsNavigation(true);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(false);
    rtabLastObjectRef.current = targetName;

    let navResult: ARKitNavigationResult;
    const navConfig = {
      targetName,
      routeMapId: normalizeTextValue(result.route_map_id) || groundedRouteMapId || undefined,
      routeMapName: normalizeTextValue(result.route_map_name) || undefined,
      sessionId: getSessionId(),
      speakLandmarks: true,
      errorRecovery: settingsRef.current.navigationErrorRecovery,
      clockFaceDirections: settingsRef.current.navigationClockFaceDirections,
      distanceUnit: settingsRef.current.navigationDistanceUnit,
      voiceOverEnabled: screenReaderEnabledRef.current,
      ttsRate: settingsRef.current.ttsRate,
      language: settingsRef.current.language,
      // Only the in-device pipeline can leave the session warm: the backend
      // reaching pipelines capture photos after arrival and need the RN
      // camera, which the mounted ARKit session would still be holding.
      keepSessionAlive:
        resolveReachingPipeline({ reaching_ios: true, reaching: true }) === 'spatialTarget',
    };
    // The native screen is about to cover the RN UI and owns every cue until
    // it comes back. Muting this layer's earcons for that window is what stops
    // a soundless "ready"/"error" haptic reaching the user as an unexplained
    // buzz mid-walk.
    earcons.setNativeSessionActive(true);
    try {
      // A previous leg that arrived without a reaching handoff left the AR
      // session mounted and localized — or reaching handed its session back
      // when it finished. Continuing on either is what makes a
      // destination-to-destination hop skip relocalization: the step that
      // fails when the user stands at a destination facing the way they came.
      navResult = arSessionAliveRef.current
        ? await ARKitNavigationBridge.continueNavigation(navConfig)
        : await ARKitNavigationBridge.startNavigation(navConfig);
    } catch (e: any) {
      navResult = {
        success: false,
        reason: 'error',
        targetName,
        message: e?.message || 'ARKit navigation ended with an error.',
      };
    } finally {
      earcons.setNativeSessionActive(false);
    }

    arSessionAliveRef.current = navResult?.sessionAlive === true;

    console.log('🧭 [ARKitNavigation] Native result:', navResult);

    if (navResult?.success && navResult.reason === 'arrived') {
      // Reaching object marked on this destination during route capture.
      // When present, navigation hands off into in-device spatial-target
      // reaching for THAT object — not the destination POI itself.
      const reachingObjectName = normalizeTextValue(navResult.reachingObjectName);
      // Resolve the pipeline exactly the way handleiOSReaching does. Reading
      // settings.reachingPipeline raw misses In-Device Mode, which overrides
      // the stored preference without rewriting it — the default stays
      // 'visionBox', so every in-device arrival looked like a backend pipeline
      // and auto-reached, including destinations with no reaching object
      // pinned during capture.
      const isSpatialTargetReaching =
        resolveReachingPipeline({ reaching_ios: true, reaching: true }) === 'spatialTarget';
      const willAutoReach = !!reachingObjectName || !isSpatialTargetReaching;

      stopContinuousMode('ARKit navigation arrived', false);
      setIsReaching(willAutoReach);
      setIsProcessing(willAutoReach);
      setIsNavigation(false);
      setIsSpeaking(false);

      // Native holds its own screen open until "Arrived at X" has finished
      // being spoken, then reports `messageSpoken`. Repeating it here is what
      // truncated it: the second start interrupts the first, and the user is
      // handed to reaching without ever hearing that they arrived.
      if (!navResult.messageSpoken) {
        await speakContinuousSpeechAndWait(
          navResult.message ||
            (reachingObjectName
              ? strings().navigation.arrivedSwitchingToReaching(targetName, reachingObjectName)
              : strings().navigation.arrivedAt(targetName)),
          { ignoreAbort: true },
        );
      }

      if (isEmergencyStopped.current) {
        setIsReaching(false);
        setIsProcessing(false);
        return true;
      }

      if (reachingObjectName) {
        const handled = await handleiOSReaching(
          {
            text: '',
            reaching_ios: true,
            reaching_flag: false,
            object: reachingObjectName,
            navigation_target: reachingObjectName,
            route_map_id: navResult.routeMapId || result.route_map_id,
            route_map_name: navResult.routeName || result.route_map_name,
            targetWorldPosition: navResult.reachingObjectWorldPosition,
          },
          { startupSilent: false, forceSpatialTarget: true },
        );

        if (!handled) {
          await speakContinuousSpeechAndWait(
            strings().navigation.couldNotStartReaching(reachingObjectName),
            { ignoreAbort: true },
          );
          setIsReaching(false);
          setIsProcessing(false);
          setIsCameraActive(true);
          earcons.play('ready');
          announceTapToStart('Ready.');
        }

        return true;
      }

      if (isSpatialTargetReaching) {
        // In-device mode with no reaching object marked: arrival is final.
        // Reaching only activates for destinations with a pinned object.
        setIsReaching(false);
        setIsProcessing(false);
        // A warm session means the ARKit screen is still up and still holding
        // the camera; turning the RN camera on here would fight it for the
        // device. Leave it off and let the next destination continue on the
        // live session (or an explicit stop tear it down).
        setIsCameraActive(!arSessionAliveRef.current);
        earcons.play('ready');
        announceTapToStart('Ready.');
        return true;
      }

      const postureOk = await waitForGoodPostureRef.current('capture');
      if (!postureOk) {
        await speakContinuousSpeechAndWait(
          strings().navigation.holdPhoneStraight,
          { ignoreAbort: true },
        );
        setIsReaching(false);
        setIsProcessing(false);
        setIsCameraActive(true);
        earcons.play('ready');
        announceTapToStart('Ready.');
        return true;
      }

      // Glasses mode is the only reason to stay silent here; see the note in
      // handleVoiceCommand. A VoiceOver user waiting on object detection needs
      // this cue more than anyone, not less.
      if (!settingsRef.current.useWearablesCamera) {
        earcons.play('thinking');
      }

      let reachingResult: any;
      try {
        const photoPath = await reactivateCameraAndCaptureRef.current({
          enableShutterSound: false,
          busyStrategy: 'wait-new',
        });

        if (!photoPath) {
          throw new Error('Could not capture a fresh image for object guidance.');
        }

        const reachingAbortCtrl = new AbortController();
        abortControllerRef.current = reachingAbortCtrl;
        reachingResult = await sendToWorkflow(
          {
            text: targetName,
            imageUri: photoPath,
            imageWidth: lastImageDimensions.current.width,
            imageHeight: lastImageDimensions.current.height,
            cameraIntrinsics: lastCameraIntrinsics.current,
            navigation: false,
            navigation_pipeline: 'arkit',
            navigation_ios_preferred: true,
            reaching_flag: false,
            reaching_ios: true,
          },
          reachingAbortCtrl.signal,
        );
      } catch (e: any) {
        await stopLatencyLoop();
        await speakContinuousSpeechAndWait(
          e?.message || `I could not start object guidance for ${targetName}.`,
          { ignoreAbort: true },
        );
        setIsReaching(false);
        setIsProcessing(false);
        setIsCameraActive(true);
        earcons.play('ready');
        announceTapToStart('Ready.');
        return true;
      }

      await stopLatencyLoop();
      await stopLatencyLoop();
      setIsProcessing(false);

      const reachingIntroPromise = reachingResult?.text
        ? speakContinuousSpeechAndWait(reachingResult.text, { ignoreAbort: true })
        : undefined;

      const handled = await handleiOSReaching(
        {
          ...reachingResult,
          reaching_ios: true,
          object: normalizeTextValue(reachingResult?.object) || targetName,
        },
        {
          startupSilent: !!reachingIntroPromise,
          introSpeechPromise: reachingIntroPromise,
        },
      );

      if (!handled) {
        await speakContinuousSpeechAndWait(
          `I could not start ARKit reaching for ${targetName}.`,
          { ignoreAbort: true },
        );
        setIsReaching(false);
        setIsProcessing(false);
        setIsCameraActive(true);
        earcons.play('ready');
        announceTapToStart('Ready.');
      }

      return true;
    }

    setIsNavigation(false);
    // A relocalization attempt that timed out can leave the ARKit screen
    // mounted and still searching, so asking again continues that attempt
    // instead of resetting tracking. It is still holding the camera —
    // grabbing it here would fight the very session we kept alive.
    setIsCameraActive(!arSessionAliveRef.current);

    if (navResult.reason === 'ar_unavailable') {
      await speakContinuousSpeechAndWait(
        navResult.message || strings().navigation.unavailableFallback,
        { ignoreAbort: true },
      );
      setIsProcessing(false);
      result.navigation = true;
      result.navigation_ios = false;
      result.navigation_arkit = false;
      return false;
    }

    // A launch that was torn down because a newer one replaced it. Native
    // now always answers a waiting caller rather than dropping the resolver
    // (dropping it used to hang this turn forever), but the newer request is
    // already running — announcing "navigation ended" over it would be wrong.
    // Unwind quietly and let the replacement own the audio.
    if (navResult.reason === 'superseded') {
      console.log('⏩ ARKit navigation superseded by a newer request — unwinding quietly');
      setIsProcessing(false);
      return true;
    }

    // `navResult.message` comes from native, which already speaks the session
    // language, so preferring it stays correct in French.
    const navStrings = strings().navigation;
    const fallbackMessages: Record<string, string> = {
      map_not_found: navStrings.mapNotFound(targetName),
      target_not_found: navStrings.targetNotInMaps(targetName),
      relocalization_failed: navResult.message || navStrings.relocalizationFailed,
      arrival_unverified: navResult.message || navStrings.arrivalUnverified(targetName),
      cancelled: navStrings.cancelled,
      error: navResult.message || navStrings.endedWithError,
    };

    // A tap anywhere on the guidance screen is now what ends it, and a tap a
    // blind participant cannot see the result of needs an immediate answer —
    // the same earcon a manual reaching exit plays, so the two exits sound
    // identical. It lands before the sentence, which is what makes it a
    // confirmation of the tap rather than a decoration on the message.
    if (navResult.reason === 'cancelled' && !screenReaderEnabledRef.current) {
      await playStopReachingSound();
    }

    await speakContinuousSpeechAndWait(
      fallbackMessages[navResult.reason] || navResult.message || navStrings.ended,
      { ignoreAbort: true },
    );
    stopContinuousMode('ARKit navigation ended', false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    earcons.play('ready');
    announceTapToStart('Ready.');
    return true;
  }, [
    announceTapToStart,
    handleiOSReaching,
    resetContinuousSpeechQueue,
    resolveNavigationPipeline,
    resolveReachingPipeline,
    speakContinuousSpeechAndWait,
    stopRtabFeed,
  ]);

  // ============================================================================
  // Stop helpers
  // ============================================================================
  const stopContinuousModeLoop = useCallback(async () => {
    console.log('🛑 Stopping continuous mode');
    const wasContinuous =
      isNavigation ||
      isContinuousModeRunning.current ||
      isReaching ||
      getCurrentMode() === 'navigation' ||
      getCurrentMode() === 'reaching' ||
      smartGuidanceActiveRef.current ||
      smartGuidanceResumeMainRef.current ||
      reacquiringRef.current;
    continuousModeAbortRef.current = true;
    stopRtabFeed();
    // Kill the spatial cue on the interrupt itself. Waiting for the loop's
    // cleanup block would leave it beeping through the in-flight request.
    await stopTrackerSensors();
    // The native screen is coming down, and the stop confirmation this path is
    // about to play is the one cue a user who just interrupted must hear.
    earcons.setNativeSessionActive(false);
    arSessionAliveRef.current = false;
    try { await ARKitNavigationBridge.stopNavigation(); } catch { }

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await stopLatencyLoop();
    continuousTtsGenerationRef.current++;
    resetContinuousSpeechQueue();
    await speachesSentenceChunker.stop();
    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isContinuousModeRunning.current = false;
    setIsCameraActive(true);

    // The mode-exit cue is the answer to "did my stop actually land?" — the
    // single most-asked question in the pilot sessions, and one VoiceOver
    // cannot answer while the screen it would read is being torn down.
    if (wasContinuous) {
      await earcons.playAndWait('modeExit');
    } else {
      earcons.play('ready');
    }
    announceTapToStart('Stopped.');
  }, [announceTapToStart, isNavigation, isReaching, resetContinuousSpeechQueue, stopRtabFeed, stopTrackerSensors]);

  const stopNavigation = useCallback(async () => {
    navigationLoopAbortRef.current = true;
    stopRtabFeed();
    // The native screen is coming down, and the stop confirmation this path is
    // about to play is the one cue a user who just interrupted must hear.
    earcons.setNativeSessionActive(false);
    arSessionAliveRef.current = false;
    try { await ARKitNavigationBridge.stopNavigation(); } catch { }
    if (abortControllerRef.current) { abortControllerRef.current.abort(); abortControllerRef.current = null; }
    await stopLatencyLoop(); // FIX: was missing — latency SFX survived nav interrupt
    continuousTtsGenerationRef.current++;
    resetContinuousSpeechQueue();
    await speachesSentenceChunker.stop();
    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isNavigationLoopRunning.current = false;
    setIsCameraActive(true);
    await earcons.playAndWait('modeExit');
    announceTapToStart('Navigation stopped.');
  }, [announceTapToStart, resetContinuousSpeechQueue, stopRtabFeed]);

  // ============================================================================
  // Handle Voice Command  ← defined BEFORE handleAutoSubmit so ref is stable
  // ============================================================================
  const handleVoiceCommand = useCallback(async (rawCommand: string, photoPath: string) => {
    if (isProcessingRef.current || isEmergencyStopped.current) return;

    // ── Canonicalize a menu-driven request ────────────────────────────────
    //
    // When the user reached this turn through a menu row, the intent is
    // already known — they pressed a button that says so — and only the
    // argument had to be spoken. Wrapping the transcript in a fixed sentence
    // hands the classifier a request whose shape is constant and whose only
    // variable is the object name.
    //
    // This matters more than it looks. "Cereal" on its own is an utterance the
    // classifier has to guess at, and the intent prompt's own rules send a
    // bare noun to `chat` — so pressing "Find an object" and saying "cereal"
    // used to return a *description* of the cereal rather than guidance to it.
    // "Guide my hand to the cereal" cannot route anywhere else.
    //
    // The row is consumed here rather than at the button, because the user can
    // abandon a listening session and the next one must not inherit an intent
    // they never re-chose.
    const menuAction = pendingActionRef.current;
    pendingActionRef.current = null;
    const command =
      menuAction === 'find'
        ? canonicalizeMenuCommand(
          rawCommand,
          strings().commands.findObject,
          getAppLanguage(),
        )
        : rawCommand;
    if (menuAction) {
      console.log(`🎛️ [menu] "${rawCommand}" → "${command}" (row: ${menuAction})`);
    }

    if (isContinuousModeActive()) {
      const sid = resetSessionId();
      console.log('🔄 Previous continuous mode detected — new session:', sid);
    }

    const abortCtrl = new AbortController();
    abortControllerRef.current = abortCtrl;

    try {
      console.log('⚡ Processing:', command);
      if (looksLikeReachingCommand(command)) {
        prewarmDAv2InBackground('voice command');
      }
      isProcessingRef.current = true;
      setIsProcessing(true);
      markTurnProgressRef.current('command accepted');

      await nativeCall(
        () => cancelSTT(),
        WATCHDOG_TIMEOUTS.STT_CONTROL,
        'cancelSTT (handleVoiceCommand)',
        undefined,
      );
      markTurnProgressRef.current('stt cancelled');

      // ── Audio session vs. sound cues: two different questions ──────────
      //
      // These used to be one flag, and collapsing them is why blind users
      // heard nothing. They are not the same decision:
      //
      //   • configurePlaybackSession() takes the audio session EXCLUSIVELY
      //     (setActive(true) on .playAndRecord). That genuinely does interrupt
      //     VoiceOver, so it stays gated — VoiceOver's own session is already
      //     configured for output and does not need our help.
      //
      //   • The cues themselves now request a MIXABLE session (see
      //     setScreenReaderMode in utils/soundEffects.ts), so they play
      //     alongside VoiceOver instead of fighting it. Suppressing them was
      //     collateral damage from sharing a flag with the line above.
      //
      // Glasses mode still suppresses both: BluetoothHFP owns the session for
      // the glasses microphone, and any setCategory call corrupts it, leaving
      // the latency loop in a zombie state that .stop() cannot silence.
      const wearablesActive = settingsRef.current.useWearablesCamera;
      const canTakeExclusiveSession = !screenReaderEnabledRef.current && !wearablesActive;
      const shouldPlaySFX = !wearablesActive;

      if (canTakeExclusiveSession) {
        // FIX: Restore full-volume audio session after STT's Record+Measurement
        //
        // Bounded: an AVAudioSession category switch can block indefinitely
        // when another process (or the glasses' HFP link) holds the session.
        // Losing the earcon is a cosmetic failure; hanging here was a fatal one.
        await nativeCall(
          () => configurePlaybackSession(!wearablesActive),
          WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
          'configurePlaybackSession',
          undefined,
        );
      }

      if (shouldPlaySFX) {
        await nativeCall(
          () => stopListenSound(),
          WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
          'stopListenSound',
          undefined,
        );
        earcons.play('thinking');
      }
      markTurnProgressRef.current('audio session ready');


      if (!photoPath) {
        if (settingsRef.current.useWearablesCamera) {
          await speakWearablesError(new Error(
            'Could not get an image from the glasses. Try toggling the glasses camera off and on.'
          ));
          return;
        }

        console.warn('⚠️ No photo — voice-only mode');
        Announcer.announceStatus(strings().speech.processingWithoutPhoto);
      }

      if (isEmergencyStopped.current) return;

      const result = await sendToWorkflow(
        {
          text: command,
          // What the session is about, so a question that only says "this" or
          // "the correct object" resolves to the thing the user was just
          // guided to or told to reach for.
          object: rtabLastObjectRef.current || undefined,
          imageUri: photoPath || '',
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          cameraIntrinsics: lastCameraIntrinsics.current,
          navigation: false,
          navigation_pipeline: settingsRef.current.navigationPipeline,
          navigation_ios_preferred: Platform.OS === 'ios' && settingsRef.current.navigationPipeline === 'arkit',
          reaching_flag: false,
        },
        abortCtrl.signal
      );
      markTurnProgressRef.current('workflow responded');

      if (isEmergencyStopped.current) return;

      if (result?.object) {
        rtabLastObjectRef.current = result.object;
      }

      await nativeCall(
        () => stopLatencyLoop(),
        WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
        'stopLatencyLoop (post-response)',
        undefined,
      );
      // Bug 3 defense: second stop catches the race where iOS audio session
      // switch during the first stop re-queued a play.
      await nativeCall(
        () => stopLatencyLoop(),
        WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
        'stopLatencyLoop (post-response, 2nd)',
        undefined,
      );
      //await playSuccessChime();          // ← plays jbl_success_sae.caf

      console.log('✅ Response:', {
        text: result.text.substring(0, 50) + '...',
        navigation: result.navigation,
        navigation_pipeline: result.navigation_pipeline,
        reaching_flag: result.reaching_flag,
        reaching_ios: result.reaching_ios,
        loopDelay: result.loopDelay,
      });

      setIsProcessing(false);
      let introSpeechPromise: Promise<void> | undefined;
      if (result.text) {
        // Retained so "Repeat that" can replay it with no network, no model,
        // and no camera. Blind users ask for a repeat constantly — an answer
        // heard once, over a PA system or a passing trolley, is an answer half
        // received — and until now the only way to get one was to run the
        // entire pipeline again and hope it returned the same thing.
        lastAnswerRef.current = result.text;
        setLastAnswer(result.text);
        setIsSpeaking(true);
        // Haptic only under VoiceOver: an answer is about to be spoken, and a
        // chime immediately before speech is the one cue that genuinely does
        // collide with it. The buzz says "answer incoming" without competing
        // for the same channel the answer arrives on.
        earcons.play(screenReaderEnabledRef.current ? 'ready' : 'success');

        // ── Bug 1 fix: When VoiceOver is on, wait for VoiceOver to ─────
        // finish speaking its 'Thinking' announcement before starting TTS.
        // Without this, VoiceOver and AVSpeechSynthesizer both speak at
        // once, creating the double-voice/echo effect.
        if (screenReaderEnabledRef.current) {
          await new Promise<void>(resolve => setTimeout(() => resolve(), 600));
        }

        introSpeechPromise = (
          screenReaderEnabledRef.current
            ? new Promise<void>(resolve => {
              // `force`: an answer must always be spoken. Asking the same
              // question twice and getting the same answer is a legitimate
              // repeat, and the duplicate filter would eat the second one —
              // leaving the user with a turn that appears to have done nothing.
              Announcer.announce(result.text, { priority: 'status', force: true });
              setTimeout(resolve, Math.min(6500, Math.max(1200, result.text.length * 55)));
            })
            : speachesSentenceChunker.synthesizeSpeechChunked(result.text)
        )
          .then(() => {
            setIsSpeaking(false);
            // Bug 4 defense: kill any latency loop that may have been
            // re-started by a downstream code path (or that survived an
            // earlier stop's iOS audio race) when speech naturally ends.
            stopLatencyLoop().catch(() => { });
          })
          .catch((e: any) => {
            setIsSpeaking(false);
            stopLatencyLoop().catch(() => { });
            if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
              console.warn('⚠️ Intro TTS error (non-fatal):', e?.message);
            }
          });
      } else {
        setIsSpeaking(false);
      }

      if (isEmergencyStopped.current) return;

      finalTranscriptRef.current = '';

      // ── iOS ARKit navigation on first response (opt-in setting) ─────────
      const wantsARKitDestination = looksLikeARKitDestinationCommand(command);
      if (
        Platform.OS === 'ios' &&
        (
          result.navigation === true ||
          result.navigation_ios === true ||
          result.navigation_arkit === true ||
          (
            result.navigation_pipeline === 'arkit' &&
            (
              wantsARKitDestination ||
              (
                result.reaching_ios !== true &&
                result.reaching_flag !== true
              )
            )
          )
        )
      ) {
        const handled = await handleARKitNavigation(result, {
          introSpeechPromise,
          requestedText: command,
        });
        if (handled) return;
        // If not handled because ARKit is unavailable, fall through to the
        // existing Rtab loop using the mutated fallback navigation flag.
      }

      // ── iOS ARKit reaching on first response (respects user preference) ──
      if (Platform.OS === 'ios' && result.reaching_ios === true) {
        const handled = await handleiOSReaching(result, {
          startupSilent: !!introSpeechPromise,
          introSpeechPromise,
        });
        if (handled) return; // ARKit took over or gave fallback message
        // If not handled (e.g. user prefers standard pipeline), fall through
      }

      // Keep existing behavior for non-ARKit paths: finish response speech first.
      if (introSpeechPromise) {
        await introSpeechPromise;
      }

      if (isEmergencyStopped.current) return;

      // ── Continuous mode activation ─────────────────────────────────────
      const navigationActive = result.navigation === true;
      const reachingActive = result.reaching_flag === true;

      if (navigationActive || reachingActive) {
        const mode = navigationActive ? 'navigation' : 'reaching';
        console.log(`🔄 Backend requested ${mode} loop`);

        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        stopContinuousMode('resetting for new loop', false);
        await new Promise<void>(resolve => setTimeout(() => resolve(), 100));
        startContinuousMode(mode, result.loopDelay);

        await runContinuousLoop();
        return;
      }

      // ── Normal (no continuous mode) ────────────────────────────────────
      setIsCameraActive(true);
      earcons.play('ready');
      announceTapToStart('Ready.');

      // Resume wake word listening if in glasses mode
      if (settingsRef.current.useWearablesCamera) {
        wakeWordResumeRef.current?.();
      }

    } catch (error: any) {
      // ── Cancelled / aborted requests are silent ──────
      if (
        error.name === 'AbortError' ||
        error.message?.includes('aborted') ||
        error.message?.includes('cancel')
      ) {
        await stopLatencyLoop(); // FIX: abort path was leaking latency loop
        console.log('✅ Request cancelled');
        return;
      }

      if (!isEmergencyStopped.current) {
        console.error('❌ handleVoiceCommand error:', error);
        console.error('❌ Error detail:', error?.message, error?.code);

        await stopLatencyLoop();
        // Awaited so AVSpeechSynthesizer cannot steal the audio session
        // mid-playback and cut the cue short; the sound's natural duration
        // replaces the old 600ms timeout.
        await earcons.playAndWait('error');

        const errorMessage = strings().speech.requestFailed;
        if (screenReaderEnabledRef.current) {
          Announcer.announceCritical(errorMessage);
        } else {
          await speachesSentenceChunker.synthesizeSpeechChunked(errorMessage);
        }

        setIsCameraActive(true);
        earcons.play('ready');
        announceTapToStart('Ready.');

        // Resume wake word listening if in glasses mode
        if (settingsRef.current.useWearablesCamera) {
          wakeWordResumeRef.current?.();
        }
      }
    } finally {
      setIsProcessing(false);
      isProcessingRef.current = false;
      finalTranscriptRef.current = '';
      abortControllerRef.current = null;
    }
  }, [handleARKitNavigation, handleiOSReaching, runContinuousLoop]);

  // Keep ref in sync so handleAutoSubmit can call latest version
  useEffect(() => {
    handleVoiceCommandRef.current = handleVoiceCommand;
  }, [handleVoiceCommand]);
  const stripVoiceOverListeningPrefix = useCallback((text: string): string => {
    if (!screenReaderEnabledRef.current) return text;
    return text.replace(/^\s*listening[\s,.:;!\-]+/i, '').trim();
  }, []);

  // ============================================================================
  // Handle Auto-Submit (silence detection)
  // ============================================================================
  const handleAutoSubmit = useCallback(async (passedTranscript?: string) => {
    console.log('🎯 Auto-submit triggered by silence detection');

    if (isCapturingPhotoRef.current || isProcessingRef.current || isEmergencyStopped.current) {
      console.log('⚠️ Already in-flight, skipping');
      return;
    }

    let finalText = (passedTranscript || finalTranscriptRef.current).trim();
    finalText = stripVoiceOverListeningPrefix(finalText);

    if (!finalText) {
      // ⚠️ This used to announce and return, leaving the session half-open: the
      // listening sound kept playing, STT was never cancelled (both of those
      // happen further down, past this early return), and no state was reset —
      // so the app sat in a listening state that no longer had a recognizer
      // behind it, and the next tap fell through to "ready" without ever having
      // spoken. Pilot, 11 Aug 2026: "breaks the no-response after twice, goes
      // to speak without speaking, then to ready."
      //
      // Unwind the same way every other abandoned turn does.
      await stopListenSound();
      try { await cancelSTT(); } catch { }
      finalTranscriptRef.current = '';
      setIsProcessing(false);
      isProcessingRef.current = false;
      isCapturingPhotoRef.current = false;
      setIsCameraActive(true);
      Announcer.announceStatus(strings().speech.noVoiceInput);
      if (!screenReaderEnabledRef.current) { playErrorSound(); }
      announceTapToStart('');
      return;
    }

    // ── VOICEOVER SAFETY NET ──────────────────────────────────────────────
    // Even with the STT delay, VoiceOver might still bleed into the mic.
    // Reject transcripts that are clearly VoiceOver UI text, not user speech.
    // Uses ref (not state) because handleAutoSubmit has stable [] deps.
    if (screenReaderEnabledRef.current) {
      // Unwinding a rejected turn.
      //
      // These two paths used to `return` bare, which left the session
      // half-open in exactly the way the empty-transcript case above was
      // fixed for on 11 Aug: the listening sound kept playing and STT was
      // never cancelled, so the app sat in a listening state with no
      // recognizer behind it and the next tap fell through without ever
      // speaking. Every abandoned turn has to unwind the same way.
      //
      // The one thing this must NOT do is announce: VoiceOver would read the
      // announcement, the mic would pick it up, and it would come back as the
      // next transcript — which is the very noise being rejected here.
      const unwindRejectedTurn = async (why: string) => {
        console.log(`♿ VoiceOver noise rejected (${why}):`, finalText);
        await nativeCall(
          () => stopListenSound(),
          WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
          'stopListenSound (VO noise)',
          undefined,
        );
        await nativeCall(
          () => cancelSTT(),
          WATCHDOG_TIMEOUTS.STT_CONTROL,
          'cancelSTT (VO noise)',
          undefined,
        );
        finalTranscriptRef.current = '';
        setIsProcessing(false);
        isProcessingRef.current = false;
        isCapturingPhotoRef.current = false;
        setIsCameraActive(true);
      };

      const lower = finalText.toLowerCase().trim();
      if (
        lower.length <= 12 &&
        ['speak', 'tap', 'ready', 'start', 'listen', 'listening', 'button'].includes(lower)
      ) {
        await unwindRejectedTurn('short');
        return;
      }
      const voPatterns = [
        'speak naturally', 'tap to stop', 'tap to speak', 'tap to interrupt',
        'cybersight is ready', 'cybersight is listening', 'cybersight is speaking',
        'cybersight is processing', 'processing your request', 'double tap to',
        'ready tap to speak', 'ready button', 'listening button',
        'thinking button', 'speaking button', 'navigating button',
        'button tap', 'ready tap', 'ready to speak',
        'please speak your command', 'please speak your',
      ];
      if (voPatterns.some(p => lower.includes(p))) {
        // CRITICAL: Do NOT announce anything here. Any announceForAccessibility
        // call gets read by VoiceOver, the mic picks it up, and it becomes
        // the transcript for the NEXT listening session ("please speak your command").
        await unwindRejectedTurn('pattern');
        return;
      }
    }

    console.log('⚡ Processing:', finalText);
    if (looksLikeReachingCommand(finalText)) {
      prewarmDAv2InBackground('voice command');
    }

    await stopListenSound();

    const postureOk = await waitForGoodPostureRef.current('capture');
    if (!postureOk) {
      setIsProcessing(false);
      isCapturingPhotoRef.current = false;
      earcons.play('ready');
      announceTapToStart('Ready.');
      return;
    }

    setIsProcessing(true);
    isCapturingPhotoRef.current = true;
    markTurnProgressRef.current('auto-submit accepted');
    try {
      await nativeCall(
        () => cancelSTT(),
        WATCHDOG_TIMEOUTS.STT_CONTROL,
        'cancelSTT (handleAutoSubmit)',
        undefined,
      );

      await new Promise<void>(resolve => setTimeout(() => resolve(), AUDIO_SESSION_RELEASE_DELAY_MS));

      if (isEmergencyStopped.current) {
        setIsProcessing(false);
        isCapturingPhotoRef.current = false;
        return;
      }

      let photoPath = '';
      try {
        // reactivateCameraAndCapture bounds itself, so a capture that never
        // calls back surfaces here as a TimeoutError rather than hanging the
        // turn. The voice-only fallback below already handles a failed
        // capture gracefully.
        photoPath = await reactivateCameraAndCaptureRef.current({
          enableShutterSound: false,
        });
        markTurnProgressRef.current('photo captured');
      } catch (e: any) {
        console.error('❌ Camera error:', e);

        // ── Glasses path: hard-fail with a clear message, do NOT call backend ─
        if (isWearablesCaptureError(e)) {
          await stopLatencyLoop();
          await speakWearablesError(e);
          setIsProcessing(false);
          isProcessingRef.current = false;
          isCapturingPhotoRef.current = false;
          finalTranscriptRef.current = '';
          // Reset to ready state so the next tap starts fresh.
          setIsCameraActive(true);
          earcons.play('ready');
          announceTapToStart('Ready.');
          return;
        }
        // iPhone path: keep existing voice-only fallback.
      }

      if (!photoPath && !settingsRef.current.useWearablesCamera) {
        // Voice-only fallback only applies when iPhone camera is selected.
        Announcer.announceCritical(strings().speech.photoCaptureFailed);
      }

      if (isEmergencyStopped.current) {
        setIsProcessing(false);
        isCapturingPhotoRef.current = false;
        return;
      }

      // Call via ref to avoid stale closure / circular dep
      await handleVoiceCommandRef.current(finalText, photoPath);

    } catch (error: any) {
      console.error('❌ Auto-submit error:', error);
      Announcer.announceCritical(`Error: ${error.message || error}`);
      setIsProcessing(false);
    } finally {
      isCapturingPhotoRef.current = false;
    }
  }, []); // stable — uses refs only

  // ============================================================================
  // STT hook (phone mic — used when NOT in glasses mode)
  // ============================================================================
  const {
    startListening: startSTT,
    stopListening: stopSTT,
    cancelListening: cancelSTT,
    isListening,
    transcript,
  } = useSTT({
    onAutoSubmit: handleAutoSubmit,
    enableAutoSubmit: true,
    silenceThreshold: 1500,
    enableRMSVAD: true,
    // When glasses mode is on, the wake word hook owns the Voice singleton.
    // Disable this hook to prevent listener conflicts.
    disabled: settings.useWearablesCamera,
  });

  // ── Sync transcript ref ────────────────────────────────────────────────────
  useEffect(() => {
    if (transcript) finalTranscriptRef.current = transcript;
  }, [transcript]);

  // ── Disable camera during voice recognition ────────────────────────────────
  useEffect(() => {
    if (isListening) {
      console.log('📷 Disabling camera (voice recognition active)');
      setIsCameraActive(false);
    }
  }, [isListening]);

  // ── Pulse animation ────────────────────────────────────────────────────────
  useEffect(() => {
    if ((isListening || isNavigation) && !reduceMotionEnabled) {
      Animated.loop(
        Animated.sequence([
          Animated.parallel([
            Animated.timing(pulseAnim, { toValue: 1.3, duration: 1000, useNativeDriver: true }),
            Animated.timing(opacityAnim, { toValue: 0.8, duration: 1000, useNativeDriver: true }),
          ]),
          Animated.parallel([
            Animated.timing(pulseAnim, { toValue: 1, duration: 1000, useNativeDriver: true }),
            Animated.timing(opacityAnim, { toValue: 0.3, duration: 1000, useNativeDriver: true }),
          ]),
        ])
      ).start();
    } else {
      Animated.parallel([
        Animated.timing(pulseAnim, { toValue: 1, duration: 300, useNativeDriver: true }),
        Animated.timing(opacityAnim, { toValue: 0.3, duration: 300, useNativeDriver: true }),
      ]).start();
    }
  }, [isListening, isNavigation, reduceMotionEnabled]);

  // ============================================================================
  // Wake Word STT hook (glasses mic — used when IN glasses mode)
  // ============================================================================
  const wakeWordPauseRef = useRef<(() => Promise<void>) | null>(null);
  const wakeWordResumeRef = useRef<(() => Promise<void>) | null>(null);

  const handleWakeWordQuery = useCallback(async (query: string) => {
    console.log('🎤 [WakeWord] Query received:', `"${query}"`);

    // The wake word hook has already paused itself. Run through the same
    // auto-submit pipeline that the phone-mic flow uses.
    if (isCapturingPhotoRef.current || isProcessingRef.current || isEmergencyStopped.current) {
      console.log('⚠️ [WakeWord] Already in-flight, skipping — resuming wake word');
      wakeWordResumeRef.current?.();
      return;
    }

    console.log('⚡ [WakeWord] Processing:', query);
    if (looksLikeReachingCommand(query)) {
      prewarmDAv2InBackground('wake word command');
    }

    const postureOk = await waitForGoodPostureRef.current('capture');
    if (!postureOk) {
      setIsProcessing(false);
      isCapturingPhotoRef.current = false;
      wakeWordResumeRef.current?.();
      return;
    }

    setIsProcessing(true);
    isCapturingPhotoRef.current = true;
    try {
      // Configure audio for playback before capture/backend call.
      // Skip in glasses mode — audio session is locked by BluetoothHFP.
      if (!screenReaderEnabledRef.current && !settingsRef.current.useWearablesCamera) {
        await configurePlaybackSession(!settingsRef.current.useWearablesCamera);
      }

      let photoPath = '';
      try {
        photoPath = await reactivateCameraAndCaptureRef.current({ enableShutterSound: false });
      } catch (e: any) {
        console.error('❌ [WakeWord] Camera error:', e);
        if (isWearablesCaptureError(e)) {
          await stopLatencyLoop();
          await speakWearablesError(e);
          setIsProcessing(false);
          isProcessingRef.current = false;
          isCapturingPhotoRef.current = false;
          finalTranscriptRef.current = '';
          setIsCameraActive(true);
          earcons.play('ready');
          // Resume wake word listening after error
          wakeWordResumeRef.current?.();
          return;
        }
      }

      isCapturingPhotoRef.current = false;

      if (isEmergencyStopped.current) {
        setIsProcessing(false);
        return;
      }

      // Process through the standard voice command handler
      await handleVoiceCommandRef.current(query, photoPath);

    } catch (error: any) {
      console.error('❌ [WakeWord] Auto-submit error:', error);
      Announcer.announceCritical(`Error: ${error.message || error}`);
      setIsProcessing(false);
    } finally {
      isCapturingPhotoRef.current = false;
    }
  }, []);
  const handleWakeWordHeard = useCallback(() => {
    console.log('🎤 [WakeWord] Wake phrase detected!');
  }, []);

  const {
    isAwaitingWakeWord,
    isCapturingQuery: isWakeWordCapturing,
    queryTranscript: wakeWordTranscript,
    debugStatus: wakeWordDebugStatus,
    debugRawTranscript: wakeWordDebugRaw,
    pause: pauseWakeWord,
    resume: resumeWakeWord,
    stop: stopWakeWord,
  } = useWakeWordSTT({
    onQueryDetected: handleWakeWordQuery,
    onWakeWordHeard: handleWakeWordHeard,
    enabled: settings.useWearablesCamera && !showSettings && !showStartupLoader,
    microphoneSource: settings.wearablesMicrophoneSource,
    silenceThreshold: 1500,
    enableOpenAIVAD: true,
  });

  // Keep refs in sync so stable callbacks can access pause/resume
  useEffect(() => {
    wakeWordPauseRef.current = pauseWakeWord;
    wakeWordResumeRef.current = resumeWakeWord;
  }, [pauseWakeWord, resumeWakeWord]);

  // ── Re-entry guard for startListening ─────────────────────────────────────
  const isStartingRef = useRef(false);

  // ============================================================================
  // Start Listening
  // ============================================================================
  const startListening = async () => {
    // ── Re-entry guard: prevent multiple concurrent calls ────────────────
    // VoiceOver double-tap can fire handleScreenTap multiple times if the
    // user taps rapidly. Without this guard, each tap queues a startSTT().
    if (isStartingRef.current) {
      console.log('⚠️ startListening already in progress — ignoring');
      return;
    }
    isStartingRef.current = true;

    const voiceOverEnabled = screenReaderEnabledRef.current;
    if (voiceOverEnabled) {
      // INTENTIONAL: do NOT call announceForAccessibility('Listening') here.
      // The button's accessibilityLabel automatically becomes "Listening"
      // when isListening flips true — VoiceOver reads that label change on
      // its own. Adding a manual announcement here produces the double-voice
      // echo and consumes the user's next double-tap.
      //
      // The delay below is still useful: it gives VoiceOver time to finish
      // reading whatever label change just happened before we open the mic,
      // so the recogniser doesn't capture VoiceOver's own speech.
      await new Promise<void>(resolve => setTimeout(() => resolve(), VOICEOVER_LISTENING_ANNOUNCE_DELAY_MS));
    }

    try {
      await stopLatencyLoop(); // ensure no stale thinking loop continues into listening
      if (Platform.OS === 'android') {
        const granted = await PermissionsAndroid.request(
          PermissionsAndroid.PERMISSIONS.RECORD_AUDIO
        );
        if (granted !== PermissionsAndroid.RESULTS.GRANTED) {
          Alert.alert('Permission Required', 'Microphone access is required.');
          return;
        }
      }

      isEmergencyStopped.current = false;
      isCapturingPhotoRef.current = false;
      await stopTTS();
      finalTranscriptRef.current = '';

      // ── Audio feedback ────────────────────────────────────────────────
      //
      // The listening cue is the single most important sound the app makes:
      // it is the "speak now" signal, and the whole turn depends on the user
      // starting to talk at the right moment. It used to be skipped entirely
      // whenever VoiceOver was on, which left blind users guessing — the very
      // users who cannot see the visualizer that was standing in for it.
      //
      // Only the EXCLUSIVE session grab is still gated. configurePlaybackSession
      // calls setActive(true), which cuts VoiceOver off mid-word and produced
      // the "!pri" errors and glitchy artifacts that motivated the original
      // suppression. The cue itself now requests a mixable session (see
      // setScreenReaderMode in utils/soundEffects.ts) and coexists with
      // VoiceOver instead of fighting it for ownership.
      if (!screenReaderEnabled) {
        // FIX: After STT leaves the audio session in Record+Measurement mode,
        // react-native-sound's setCategory alone doesn't restore full volume.
        // This native call sets .playback + .default mode + setActive + speaker
        // route — matching the reaching pipeline's audio config.
        await configurePlaybackSession(!settingsRef.current.useWearablesCamera);
      }

      // Single 215ms tone. Users start speaking on it, and the mic is not
      // open until this promise resolves + the settle delay below — so the
      // cue asset must never grow back into a multi-tone earcon.
      // See playListenSound() in utils/soundEffects.ts.
      await earcons.playAndWait('listenStart');

      // The listening cue is finished now; switch to recording for STT.
      prepareForRecording();

      // Delay to let the audio session reconfigure after the category switch.
      //
      // 350ms was tuned against configurePlaybackSession, which performs a
      // full native category + mode + setActive + route override. Under
      // VoiceOver that call is skipped and the only switch is
      // react-native-sound's much lighter setCategory, so charging the same
      // delay would add a third of a second of dead microphone to the users
      // who already wait longest — they also sit through the 800ms VoiceOver
      // settle above. Retune either number only with on-device verification.
      await new Promise<void>(resolve =>
        setTimeout(() => resolve(), screenReaderEnabled ? 150 : 350),
      );

      // ── Start STT with a short VoiceOver grace window ─────────────────
      // VoiceOver speaks "Listening"; the mic can catch the tail end.
      // We discard a brief window of early results to avoid the prefix
      // while keeping the app responsive for the user.
      const gracePeriodMs = voiceOverEnabled ? VOICEOVER_LISTENING_GRACE_MS : 0;

      await startSTT(gracePeriodMs);
      console.log('✅ Voice recognition started');
    } catch (error) {
      console.error('❌ Start listening error:', error);
      if (screenReaderEnabled) {
        Announcer.announceCritical(strings().speech.errorStartingVoice);
      }
    } finally {
      isStartingRef.current = false;
    }
  };

  // ============================================================================
  // Manual Stop
  // ============================================================================
  const stopListeningManually = async () => {
    try {
      if (isCapturingPhotoRef.current || isProcessingRef.current || isEmergencyStopped.current) return;

      const finalTranscript = await stopSTT();
      let finalText = finalTranscript.trim();
      finalText = stripVoiceOverListeningPrefix(finalText);
      if (!finalText) { /* ... */ return; }

      // ── VoiceOver safety net ────────────────────────────────────────────
      if (isVoiceOverNoise(finalText)) {
        console.log('♿ VoiceOver noise rejected (manual stop):', finalText);
        // Silent discard — no announcement (would feed back into mic)
        return;
      }

      const postureOk = await waitForGoodPosture('capture');
      if (!postureOk) {
        earcons.play('ready');
        announceTapToStart('Ready.');
        return;
      }

      isCapturingPhotoRef.current = true;
      await new Promise<void>(resolve => setTimeout(() => resolve(), AUDIO_SESSION_RELEASE_DELAY_MS));
      if (isEmergencyStopped.current) { isCapturingPhotoRef.current = false; return; }

      let photoPath = '';
      try {
        photoPath = await reactivateCameraAndCaptureRef.current({
          enableShutterSound: true,
        });
      } catch (e: any) {
        console.error('❌ Camera error (manual stop):', e);
        isCapturingPhotoRef.current = false;
        if (isWearablesCaptureError(e)) {
          await stopLatencyLoop();
          await speakWearablesError(e);
          setIsProcessing(false);
          isProcessingRef.current = false;
          setIsCameraActive(true);
          earcons.play('ready');
          announceTapToStart('Ready.');
          return;
        }
        // iPhone path: fall through with empty photoPath, voice-only.
      }
      isCapturingPhotoRef.current = false;

      // FIX: Check emergency flag AFTER capture — user may have tapped
      // emergency stop while the camera was taking the photo
      if (isEmergencyStopped.current) return;

      // ✅ DON'T set isProcessingRef here — handleVoiceCommand sets it itself
      await handleVoiceCommand(finalText, photoPath);
    } catch (error) {
      isCapturingPhotoRef.current = false;
      setIsProcessing(false);
      isProcessingRef.current = false;
    }
  };

  // ============================================================================
  // Emergency Stop
  // ============================================================================
  const emergencyStop = async () => {
    console.log('🚨 EMERGENCY STOP');

    // ── Release every input gate FIRST, before any await ──────────────────
    // This ordering is the whole point. The teardown below talks to native
    // modules, and emergency stop is precisely the moment when one of them is
    // most likely to be wedged — that is usually why the user is reaching for
    // it. Awaiting native work before clearing the latches meant the recovery
    // path could hang on the same module it was trying to recover from,
    // leaving the app permanently deaf: the one action guaranteed to save the
    // session was the one that could not complete.
    //
    // Clearing synchronously first means the app is responsive again the
    // instant the user taps, whatever native does afterwards.
    releaseInputGates('emergency stop');
    // Queued announcements describe a session that is over. Speaking them now
    // would talk over the stop confirmation and describe a state the app is
    // no longer in — which is how "it kept talking after I stopped it" gets
    // reported as the app ignoring the stop.
    Announcer.reset();
    pendingActionRef.current = null;
    isEmergencyStopped.current = true;
    isStartingRef.current = false; // ← release re-entry guard
    continuousModeAbortRef.current = true;
    arSessionAliveRef.current = false;
    // Whatever native screen was up is going away, and the stop confirmation
    // below is the one cue a user who just interrupted must hear.
    earcons.setNativeSessionActive(false);
    continuousTtsGenerationRef.current++;

    setIsProcessing(false);
    setIsSpeaking(false);
    setIsNavigation(false);
    setIsReaching(false);

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    resetContinuousSpeechQueue();
    stopContinuousMode('emergency stop', false);

    // ── Best-effort teardown, all bounded ─────────────────────────────────
    // Every one of these can wedge. None of them may block the others, and
    // none of them can block the user any more.
    await nativeCall(
      () => ARKitNavigationBridge.stopNavigation(),
      WATCHDOG_TIMEOUTS.AR_TEARDOWN,
      'ARKitNavigationBridge.stopNavigation',
      undefined,
    );
    await nativeCall(
      () => stopLatencyLoop(),
      WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
      'stopLatencyLoop',
      undefined,
    );
    await nativeCall(
      () => speachesSentenceChunker.stop(),
      WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
      'speachesSentenceChunker.stop',
      undefined,
    );
    await nativeCall(
      () => cancelSTT(),
      WATCHDOG_TIMEOUTS.STT_CONTROL,
      'cancelSTT',
      undefined,
    );
    await nativeCall(
      () => Promise.resolve(wakeWordPauseRef.current?.()),
      WATCHDOG_TIMEOUTS.STT_CONTROL,
      'wakeWordPause',
      undefined,
    );

    await new Promise<void>(resolve => setTimeout(() => resolve(), 300));

    // Re-assert: the bounded teardown above yields, and an in-flight turn
    // could have set a gate again on its way out.
    releaseInputGates('emergency stop settled');
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(true);
    // NOTE: Do NOT clear isEmergencyStopped here. It is cleared in
    // startListening() when the user initiates a new interaction.
    // Clearing it here allows in-flight async ops (photo capture in
    // handleAutoSubmit) to resume and restart the latency loop.

    // Emergency stop is where the confirmation cue matters most: the user
    // reached for it because they had lost confidence in what the app was
    // doing, and silence in response is the worst possible answer.
    earcons.play('modeExit');
    announceTapToStart('Stopped.');

    // Resume wake word listening after emergency stop
    if (settingsRef.current.useWearablesCamera) {
      isEmergencyStopped.current = false; // clear so wake word flow can proceed
      wakeWordResumeRef.current?.();
    }
    console.log('✅ Emergency stop complete');
  };

  // ============================================================================
  // Turn watchdog — the backstop that makes a hang self-clearing
  // ============================================================================
  // Every specific fix in this change removes one way for a turn to strand.
  // This removes the *consequence* of stranding, including for causes not yet
  // identified: a turn that holds the input gate without making progress is
  // unwound automatically and the user is told, out loud, that they can speak
  // again. No force-quit, no silent deaf app, no lost pilot session.
  //
  // The trigger is silence, not duration. `markTurnProgress` is called at each
  // real step, so a slow-but-working turn keeps resetting the clock and is
  // never interrupted. Active AR sessions are exempt entirely: navigation and
  // reaching legitimately run for minutes with no JS-side activity, and both
  // now carry their own native watchdogs.
  const recoverFromStuckTurn = useCallback(async (heldForMs: number) => {
    if (turnWatchdogRecoveringRef.current) return;
    turnWatchdogRecoveringRef.current = true;

    console.error(
      `🚑 [turn-watchdog] Input has been gated for ${Math.round(heldForMs / 1000)}s ` +
      'with no forward progress — force-recovering',
    );
    debugLogger.logAPI(
      '🚑 Turn watchdog recovery',
      `heldForMs=${heldForMs} processing=${isProcessingRef.current} ` +
      `capturing=${isCapturingPhotoRef.current}`,
    );

    try {
      // Free the gates before anything else, for the same reason emergency
      // stop does: the teardown may itself be talking to a wedged module.
      releaseInputGates('turn watchdog');
      setIsProcessing(false);
      setIsSpeaking(false);

      if (abortControllerRef.current) {
        abortControllerRef.current.abort();
        abortControllerRef.current = null;
      }

      continuousTtsGenerationRef.current++;
      resetContinuousSpeechQueue();
      stopContinuousMode('turn watchdog recovery', false);

      await nativeCall(
        () => stopLatencyLoop(),
        WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
        'stopLatencyLoop (watchdog)',
        undefined,
      );
      await nativeCall(
        () => speachesSentenceChunker.stop(),
        WATCHDOG_TIMEOUTS.AUDIO_CONTROL,
        'chunker.stop (watchdog)',
        undefined,
      );
      await nativeCall(
        () => cancelSTT(),
        WATCHDOG_TIMEOUTS.STT_CONTROL,
        'cancelSTT (watchdog)',
        undefined,
      );

      releaseInputGates('turn watchdog settled');
      setIsCameraActive(true);

      // Say something. A blind user has been waiting on silence; the one
      // thing they must not have to do is guess whether the app is alive.
      const message = strings().speech.requestFailed;
      if (screenReaderEnabledRef.current) {
        Announcer.announceStatus(message);
      } else {
        await nativeCall(
          () => speachesSentenceChunker.synthesizeSpeechChunked(message),
          WATCHDOG_TIMEOUTS.TTS_CHUNK,
          'watchdog recovery speech',
          undefined,
        );
        earcons.play('ready');
      }
      announceTapToStart('Ready.');

      if (settingsRef.current.useWearablesCamera) {
        isEmergencyStopped.current = false;
        wakeWordResumeRef.current?.();
      }
    } finally {
      turnWatchdogRecoveringRef.current = false;
    }
  }, [announceTapToStart, cancelSTT, releaseInputGates, resetContinuousSpeechQueue]);

  // Read through a ref so the interval below can be created exactly once.
  const recoverFromStuckTurnRef = useRef(recoverFromStuckTurn);
  useEffect(() => {
    recoverFromStuckTurnRef.current = recoverFromStuckTurn;
  }, [recoverFromStuckTurn]);

  useEffect(() => {
    // Must exceed the longest step a healthy turn can legitimately spend
    // without reporting progress, or the backstop becomes the bug: the
    // workflow request is bounded at CONFIG.REQUEST_TIMEOUT and
    // marks progress only when it returns, so anything at or below that would
    // tear down requests that were still going to succeed. Derived rather than
    // hardcoded so raising the request timeout cannot silently reintroduce
    // that. The margin covers the bounded audio and TTS work on either side.
    const STUCK_TURN_MS = CONFIG.REQUEST_TIMEOUT + 30_000;
    const CHECK_INTERVAL_MS = 5_000;

    // Speech counts as progress. A long response is spoken as a sequence of
    // chunks, and each chunk is individually bounded by the TTS safety timer,
    // so an advancing chunk index proves the pipeline is moving even though no
    // JS step is running. Without this the watchdog would cut off a long but
    // perfectly healthy answer mid-sentence.
    let lastSpeechMarker = '';

    // Empty deps, everything read through refs: this interval must be created
    // once and live for the life of the screen. If it were rebuilt on every
    // render — which is what happens the moment a dependency stops being
    // stable — the 5s timer would keep restarting and the watchdog would
    // silently never fire, which is the one failure this code cannot have.
    const timer = setInterval(() => {
      if (speachesSentenceChunker.isCurrentlyPlaying()) {
        const { current, total } = speachesSentenceChunker.getProgress();
        const marker = `${current}/${total}`;
        if (marker !== lastSpeechMarker) {
          lastSpeechMarker = marker;
          lastTurnProgressAtRef.current = Date.now();
        }
      } else {
        lastSpeechMarker = '';
      }

      const gated = isProcessingRef.current || isCapturingPhotoRef.current;
      if (!gated) {
        // Idle: keep the clock fresh so the next turn starts from now.
        lastTurnProgressAtRef.current = Date.now();
        return;
      }

      // A live AR session is allowed to take as long as the walk takes.
      if (
        isNavigationRef.current ||
        isReachingRef.current ||
        arSessionAliveRef.current
      ) {
        lastTurnProgressAtRef.current = Date.now();
        return;
      }

      if (turnWatchdogRecoveringRef.current) return;

      const heldForMs = Date.now() - lastTurnProgressAtRef.current;
      if (heldForMs > STUCK_TURN_MS) {
        void recoverFromStuckTurnRef.current(heldForMs);
      }
    }, CHECK_INTERVAL_MS);

    return () => clearInterval(timer);
  }, []);

  // ============================================================================
  // Foreground recovery
  // ============================================================================
  // iOS suspends the app when it goes to the background, and native callbacks
  // that were in flight at that moment are often simply never delivered — the
  // AR session is interrupted, the audio session is handed to another app, the
  // speech recognizer is torn down. Coming back to the foreground with a latch
  // still held is the other way a session used to die, and it is why "close
  // and reopen" worked: relaunching was the only thing that reset the flags.
  //
  // Reopening should not be necessary. If the app returns to the foreground
  // gated but with no AR session running, that turn is over — its callbacks
  // are not coming — so release it and let the user speak.
  useEffect(() => {
    const sub = AppState.addEventListener('change', state => {
      if (state !== 'active') return;

      const gated = isProcessingRef.current || isCapturingPhotoRef.current;
      const arActive =
        isNavigationRef.current ||
        isReachingRef.current ||
        arSessionAliveRef.current;

      if (gated && !arActive) {
        console.warn(
          '🚑 [foreground] Returned to foreground with input still gated — releasing',
        );
        releaseInputGates('returned to foreground');
        setIsProcessing(false);
        setIsSpeaking(false);
        setIsCameraActive(true);
        announceTapToStart('Ready.');
      }

      // Whatever happened while suspended, do not let stale time trip the
      // turn watchdog the moment we come back.
      lastTurnProgressAtRef.current = Date.now();
    });

    return () => sub.remove();
  }, [announceTapToStart, releaseInputGates]);

  // ============================================================================
  // Accessibility helpers
  // ============================================================================

  // ── VoiceOver Noise Filter ──────────────────────────────────────────────
  // When VoiceOver is on, it reads UI elements aloud. The mic can pick
  // this up and the speech recognizer treats it as user speech. This filter
  // rejects transcripts that match known VoiceOver UI text patterns.
  const isVoiceOverNoise = useCallback((text: string): boolean => {
    if (!screenReaderEnabled) return false;
    const lower = text.toLowerCase().trim();
    if (
      lower.length <= 12 &&
      ['speak', 'tap', 'ready', 'start', 'listen', 'listening', 'button'].includes(lower)
    ) {
      return true;
    }
    const patterns = [
      // Old labels (might still echo from previous announcement)
      'speak naturally', 'tap to stop', 'tap to speak', 'tap to interrupt',
      'cybersight is ready', 'cybersight is listening', 'cybersight is speaking',
      'cybersight is processing', 'processing your request', 'double tap to',
      // New simplified labels (VoiceOver reads these from the button)
      'ready tap to speak', 'ready button', 'listening button',
      'thinking button', 'speaking button', 'navigating button',
      'speaking tap', 'thinking tap', 'navigating tap',
      // Generic VoiceOver UI fragments
      'button tap', 'ready tap', 'ready to speak',
      // Our own rejection announcements (if they leaked)
      'please speak your command', 'please speak your',
    ];
    return patterns.some(p => lower.includes(p));
  }, [screenReaderEnabled]);

  const getAccessibilityLabel = () => {
    // VoiceOver reads: {label}. {role}.
    // With accessibilityRole="button", VoiceOver appends "Button" automatically.
    // So "Ready. Tap to speak" → VoiceOver says "Ready. Tap to speak. Button."
    // Keep labels SHORT — no "CyberSight is" prefix (wastes time).
    if (isNavigation) return 'Navigating. Tap to stop';
    if (isSpeaking) return 'Speaking. Tap to stop';
    if (isProcessing) return 'Thinking';
    if (isListening || isWakeWordCapturing) return 'Listening';
    if (isAwaitingWakeWord) return 'Say Hey ShelfScout to ask a question';
    return screenReaderEnabled ? 'Ready' : 'Ready. Tap to speak';
  };

  // Debounce the accessibility label to prevent VoiceOver from resetting
  // its double-tap gesture on rapid state transitions.
  const rawLabel = getAccessibilityLabel();
  useEffect(() => {
    if (!screenReaderEnabled) {
      // No debouncing needed without VoiceOver
      setDebouncedLabel(rawLabel);
      return;
    }
    // Clear any pending label update
    if (labelTimerRef.current) {
      clearTimeout(labelTimerRef.current);
    }
    // Once redundant announcements are removed (see announceIfNoVoiceOver
    // throughout this file), label cycling is much rarer. 150ms is short
    // enough to feel responsive but long enough to absorb the Listening→
    // Thinking transition that fires within ~50ms of releasing the mic.
    labelTimerRef.current = setTimeout(() => {
      setDebouncedLabel(rawLabel);
    }, 150);
    return () => {
      if (labelTimerRef.current) {
        clearTimeout(labelTimerRef.current);
      }
    };
  }, [rawLabel, screenReaderEnabled]);

  // Use debounced label for VoiceOver, raw label for sighted users
  const effectiveLabel = screenReaderEnabled ? (debouncedLabel || rawLabel) : rawLabel;

  const getAccessibilityHint = () => {
    // Hints are read AFTER label + role, with a pause.
    // Only use for info NOT in the label.
    if (screenReaderEnabled && !isListening && !isProcessing && !isSpeaking && !isNavigation) {
      return 'Double tap to start listening';
    }
    return '';
  };

  // ── Persistent activity status ─────────────────────────────────────────
  //
  // The same information the visualizer draws, in a form VoiceOver can focus.
  // `activityStatus` is preferred wherever it is set because it names the
  // TARGET as well as the state — "Finding the cereal" answers a question that
  // "Thinking" leaves open, and mid-session the target is the thing users
  // most often lost track of.
  const overlayStatus = (() => {
    const flow = strings().flow;
    if (isReaching || isNavigation) return activityStatus || flow.statusThinking;
    if (isSpeaking) return flow.statusSpeaking;
    if (isProcessing) return activityStatus || flow.statusThinking;
    if (isListening || isWakeWordCapturing) return flow.statusListening;
    return activityStatus || flow.statusReady;
  })();

  // Clear the turn-scoped status once everything settles, so a stale target
  // name cannot be read back during the next, unrelated turn.
  useEffect(() => {
    if (
      !isListening &&
      !isProcessing &&
      !isSpeaking &&
      !isNavigation &&
      !isReaching &&
      !isWakeWordCapturing
    ) {
      setActivityStatus('');
      pendingActionRef.current = null;
      setPendingAction(null);
    }
  }, [isListening, isProcessing, isSpeaking, isNavigation, isReaching, isWakeWordCapturing]);

  // ============================================================================
  // Handle Tap
  // ============================================================================
  const handleScreenTap = async () => {
    console.log('👆 TAP');

    if (isNavigation || isReaching || isContinuousModeRunning.current) {
      const mode = isNavigation ? 'navigation' : 'reaching';
      // Bug 1/2 fix: Skip announcement when VoiceOver is on to avoid
      // consuming the next double-tap gesture.
      if (!screenReaderEnabledRef.current) {
        Announcer.announceStatus(strings().speech.stoppingMode(mode));
      }
      await stopContinuousModeLoop();
      // Resume wake word after stopping continuous mode
      if (settingsRef.current.useWearablesCamera) {
        wakeWordResumeRef.current?.();
      }
      return;
    }

    if (isSpeaking || isProcessing) {
      // Bug 1/2 fix: Skip the announcement when VoiceOver is on.
      // VoiceOver reading 'Stopping' consumes the next double-tap gesture,
      // making the user tap additional times to reach the Ready state.
      if (!screenReaderEnabledRef.current) {
        Announcer.announceStatus(strings().speech.stopping);
      }
      await emergencyStop();
      return;
    }

    if (isListening) {
      // Bug 1/2 fix: VoiceOver reads the label change to 'Thinking' automatically.
      if (!screenReaderEnabledRef.current) {
        Announcer.announceStatus(strings().speech.thinking);
      }
      await stopListeningManually();
      return;
    }

    // In glasses mode, tap is a no-op when already listening for wake word
    // (the user should say "hey shelfscout" instead of tapping)
    if (isAwaitingWakeWord || isWakeWordCapturing) {
      console.log('👆 [Glasses] Tap during wake word listening — no-op');
      return;
    }

    // A bare tap is an open-ended request. If a menu row opened a previous
    // listening session that was abandoned before it reached the pipeline,
    // its intent must not survive to wrap this unrelated utterance — the user
    // would ask a question and be sent hand-guidance instead.
    pendingActionRef.current = null;
    setPendingAction(null);

    await startListening();
  };

  // `startListening` and `handleScreenTap` are plain functions, re-created on
  // every render. Mirroring them the way `waitForGoodPostureRef` does lets the
  // menu handlers below be genuinely []-memoized instead of listing a
  // dependency that changes every render — which would make every callback
  // handed to ActionMenu a new identity and re-render the whole menu on any
  // state change, including ones that have nothing to do with it.
  const startListeningRef = useRef(startListening);
  const handleScreenTapRef = useRef(handleScreenTap);
  useEffect(() => {
    startListeningRef.current = startListening;
    handleScreenTapRef.current = handleScreenTap;
  });

  // ============================================================================
  // Menu actions
  // ============================================================================
  //
  // Every handler below is a complete path from a button press to a running
  // pipeline. None of them consults an intent classifier, and four of the six
  // never open the microphone. That is the point: the app's capabilities stop
  // depending on whether a sentence was heard and understood correctly.

  /** True while a turn owns the input gates and a new one must not start. */
  const isTurnRunning = useCallback(
    () =>
      isProcessingRef.current ||
      isCapturingPhotoRef.current ||
      isNavigationRef.current ||
      isReachingRef.current ||
      isContinuousModeRunning.current,
    [],
  );

  /** Speak an answer through whichever channel the user is actually hearing. */
  const speakAnswer = useCallback(async (text: string) => {
    if (screenReaderEnabledRef.current) {
      // `force` because a repeat is deliberately the same words as last time,
      // which is exactly what the duplicate filter is built to drop.
      Announcer.announce(text, { priority: 'status', force: true });
      return;
    }
    try {
      await configurePlaybackSession(!settingsRef.current.useWearablesCamera);
      await speachesSentenceChunker.synthesizeSpeechChunked(text);
    } catch (e: any) {
      if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
        console.warn('⚠️ speakAnswer failed:', e?.message || e);
      }
    }
  }, []);

  /**
   * Capture a frame and run a fixed command — no speech recognition anywhere
   * in the path.
   *
   * Mirrors `stopListeningManually` exactly from the posture gate onward. It
   * deliberately does not share code with it: that function's first half is
   * all microphone teardown and transcript validation, and threading a
   * "there is no transcript" flag through it would put a branch in the most
   * heavily-patched control flow in the app to save a dozen lines here.
   */
  const runDirectCommand = useCallback(async (command: string, status: string) => {
    if (isTurnRunning()) {
      Announcer.announce(strings().flow.busy, { priority: 'status' });
      return;
    }

    setActivityStatus(status);
    Announcer.announce(status, { priority: 'status' });
    isEmergencyStopped.current = false;

    // Claim the capture latch BEFORE the posture wait, not after it. The
    // posture gate can hold for several seconds while the user re-aims the
    // phone, and a press during that window passed `isTurnRunning()` and
    // started a second capture on top of the first.
    //
    // `setIsProcessing` sets the React state only — never `isProcessingRef` —
    // because `handleVoiceCommand` returns early when that ref is already set,
    // so setting it here would make the turn we are about to start refuse to
    // run. Same split as `handleAutoSubmit`. Setting the state does flip the
    // screen out of idle, which is what puts a Stop button in reach while the
    // camera is still waking.
    isCapturingPhotoRef.current = true;
    setIsProcessing(true);
    markTurnProgressRef.current('direct command accepted');

    // Started before the capture, not after, because the camera takes most of
    // a second to wake and hand back a frame. Without a cue filling that gap
    // the press produces silence, and a user who gets silence presses again —
    // which cancels the turn they just started. That was the single most
    // common self-inflicted failure in the pilot.
    earcons.play('thinking');

    const postureOk = await waitForGoodPostureRef.current('capture');
    if (!postureOk) {
      // The loop plays until something stops it. Every early return from here
      // on has to stop it, or the app is left buzzing at a user who has been
      // told to reposition the phone and has no idea the app gave up.
      await stopLatencyLoop();
      isCapturingPhotoRef.current = false;
      setIsProcessing(false);
      setActivityStatus('');
      earcons.play('ready');
      return;
    }

    let photoPath = '';
    try {
      photoPath = await reactivateCameraAndCaptureRef.current({ enableShutterSound: false });
      markTurnProgressRef.current('direct command photo captured');
    } catch (e: any) {
      console.error('❌ Camera error (direct command):', e);
      isCapturingPhotoRef.current = false;
      await stopLatencyLoop();
      if (isWearablesCaptureError(e)) {
        await speakWearablesError(e);
      } else {
        Announcer.announceCritical(strings().speech.photoCaptureFailed);
      }
      setActivityStatus('');
      setIsProcessing(false);
      isProcessingRef.current = false;
      setIsCameraActive(true);
      earcons.play('error');
      return;
    }
    isCapturingPhotoRef.current = false;

    if (isEmergencyStopped.current) {
      // The user stopped while the camera was busy. Release the state this
      // function claimed — emergencyStop cleared the refs, but the React
      // `isProcessing` set above is ours to undo, and leaving it true holds
      // the screen off the menu with nothing running behind it.
      await stopLatencyLoop();
      setIsProcessing(false);
      setActivityStatus('');
      return;
    }

    await handleVoiceCommandRef.current(command, photoPath);
  }, [isTurnRunning]);

  /**
   * Start listening on behalf of a menu row.
   *
   * The prompt is spoken before the microphone opens rather than after,
   * because the listening cue is the signal to start talking: a user who
   * hears "What should I find?" *after* the cue has already spoken over the
   * first word of their answer.
   */
  const startListeningFor = useCallback(async (action: MenuActionId, prompt: string) => {
    if (isTurnRunning()) {
      Announcer.announce(strings().flow.busy, { priority: 'status' });
      return;
    }
    pendingActionRef.current = action;
    setPendingAction(action);
    setActivityStatus(strings().flow.statusListening);
    Announcer.announce(prompt, { priority: 'status' });
    await startListeningRef.current();
  }, [isTurnRunning]);

  /**
   * Fire-and-forget a menu action, but never silently.
   *
   * `onPress` cannot await, so these promises are unobserved by definition. An
   * unobserved rejection here would leave the user holding a phone that made a
   * selection sound and then did nothing at all — the exact failure mode this
   * whole screen exists to eliminate. So a failure gets an error cue, which is
   * the one thing a blind user can act on.
   */
  const runWithFailureCue = useCallback((work: Promise<unknown>) => {
    work.catch((error: any) => {
      console.error('❌ [menu] action failed:', error);
      earcons.play('error');
      Announcer.announceCritical(strings().speech.requestFailed);
      setActivityStatus('');
    });
  }, []);

  const handleMenuAction = useCallback((action: MenuActionId) => {
    const t = strings();
    switch (action) {
      case 'ask':
        runWithFailureCue(startListeningFor('ask', t.flow.askPrompt));
        return;
      case 'find':
        runWithFailureCue(startListeningFor('find', t.flow.findPrompt));
        return;
      case 'describe':
        runWithFailureCue(
          runDirectCommand(t.commands.describeScene, t.flow.statusDescribing),
        );
        return;
      case 'navigate':
        setHomeView('destinations');
        return;
      case 'repeat': {
        const answer = lastAnswerRef.current;
        if (!answer) {
          Announcer.announce(t.flow.nothingToRepeat, { priority: 'status' });
          return;
        }
        runWithFailureCue(speakAnswer(answer));
        return;
      }
    }
  }, [runDirectCommand, runWithFailureCue, speakAnswer, startListeningFor]);

  /**
   * Launch route guidance to a destination the user picked from the list.
   *
   * The synthesized result stands in for a backend response, so this reuses
   * the identical, already-tested code path a spoken request takes — the only
   * difference is that `navigation_target` is an exact saved label rather
   * than a transcription that then has to be fuzzy-matched back to one.
   */
  const handleDestinationSelected = useCallback(async (entry: {
    label: string; mapId: string; mapName: string;
  }) => {
    if (isTurnRunning()) {
      Announcer.announce(strings().flow.busy, { priority: 'status' });
      return;
    }

    isEmergencyStopped.current = false;
    setActivityStatus(strings().flow.statusNavigating(entry.label));
    earcons.play('modeEnter');

    // The picker stays mounted until navigation resolves. Returning to the
    // menu first looks harmless but is not: ActionMenu moves VoiceOver focus
    // to its first row on mount, so the user who just chose a destination
    // would be thrown back to "Ask a question" while the route was still
    // loading — reading, to them, as if their choice had been discarded.
    try {
      const handled = await handleARKitNavigation(
        {
          navigation: true,
          navigation_pipeline: 'arkit',
          navigation_target: entry.label,
          route_map_id: entry.mapId,
          route_map_name: entry.mapName,
        },
        { requestedText: entry.label },
      );

      if (!handled) {
        // Route guidance is an ARKit-only capability. On a device or a
        // settings combination where it does not resolve, say so plainly
        // instead of returning the user to a menu that silently did nothing.
        Announcer.announceCritical(strings().navigation.unavailableFallback);
        earcons.play('error');
      }
    } catch (error: any) {
      // Nothing awaits this handler — it is a button's onPress — so an
      // unhandled rejection would strand the user on a picker that has stopped
      // responding with no indication why.
      console.error('❌ [menu] destination launch failed:', error);
      Announcer.announceCritical(strings().navigation.endedWithError);
      earcons.play('error');
    } finally {
      setActivityStatus('');
      setHomeView('menu');
    }
  }, [handleARKitNavigation, isTurnRunning]);

  /** The Stop button in ActivityOverlay. Same semantics as tapping the screen. */
  const handleStopPressed = useCallback(async () => {
    Announcer.reset();
    earcons.play('modeExit');
    setActivityStatus('');
    pendingActionRef.current = null;
    setPendingAction(null);
    await handleScreenTapRef.current();
  }, []);

  // ============================================================================
  // Render
  // ============================================================================
  const renderLoaderScreen = (label: string) => (
    <View
      style={styles.loaderContainer}
      accessible={true}
      accessibilityLabel={label}
    >
      <StatusBar barStyle="light-content" backgroundColor="#000" />
      <Text style={styles.loaderTitle} accessible={false}>shelfscout</Text>

      <View style={styles.loaderBottomMediaContainer} accessible={false}>
        <Video
          source={require('./src/assets/videos/srlLogo.mp4')}
          style={styles.loaderBottomMedia}
          resizeMode="contain"
          repeat={true}
          muted={true}
          paused={false}
          playWhenInactive={false}
          playInBackground={false}
          ignoreSilentSwitch="ignore"
          onLoad={() => {
            console.log('✅ Startup logo video loaded');
          }}
          onError={(error) => {
            console.error('❌ Startup logo video error:', error);
          }}
          accessible={false}
        />
      </View>
    </View>
  );

  if (showStartupLoader) {
    return renderLoaderScreen('Starting ShelfScout. Please wait.');
  }

  if (!settings.useWearablesCamera && (!hasCameraPermission || !device)) {
    return renderLoaderScreen('Waiting for camera permission.');
  }

  // ── Settings overlay (full-screen, sits above everything) ─────────────────
  if (showSettings) {
    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" backgroundColor="#0A0A0F" />
        <SettingsScreen onClose={() => setShowSettings(false)} />
        {settings.developerMode && <DebugOverlay />}
      </View>
    );
  }

  // ── Home surfaces (menu / destinations) ───────────────────────────────────
  //
  // Shown only while nothing is running. An active turn always takes the
  // screen, so the user can never be looking at a menu while the app is
  // mid-session — which was a real source of confusion when the only visible
  // difference between the two was a word in the middle of the display.
  //
  // The wake-word wait is treated as idle on purpose: in glasses mode the app
  // sits there for minutes at a time, and hiding every capability behind that
  // wait would mean the phone in the user's hand can do nothing while the
  // glasses listen.
  const isIdle =
    !isListening &&
    !isProcessing &&
    !isSpeaking &&
    !isNavigation &&
    !isReaching &&
    !isWakeWordCapturing;

  const useMenuHome = settings.homeScreenLayout === 'menu';

  if (useMenuHome && isIdle) {
    return (
      <View style={styles.container}>
        <StatusBar barStyle="light-content" backgroundColor="#111A2E" />

        {/*
          Kept mounted behind the opaque menu. "Describe surroundings" and
          "Read text" capture the instant they are pressed, and a camera that
          has to cold-start first adds roughly a second of dead air between
          the press and any sign that something happened — long enough that
          pilot users pressed again, which cancelled the turn they had just
          started.
        */}
        {!settings.useWearablesCamera && device && (
          <Camera
            ref={cameraRef}
            style={StyleSheet.absoluteFill}
            device={device}
            isActive={isCameraActive}
            photo={true}
            accessible={false}
            accessibilityElementsHidden={true}
            importantForAccessibility="no-hide-descendants"
          />
        )}

        {homeView === 'destinations' ? (
          <DestinationPicker
            onSelect={handleDestinationSelected}
            onCancel={() => setHomeView('menu')}
          />
        ) : (
          <ActionMenu
            onAction={handleMenuAction}
            onOpenSettings={() => setShowSettings(true)}
            canRepeat={Boolean(lastAnswer)}
          />
        )}

        {settings.developerMode && <DebugOverlay />}
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <TouchableWithoutFeedback
        onPress={handleScreenTap}
        accessible={true}
        accessibilityLabel={effectiveLabel}
        accessibilityHint={getAccessibilityHint()}
        accessibilityRole="button"
        accessibilityState={{ busy: isProcessing || isNavigation, disabled: false }}
        accessibilityActions={[{ name: 'activate', label: 'Activate' }]}
        onAccessibilityAction={(event) => {
          if (event.nativeEvent.actionName === 'activate') {
            handleScreenTap();
          }
        }}
      >
        {/*
          Do NOT set accessible / importantForAccessibility here: TouchableWithoutFeedback
          clones this child and overwrites both (accessible -> true,
          importantForAccessibility -> undefined), so anything set here is silently
          discarded. That clone is what makes the whole screen a single VoiceOver
          button labelled `effectiveLabel` — which is the intent — but it also means
          every descendant is absorbed into that one element and can never take
          VoiceOver focus. Interactive controls must live OUTSIDE this subtree
          (see the settings gear below).
        */}
        <View ref={containerRef} style={StyleSheet.absoluteFill}>
          <StatusBar barStyle="light-content" backgroundColor="#000" />

          {/* Camera */}
          {!settings.useWearablesCamera && device && (
            <Camera
              ref={cameraRef}
              style={StyleSheet.absoluteFill}
              device={device}
              isActive={isCameraActive}
              photo={true}
              accessible={false}
              accessibilityElementsHidden={true}
            />
          )}

          <View
            style={styles.darkOverlay}
            accessible={false}
            importantForAccessibility="no-hide-descendants"
          />

          {/* Voice Visualizer */}
          <VoiceVisualizer
            isListening={isListening || isWakeWordCapturing}
            isProcessing={isProcessing}
            isSpeaking={isSpeaking}
            isNavigation={isNavigation}
            isReaching={isReaching}
            isGlassesListening={isAwaitingWakeWord}
            transcript={isWakeWordCapturing ? wakeWordTranscript : transcript}
            pulseAnim={pulseAnim}
            opacityAnim={opacityAnim}
            glassesDebugStatus={wakeWordDebugStatus}
            glassesDebugRaw={wakeWordDebugRaw}
          />

        </View>
      </TouchableWithoutFeedback>

      {/* ── Persistent activity readout ──
          A sibling of the tap surface, never a child — inside it every element
          is absorbed into the screen-wide accessibility element and VoiceOver
          can never reach the Stop button. Declared after the tap surface so it
          paints on top, and before the gear so VoiceOver reads Stop first.

          Its banners are pointer-transparent, so the existing "tap anywhere to
          stop" gesture is unchanged for users who are not running VoiceOver. */}
      <ActivityOverlay
        status={overlayStatus}
        onStop={handleStopPressed}
        showStop={!isIdle}
        // The settings gear is absolutely positioned over this same strip, so
        // the status pill has to stop short of it. Without the inset the pill
        // stretched the full width and the gear sat on top of the text —
        // visible in the "Listening" screenshot, and worse under large text
        // where the label runs right up to the gear's edge.
        // 44pt button + 20pt right offset + 10pt breathing room.
        trailingInset={74}
      />

      {/* ── Settings Gear Button (top-right) ──
          Sibling of the tap surface, never a child: inside it the gear is swallowed
          by the screen-wide accessibility element and cannot be reached by VoiceOver
          swipe. Declared after the tap surface so it still paints on top and keeps
          winning the touch, and so VoiceOver reads the main button first. */}
      <TouchableOpacity
        style={styles.settingsGearButton}
        onPress={(event) => {
          event.stopPropagation();
          setShowSettings(true);
        }}
        accessible={true}
        accessibilityRole="button"
        accessibilityLabel={strings().menu.settingsLabel}
        accessibilityHint={strings().menu.settingsHint}
        hitSlop={{ top: 10, bottom: 10, left: 10, right: 10 }}
      >
        {/*
          A drawn icon, not the U+2699 character. iOS renders that codepoint
          from the emoji font — a small colour picture that ignores the
          surrounding text colour, blurs when scaled, and does not respond to
          Increase Contrast or Smart Invert. The SVG inherits the palette and
          stays crisp at any size.
        */}
        <GearIcon size={22} color="rgba(255,255,255,0.92)" />
      </TouchableOpacity>

      {/* ── Debug Overlay (outside TouchableWithoutFeedback so touches work) ── */}
      {settings.developerMode && <DebugOverlay />}
    </View>
  );
}

// =============================================================================
// Root — wraps AppInner with SettingsProvider
// =============================================================================
function App(): React.JSX.Element {
  return (
    <SettingsProvider>
      <AppInner />
    </SettingsProvider>
  );
}

export default App;

// =============================================================================
// Styles
// =============================================================================
const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000',
  },
  loaderContainer: {
    flex: 1,
    backgroundColor: '#000',
    alignItems: 'center',
    justifyContent: 'center',
  },
  loaderTitle: {
    color: '#FFF',
    fontSize: 48,
    fontWeight: '700',
    letterSpacing: 0.6,
    marginBottom: 24,
    textTransform: 'lowercase',
  },
  loaderBottomMediaContainer: {
    position: 'absolute',
    bottom: 28,
    width: 280,
    height: 110,
    overflow: 'hidden',
  },
  loaderBottomMedia: {
    width: '100%',
    height: '100%',
  },
  darkOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(0, 0, 0, 0.85)',
  },
  settingsGearButton: {
    position: 'absolute',
    top: Platform.OS === 'ios' ? 56 : 24,
    right: 20,
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: 'rgba(255,255,255,0.08)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.15)',
    alignItems: 'center',
    justifyContent: 'center',
    zIndex: 100,
  },
});
