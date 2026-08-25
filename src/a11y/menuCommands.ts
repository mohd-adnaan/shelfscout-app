// src/a11y/menuCommands.ts
//
// Turning a menu row plus a spoken fragment into one unambiguous command.
//
// ── The problem ────────────────────────────────────────────────────────────
// When a user presses "Find an object" and then speaks, the intent is already
// settled — they pressed a button that says so. Only the target is unknown.
// But the pipeline downstream still classifies whatever text it is handed, and
// a bare noun classifies badly: the intent prompt's own rules send an
// utterance with no verb to `chat`, so pressing "Find an object" and saying
// "cereal" returned a *description* of the cereal instead of guidance to it.
//
// Wrapping the fragment in a fixed sentence fixes that — the classifier sees
// a request whose only variable is a noun phrase. The catch is that people do
// not speak in noun phrases. Having pressed a button labelled "Find an
// object", a user will still say "find the cereal", because that is how
// speaking to an assistant works. Naive wrapping then produces "Guide my hand
// to find the cereal", and target extraction pulls out "find the cereal".
//
// So the fragment is stripped of any leading request verb before it is
// wrapped. This is deliberately a small, closed list of exact phrasings rather
// than anything clever: over-stripping would eat part of a real target ("find
// the finder" is not a thing, but "search light" is), and the cost of a missed
// strip is a slightly awkward sentence that still routes correctly, while the
// cost of a wrong strip is guidance to the wrong object.

import { AppLanguage } from '../i18n';

/**
 * Leading request phrases to remove, longest-first within each language.
 *
 * Anchored at the start and required to be followed by whitespace, so a target
 * that merely begins with one of these letters is never touched.
 */
const LEADING_REQUESTS: Record<AppLanguage, RegExp[]> = {
  en: [
    /^(?:please\s+)?(?:could you\s+|can you\s+|would you\s+)?(?:please\s+)?(?:help me\s+(?:to\s+)?)?(?:find|locate|search for|look for|get|grab|reach|take|pick up|point me to|guide me to|show me|bring me to|where is|where's|where are)\s+/i,
    /^(?:i\s+(?:want|need)\s+(?:to\s+(?:find|get|reach|grab)\s+)?)/i,
    /^(?:the\s+object\s+is\s+)/i,
  ],
  fr: [
    /^(?:s['’]?il\s+(?:te|vous)\s+pla[iî]t\s+)?(?:peux[- ]tu\s+|pouvez[- ]vous\s+)?(?:m['’]?aider\s+[àa]\s+)?(?:trouve[rz]?|cherche[rz]?|attrape[rz]?|prend[rs]?e?[sz]?|localise[rz]?|guide[- ]?moi\s+(?:vers|jusqu['’]?[àa])|am[eè]ne[- ]?moi\s+(?:vers|[àa])|montre[- ]?moi|o[uù]\s+(?:est|sont|se\s+trouve))\s+/i,
    /^(?:je\s+(?:veux|cherche|voudrais)\s+(?:trouver\s+|prendre\s+)?)/i,
  ],
};

/** Trailing politeness that adds nothing and confuses target extraction. */
const TRAILING_NOISE: Record<AppLanguage, RegExp> = {
  en: /\s*(?:please|for me|thanks|thank you)\s*[.!?]*$/i,
  fr: /\s*(?:s['’]?il\s+(?:te|vous)\s+pla[iî]t|pour\s+moi|merci)\s*[.!?]*$/i,
};

/**
 * Reduce a spoken fragment to the target it names.
 *
 * Returns the original text when stripping would leave nothing — "find it"
 * with no other content is better sent through whole than sent through empty,
 * because an empty target is a guaranteed failure while a vague one at least
 * reaches the classifier's own disambiguation.
 */
export function extractTargetPhrase(
  transcript: string,
  language: AppLanguage = 'en',
): string {
  const original = (transcript || '').trim();
  if (!original) return '';

  let text = original;

  const patterns = LEADING_REQUESTS[language] ?? LEADING_REQUESTS.en;
  for (const pattern of patterns) {
    // `test` first: `replace` on a non-matching pattern returns the input
    // unchanged, which is indistinguishable from a successful strip and would
    // stop the search at the first pattern every time.
    if (!pattern.test(text)) continue;
    const stripped = text.replace(pattern, '').trim();
    // Only accept a strip that leaves something behind, and stop at the first
    // one that does. Stripping repeatedly is how "find the search light"
    // loses its noun.
    if (stripped) {
      text = stripped;
      break;
    }
  }

  text = text.replace(TRAILING_NOISE[language] ?? TRAILING_NOISE.en, '').trim();
  // Trailing punctuation, so the wrapper's own full stop is not doubled into
  // "cereal.." and a comma left by a stripped politeness does not survive.
  text = text.replace(/[.,;!?]+$/, '').trim();

  return text || original;
}

/**
 * Build the command text for a menu row that collects a spoken argument.
 *
 * `buildCommand` comes from the active string catalog, so the sentence is
 * built in the language the classifier is prompted in.
 */
export function canonicalizeMenuCommand(
  transcript: string,
  buildCommand: (target: string) => string,
  language: AppLanguage = 'en',
): string {
  const target = extractTargetPhrase(transcript, language);
  if (!target) return (transcript || '').trim();
  return buildCommand(target);
}
