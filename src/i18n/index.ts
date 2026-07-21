// src/i18n/index.ts
//
// The app-wide language store.
//
// Deliberately a plain module singleton rather than React state alone: TTS/STT
// clients, the wake-word hook, and the orchestrator are not React components
// but still need the current language synchronously, mid-call. React consumers
// get `useStrings()` / `useAppLanguage()`, which subscribe to the same store.
//
// SettingsContext owns persistence and is the only thing that should call
// `setAppLanguage`.

import { useCallback, useSyncExternalStore } from 'react';
import {
  AppLanguage,
  DEFAULT_LANGUAGE,
  LANGUAGE_LOCALES,
  LanguageLocales,
} from './languages';
import { en, StringCatalog } from './strings/en';
import { fr } from './strings/fr';

export * from './languages';
export type { StringCatalog } from './strings/en';

const CATALOGS: Record<AppLanguage, StringCatalog> = { en, fr };

let currentLanguage: AppLanguage = DEFAULT_LANGUAGE;

const listeners = new Set<(language: AppLanguage) => void>();

/** The active language. Safe to call from anywhere, including non-React code. */
export function getAppLanguage(): AppLanguage {
  return currentLanguage;
}

/**
 * Switch the app language and notify every subscriber.
 *
 * Returns true when the language actually changed, so callers can skip
 * expensive re-configuration (restarting the recognizer, re-picking a voice)
 * on a no-op set.
 */
export function setAppLanguage(language: AppLanguage): boolean {
  if (language === currentLanguage) return false;
  currentLanguage = language;
  listeners.forEach(listener => {
    try {
      listener(language);
    } catch (error) {
      console.warn('[i18n] Language listener failed:', error);
    }
  });
  return true;
}

/**
 * Subscribe to language changes. Returns an unsubscribe function.
 * Used by long-lived services (STT restart, TTS voice re-selection).
 */
export function onAppLanguageChange(
  listener: (language: AppLanguage) => void,
): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/** Catalog for the active language — `strings().speech.thinking`. */
export function strings(): StringCatalog {
  return CATALOGS[currentLanguage];
}

/** Catalog for a specific language, regardless of the active one. */
export function stringsFor(language: AppLanguage): StringCatalog {
  return CATALOGS[language];
}

/** Locale tags (STT / TTS / Speaches / BCP-47) for the active language. */
export function currentLocales(): LanguageLocales {
  return LANGUAGE_LOCALES[currentLanguage];
}

// ── React bindings ─────────────────────────────────────────────────────────

function subscribe(onStoreChange: () => void): () => void {
  return onAppLanguageChange(onStoreChange);
}

/** Re-renders the component whenever the language changes. */
export function useAppLanguage(): AppLanguage {
  return useSyncExternalStore(subscribe, getAppLanguage, getAppLanguage);
}

/** Localized catalog that re-renders the component on language change. */
export function useStrings(): StringCatalog {
  const language = useAppLanguage();
  return CATALOGS[language];
}

/** Locale tags that re-render the component on language change. */
export function useLocales(): LanguageLocales {
  const language = useAppLanguage();
  return LANGUAGE_LOCALES[language];
}

/**
 * Stable `t`-style accessor for callbacks that must not close over a stale
 * catalog: `const t = useStringsGetter(); ... t().speech.thinking`.
 */
export function useStringsGetter(): () => StringCatalog {
  return useCallback(() => CATALOGS[currentLanguage], []);
}
