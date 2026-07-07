// src/context/SettingsContext.tsx


import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
  ReactNode,
} from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { Platform } from 'react-native';
import { iOSTts } from '../services/iOSTtsClient';
import { orchestratorConfig } from '../services/OrchestratorConfig';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export type WearablesMicrophoneSource = 'wearables' | 'phone';
export type NavigationPipeline = 'rtab' | 'arkit';
export type ReachingPipeline = 'visionBox' | 'spatialTarget' | 'standard';

export interface AppSettings {
  /**
   * Master switch. When true, ShelfScout runs fully on-device: ARKit
   * navigation + spatial-target ARKit reaching + local (Groq/Apple FM)
   * orchestration, with no backend calls. When false, backend mode: Kasra
   * RTAB navigation + backend-driven reaching (Vision Box or Standard/Melody).
   * This is the effective driver; navigationPipeline/reachingPipeline below
   * store the user's *backend-mode* preferences and are only used when this
   * is false.
   */
  inDeviceMode: boolean;
  /** Indoor route navigation engine. Defaults to RTAB for compatibility. */
  navigationPipeline: NavigationPipeline;
  /** Reaching guidance engine. spatialTarget is backend-bbox-free on iOS. */
  reachingPipeline: ReachingPipeline;
  /** @deprecated use reachingPipeline === 'standard'. Kept for saved-settings migration. */
  preferAlternativeReaching: boolean;
  /** When true, use Meta Ray-Ban camera feed instead of phone camera */
  useWearablesCamera: boolean;
  /** Microphone used for "Hey ShelfScout" when glasses mode is active */
  wearablesMicrophoneSource: WearablesMicrophoneSource;
  /** iOS TTS speech rate (0.1 = slowest, 1.0 = fastest). Default 0.5 */
  ttsRate: number;
  /** When true, shows the debug overlay bug button. Default false. */
  developerMode: boolean;
  /** ARKit reaching mode: 'handFree' (default) or 'withHand' */
  reachingMode: 'handFree' | 'withHand';
  /** Distance unit for reaching guidance: 'steps' (default) or 'cm' */
  distanceUnit: 'steps' | 'cm';
  /** When true, allow ARKit auto-exit via acquisition validation */
  enableAcquisitionAutoExit: boolean;
}

interface SettingsContextValue {
  settings: AppSettings;
  isLoaded: boolean;
  updateInDeviceMode: (value: boolean) => Promise<void>;
  updatePreferAlternativeReaching: (value: boolean) => Promise<void>;
  updateReachingPipeline: (pipeline: ReachingPipeline) => Promise<void>;
  updateUseWearablesCamera: (value: boolean) => Promise<void>;
  updateNavigationPipeline: (pipeline: NavigationPipeline) => Promise<void>;
  updateWearablesMicrophoneSource: (source: WearablesMicrophoneSource) => Promise<void>;
  updateTtsRate: (rate: number) => Promise<void>;
  updateDeveloperMode: (value: boolean) => Promise<void>;
  updateReachingMode: (mode: 'handFree' | 'withHand') => Promise<void>;
  updateDistanceUnit: (unit: 'steps' | 'cm') => Promise<void>;
  updateEnableAcquisitionAutoExit: (value: boolean) => Promise<void>;
  /**
   * Given the backend flags, decide which reaching pipeline to use.
   * Returns 'spatialTarget' | 'arkit' | 'standard' | 'none'.
   */
  resolveReachingPipeline: (flags: {
    reaching_ios?: boolean;
    reaching?: boolean;
  }) => ReachingPipeline | 'arkit' | 'none';
  /**
   * Given backend navigation flags, decide which navigation pipeline to use.
   * Returns 'arkit' only when user opted in and the platform can present ARKit.
   */
  resolveNavigationPipeline: (flags: {
    navigation?: boolean;
    navigation_ios?: boolean;
    navigation_arkit?: boolean;
    navigation_pipeline?: NavigationPipeline;
  }) => NavigationPipeline | 'none';
  /** Navigation engine actually in effect right now (honors In-Device Mode). */
  effectiveNavigationPipeline: NavigationPipeline;
  /** Reaching engine actually in effect right now (honors In-Device Mode). */
  effectiveReachingPipeline: ReachingPipeline;
}

// ─────────────────────────────────────────────────────────────────────────────
// Defaults
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_SETTINGS: AppSettings = {
  inDeviceMode: false,
  navigationPipeline: 'rtab',
  reachingPipeline: 'visionBox',
  preferAlternativeReaching: false,
  useWearablesCamera: false,
  wearablesMicrophoneSource: 'wearables',
  ttsRate: 0.5,
  developerMode: false,
  reachingMode: 'handFree',
  distanceUnit: 'steps',
  enableAcquisitionAutoExit: false,
};

const STORAGE_KEY = '@cybersight_settings_v1';

// ─────────────────────────────────────────────────────────────────────────────
// Context
// ─────────────────────────────────────────────────────────────────────────────

const SettingsContext = createContext<SettingsContextValue | undefined>(undefined);

// ─────────────────────────────────────────────────────────────────────────────
// Provider
// ─────────────────────────────────────────────────────────────────────────────

export function SettingsProvider({ children }: { children: ReactNode }) {
  const [settings, setSettings] = useState<AppSettings>(DEFAULT_SETTINGS);
  const [isLoaded, setIsLoaded] = useState(false);

  // ── Load from storage on mount ───────────────────────────────────────────
  useEffect(() => {
    (async () => {
      try {
        const raw = await AsyncStorage.getItem(STORAGE_KEY);
        if (raw) {
          const saved: Partial<AppSettings> = JSON.parse(raw);
          const migratedReachingPipeline: ReachingPipeline =
            saved.reachingPipeline ||
            (saved.preferAlternativeReaching ? 'standard' : DEFAULT_SETTINGS.reachingPipeline);
          // Legacy in-device combo (arkit nav + spatialTarget reaching saved
          // before the master toggle existed) → infer inDeviceMode.
          const migratedInDeviceMode =
            typeof saved.inDeviceMode === 'boolean'
              ? saved.inDeviceMode
              : saved.navigationPipeline === 'arkit' && migratedReachingPipeline === 'spatialTarget';
          const merged: AppSettings = {
            ...DEFAULT_SETTINGS,
            ...saved,
            inDeviceMode: migratedInDeviceMode,
            reachingPipeline: migratedReachingPipeline,
            preferAlternativeReaching: migratedReachingPipeline === 'standard',
          };
          setSettings(merged);

          // Bridge the master switch into the plain orchestrator singleton.
          orchestratorConfig.setInDeviceMode(merged.inDeviceMode);

          // ✅ Apply saved rate through singleton (per-utterance approach)
          // NEVER call Tts.setDefaultRate() — BOOL crash on New Architecture
          iOSTts.setSpeechRate(merged.ttsRate);
        }
      } catch (e) {
        console.warn('[Settings] Failed to load settings:', e);
      } finally {
        setIsLoaded(true);
      }
    })();
  }, []);

  // ── Helpers ───────────────────────────────────────────────────────────────

  const persist = useCallback(async (next: AppSettings) => {
    try {
      await AsyncStorage.setItem(STORAGE_KEY, JSON.stringify(next));
    } catch (e) {
      console.warn('[Settings] Failed to save settings:', e);
    }
  }, []);

  // ── Updaters ──────────────────────────────────────────────────────────────

  const updateInDeviceMode = useCallback(
    async (value: boolean) => {
      const next = { ...settings, inDeviceMode: value };
      setSettings(next);
      await persist(next);
      orchestratorConfig.setInDeviceMode(value);
      console.log(
        `[Settings] In-Device Mode → ${value ? 'ON (ARKit nav + Spatial Target reaching + local orchestration)' : 'OFF (backend)'}`,
      );
    },
    [settings, persist],
  );

  const updatePreferAlternativeReaching = useCallback(
    async (value: boolean) => {
      const next = {
        ...settings,
        preferAlternativeReaching: value,
        reachingPipeline: value ? 'standard' as ReachingPipeline : 'visionBox' as ReachingPipeline,
      };
      setSettings(next);
      await persist(next);
      console.log(
        `[Settings] Reaching pipeline → ${value ? 'Standard (reaching)' : 'Vision Box (reaching_ios)'}`,
      );
    },
    [settings, persist],
  );

  const updateReachingPipeline = useCallback(
    async (pipeline: ReachingPipeline) => {
      const next = {
        ...settings,
        reachingPipeline: pipeline,
        preferAlternativeReaching: pipeline === 'standard',
      };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Reaching pipeline → ${pipeline}`);
    },
    [settings, persist],
  );

  const updateUseWearablesCamera = useCallback(
    async (value: boolean) => {
      const next = { ...settings, useWearablesCamera: value };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Wearables camera → ${value ? 'ON' : 'OFF'}`);
    },
    [settings, persist],
  );

  const updateNavigationPipeline = useCallback(
    async (pipeline: NavigationPipeline) => {
      const next = { ...settings, navigationPipeline: pipeline };
      setSettings(next);
      await persist(next);
      console.log(
        `[Settings] Navigation pipeline → ${pipeline === 'arkit' ? 'ARKit on-device' : 'RTAB'}`,
      );
    },
    [settings, persist],
  );

  const updateWearablesMicrophoneSource = useCallback(
    async (source: WearablesMicrophoneSource) => {
      const next = { ...settings, wearablesMicrophoneSource: source };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Wearables microphone → ${source === 'wearables' ? 'Meta glasses' : 'iPhone'}`);
    },
    [settings, persist],
  );

  const updateTtsRate = useCallback(
    async (rate: number) => {
      const clamped = Math.max(0.1, Math.min(1.0, rate));
      const next = { ...settings, ttsRate: clamped };
      setSettings(next);
      await persist(next);

      // ✅ Apply through singleton only — per-utterance rate control
      iOSTts.setSpeechRate(clamped);
    },
    [settings, persist],
  );

  const updateDeveloperMode = useCallback(
    async (value: boolean) => {
      const next = { ...settings, developerMode: value };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Developer mode → ${value ? 'ON' : 'OFF'}`);
    },
    [settings, persist],
  );

  const updateReachingMode = useCallback(
    async (mode: 'handFree' | 'withHand') => {
      const next = { ...settings, reachingMode: mode };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Reaching mode → ${mode === 'handFree' ? 'Hands-free' : 'With hand tracking'}`);
    },
    [settings, persist],
  );

  const updateDistanceUnit = useCallback(
    async (unit: 'steps' | 'cm') => {
      const next = { ...settings, distanceUnit: unit };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Distance unit → ${unit === 'steps' ? 'Steps' : 'Centimeters'}`);
    },
    [settings, persist],
  );

  const updateEnableAcquisitionAutoExit = useCallback(
    async (value: boolean) => {
      const next = { ...settings, enableAcquisitionAutoExit: value };
      setSettings(next);
      await persist(next);
      console.log(`[Settings] Reaching auto-exit → ${value ? 'ON' : 'OFF'}`);
    },
    [settings, persist],
  );

  // ── Pipeline resolver ─────────────────────────────────────────────────────

  const resolveReachingPipeline = useCallback(
    (flags: { reaching_ios?: boolean; reaching?: boolean }): ReachingPipeline | 'arkit' | 'none' => {
      const { reaching_ios, reaching } = flags;

      // In-device mode always uses bbox-free spatial-target ARKit reaching.
      if (settings.inDeviceMode) {
        return Platform.OS === 'ios' ? 'spatialTarget' : 'none';
      }

      if (settings.reachingPipeline === 'standard') {
        return reaching ? 'standard' : 'none';
      }

      if (settings.reachingPipeline === 'spatialTarget' && reaching_ios && Platform.OS === 'ios') {
        return 'spatialTarget';
      }

      if (reaching_ios && Platform.OS === 'ios') {
        return 'arkit';
      }
      if (reaching) {
        return 'standard';
      }
      return 'none';
    },
    [settings.inDeviceMode, settings.reachingPipeline],
  );

  const resolveNavigationPipeline = useCallback(
    (flags: {
      navigation?: boolean;
      navigation_ios?: boolean;
      navigation_arkit?: boolean;
      navigation_pipeline?: NavigationPipeline;
    }): NavigationPipeline | 'none' => {
      // In-device mode always uses on-device ARKit route navigation.
      if (settings.inDeviceMode && Platform.OS === 'ios') {
        return 'arkit';
      }

      const wantsNavigation =
        flags.navigation === true ||
        flags.navigation_ios === true ||
        flags.navigation_arkit === true ||
        flags.navigation_pipeline === 'arkit';

      if (!wantsNavigation) {
        return 'none';
      }

      if (
        Platform.OS === 'ios' &&
        (settings.navigationPipeline === 'arkit' || flags.navigation_pipeline === 'arkit')
      ) {
        return 'arkit';
      }

      return 'rtab';
    },
    [settings.inDeviceMode, settings.navigationPipeline],
  );

  // ── Value ─────────────────────────────────────────────────────────────────

  const value: SettingsContextValue = {
    settings,
    isLoaded,
    updateInDeviceMode,
    updatePreferAlternativeReaching,
    updateReachingPipeline,
    updateUseWearablesCamera,
    updateNavigationPipeline,
    updateWearablesMicrophoneSource,
    updateTtsRate,
    updateDeveloperMode,
    updateReachingMode,
    updateDistanceUnit,
    updateEnableAcquisitionAutoExit,
    resolveReachingPipeline,
    resolveNavigationPipeline,
    effectiveNavigationPipeline: settings.inDeviceMode ? 'arkit' : settings.navigationPipeline,
    effectiveReachingPipeline: settings.inDeviceMode ? 'spatialTarget' : settings.reachingPipeline,
  };

  return (
    <SettingsContext.Provider value={value}>{children}</SettingsContext.Provider>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Hook
// ─────────────────────────────────────────────────────────────────────────────

export function useSettings(): SettingsContextValue {
  const ctx = useContext(SettingsContext);
  if (!ctx) {
    throw new Error('useSettings must be used within a SettingsProvider');
  }
  return ctx;
}