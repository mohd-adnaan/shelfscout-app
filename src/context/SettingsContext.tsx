/**
 * src/context/SettingsContext.tsx
 *
 * Persistent settings for CyberSight / ShelfScout.
 *
 * Settings managed:
 *  - preferAlternativeReaching: boolean
 *      false (default) → use ARKit pipeline when reaching_ios flag is true
 *      true            → use the standard "reaching" pipeline instead
 *
 *  - ttsRate: number (0.1 – 1.0)
 *      Controls react-native-tts speech rate on iOS.
 *      Default: 0.5
 *
 * Persistence: AsyncStorage under key '@cybersight_settings_v1'
 */

import React, {
  createContext,
  useContext,
  useState,
  useEffect,
  useCallback,
  ReactNode,
} from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import Tts from 'react-native-tts';
import { Platform } from 'react-native';
import { iOSTts } from '../services/iOSTtsClient';
// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export interface AppSettings {
  /** When true, ignore reaching_ios → use the generic "reaching" pipeline */
  preferAlternativeReaching: boolean;
  /** iOS TTS speech rate (0.1 = slowest, 1.0 = fastest). Default 0.5 */
  ttsRate: number;
}

interface SettingsContextValue {
  settings: AppSettings;
  isLoaded: boolean;
  updatePreferAlternativeReaching: (value: boolean) => Promise<void>;
  updateTtsRate: (rate: number) => Promise<void>;
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
  ttsRate: 0.5,
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
          applyTtsRate(merged.ttsRate);
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

  const applyTtsRate = (rate: number) => {
    if (Platform.OS === 'ios') {
      try {
        Tts.setDefaultRate(parseFloat(rate as any)); // true = iOS-only "skipTransform"
        console.log(`[Settings] TTS rate set to ${rate}`);
      } catch (e) {
        console.warn('[Settings] Failed to apply TTS rate:', e);
      }
    }
  };

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

  const updateTtsRate = useCallback(
    async (rate: number) => {
      const clamped = Math.max(0.1, Math.min(1.0, rate));
      const next = { ...settings, ttsRate: clamped };
      setSettings(next);
      applyTtsRate(clamped);
      await persist(next);
      iOSTts.setSpeechRate(clamped);
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
    updateTtsRate,
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