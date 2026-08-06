// src/services/speachesLanguage.ts
//
// Language-dependent Speaches parameters, shared by the buffered and
// streaming TTS clients. Kept in its own module so importing it does not
// construct either client singleton (both touch react-native-sound at
// construction time).

import { AppLanguage, getAppLanguage } from '../i18n';

export interface KokoroVoiceParams {
  voice: string;
  language: string;
}

/**
 * Kokoro voice per language. The voice prefix encodes the language
 * (`a` = American English, `f` = French), so switching `language` alone is not
 * enough — an English voice reading French text applies English phonetics to
 * French spelling, which is unintelligible.
 *
 * ⚠️ `ff_siwis` is EUROPEAN French — Kokoro ships no Quebec voice, and the rest
 * of the app is deliberately fr-CA (see LANGUAGE_LOCALES and the Amélie/Nicolas
 * preference list in iOSTtsClient). This path is currently dormant:
 * SpeechOutputService speaks through `iOSTts` only, which does honour fr-CA.
 * Do not re-enable Speaches TTS for a Quebec session without checking with the
 * study lead — participants would hear Paris French for every spoken cue.
 */
export const KOKORO_VOICES: Record<AppLanguage, KokoroVoiceParams> = {
  en: { voice: 'af_heart', language: 'en-us' },
  fr: { voice: 'ff_siwis', language: 'fr-fr' },
};

export function kokoroParamsForCurrentLanguage(): KokoroVoiceParams {
  return KOKORO_VOICES[getAppLanguage()];
}
