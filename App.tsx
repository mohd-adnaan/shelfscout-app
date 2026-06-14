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
import { VoiceVisualizer } from './src/components/VoiceVisualizer';
import {
  initSounds,
  releaseSounds,
  playListenSound,
  stopListenSound,
  playThinkingStarted,
  stopLatencyLoop,
  playSuccessChime,
  playErrorSound,
  prepareForRecording,
  configurePlaybackSession,
  setWearablesMode,
  playStopReachingSound,
} from './src/utils/soundEffects';
import { audioFeedback } from './src/services/AudioFeedbackService';
import { speachesSentenceChunker } from './src/services/SpeachesSentenceChunker';
import { NAVIGATION_CONFIG, DETECTION_URL, ACQUISITION_URL } from './src/utils/constants';
import { fixImageOrientation } from './src/services/fixImageOrientation';
import { SettingsProvider, useSettings } from './src/context/SettingsContext';
import SettingsScreen from './src/screens/SettingsScreen';
import { debugLogger } from './src/services/DebugLogger';
import { DebugOverlay } from './src/components/DebugOverlay';
import { wearablesCamera } from './src/services/WearablesCamera';
import { ARKitNavigationBridge, ARKitNavigationResult } from './src/native/ARKitNavigationModule';
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
  if (/\b(reaching|hand|object|target)\b/.test(normalized)) return 'reaching';
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
  const rtabFeedIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const rtabLastSentFrameRef = useRef<string>('');
  const rtabLastObjectRef = useRef<string>('');
  const rtabIsSendingRef = useRef(false);
  const rtabFrameSeqRef = useRef(0);
  const rtabSubmittedFrameUrisRef = useRef<Set<string>>(new Set());
  const rtabSubmittedFrameQueueRef = useRef<string[]>([]);
  // Ref so handleAutoSubmit can call handleVoiceCommand without circular dep
  const handleVoiceCommandRef = useRef<(command: string, photoPath: string) => Promise<void>>(async () => { });
  // Ref so handleAutoSubmit (stable [] deps) can check screen reader state
  const screenReaderEnabledRef = useRef(false);

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

  // ── Accessibility ──────────────────────────────────────────────────────────
  useEffect(() => {
    (async () => {
      try {
        const [sr, rm] = await Promise.all([
          AccessibilityInfo.isScreenReaderEnabled(),
          AccessibilityInfo.isReduceMotionEnabled(),
        ]);
        setScreenReaderEnabled(sr);
        screenReaderEnabledRef.current = sr;
        setReduceMotionEnabled(rm);
        // NOTE: Do NOT announce here — VoiceOver will read the button's
        // accessibilityLabel automatically when focus lands on it.
        // A programmatic announcement creates double-speech:
        // "CyberSight is ready tap to speak button tap to start speaking"
      } catch (e) { console.error('❌ Accessibility check:', e); }
    })();

    const srSub = AccessibilityInfo.addEventListener('screenReaderChanged', (enabled: boolean) => {
      setScreenReaderEnabled(enabled);
      screenReaderEnabledRef.current = enabled;
    });
    const rmSub = AccessibilityInfo.addEventListener('reduceMotionChanged', setReduceMotionEnabled);
    return () => { srSub?.remove(); rmSub?.remove(); };
  }, []);

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

    if (!screenReaderEnabledRef.current) {
      audioFeedback.playEarcon('cancel');
      await playErrorSound();
    }
    AccessibilityInfo.announceForAccessibility(spoken);
    await speachesSentenceChunker.synthesizeSpeechChunked(spoken);
  };
  // ────────────────────────────────────────────────────────────────────────
  // VoiceOver-aware announcement helper.
  //
  // When VoiceOver is ON, the button's accessibilityLabel is automatically
  // read aloud on every state change (Ready → Listening → Thinking → ...).
  // Calling AccessibilityInfo.announceForAccessibility() with text that
  // duplicates the label produces two simultaneous utterances → user hears
  // double voice / echo / cut-off.
  //
  // More damaging: every redundant announcement also restarts VoiceOver's
  // announcement queue, which CONSUMES the user's next double-tap gesture
  // (VoiceOver uses the tap to dismiss the announcement instead of routing
  // to handleScreenTap). That's why VoiceOver users need many taps to act.
  //
  // Use this helper everywhere the announcement duplicates the label.
  // For genuinely-new info (errors, guidance text) just call the regular
  // API directly — VoiceOver SHOULD speak those.
  // ────────────────────────────────────────────────────────────────────────
  const announceIfNoVoiceOver = useCallback((message: string) => {
    if (screenReaderEnabledRef.current) {
      // VoiceOver will read the label change automatically; do nothing.
      return;
    }
    AccessibilityInfo.announceForAccessibility(message);
  }, []);

  const announceTapToStart = useCallback((prefix: string) => {
    // ── Bug 1 fix: When VoiceOver is on, do NOT announce here. ───────
    // VoiceOver will automatically read the button's accessibilityLabel
    // when focus returns to it. A programmatic announcement creates
    // overlapping speech: VoiceOver reads the label AND speaks the
    // announcement simultaneously.
    if (screenReaderEnabledRef.current) {
      // Just log — VoiceOver reads the label automatically.
      console.log('♿ [announceTapToStart] Skipping (VoiceOver reads label)');
      return;
    }
    const suffix = 'Tap to speak.';
    const trimmedPrefix = prefix.trim();
    AccessibilityInfo.announceForAccessibility(
      trimmedPrefix ? `${trimmedPrefix} ${suffix}` : suffix
    );
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

  const maybeAnnouncePosture = useCallback(async (context: 'capture' | 'continuous') => {
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

    if (now - lastPostureWarningRef.current < POSTURE_WARNING_COOLDOWN_MS) return false;

    const message = buildPostureMessage(status);
    if (!message) return false;

    lastPostureWarningRef.current = now;

    if (!screenReaderEnabledRef.current) {
      audioFeedback.playEarcon('error');
    }
    AccessibilityInfo.announceForAccessibility(message);

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
      await new Promise(resolve => setTimeout(resolve, POSTURE_POLL_INTERVAL_MS));
      if (getPostureStatus().ok) return true;
    }

    return getPostureStatus().ok;
  }, [getPostureStatus, maybeAnnouncePosture]);

  // Keep a stable ref for callbacks that are intentionally []-memoized.
  const waitForGoodPostureRef = useRef(waitForGoodPosture);
  useEffect(() => {
    waitForGoodPostureRef.current = waitForGoodPosture;
  }, [waitForGoodPosture]);
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

    const capturePromise = (async (): Promise<string> => {
      try {
        console.log('📷 Reactivating camera for capture...');
        setIsCameraActive(true);

        const useSystemShutterSound =
          options?.enableShutterSound === true &&
          Platform.OS === 'ios' &&
          !settingsRef.current.useWearablesCamera;

        if (settingsRef.current.useWearablesCamera) {
          try {
            const wearablesPhoto = await wearablesCamera.capturePhoto();
            lastImageDimensions.current = { width: 0, height: 0 };
            return wearablesPhoto;
          } catch (error) {
            console.error('❌ Wearables capture failed:', error);
            throw error;
          }
        }

        await new Promise(resolve => setTimeout(resolve, CAMERA_REACTIVATION_DELAY_MS));

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
          const fixedImage = await fixImageOrientation(photo.path);
          lastImageDimensions.current = {
            width: fixedImage.width || 0,
            height: fixedImage.height || 0,
          };
          console.log('✅ Photo captured & fixed:', fixedImage.uri,
            `(${fixedImage.width}×${fixedImage.height})`);
          return fixedImage.uri;
        } catch (error) {
          console.error('❌ Photo capture failed, retrying:', error);
          await new Promise(resolve => setTimeout(resolve, 500));
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
            return retry.path;
          } catch (e) {
            console.error('❌ Retry also failed:', e);
            return '';
          }
        }
      } finally {
        isCapturingRef.current = false;
        activeCapturePromiseRef.current = null;
      }
    })();

    activeCapturePromiseRef.current = capturePromise;
    return capturePromise;
  }, []);
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
        now - lastAccepted.acceptedAt < CONTINUOUS_TTS_REPEAT_SUPPRESSION_MS &&
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
    }
  ): Promise<boolean> => {
    // ── Resolve user preference ───────────────────────────────────────────
    const pipeline = resolveReachingPipeline({
      reaching_ios: result.reaching_ios,
      reaching: result.reaching_flag,
    });

    if (pipeline !== 'arkit') {
      // User prefers standard pipeline or ARKit not available
      console.log(`🎯 [Reaching] Skipping ARKit — pipeline resolved to: ${pipeline}`);
      return false;
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
      await speachesSentenceChunker.synthesizeSpeechChunked(
        `I can detect the ${result.object || 'object'} in the scene, but I could not get precise coordinates for guidance. Try pointing your camera more directly at it and ask again.`
      );
      setIsSpeaking(false);                // ← release speaking guard
      // Clean transition to ready (matches the ARKit-success path below)
      setIsCameraActive(true);
      if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
      announceTapToStart('Ready.');
      return true; // Handled (but without ARKit)
    }

    console.log('🎯 [ARKit] Launching native reaching for:', result.object, 'bbox:', bbox);
    prewarmDAv2InBackground('reaching_ios response');

    AccessibilityInfo.announceForAccessibility(
      `Guiding you to ${result.object || 'object'}. Follow the audio beeps. Tap anywhere when you have it.`
    );

    setIsCameraActive(false);
    setIsReaching(true);
    await new Promise(resolve => setTimeout(resolve, 500));

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
          startupSilent: options?.startupSilent === true,
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
            ? `${result.object || 'Object'} reached!`
            : 'Reaching guidance ended.';
        AccessibilityInfo.announceForAccessibility(msg);
      } else {
        console.warn('⚠️ ReachingModule not available — native module not linked');
        AccessibilityInfo.announceForAccessibility(
          'Reaching module not available. Please rebuild the app.'
        );
      }
    } catch (e: any) {
      console.error('❌ [ARKit] Native module error:', e);
      AccessibilityInfo.announceForAccessibility(`Reaching error: ${e.message || 'Unknown error'}`);
    }

    resetSessionId();
    setIsReaching(false);
    setIsCameraActive(true);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
        AccessibilityInfo.announceForAccessibility('Stopped due to time limit.');
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
            await new Promise(r => setTimeout(r, Math.max(300, PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN)));
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
            await new Promise(r => setTimeout(r, SMART_GUIDANCE_MIN_CYCLE_MS));
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
            smartGuidanceActiveRef.current = false;
            smartGuidanceResumeMainRef.current = true;
            smartGuidanceSeededRef.current = false;
            reacquiringRef.current = true;
          } else {
            usedSmartGuidance = true;
            const smartResponse = await sendToSmartGuidance(
              {
                object: objectName,
                bbox: bboxToSend,
                image: imageDataUrl,
                annotated_image: annotatedImage,
                success: true,
                session_id: getSessionId(),
                confidence: cached?.confidence,
              },
              abortCtrl.signal
            );
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
              navigation: loopMode === 'navigation',
              navigation_pipeline: settingsRef.current.navigationPipeline,
              navigation_ios_preferred: Platform.OS === 'ios' && settingsRef.current.navigationPipeline === 'arkit',
              reaching_flag: loopMode === 'reaching' && (Platform.OS !== 'ios' || settingsRef.current.preferAlternativeReaching),
              reaching_ios: loopMode === 'reaching' && Platform.OS === 'ios' && !settingsRef.current.preferAlternativeReaching,
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
          await new Promise(r => setTimeout(r, Math.max(1200, PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN)));
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
          });
        } else if (isNullResponse) {
          // ── Fast-poll: "Null" text — skip TTS, rapid 500ms cycle ─────────
          const nullCooldown = fastReachingCycle
            ? SMART_GUIDANCE_MIN_CYCLE_MS
            : 500;
          console.log(`🔄 ⏭️ Null fast-poll — waiting ${nullCooldown}ms before next cycle`);
          await new Promise(resolve => setTimeout(resolve, nullCooldown));
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
            await new Promise(r => setTimeout(r, cooldown));
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
        if (!screenReaderEnabledRef.current && !settingsRef.current.useWearablesCamera) {
          audioFeedback.playEarcon('cancel');
          await playErrorSound();
        }
        AccessibilityInfo.announceForAccessibility(`Error: ${error.message}`);
        break;
      }
    }

    // ── Cleanup ────────────────────────────────────────────────────────────
    console.log('🔄 [ContinuousMode] Loop ended');
    await stopLatencyLoop();
    stopRtabFeed();
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
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
    stopRtabFeed,
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

    const targetName = normalizeTextValue(result.navigation_target) ||
      normalizeTextValue(result.object) ||
      inferNavigationTargetFromCommand(options?.requestedText);

    if (!targetName) {
      if (options?.introSpeechPromise) {
        try { await options.introSpeechPromise; } catch { }
      }
      await speakContinuousSpeechAndWait(
        'I could not identify the navigation target. Please ask for the destination again.',
        { ignoreAbort: true },
      );
      setIsNavigation(false);
      setIsProcessing(false);
      setIsCameraActive(true);
      if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
      announceTapToStart('Ready.');
      return true;
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
        'ARKit navigation is not available on this device. Falling back to Rtab navigation.',
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
    } else if (!result.text) {
      await speakContinuousSpeechAndWait(
        `Starting ARKit route guidance to ${targetName}.`,
        { ignoreAbort: true },
      );
    }

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
    try {
      navResult = await ARKitNavigationBridge.startNavigation({
        targetName,
        routeMapId: normalizeTextValue(result.route_map_id) || undefined,
        routeMapName: normalizeTextValue(result.route_map_name) || undefined,
        sessionId: getSessionId(),
        speakLandmarks: true,
        errorRecovery: false,
        ttsRate: settingsRef.current.ttsRate,
      });
    } catch (e: any) {
      navResult = {
        success: false,
        reason: 'error',
        targetName,
        message: e?.message || 'ARKit navigation ended with an error.',
      };
    }

    console.log('🧭 [ARKitNavigation] Native result:', navResult);

    if (navResult?.success && navResult.reason === 'arrived') {
      stopContinuousMode('ARKit navigation arrived; starting iOS reaching acquisition', false);
      setIsReaching(true);
      setIsProcessing(true);
      setIsNavigation(false);
      setIsSpeaking(false);

      await speakContinuousSpeechAndWait(
        navResult.message || `Arrived at ${targetName}. Switching to object guidance.`,
        { ignoreAbort: true },
      );

      if (isEmergencyStopped.current) {
        setIsReaching(false);
        setIsProcessing(false);
        return true;
      }

      const postureOk = await waitForGoodPostureRef.current('capture');
      if (!postureOk) {
        await speakContinuousSpeechAndWait(
          'Hold the phone straight with the camera facing forward, then ask again.',
          { ignoreAbort: true },
        );
        setIsReaching(false);
        setIsProcessing(false);
        setIsCameraActive(true);
        if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
        announceTapToStart('Ready.');
        return true;
      }

      const shouldPlaySFX = !screenReaderEnabledRef.current && !settingsRef.current.useWearablesCamera;
      if (shouldPlaySFX) {
        playThinkingStarted();
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
        if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
        if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
        announceTapToStart('Ready.');
      }

      return true;
    }

    setIsNavigation(false);
    setIsCameraActive(true);

    if (navResult.reason === 'ar_unavailable') {
      await speakContinuousSpeechAndWait(
        navResult.message || 'ARKit navigation is unavailable. Falling back to Rtab navigation.',
        { ignoreAbort: true },
      );
      setIsProcessing(false);
      result.navigation = true;
      result.navigation_ios = false;
      result.navigation_arkit = false;
      return false;
    }

    const fallbackMessages: Record<string, string> = {
      map_not_found: `No saved AR route map was found for ${targetName}. Open Settings, Manage AR Route Maps, and map the route first.`,
      target_not_found: `${targetName} is not in the saved AR route maps. Add it as a destination or landmark, then try again.`,
      relocalization_failed: 'I could not relocalize against the saved AR map. Return to the route start and slowly scan the area.',
      cancelled: 'ARKit navigation cancelled.',
      error: navResult.message || 'ARKit navigation ended with an error.',
    };

    await speakContinuousSpeechAndWait(
      fallbackMessages[navResult.reason] || navResult.message || 'ARKit navigation ended.',
      { ignoreAbort: true },
    );
    stopContinuousMode('ARKit navigation ended', false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
    announceTapToStart('Ready.');
    return true;
  }, [
    announceTapToStart,
    handleiOSReaching,
    resetContinuousSpeechQueue,
    resolveNavigationPipeline,
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

    if (!screenReaderEnabledRef.current) { 
      audioFeedback.playEarcon('cancel'); 
      if (wasContinuous) {
        await playStopReachingSound();
      }
    }
    announceTapToStart('Stopped.');
  }, [announceTapToStart, isNavigation, isReaching, resetContinuousSpeechQueue, stopRtabFeed]);

  const stopNavigation = useCallback(async () => {
    navigationLoopAbortRef.current = true;
    stopRtabFeed();
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
    if (!screenReaderEnabledRef.current) { 
      audioFeedback.playEarcon('cancel'); 
      await playStopReachingSound();
    }
    announceTapToStart('Navigation stopped.');
  }, [announceTapToStart, resetContinuousSpeechQueue, stopRtabFeed]);

  // ============================================================================
  // Handle Voice Command  ← defined BEFORE handleAutoSubmit so ref is stable
  // ============================================================================
  const handleVoiceCommand = useCallback(async (command: string, photoPath: string) => {
    if (isProcessingRef.current || isEmergencyStopped.current) return;

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

      try { await cancelSTT(); } catch { }

      // Skip earcons/SFX when VoiceOver is on — audio session conflicts.
      // Also skip in glasses mode — the audio session is locked by BluetoothHFP
      // for the glasses mic. Playing sounds via react-native-sound calls
      // Sound.setCategory('Playback') which corrupts the HFP session, leaving
      // the latency sound in a zombie state that s.stop() can't silence.
      const shouldPlaySFX = !screenReaderEnabledRef.current && !settingsRef.current.useWearablesCamera;
      if (shouldPlaySFX) {
        // FIX: Restore full-volume audio session after STT's Record+Measurement
        await configurePlaybackSession(!settingsRef.current.useWearablesCamera);

        await stopListenSound();
        playThinkingStarted();
      }


      if (!photoPath) {
        if (settingsRef.current.useWearablesCamera) {
          await speakWearablesError(new Error(
            'Could not get an image from the glasses. Try toggling the glasses camera off and on.'
          ));
          return;
        }

        console.warn('⚠️ No photo — voice-only mode');
        AccessibilityInfo.announceForAccessibility('Processing without photo.');
      }

      if (isEmergencyStopped.current) return;

      const result = await sendToWorkflow(
        {
          text: command,
          imageUri: photoPath || '',
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          navigation: false,
          navigation_pipeline: settingsRef.current.navigationPipeline,
          navigation_ios_preferred: Platform.OS === 'ios' && settingsRef.current.navigationPipeline === 'arkit',
          reaching_flag: false,
        },
        abortCtrl.signal
      );

      if (isEmergencyStopped.current) return;

      if (result?.object) {
        rtabLastObjectRef.current = result.object;
      }

      await stopLatencyLoop();
      // Bug 3 defense: second stop catches the race where iOS audio session
      // switch during the first stop re-queued a play.
      await stopLatencyLoop();
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
        setIsSpeaking(true);
        // Skip earcon when VoiceOver is on — it would overlap with TTS response
        if (!screenReaderEnabledRef.current) {
          audioFeedback.playEarcon('speaking');
        }

        // ── Bug 1 fix: When VoiceOver is on, wait for VoiceOver to ─────
        // finish speaking its 'Thinking' announcement before starting TTS.
        // Without this, VoiceOver and AVSpeechSynthesizer both speak at
        // once, creating the double-voice/echo effect.
        if (screenReaderEnabledRef.current) {
          await new Promise(resolve => setTimeout(resolve, 600));
        }

        introSpeechPromise = speachesSentenceChunker.synthesizeSpeechChunked(result.text)
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
        await new Promise(resolve => setTimeout(resolve, 100));
        startContinuousMode(mode, result.loopDelay);

        await runContinuousLoop();
        return;
      }

      // ── Normal (no continuous mode) ────────────────────────────────────
      setIsCameraActive(true);
      if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
        if (!screenReaderEnabledRef.current) {
          audioFeedback.playEarcon('cancel');
          // FIX: await the error sound so AVSpeechSynthesizer can't steal
          // the audio session mid-playback and cut the sound short.
          // The sound's natural duration replaces the old 600ms timeout.
          await playErrorSound();
        }

        await speachesSentenceChunker.synthesizeSpeechChunked(
          'Error processing your request. Try again.'
        );

        setIsCameraActive(true);
        if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
  const handleAutoSubmit = useCallback(async (passedTranscript: string) => {
    console.log('🎯 Auto-submit triggered by silence detection');

    if (isCapturingPhotoRef.current || isProcessingRef.current || isEmergencyStopped.current) {
      console.log('⚠️ Already in-flight, skipping');
      return;
    }

    let finalText = (passedTranscript || finalTranscriptRef.current).trim();
    finalText = stripVoiceOverListeningPrefix(finalText);

    if (!finalText) {
      AccessibilityInfo.announceForAccessibility('No voice input detected. Tap to try again.');
      if (!screenReaderEnabledRef.current) { playErrorSound(); }
      return;
    }

    // ── VOICEOVER SAFETY NET ──────────────────────────────────────────────
    // Even with the STT delay, VoiceOver might still bleed into the mic.
    // Reject transcripts that are clearly VoiceOver UI text, not user speech.
    // Uses ref (not state) because handleAutoSubmit has stable [] deps.
    if (screenReaderEnabledRef.current) {
      const lower = finalText.toLowerCase().trim();
      if (
        lower.length <= 12 &&
        ['speak', 'tap', 'ready', 'start', 'listen', 'listening', 'button'].includes(lower)
      ) {
        console.log('♿ VoiceOver noise rejected (short):', finalText);
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
        console.log('♿ VoiceOver noise rejected:', finalText);
        // CRITICAL: Do NOT announce anything here. Any announceForAccessibility
        // call gets read by VoiceOver, the mic picks it up, and it becomes
        // the transcript for the NEXT listening session ("please speak your command").
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
      if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
      announceTapToStart('Ready.');
      return;
    }

    setIsProcessing(true);
    isCapturingPhotoRef.current = true;
    try {
      try { await cancelSTT(); } catch { }

      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));

      if (isEmergencyStopped.current) {
        setIsProcessing(false);
        isCapturingPhotoRef.current = false;
        return;
      }

      let photoPath = '';
      try {
        photoPath = await reactivateCameraAndCaptureRef.current({
          enableShutterSound: false,
        });
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
          if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
          announceTapToStart('Ready.');
          return;
        }
        // iPhone path: keep existing voice-only fallback.
      }

      if (!photoPath && !settingsRef.current.useWearablesCamera) {
        // Voice-only fallback only applies when iPhone camera is selected.
        AccessibilityInfo.announceForAccessibility(
          'Warning: Failed to capture photo. Continuing with voice only.'
        );
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
      AccessibilityInfo.announceForAccessibility(`Error: ${error.message || error}`);
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
          if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
      AccessibilityInfo.announceForAccessibility(`Error: ${error.message || error}`);
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
      await new Promise(resolve => setTimeout(resolve, VOICEOVER_LISTENING_ANNOUNCE_DELAY_MS));
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

      // ── Audio feedback: Skip earcon/SFX when VoiceOver is on ──────────
      // VoiceOver owns the iOS audio session. Playing earcon sounds causes
      // audio session conflicts ("Failed to set properties, error: '!pri'")
      // producing glitchy/screamy artifacts. VoiceOver announcements replace
      // earcon feedback for blind users.
      if (!screenReaderEnabled) {
        // FIX: After STT leaves the audio session in Record+Measurement mode,
        // react-native-sound's setCategory alone doesn't restore full volume.
        // This native call sets .playback + .default mode + setActive + speaker
        // route — matching the reaching pipeline's audio config.
        await configurePlaybackSession(!settingsRef.current.useWearablesCamera);

        await playListenSound();

        // The listening cue is finished now; switch to recording for STT.
        prepareForRecording();
      }

      // Delay to let audio session reconfigure after category switch
      if (!screenReaderEnabled) {
        await new Promise(resolve => setTimeout(resolve, 350));
      }

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
        AccessibilityInfo.announceForAccessibility('Error starting voice. Tap to try again.');
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
        if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
        announceTapToStart('Ready.');
        return;
      }

      isCapturingPhotoRef.current = true;
      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));
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
          if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
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
    isEmergencyStopped.current = true;
    isStartingRef.current = false; // ← release re-entry guard
    continuousModeAbortRef.current = true;
    try { await ARKitNavigationBridge.stopNavigation(); } catch { }

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await stopLatencyLoop(); // FIX: kill thinking SFX immediately on emergency stop
    continuousTtsGenerationRef.current++;
    resetContinuousSpeechQueue();
    await speachesSentenceChunker.stop();
    try { await cancelSTT(); } catch { }
    // Pause wake word listening during emergency stop
    try { await wakeWordPauseRef.current?.(); } catch { }

    await new Promise(resolve => setTimeout(resolve, 300));

    setIsProcessing(false);
    setIsSpeaking(false);
    setIsNavigation(false);
    setIsReaching(false);
    isProcessingRef.current = false;
    finalTranscriptRef.current = '';
    isCapturingPhotoRef.current = false;
    isContinuousModeRunning.current = false;

    stopContinuousMode('emergency stop', false);
    setIsCameraActive(true);
    // NOTE: Do NOT clear isEmergencyStopped here. It is cleared in
    // startListening() when the user initiates a new interaction.
    // Clearing it here allows in-flight async ops (photo capture in
    // handleAutoSubmit) to resume and restart the latency loop.

    // Skip earcon when VoiceOver is on — audio session conflict
    if (!screenReaderEnabled) {
      audioFeedback.playEarcon('ready');
    }
    announceTapToStart('Stopped.');

    // Resume wake word listening after emergency stop
    if (settingsRef.current.useWearablesCamera) {
      isEmergencyStopped.current = false; // clear so wake word flow can proceed
      wakeWordResumeRef.current?.();
    }
    console.log('✅ Emergency stop complete');
  };

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
        AccessibilityInfo.announceForAccessibility(`Stopping ${mode}.`);
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
        AccessibilityInfo.announceForAccessibility('Stopping.');
      }
      await emergencyStop();
      return;
    }

    if (isListening) {
      // Bug 1/2 fix: VoiceOver reads the label change to 'Thinking' automatically.
      if (!screenReaderEnabledRef.current) {
        AccessibilityInfo.announceForAccessibility('Thinking.');
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

    await startListening();
  };

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
        <View
          ref={containerRef}
          style={StyleSheet.absoluteFill}
          accessible={false}
          importantForAccessibility="no-hide-descendants"
        >
          <StatusBar barStyle="light-content" backgroundColor="#000" />

          {/* Camera */}
          {!settings.useWearablesCamera && (
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

          {/* ── Settings Gear Button (top-right) ── */}
          <TouchableOpacity
            style={styles.settingsGearButton}
            onPress={() => setShowSettings(true)}
            accessible={true}
            accessibilityRole="button"
            accessibilityLabel="Open settings"
            accessibilityHint="Double tap to open settings for voice speed and reaching pipeline"
            // Prevent the gear tap from also firing handleScreenTap
            onStartShouldSetResponder={() => true}
          >
            <Text style={styles.settingsGear} accessible={false}>⚙</Text>
          </TouchableOpacity>

        </View>
      </TouchableWithoutFeedback>

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
  settingsGear: {
    color: 'rgba(255,255,255,0.7)',
    fontSize: 20,
  },
});
