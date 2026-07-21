// src/i18n/languages.ts
//
// Language identity and the locale tags each subsystem needs.
//
// ShelfScout speaks and listens in one language at a time. That language is a
// user setting (see SettingsContext.language), NOT the system locale — a blind
// user in Quebec may run an English iPhone but want French guidance, or the
// reverse. The system locale only seeds the first launch.

import { NativeModules, Platform } from 'react-native';

/** Languages the app can speak, listen in, and render. */
export type AppLanguage = 'en' | 'fr';

export const SUPPORTED_LANGUAGES: AppLanguage[] = ['en', 'fr'];

export const DEFAULT_LANGUAGE: AppLanguage = 'en';

/**
 * Locale tags per subsystem. These differ in format, which is why they are
 * spelled out rather than derived from the language code:
 *
 *  - `stt`     BCP-47 for SFSpeechRecognizer via @react-native-voice/voice
 *  - `tts`     BCP-47 for AVSpeechSynthesisVoice / react-native-tts
 *  - `speaches` bare language code for the Speaches STT/TTS server
 *  - `bcp47`   canonical tag for anything else (native module config)
 *
 * French is fr-CA (Quebec) throughout: Apple ships fr-CA recognition and the
 * Amélie/Nicolas voices, so a Quebec user hears local French rather than
 * European French.
 */
export interface LanguageLocales {
  stt: string;
  tts: string;
  speaches: string;
  bcp47: string;
}

export const LANGUAGE_LOCALES: Record<AppLanguage, LanguageLocales> = {
  en: { stt: 'en-US', tts: 'en-US', speaches: 'en', bcp47: 'en-US' },
  fr: { stt: 'fr-CA', tts: 'fr-CA', speaches: 'fr', bcp47: 'fr-CA' },
};

/**
 * Endonyms — each language names itself in its own language, so the Settings
 * picker is readable to a user who cannot read the *current* language. This is
 * the platform convention (iOS Language & Region lists "Français", not
 * "French").
 */
export const LANGUAGE_ENDONYMS: Record<AppLanguage, string> = {
  en: 'English',
  fr: 'Français',
};

/** Narrow an arbitrary string to a supported language, or null. */
export function parseLanguage(value: unknown): AppLanguage | null {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toLowerCase().replace('_', '-');
  if (!normalized) return null;
  // Match on the primary subtag so fr-CA, fr-FR, fr-BE all resolve to 'fr'.
  const primary = normalized.split('-')[0];
  return (SUPPORTED_LANGUAGES as string[]).includes(primary)
    ? (primary as AppLanguage)
    : null;
}

/**
 * The device's preferred language, used only to seed the setting on first
 * launch. Read through NativeModules rather than adding a localization
 * dependency — this is the same source react-native-localize reads.
 */
export function detectDeviceLanguage(): AppLanguage {
  try {
    const candidates: unknown[] = [];

    if (Platform.OS === 'ios') {
      const settings = NativeModules.SettingsManager?.settings;
      // AppleLanguages is ordered by user preference; AppleLocale is the
      // region-formatted locale. Prefer the language list.
      const appleLanguages = settings?.AppleLanguages;
      if (Array.isArray(appleLanguages)) {
        candidates.push(...appleLanguages);
      }
      candidates.push(settings?.AppleLocale);
    } else {
      candidates.push(NativeModules.I18nManager?.localeIdentifier);
    }

    for (const candidate of candidates) {
      const parsed = parseLanguage(candidate);
      if (parsed) return parsed;
    }
  } catch (error) {
    console.warn('[i18n] Could not read device language:', error);
  }

  return DEFAULT_LANGUAGE;
}
