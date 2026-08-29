/**
 * src/utils/spokenAnswer.ts
 *
 * The last gate before an answer becomes speech.
 *
 * ── Why this exists ────────────────────────────────────────────────────────
 * `GroqVisionClient` has always capped its own output at 300 characters, with
 * a third LLM pass to compress anything longer. That cap protected exactly one
 * of the several paths an answer can arrive on, and it protected it *softly*:
 * the shorten pass returns null — "keep what you had" — whenever it fails or
 * comes back no shorter, which is the correct call for a summarizer and the
 * wrong outcome for a listener. Everything from the n8n backend had no cap at
 * all.
 *
 * On 25 Aug 2026 a scene description ran close to a minute of speech. For a
 * sighted user that is a paragraph to skim; for the user this app is built
 * for it is a minute of standing still, unable to skip ahead, unable to tell
 * whether the useful sentence has already gone past. The budget is not a
 * formatting preference, it is the difference between an answer and a monologue.
 *
 * So the cap moves here, where it applies to whatever the LLM returned and
 * whichever LLM returned it, and it is enforced in code rather than requested
 * in a prompt.
 *
 * ── Why sentence-aware ─────────────────────────────────────────────────────
 * A hard slice at 300 characters ends mid-word, and TTS reads the fragment
 * out loud with no indication that anything was cut. Whole sentences are kept
 * while they fit; the first sentence is always kept even when it alone
 * overruns, because an answer that has been trimmed to nothing is worse than
 * one that is too long.
 */

/** Spoken budget, in characters. Roughly 20 seconds at a normal TTS rate. */
export const SPOKEN_ANSWER_MAX_CHARS = 300;

/** Sentence end followed by whitespace. A decimal point has a digit after it. */
const SENTENCE_BOUNDARY = /(?<=[.!?])\s+/;

/**
 * Trim a spoken answer to the budget, on sentence boundaries where possible.
 *
 * Never lengthens, never empties, never throws. Text already inside the budget
 * comes back byte-identical, so this is safe to apply to every response
 * including the short guidance strings that make up most of them.
 */
export function trimSpokenAnswer(
  text: string,
  maxChars: number = SPOKEN_ANSWER_MAX_CHARS,
): string {
  if (typeof text !== 'string') return '';
  const trimmed = text.trim();
  if (trimmed.length <= maxChars) return trimmed;

  const sentences = trimmed.split(SENTENCE_BOUNDARY).filter(s => s.length > 0);

  let kept = '';
  for (const sentence of sentences) {
    const candidate = kept ? `${kept} ${sentence}` : sentence;
    if (candidate.length > maxChars) break;
    kept = candidate;
  }

  if (kept) return kept;

  // The first sentence alone overruns. Cut at the last word boundary inside
  // the budget rather than mid-word, and close it so TTS reads it as a
  // finished statement instead of trailing off.
  const slice = trimmed.slice(0, maxChars);
  const lastSpace = slice.lastIndexOf(' ');
  const head = (lastSpace > maxChars * 0.5 ? slice.slice(0, lastSpace) : slice).trimEnd();
  return /[.!?]$/.test(head) ? head : `${head}.`;
}
