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
 */
export const KOKORO_VOICES: Record<AppLanguage, KokoroVoiceParams> = {
  en: { voice: 'af_heart', language: 'en-us' },
  fr: { voice: 'ff_siwis', language: 'fr-fr' },
};

export function kokoroParamsForCurrentLanguage(): KokoroVoiceParams {
  return KOKORO_VOICES[getAppLanguage()];
}
