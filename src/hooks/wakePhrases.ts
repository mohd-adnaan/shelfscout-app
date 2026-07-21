// src/hooks/wakePhrases.ts
//
// Pure wake-phrase matching, split out from useWakeWordSTT so it can be tested
// without pulling in @react-native-voice/voice and the audio-session natives.
// No React, no native modules — text in, query out.

import { AppLanguage, getAppLanguage } from '../i18n';

/**
 * Single-character diacritic folding, so "hé écoute" matches the ASCII phrase
 * list whether or not the recogniser emits accents (it is inconsistent,
 * especially over a Bluetooth mic).
 *
 * Deliberately NOT `normalize('NFD')` + strip: that changes string length, and
 * stripWakePhrase indexes back into the ORIGINAL text to extract the query.
 * Every mapping here is one character to one character, so indices stay valid.
 */
const DIACRITIC_FOLDING: Record<string, string> = {
  à: 'a', á: 'a', â: 'a', ä: 'a', ã: 'a', å: 'a',
  ç: 'c',
  è: 'e', é: 'e', ê: 'e', ë: 'e',
  ì: 'i', í: 'i', î: 'i', ï: 'i',
  ñ: 'n',
  ò: 'o', ó: 'o', ô: 'o', ö: 'o', õ: 'o',
  ù: 'u', ú: 'u', û: 'u', ü: 'u',
  ý: 'y', ÿ: 'y',
};

/** Lower-case and fold diacritics while preserving character offsets. */
function foldForWakeMatch(text: string): string {
  let out = '';
  for (const ch of text.toLowerCase()) {
    out += DIACRITIC_FOLDING[ch] ?? ch;
  }
  return out;
}

/**
 * Wake phrase variants the speech recognizer might produce.
 *
 * REAL-WORLD CALIBRATION (from device logs, BT mic via Ray-Ban Meta):
 * Apple's on-device speech recogniser frequently mis-hears "shelfscout":
 *   - "shelfscout" is not a dictionary word, so the recogniser substitutes
 *     phonetically similar tokens. Observed substitutions include:
 *       "shelf scout", "shell scout", "shelves", "shelves scout",
 *       "hey scout"  (← `shelf` gets dropped entirely; most common),
 *       "asian scout", "patient scout", "shell scout scott", "scout watson",
 *       "she scout", "shelf scott", "shell scott", "scout".
 *   - Sometimes the leading "hey" survives ("hey scout") and sometimes the
 *     "hey" gets merged with the next word ("asian", "patient").
 *
 * Strategy: list every commonly-observed variant. Matching is now
 * SUBSTRING (not prefix) to handle the case where the iOS recogniser
 * concatenates multiple utterances into one ever-growing FINAL transcript.
 */
const WAKE_PHRASES_EN: string[] = [
  // Canonical forms
  'hey shelfscout',
  'hey shelf scout',
  'hey shelfscout,',
  'hey shelf scout,',
  'hey shellscout',
  'hi shelfscout',
  'hishelf scout',
  'hi shelfscout',
  'hi shelf scout',
  'hey she',
  'he she',
  'scout',
  'skout',
  'shelfcout',
  'shelves code',
  'Asian Scout',

  // "shelf" → "self" / "shell" / "shelves" substitutions
  'hey self scout',
  'hey self scout,',
  'hey shell scout',
  'hey shell scout,',
  'hey shelves scout',
  'hey shelves',
  'Hey Scout',
  'Hey Shell',
  'hey patient',


  // "hey" mis-merged with following word
  'asian scout',
  'patient scout',
  'a shelfscout',
  'a shelf scout',

  // "shelf" entirely dropped — most common mis-hearing in BT-mic logs
  'hey scout',
  'hey scott',
  'hey shell scott',
  'hey shell scott,',
  'he shall scout',
  'he shall scouts',
  'he shall scout Hazel Shell',
  'hey Shell',
  'hey Scott',
  'hey Shall',
  'he Scott',
  'scotland',
  'hi scott',
  'hi scount',
  'hi scout',


  // No-"hey" variants (when "hey" gets lost in BT compression)
  'shelfscout',
  'shelf scout',
  'shell scout',
  'shell scott',
  'shelves scout',
  'Haitian scout',
  'haitian',
];

/**
 * French (fr-CA) wake phrase variants.
 *
 * "ShelfScout" is an English brand name, so the FRENCH recogniser mis-hears it
 * in a completely different way than the English one does — it maps the sounds
 * onto French orthography and French vocabulary. Predicted substitutions:
 *   - "hey"   → "hé", "eh", "et", "ait", "aie" (all homophones in fr-CA)
 *   - "shelf" → "chef", "échelle", "chelf", "self", "sel", "chelle"
 *   - "scout" → "scout", "scoute", "scott", "écoute" (very common: the
 *               recogniser prefers the real French verb "écoute")
 *
 * ⚠️ UNCALIBRATED. The English list above was tuned against real device logs
 * (Ray-Ban Meta BT mic); this one is derived from French phonology and has NOT
 * yet been checked against field recordings. Re-tune it from logs during the
 * first French pilot session, exactly as the English list was.
 */
const WAKE_PHRASES_FR: string[] = [
  // Canonical forms
  'hey shelfscout',
  'hey shelf scout',
  'he shelfscout',
  'he shelf scout',
  'et shelf scout',
  'eh shelf scout',

  // "scout" → "écoute" / "scoute" (recogniser prefers real French words)
  'he ecoute',
  'et ecoute',
  'eh ecoute',
  'he scoute',
  'et scoute',
  'he shelf ecoute',
  'he chef ecoute',
  'chef ecoute',
  'shelf ecoute',

  // "shelf" → "chef" (closest common French word)
  'he chef scout',
  'et chef scout',
  'chef scout',
  'chef scoute',

  // "shelf" → "échelle" (the literal French sense, often surfaces)
  'he echelle scout',
  'echelle scout',
  'echelle scoute',

  // "shelf" → "self" / "sel" / "chelle"
  'he self scout',
  'self scout',
  'he sel scout',
  'sel scout',
  'chelle scout',

  // "shelf" dropped entirely
  'he scout',
  'et scout',
  'eh scout',
  'aie scout',
  'ait scout',
  'he scott',
  'et scott',

  // No-"hey" variants (when the leading interjection is lost)
  'shelfscout',
  'shelf scout',
  'shell scout',
  'scout',
  'scoute',
];

const WAKE_PHRASES_BY_LANGUAGE: Record<AppLanguage, string[]> = {
  // Matching runs against lower-cased, diacritic-folded text, so fold the
  // lists the same way here. Several entries above are written with capitals
  // ('Hey Scout', 'Asian Scout', 'Haitian scout'); without this pass they
  // could never match and were silently dead.
  en: WAKE_PHRASES_EN.map(foldForWakeMatch),
  fr: WAKE_PHRASES_FR.map(foldForWakeMatch),
};

/** Wake phrases for the language the recogniser is currently running in. */
function activeWakePhrases(): string[] {
  return WAKE_PHRASES_BY_LANGUAGE[getAppLanguage()];
}




// ============================================================================
// Helpers
// ============================================================================

/**
 * Search `text` for any wake phrase variant and return the substring that
 * follows the LAST occurrence (i.e. the user's query). Returns null if no
 * wake phrase variant is present anywhere in the transcript.
 *
 * Why "last occurrence" and not "first"?
 *   iOS STT accumulates a long transcript over time. If the user says the
 *   wake phrase twice (a retry), we want the query that follows the most
 *   recent wake — not stale text after the first one.
 *
 * Word-boundary aware: a phrase is only considered matched if it sits on
 * word boundaries, so "shelf" doesn't accidentally match inside "shelves".
 */
export function stripWakePhrase(text: string): string | null {
  // NOTE: fold but do NOT trim — trimming would shift every index relative to
  // `text`, which we slice below to recover the user's query.
  const lower = foldForWakeMatch(text);
  if (!lower.trim()) return null;

  let bestEndIndex = -1;     // position immediately AFTER the matched phrase
  let bestPhrase = '';

  for (const phrase of activeWakePhrases()) {
    // Find the LAST occurrence of this phrase in the lower-cased transcript
    let idx = lower.lastIndexOf(phrase);
    while (idx !== -1) {
      // Word-boundary check: char before must not be alphanumeric, char
      // after must not be alphanumeric (or end-of-string).
      const charBefore = idx === 0 ? ' ' : lower[idx - 1];
      const charAfter = lower[idx + phrase.length] ?? ' ';
      const isWordBoundaryBefore = !/[a-z0-9]/.test(charBefore);
      const isWordBoundaryAfter = !/[a-z0-9]/.test(charAfter);

      if (isWordBoundaryBefore && isWordBoundaryAfter) {
        const endIdx = idx + phrase.length;
        if (endIdx > bestEndIndex) {
          bestEndIndex = endIdx;
          bestPhrase = phrase;
        }
        break; // we already have the LAST occurrence of THIS phrase
      }
      // Not a word boundary, look earlier in the string for another match.
      //
      // The `idx > 0` guard is load-bearing: lastIndexOf clamps a negative
      // fromIndex to 0 rather than returning -1, so a phrase sitting at index
      // 0 that FAILS the boundary check would be found at 0 again, forever.
      // "hey she" (a real entry) matches at index 0 of "hey shelfscout ..."
      // and is followed by "l", which is exactly that case — it hung the JS
      // thread on the canonical wake phrase.
      idx = idx > 0 ? lower.lastIndexOf(phrase, idx - 1) : -1;
    }
  }

  if (bestEndIndex === -1) return null;

  // Extract whatever comes after the matched wake phrase as the query.
  // Use the original-case `text` so user words keep their casing.
  let rest = text.substring(bestEndIndex).replace(/^[,\s.!?]+/, '').trim();
  console.log(`🎯 [WakeWord] Matched phrase "${bestPhrase}" → query: "${rest}"`);
  return rest;
}

/**
 * Check if a partial transcript contains the beginning of a wake phrase,
 * even if it's incomplete (e.g. just "hey" or "hey shelf").
 */
export function containsPartialWakePhrase(text: string): boolean {
  const lower = foldForWakeMatch(text).trim();
  // Check if any wake phrase starts with what we have
  return activeWakePhrases().some(
    phrase => phrase.startsWith(lower) && lower.length >= 3,
  );
}
