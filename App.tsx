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
import {
  sendToWorkflow,
  sendToSmartGuidance,
  isContinuousModeActive,
  getCurrentMode,
  startContinuousMode,
  stopContinuousMode,
  incrementContinuousMode,
  getCurrentLoopDelay,
  shouldPreventInfiniteLoop,
  updateLoopDelay,
  getSessionId,
  resetSessionId,
  determineActionMode,
} from './src/services/WorkflowService';
import { sendToKasraGuidance } from './src/services/KasraGuidanceService';
import { VoiceVisualizer } from './src/components/VoiceVisualizer';
import {
  initSounds,
  releaseSounds,
  playListenSound,
  playThinkingStarted,
  stopLatencyLoop,
  playSuccessChime,
  playErrorSound,
  prepareForRecording,
  configurePlaybackSession,
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

const SMART_GUIDANCE_MIN_CYCLE_MS = Math.ceil(2000 / 3);
const KASRA_FEED_INTERVAL_MS = 500;

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
  const { settings, resolveReachingPipeline } = useSettings();
  // Ref always holds the latest settings — avoids stale closure in useCallback
  const settingsRef = useRef(settings);
  useEffect(() => { settingsRef.current = settings; }, [settings]);

  // ── Camera / Permissions ───────────────────────────────────────────────────
  const device = useCameraDevice('back');
  const { hasPermission: hasCameraPermission, requestPermission: requestCameraPermission } = useCameraPermission();
  const { hasPermission: hasMicPermission, requestPermission: requestMicPermission } = useMicrophonePermission();
  const cameraRef = useRef<Camera>(null);
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
  const lastImageDimensions = useRef<{ width: number; height: number }>({ width: 0, height: 0 });
  const prefetchedPhotoRef = useRef<string | null>(null);
  const wearablesPrewarmAttemptedRef = useRef(false);
  const smartGuidanceActiveRef = useRef(false);
  const smartGuidanceResumeMainRef = useRef(false);
  const smartGuidanceCacheRef = useRef<{
    object?: string;
    bbox?: any;
    annotatedImage?: string;
  } | null>(null);
  const kasraFeedIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const kasraLastFrameRef = useRef<string>('');
  const kasraLastObjectRef = useRef<string>('');
  const kasraIsSendingRef = useRef(false);
  // Ref so handleAutoSubmit can call handleVoiceCommand without circular dep
  const handleVoiceCommandRef = useRef<(command: string, photoPath: string) => Promise<void>>(async () => { });
  // Ref so handleAutoSubmit (stable [] deps) can check screen reader state
  const screenReaderEnabledRef = useRef(false);

  // ── Animation ──────────────────────────────────────────────────────────────
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const opacityAnim = useRef(new Animated.Value(0.3)).current;

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
    if (!settings.useWearablesCamera || Platform.OS !== 'ios') return;
    if (wearablesPrewarmAttemptedRef.current) return;

    let timeoutId: ReturnType<typeof setTimeout> | null = null;
    let sub: { remove: () => void } | null = null;

    const runPrewarm = async () => {
      wearablesPrewarmAttemptedRef.current = true;
      try {
        await wearablesCamera.startRegistration();
        await wearablesCamera.preWarm();
      } catch (error) {
        console.warn('[Wearables] Auto-prewarm failed:', error);
      }
    };

    if (AppState.currentState === 'active') {
      timeoutId = setTimeout(() => {
        runPrewarm().catch((error) => {
          console.warn('[Wearables] Auto-prewarm failed:', error);
        });
      }, 1500);
    } else {
      sub = AppState.addEventListener('change', (state) => {
        if (state === 'active' && !wearablesPrewarmAttemptedRef.current) {
          runPrewarm().catch((error) => {
            console.warn('[Wearables] Auto-prewarm failed:', error);
          });
          sub?.remove();
        }
      });
    }

    return () => {
      if (timeoutId) clearTimeout(timeoutId);
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

  const announceTapToStart = useCallback((prefix: string) => {
    const suffix = screenReaderEnabledRef.current ? 'Tap to start.' : 'Tap to speak.';
    const trimmedPrefix = prefix.trim();
    AccessibilityInfo.announceForAccessibility(
      trimmedPrefix ? `${trimmedPrefix} ${suffix}` : suffix
    );
  }, []);
  const reactivateCameraAndCapture = async (options?: {
    enableShutterSound?: boolean;
  }): Promise<string> => {
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
  };

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

  const stopKasraFeed = useCallback(() => {
    if (kasraFeedIntervalRef.current) {
      clearInterval(kasraFeedIntervalRef.current);
      kasraFeedIntervalRef.current = null;
    }
    kasraIsSendingRef.current = false;
  }, []);

  const startKasraFeed = useCallback(() => {
    if (kasraFeedIntervalRef.current) return;

    kasraFeedIntervalRef.current = setInterval(() => {
      if (!isContinuousModeRunning.current || getCurrentMode() !== 'navigation') return;

      const imageUri = kasraLastFrameRef.current;
      const objectName = kasraLastObjectRef.current;
      if (!imageUri || !objectName || kasraIsSendingRef.current) return;

      kasraIsSendingRef.current = true;
      sendToKasraGuidance({ imageUri, objectName })
        .catch((err: any) => {
          console.warn('[Kasra] Guidance send failed:', err?.message || err);
        })
        .finally(() => {
          kasraIsSendingRef.current = false;
        });
    }, KASRA_FEED_INTERVAL_MS);
  }, []);

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

    AccessibilityInfo.announceForAccessibility(
      `Guiding you to ${result.object || 'object'}. Follow the audio beeps. Tap anywhere when you have it.`
    );

    setIsCameraActive(false);
    setIsReaching(true);
    await new Promise(resolve => setTimeout(resolve, 500));

    try {
      const { ReachingModule } = NativeModules;
      if (ReachingModule?.startReaching) {
        const reachingPromise = ReachingModule.startReaching({
          bbox,
          object: result.object || 'object',
          sessionId: getSessionId(),
          depth: result.depth,
          imageWidth: lastImageDimensions.current.width,
          imageHeight: lastImageDimensions.current.height,
          detectionUrl: DETECTION_URL,
          acquisitionUrl: ACQUISITION_URL,
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
    prefetchedPhotoRef.current = null;
    let cycleCount = 0;

    const currentMode = getCurrentMode();
    AccessibilityInfo.announceForAccessibility(`${currentMode} started. Tap to stop.`);

    while (!continuousModeAbortRef.current && !isEmergencyStopped.current) {
      const intervalMode = getCurrentMode();
      if (intervalMode !== 'reaching' && smartGuidanceActiveRef.current) {
        smartGuidanceActiveRef.current = false;
        smartGuidanceResumeMainRef.current = false;
        smartGuidanceCacheRef.current = null;
      }

      const minIntervalOverride = smartGuidanceActiveRef.current
        ? SMART_GUIDANCE_MIN_CYCLE_MS
        : undefined;
      if (shouldPreventInfiniteLoop(minIntervalOverride)) {
        AccessibilityInfo.announceForAccessibility('Stopped due to time limit.');
        break;
      }

      cycleCount++;
      const cycleStart = Date.now();
      console.log(`\n🔄 ═══ CYCLE #${cycleCount} START ═══`);

      try {
        incrementContinuousMode();
        const loopMode = getCurrentMode();

        // ── Capture ────────────────────────────────────────────────────────
        let photoPath = '';
        if (prefetchedPhotoRef.current) {
          photoPath = prefetchedPhotoRef.current;
          prefetchedPhotoRef.current = null;
          console.log('🔄 ✅ Using PRE-FETCHED photo');
        } else {
          photoPath = await reactivateCameraAndCapture({
            enableShutterSound: false,
          });
        }

        if (loopMode === 'navigation') {
          if (photoPath) {
            kasraLastFrameRef.current = photoPath;
          }
          startKasraFeed();
        } else {
          stopKasraFeed();
        }

        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

        // ── Send to backend ────────────────────────────────────────────────
        setIsProcessing(true);
        const abortCtrl = new AbortController();
        abortControllerRef.current = abortCtrl;

        if (!screenReaderEnabledRef.current) {
          playThinkingStarted(); // ← start thinking SFX for this cycle
        }

        const shouldUseSmartGuidance = loopMode === 'reaching' && smartGuidanceActiveRef.current;
        let usedSmartGuidance = false;
        let result: any;

        if (shouldUseSmartGuidance) {
          const cached = smartGuidanceCacheRef.current;
          const imageDataUrl = await readImageAsDataUrl(photoPath || '');
          const bboxString = bboxToString(cached?.bbox);
          const objectName = cached?.object || 'object';
          const annotatedImage = cached?.annotatedImage
            ? toDataUrl(cached.annotatedImage)
            : (imageDataUrl || '');

          if (!imageDataUrl || !bboxString) {
            console.warn('⚠️ [SmartGuidance] Missing payload, resuming main workflow');
            smartGuidanceActiveRef.current = false;
            smartGuidanceResumeMainRef.current = true;
          } else {
            usedSmartGuidance = true;
            const smartResponse = await sendToSmartGuidance(
              {
                object: objectName,
                bbox: bboxString,
                image: imageDataUrl,
                annotated_image: annotatedImage,
                success: true,
                session_id: getSessionId(),
              },
              abortCtrl.signal
            );

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

            smartGuidanceCacheRef.current = {
              object: smartResponse?.class_name || objectName,
              bbox: smartResponse?.bbox || cached?.bbox,
              annotatedImage: cached?.annotatedImage || annotatedImage,
            };

            if (smartResponse?.tracking_active === false) {
              smartGuidanceActiveRef.current = false;
              smartGuidanceResumeMainRef.current = true;
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
              reaching_flag: loopMode === 'reaching',
            },
            abortCtrl.signal
          );

          if (smartGuidanceResumeMainRef.current) {
            smartGuidanceResumeMainRef.current = false;
          }

          if (loopMode === 'reaching' && result?.tracking_active === true && result?.bbox && result?.object) {
            smartGuidanceActiveRef.current = true;
            smartGuidanceCacheRef.current = {
              object: result?.object || smartGuidanceCacheRef.current?.object,
              bbox: result?.bbox || smartGuidanceCacheRef.current?.bbox,
              annotatedImage: result?.annotated_image || smartGuidanceCacheRef.current?.annotatedImage,
            };
          }
        }

        await stopLatencyLoop(); // ← stop thinking SFX when result arrives
        setIsProcessing(false);


        if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

        if (loopMode === 'navigation' && result?.object) {
          kasraLastObjectRef.current = result.object;
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
          `🔄 Cycle #${cycleCount} | ${isNullResponse ? '⏭️ NULL' : '🔊 SPEAK'} | ${cycleElapsed}ms`,
          `mode=${loopMode} nav=${result.navigation} reach=${result.reaching_flag} ios=${result.reaching_ios} smart=${usedSmartGuidance} text="${(rawText || '').substring(0, 80)}"`,
        );

        if (isNullResponse) {
          console.log(`🔄 ⏭️ Cycle #${cycleCount} — "Null" response, skipping TTS, fast-polling…`);
        }

        // ── iOS ARKit reaching check (respects user preference) ───────────
        if (Platform.OS === 'ios' && result.reaching_ios === true) {
          // Check pipeline FIRST — determines whether to kill the loop or continue it
          const loopPipeline = resolveReachingPipeline({
            reaching_ios: result.reaching_ios,
            reaching: result.reaching_flag,
          });

          if (loopPipeline === 'arkit') {
            // ── ARKit path: intro TTS + silent ARKit bootstrap in parallel ─
            let introSpeechPromise: Promise<void> | undefined;
            if (result.text) {
              setIsSpeaking(true);
              introSpeechPromise = speachesSentenceChunker.synthesizeSpeechChunked(result.text)
                .then(() => {
                  setIsSpeaking(false);
                  // Bug 4 defense — see continuous-mode .then() above.
                  stopLatencyLoop().catch(() => {});
                })
                .catch((e: any) => {
                  setIsSpeaking(false);
                  stopLatencyLoop().catch(() => {});
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
                setIsSpeaking(true);
                await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
                setIsSpeaking(false);
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
            setIsSpeaking(true);
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
            setIsSpeaking(false);
          }
          console.log('✅ [SmartGuidance] reaching_completed=true — resetting session');
          smartGuidanceActiveRef.current = false;
          smartGuidanceResumeMainRef.current = false;
          resetSessionId();
          stopContinuousMode('smart guidance complete', true);
          break;
        }

        // ── Flag check ─────────────────────────────────────────────────────
        const navigationActive = result.navigation === true;
        const smartGuidanceActive = smartGuidanceActiveRef.current;
        const reachingActive = result.reaching_flag === true || smartGuidanceActive || smartGuidanceResumeMainRef.current;
        const bothInactive = !navigationActive && !reachingActive;

        setIsNavigation(navigationActive);
        setIsReaching(reachingActive);

        // ── RTAB → Reaching auto-handoff (Kasra) ──────────────────────────
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
            setIsSpeaking(true);
            try {
              await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
            } catch (e: any) {
              if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
                console.warn('⚠️ [RTAB→Reaching] arrival TTS error (non-fatal):', e?.message);
              }
            }
            setIsSpeaking(false);
          }

          if (continuousModeAbortRef.current || isEmergencyStopped.current) break;

          // Flip the loop mode so the next iteration sends reaching_flag=true
          // even if the current response did not have it set.
          startContinuousMode('reaching', result.loopDelay);
          setIsNavigation(false);
          setIsReaching(true);
          AccessibilityInfo.announceForAccessibility('Arrived. Switching to object guidance.');

          // Cooldown before next capture (skip null fast-poll path).
          await new Promise(r => setTimeout(r, PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN));
          continue; // ★ next iteration runs with loopMode='reaching'
        }

        if (bothInactive) {
          if (result.text) {
            setIsSpeaking(true);
            await speachesSentenceChunker.synthesizeSpeechChunked(result.text);
            setIsSpeaking(false);
          }
          AccessibilityInfo.announceForAccessibility('Task complete.');
          stopContinuousMode('both flags false', true);
          break;
        }

        // ── Mode transitions ───────────────────────────────────────────────
        if (navigationActive && !reachingActive && loopMode !== 'navigation') {
          startContinuousMode('navigation', result.loopDelay);
          AccessibilityInfo.announceForAccessibility('Switching to navigation.');
        } else if (reachingActive && !navigationActive && loopMode !== 'reaching') {
          startContinuousMode('reaching', result.loopDelay);
          AccessibilityInfo.announceForAccessibility('Switching to object guidance.');
        }

        // ── Speak (fire-and-forget) + immediately continue loop ───────────
        //
        // KEY FIX: Do NOT await TTS before starting the next cycle.
        // Old pattern:  await backend → await TTS (7s) → next capture
        //               cycle time = backend RTT + TTS duration = 8–10s
        //
        // New pattern:  await backend → fire TTS (no await) → next capture
        //               cycle time = backend RTT + MIN_CYCLE_COOLDOWN = ~2s
        //               TTS plays in background while next backend call runs.
        //
        // "Latest wins": if a new response arrives before current TTS finishes,
        // speachesSentenceChunker.stop() (called at the start of each new TTS
        // call) cuts off the stale guidance and plays the fresher one.
        // This is correct behaviour — the user has moved since the old guidance.
        //
        if (result.text && !continuousModeAbortRef.current && !isEmergencyStopped.current) {
          setIsSpeaking(true);
          // Fire TTS — do NOT await. Loop proceeds to next capture immediately.
          speachesSentenceChunker.synthesizeSpeechChunked(result.text)
            .then(() => {
              setIsSpeaking(false);
              // Bug 4 defense: if no next cycle is running yet (e.g. the
              // loop aborted between fire-and-forget start and now),
              // make sure the latency thinking sound isn't left playing.
              if (!isContinuousModeRunning.current) {
                stopLatencyLoop().catch(() => {});
              }
            })
            .catch((e: any) => {
              setIsSpeaking(false);
              if (!isContinuousModeRunning.current) {
                stopLatencyLoop().catch(() => {});
              }
              if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
                console.warn('🔄 [ContinuousMode] TTS error (non-fatal):', e?.message);
              }
            });
        } else if (isNullResponse) {
          // ── Fast-poll: "Null" text — skip TTS, rapid 500ms cycle ─────────
          const nullCooldown = smartGuidanceActiveRef.current
            ? SMART_GUIDANCE_MIN_CYCLE_MS
            : 500;
          console.log(`🔄 ⏭️ Null fast-poll — waiting ${nullCooldown}ms before next cycle`);
          await new Promise(resolve => setTimeout(resolve, nullCooldown));
        }

        // Brief cooldown before next capture — gives JS thread a breath and
        // prevents hammering the backend faster than it can handle.
        // TTS is already playing in background; this does NOT wait for it.
        if (!isNullResponse && !continuousModeAbortRef.current) {
          const minCycleMs = smartGuidanceActiveRef.current
            ? SMART_GUIDANCE_MIN_CYCLE_MS
            : PREFETCH_CONFIG.MIN_CYCLE_COOLDOWN;
          const elapsed = Date.now() - cycleStart;
          const cooldown = Math.max(0, minCycleMs - elapsed);
          if (cooldown > 0) {
            await new Promise(r => setTimeout(r, cooldown));
          }
        }

        const cycleMs = Date.now() - cycleStart;
        debugLogger.logAPI(
          `🔄 Cycle #${cycleCount} DONE | ${isNullResponse ? 'NULL→SKIP' : 'SPOKE'} | ${(cycleMs / 1000).toFixed(1)}s`,
        );
        console.log(`🔄 ═══ CYCLE #${cycleCount} DONE (${(cycleMs / 1000).toFixed(1)}s) ${isNullResponse ? '[NULL-SKIP]' : ''} ═══`);

      } catch (error: any) {
        console.error('🔄 [ContinuousMode] Error:', error);
        if (error.message?.includes('cancel')) break;
        AccessibilityInfo.announceForAccessibility(`Error: ${error.message}`);
        break;
      }
    }

    // ── Cleanup ────────────────────────────────────────────────────────────
    console.log('🔄 [ContinuousMode] Loop ended');
    await stopLatencyLoop();
    stopKasraFeed();
    isContinuousModeRunning.current = false;
    stopContinuousMode('loop ended', false);
    smartGuidanceActiveRef.current = false;
    smartGuidanceResumeMainRef.current = false;
    smartGuidanceCacheRef.current = null;
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    setIsCameraActive(true);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('ready'); }
    announceTapToStart('Ready.');
  }, [announceTapToStart, handleiOSReaching, resolveReachingPipeline, startKasraFeed, stopKasraFeed]);

  // ============================================================================
  // Stop helpers
  // ============================================================================
  const stopContinuousModeLoop = useCallback(async () => {
    console.log('🛑 Stopping continuous mode');
    continuousModeAbortRef.current = true;
    stopKasraFeed();

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await stopLatencyLoop();
    await speachesSentenceChunker.stop();
    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsReaching(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isContinuousModeRunning.current = false;
    setIsCameraActive(true);

    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('cancel'); }
    announceTapToStart('Stopped.');
  }, [announceTapToStart, stopKasraFeed]);

  const stopNavigation = useCallback(async () => {
    navigationLoopAbortRef.current = true;
    stopKasraFeed();
    if (abortControllerRef.current) { abortControllerRef.current.abort(); abortControllerRef.current = null; }
    await stopLatencyLoop(); // FIX: was missing — latency SFX survived nav interrupt
    await speachesSentenceChunker.stop();
    stopContinuousMode('user interrupt', false);
    setIsNavigation(false);
    setIsProcessing(false);
    setIsSpeaking(false);
    isNavigationLoopRunning.current = false;
    setIsCameraActive(true);
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('cancel'); }
    announceTapToStart('Navigation stopped.');
  }, [announceTapToStart, stopKasraFeed]);

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
      isProcessingRef.current = true;
      setIsProcessing(true);

      try { await cancelSTT(); } catch { }

      // Skip earcons/SFX when VoiceOver is on — audio session conflicts
      if (!screenReaderEnabledRef.current) {
        // FIX: Restore full-volume audio session after STT's Record+Measurement
        await configurePlaybackSession(!settingsRef.current.useWearablesCamera);

        audioFeedback.playEarcon('thinking');
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
          reaching_flag: false,
        },
        abortCtrl.signal
      );

      if (isEmergencyStopped.current) return;

      if (result?.object) {
        kasraLastObjectRef.current = result.object;
      }

      await stopLatencyLoop();
      //await playSuccessChime();          // ← plays jbl_success_sae.caf

      console.log('✅ Response:', {
        text: result.text.substring(0, 50) + '...',
        navigation: result.navigation,
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

        introSpeechPromise = speachesSentenceChunker.synthesizeSpeechChunked(result.text)
          .then(() => {
            setIsSpeaking(false);
            // Bug 4 defense: kill any latency loop that may have been
            // re-started by a downstream code path (or that survived an
            // earlier stop's iOS audio race) when speech naturally ends.
            stopLatencyLoop().catch(() => {});
          })
          .catch((e: any) => {
            setIsSpeaking(false);
            stopLatencyLoop().catch(() => {});
            if (!e?.message?.includes('cancel') && !e?.message?.includes('stop')) {
              console.warn('⚠️ Intro TTS error (non-fatal):', e?.message);
            }
          });
      } else {
        setIsSpeaking(false);
      }

      if (isEmergencyStopped.current) return;

      finalTranscriptRef.current = '';

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
      }
    } finally {
      setIsProcessing(false);
      isProcessingRef.current = false;
      finalTranscriptRef.current = '';
      abortControllerRef.current = null;
    }
  }, [handleiOSReaching, runContinuousLoop]);

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
    setIsProcessing(true);
    isCapturingPhotoRef.current = true;
    if (!screenReaderEnabledRef.current) { audioFeedback.playEarcon('thinking'); }
    AccessibilityInfo.announceForAccessibility('Thinking');

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
        photoPath = await reactivateCameraAndCapture({
          enableShutterSound: true,
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
  // STT hook
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
  });

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
      AccessibilityInfo.announceForAccessibility('Listening');
      // Let VoiceOver finish before the mic opens to avoid "Listening" bleed-through.
      await new Promise(resolve => setTimeout(resolve, VOICEOVER_LISTENING_ANNOUNCE_DELAY_MS));
    }

    try {
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

        audioFeedback.playEarcon('listening');
        playListenSound();

        // ✅ FIX: The earcon sets Sound.setCategory('Playback', false) which
        // locks the audio session in exclusive-playback mode. Voice.start()
        // needs PlayAndRecord. Reset the category BEFORE starting STT so the
        // mic can be acquired. PlayAndRecord allows the earcon to keep playing
        // while recording begins simultaneously.
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

      isCapturingPhotoRef.current = true;
      if (!screenReaderEnabled) { audioFeedback.playEarcon('thinking'); }
      AccessibilityInfo.announceForAccessibility('Thinking');

      await new Promise(resolve => setTimeout(resolve, AUDIO_SESSION_RELEASE_DELAY_MS));
      if (isEmergencyStopped.current) { isCapturingPhotoRef.current = false; return; }

      let photoPath = '';
      try {
        photoPath = await reactivateCameraAndCapture({
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

    if (abortControllerRef.current) {
      abortControllerRef.current.abort();
      abortControllerRef.current = null;
    }

    await stopLatencyLoop(); // FIX: kill thinking SFX immediately on emergency stop
    await speachesSentenceChunker.stop();
    try { await cancelSTT(); } catch { }

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
    if (isListening) return 'Listening';
    return screenReaderEnabled ? 'Ready' : 'Ready. Tap to speak';
  };

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
      AccessibilityInfo.announceForAccessibility(`Stopping ${mode}.`);
      await stopContinuousModeLoop();
      return;
    }

    if (isSpeaking || isProcessing) {
      AccessibilityInfo.announceForAccessibility('Stopping.');
      await emergencyStop();
      return;
    }

    if (isListening) {
      AccessibilityInfo.announceForAccessibility('Thinking.');
      await stopListeningManually();
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
        accessibilityLabel={getAccessibilityLabel()}
        accessibilityHint={getAccessibilityHint()}
        accessibilityRole="button"
        accessibilityState={{ busy: isProcessing || isNavigation, disabled: false }}
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
            isListening={isListening}
            isProcessing={isProcessing}
            isSpeaking={isSpeaking}
            isNavigation={isNavigation}
            isReaching={isReaching}
            transcript={transcript}
            pulseAnim={pulseAnim}
            opacityAnim={opacityAnim}
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