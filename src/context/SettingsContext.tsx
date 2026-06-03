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

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export type WearablesMicrophoneSource = 'wearables' | 'phone';

export interface AppSettings {
  /** When true, ignore reaching_ios → use the generic "reaching" pipeline */
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
  updatePreferAlternativeReaching: (value: boolean) => Promise<void>;
  updateUseWearablesCamera: (value: boolean) => Promise<void>;
  updateWearablesMicrophoneSource: (source: WearablesMicrophoneSource) => Promise<void>;
  updateTtsRate: (rate: number) => Promise<void>;
  updateDeveloperMode: (value: boolean) => Promise<void>;
  updateReachingMode: (mode: 'handFree' | 'withHand') => Promise<void>;
  updateDistanceUnit: (unit: 'steps' | 'cm') => Promise<void>;
  updateEnableAcquisitionAutoExit: (value: boolean) => Promise<void>;
  /**
   * Given the backend flags, decide which reaching pipeline to use.
   * Returns 'arkit' | 'standard' | 'none'.
   */
  resolveReachingPipeline: (flags: {
    reaching_ios?: boolean;
    reaching?: boolean;
  }) => 'arkit' | 'standard' | 'none';
}

// ─────────────────────────────────────────────────────────────────────────────
// Defaults
// ─────────────────────────────────────────────────────────────────────────────

const DEFAULT_SETTINGS: AppSettings = {
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
          const merged: AppSettings = { ...DEFAULT_SETTINGS, ...saved };
          setSettings(merged);

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

  const updatePreferAlternativeReaching = useCallback(
    async (value: boolean) => {
      const next = { ...settings, preferAlternativeReaching: value };
      setSettings(next);
      await persist(next);
      console.log(
        `[Settings] Reaching pipeline → ${value ? 'Standard (reaching)' : 'ARKit (reaching_ios)'}`,
      );
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
    (flags: { reaching_ios?: boolean; reaching?: boolean }): 'arkit' | 'standard' | 'none' => {
      const { reaching_ios, reaching } = flags;

      // User explicitly chose the alternative pipeline
      if (settings.preferAlternativeReaching) {
        return reaching ? 'standard' : 'none';
      }

      // Default: prefer ARKit when available on iOS
      if (reaching_ios && Platform.OS === 'ios') {
        return 'arkit';
      }
      if (reaching) {
        return 'standard';
      }
      return 'none';
    },
    [settings.preferAlternativeReaching],
  );

  // ── Value ─────────────────────────────────────────────────────────────────

  const value: SettingsContextValue = {
    settings,
    isLoaded,
    updatePreferAlternativeReaching,
    updateUseWearablesCamera,
    updateWearablesMicrophoneSource,
    updateTtsRate,
    updateDeveloperMode,
    updateReachingMode,
    updateDistanceUnit,
    updateEnableAcquisitionAutoExit,
    resolveReachingPipeline,
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
