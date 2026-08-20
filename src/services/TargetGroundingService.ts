// src/services/TargetGroundingService.ts
//
// Grounds a free-form ASR/LLM navigation target ("serial", "onion") against
// the real spoken labels stored in the saved route maps ("cereal", "onions")
// BEFORE the AR session is opened. This restores the synonym-matching step
// the original backend architecture performed with its LLM: without it, one
// accent-driven transcription slip dead-ends guidance with "not found".
//
// Cascade, cheapest first:
//   1. exact normalized match
//   2. bounded edit distance (plural drift, one-letter slips)
//   3. phonetic consonant-skeleton key ("serial" ↔ "cereal")
//   4. token containment ("400 lounge room" ↔ "400 lounge")
//   5. phonetic token containment ("crave" / "serials" ↔ "Krave cereal")
//   6. Groq LLM label resolution against the candidate list
//
// The pure matching functions are exported separately so they are testable
// without the native bridge.

import { ARKitNavigationBridge, ARKitNavigationTargetEntry } from '../native/ARKitNavigationModule';
import { groqIntentClient } from './GroqIntentClient';
import { AppLanguage, getAppLanguage } from '../i18n';

export type GroundingMethod =
  | 'exact'
  | 'fuzzy'
  | 'phonetic'
  | 'contains'
  | 'phonetic_contains'
  | 'llm';

export interface GroundingResult {
  status: 'matched' | 'no_match' | 'no_vocabulary';
  label?: string;
  mapId?: string;
  mapName?: string;
  method?: GroundingMethod;
  /** Distinct saved labels, for spoken "saved destinations include…" feedback. */
  availableTargets: string[];
}

/**
 * Fold Latin-1 diacritics to ASCII.
 *
 * Applied before the `[^a-z0-9 ]` strip below, which would otherwise turn
 * "crème" into "cr me" and "pâtes" into "p tes" — every accented French label
 * would fail to match itself. Harmless for English, where accents are rare.
 *
 * Mirrors `SemanticRouteNavigator.foldDiacritics`.
 */
export const foldDiacritics = (raw: string): string =>
  raw
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    // Ligatures are NOT decomposed by NFD and are not diacritics, so they
    // survive both here and in Swift's .folding(). Expand them explicitly:
    // "œuf" is a real grocery word, and left alone the two implementations
    // disagree (Swift counts œ as alphanumeric, the regex below does not).
    .replace(/œ/g, 'oe')
    .replace(/Œ/g, 'OE')
    .replace(/æ/g, 'ae')
    .replace(/Æ/g, 'AE');

/**
 * Leading articles dropped from a spoken label, per language.
 *
 * French carries partitives that English does not: a shopper asks for "des
 * oignons" or "de la crème", never the bare noun, so these have to come off
 * before matching against a route-map label like "oignons".
 */
const LEADING_ARTICLES: Record<AppLanguage, string[]> = {
  en: ['the', 'a', 'an'],
  fr: ['le', 'la', 'les', 'l', 'un', 'une', 'des', 'du', 'de', 'au', 'aux'],
};

/** Max leading article tokens to drop — French "de la" needs two. */
const MAX_LEADING_ARTICLE_TOKENS = 2;

export const normalizeSpokenLabel = (raw: string): string => {
  const articles = LEADING_ARTICLES[getAppLanguage()];
  const tokens = foldDiacritics(raw)
    .toLowerCase()
    // Split elisions so "l'oignon" / "d'eau" become separate tokens and the
    // article half can be dropped below.
    .replace(/['’]/g, ' ')
    .replace(/[_-]/g, ' ')
    .replace(/[^a-z0-9 ]/g, ' ')
    .split(/\s+/)
    .filter(Boolean);

  let start = 0;
  while (
    start < tokens.length - 1 &&
    start < MAX_LEADING_ARTICLE_TOKENS &&
    articles.includes(tokens[start])
  ) {
    start += 1;
  }

  return tokens.slice(start).join(' ');
};

export const levenshteinDistance = (a: string, b: string): number => {
  if (!a.length) return b.length;
  if (!b.length) return a.length;
  let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
  let current = new Array<number>(b.length + 1).fill(0);
  for (let i = 1; i <= a.length; i += 1) {
    current[0] = i;
    for (let j = 1; j <= b.length; j += 1) {
      const substitution = previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1);
      current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, substitution);
    }
    [previous, current] = [current, previous];
  }
  return previous[b.length];
};

/**
 * French consonant-skeleton key.
 *
 * The English key below encodes English spelling rules (ph→f, kn→n, silent
 * initial w) which say nothing useful about French. The substitutions that
 * actually matter in fr-CA grocery speech are:
 *   - silent final consonants: "oignon" / "oignons" must collide, and so must
 *     "lait" / "laid"
 *   - digraphs: ch, gn, qu, ou, au/eau, ai/ei
 *   - silent h everywhere
 *
 * Heuristic, not a real phonemiser — its only job is to make ASR near-misses
 * collide while keeping genuinely different words apart.
 *
 * Mirrors `SemanticRouteNavigator.phoneticKeyFrench`.
 */
const phoneticKeyFrench = (raw: string): string =>
  foldDiacritics(raw)
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .map(word => {
      if (/^[0-9]+$/.test(word)) return word;

      let normalized = word
        // Digraphs first — order matters: 'eau' before 'au', 'ch' before 'c'.
        .replace(/eau/g, 'o')
        .replace(/au/g, 'o')
        .replace(/ou/g, 'u')
        .replace(/ai|ei|ay|ey/g, 'e')
        .replace(/ph/g, 'f')
        .replace(/ch/g, 'S')   // placeholder: 'S' survives the vowel pass
        .replace(/gn/g, 'N')   // placeholder for the palatal nasal
        .replace(/qu/g, 'k')
        .replace(/th/g, 't')
        .replace(/h/g, '');    // otherwise silent

      // Silent word-final letters, stripped in this order and BEFORE the
      // single-character swaps below. French stacks them — "haricots" ends in
      // a plural 's' on top of an already-silent 't' — so a single pass, or a
      // pass after 'x' has become 'ks', leaves singular and plural with
      // different keys. That is the exact plural drift this key exists to
      // absorb, so the order here is load-bearing:
      //   1. plural marker   haricots → haricot,  eaux → eau
      //   2. silent final e  creme    → crem
      //   3. silent final consonant   haricot → harico
      normalized = normalized
        .replace(/[sx]$/, '')
        .replace(/e$/, '')
        .replace(/[tdpzgs]$/, '');

      normalized = normalized
        .replace(/c(?=[eiy])/g, 's')
        .replace(/c/g, 'k')
        .replace(/z/g, 's')
        .replace(/x/g, 'ks')
        .replace(/y/g, 'i');

      let key = '';
      for (let i = 0; i < normalized.length; i += 1) {
        const ch = normalized[i];
        if (i > 0 && 'aeiou'.includes(ch)) continue;
        if (key.length && key[key.length - 1] === ch) continue;
        key += ch;
      }
      return key;
    })
    .join(' ');

// Mirrors SemanticRouteNavigator.phoneticKey so JS grounding and native
// fallback matching agree on what counts as "the same word".
const phoneticKeyEnglish = (raw: string): string =>
  raw
    .toLowerCase()
    .split(/[^a-z0-9]+/)
    .filter(Boolean)
    .map(word => {
      if (/^[0-9]+$/.test(word)) return word;
      let normalized = word
        .replace(/ph/g, 'f')
        .replace(/gh/g, 'g')
        .replace(/wh/g, 'w')
        .replace(/^wr/, 'r')
        .replace(/^kn/, 'n')
        // Strip a single trailing plural 's' before the skeleton is built, the
        // same silent-letter pass phoneticKeyFrench already does. Without it
        // a spoken plural ("cereals") stacked on a phonetic slip ("serials")
        // keys differently from a singular saved label ("Cereal") — "srls"
        // vs "srl" — even though the fuzzy/edit-distance rung above already
        // absorbs plural drift on its own for words with no phonetic slip.
        .replace(/s$/, '');
      let mapped = '';
      for (let i = 0; i < normalized.length; i += 1) {
        const ch = normalized[i];
        if (ch === 'c') {
          mapped += 'eiy'.includes(normalized[i + 1] ?? ' ') ? 's' : 'k';
        } else if (ch === 'q') {
          mapped += 'k';
        } else if (ch === 'z') {
          mapped += 's';
        } else if (ch === 'x') {
          mapped += 'ks';
        } else {
          mapped += ch;
        }
      }
      let key = '';
      for (let i = 0; i < mapped.length; i += 1) {
        const ch = mapped[i];
        if (i > 0 && 'aeiou'.includes(ch)) continue;
        if (key.length && key[key.length - 1] === ch) continue;
        key += ch;
      }
      return key;
    })
    .join(' ');

/**
 * Consonant-skeleton key for the active language.
 *
 * Kept as a single exported entry point so callers (and the native mirror)
 * never have to know which ruleset applies.
 */
export const phoneticKey = (raw: string): string =>
  getAppLanguage() === 'fr' ? phoneticKeyFrench(raw) : phoneticKeyEnglish(raw);

const digitTokens = (s: string): string =>
  s.split(' ').filter(token => /^[0-9]+$/.test(token)).join(' ');

const fuzzyMatches = (a: string, b: string): boolean => {
  // Numbered labels must stay exact on the number: one edit is all that
  // separates "aisle 3" from "aisle 4".
  if (digitTokens(a) !== digitTokens(b)) return false;
  const shorter = Math.min(a.length, b.length);
  const allowedEdits = shorter >= 8 ? 2 : shorter >= 5 ? 1 : 0;
  return allowedEdits > 0 && levenshteinDistance(a, b) <= allowedEdits;
};

/**
 * Token-containment score between a saved label and a spoken target.
 *
 * Edit distance and the phonetic key both compare whole strings, so a spoken
 * target that carries the saved label plus a filler word — "400 lounge room"
 * for the saved "400 lounge" — misses every earlier rung of the cascade by a
 * wide margin (five edits, different consonant skeleton) and dead-ends with
 * "not found". People describe destinations that way constantly, so treat the
 * shorter token list being wholly contained in the longer one as a match.
 *
 * Returns the number of tokens that had to line up (0 when they don't), which
 * the caller uses to prefer the most specific label and to detect ties.
 *
 * Digit tokens must still agree exactly on both sides: without that guard
 * "lounge" would match "400 lounge" and "500 lounge" equally, and "aisle 3"
 * would match "aisle 4 shelf".
 *
 * Mirrors `SemanticRouteNavigator.containmentScore`.
 */
export const containmentScore = (label: string, requested: string): number => {
  // Normalizing here (rather than trusting the caller) keeps this function
  // interchangeable with its Swift mirror; it is idempotent on the already-
  // normalized strings the cascade passes in.
  const a = normalizeSpokenLabel(label);
  const b = normalizeSpokenLabel(requested);
  if (!a || !b) return 0;
  if (digitTokens(a) !== digitTokens(b)) return 0;

  const labelTokens = a.split(' ').filter(Boolean);
  const requestedTokens = b.split(' ').filter(Boolean);
  if (!labelTokens.length || !requestedTokens.length) return 0;

  return consumeTokens(labelTokens, requestedTokens);
};

/**
 * Token containment where the tokens are compared by phonetic key.
 *
 * `containmentScore` above compares tokens literally, which means one ASR slip
 * anywhere in a multi-word label collapses the whole rung. The saved label
 * "Krave cereal" is the case that broke in the field: dictation hears "crave",
 * "serial", or both, and the target the classifier hands back is often only
 * part of the label ("crave") or the label plus a filler ("crave cereal
 * aisle"). Every one of those scores 0 here:
 *
 *   requested        whole-string phonetic   literal containment
 *   "crave"          "krv" ≠ "krv srl"       "crave" ∉ {krave, cereal}
 *   "serials"        "srl" ≠ "krv srl"       "serials" ∉ {krave, cereal}
 *   "crave cereal"   "krv srl" = "krv srl"   ✗ but the rung above saves it
 *   "crave cereal aisle"  no                 "krave" ∉ {crave, cereal, aisle}
 *
 * so guidance dead-ended with "I could not find … saved destinations include
 * Krave cereal", and whether a query worked came down to whether the
 * classifier happened to return the exact full label — which is why the same
 * request succeeded roughly once in ten.
 *
 * Comparing token keys instead makes all of them collide deterministically,
 * with no network call in the path. The guards that keep it honest are
 * unchanged: digit tokens must still agree exactly, and the caller still
 * refuses to guess between two labels that tie.
 *
 * Mirrors `SemanticRouteNavigator.phoneticContainmentScore`.
 */
export const phoneticContainmentScore = (label: string, requested: string): number => {
  const a = normalizeSpokenLabel(label);
  const b = normalizeSpokenLabel(requested);
  if (!a || !b) return 0;
  if (digitTokens(a) !== digitTokens(b)) return 0;

  // Digits keep their literal form (phoneticKey passes them through), so the
  // digit guard above still holds after keying.
  const labelKeys = a.split(' ').filter(Boolean).map(phoneticKey);
  const requestedKeys = b.split(' ').filter(Boolean).map(phoneticKey);
  if (!labelKeys.length || !requestedKeys.length) return 0;

  // A one-character skeleton carries almost no information — "eau" and "eye"
  // both reduce to a single letter — and matching on one would let unrelated
  // words collide. Same threshold the whole-string phonetic rung uses.
  //
  // Digits are exempt: phoneticKey passes them through unchanged, so a single
  // digit is a literal, not a weak skeleton. Without the exemption "Aisle 3"
  // keys to ["asl", "3"], the "3" trips the length test, and this rung is
  // silently dead for every numbered label — while the digit guard above is
  // already what keeps "aisle 3" and "aisle 4" apart.
  const tooWeak = (key: string): boolean => !/^[0-9]+$/.test(key) && key.length < 2;
  if ([...labelKeys, ...requestedKeys].some(tooWeak)) return 0;

  return consumeTokens(labelKeys, requestedKeys);
};

/**
 * Is the shorter token list wholly contained in the longer one?
 *
 * Matches are consumed so a repeated token needs a partner on both sides.
 * Returns how many tokens had to line up, which the caller uses to prefer the
 * most specific label and to detect ties.
 */
const consumeTokens = (labelTokens: string[], requestedTokens: string[]): number => {
  const [shorter, longer] = labelTokens.length <= requestedTokens.length
    ? [labelTokens, requestedTokens]
    : [requestedTokens, labelTokens];

  const pool = [...longer];
  for (const token of shorter) {
    const index = pool.indexOf(token);
    if (index === -1) return 0;
    pool.splice(index, 1);
  }
  return shorter.length;
};

const uniqueLabels = (entries: ARKitNavigationTargetEntry[]): string[] => {
  const seen = new Set<string>();
  const labels: string[] = [];
  for (const entry of entries) {
    const key = entry.label.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    labels.push(entry.label);
  }
  return labels;
};

/**
 * Pure local cascade (exact → fuzzy → phonetic) over the saved vocabulary.
 * Exact matches are exhausted across all entries before any fuzzy match is
 * accepted, so a noisy candidate can never shadow a literal one.
 */
export const matchTargetAgainstVocabulary = (
  rawTarget: string,
  entries: ARKitNavigationTargetEntry[],
): GroundingResult => {
  const availableTargets = uniqueLabels(entries);
  const requested = normalizeSpokenLabel(rawTarget);
  if (!requested || !entries.length) {
    return { status: entries.length ? 'no_match' : 'no_vocabulary', availableTargets };
  }

  const matched = (entry: ARKitNavigationTargetEntry, method: GroundingMethod): GroundingResult => ({
    status: 'matched',
    label: entry.label,
    mapId: entry.mapId,
    mapName: entry.mapName,
    method,
    availableTargets,
  });

  for (const entry of entries) {
    if (normalizeSpokenLabel(entry.label) === requested) return matched(entry, 'exact');
  }
  for (const entry of entries) {
    if (fuzzyMatches(normalizeSpokenLabel(entry.label), requested)) return matched(entry, 'fuzzy');
  }
  const requestedKey = phoneticKey(requested);
  if (requestedKey.length >= 2) {
    for (const entry of entries) {
      if (phoneticKey(normalizeSpokenLabel(entry.label)) === requestedKey) {
        return matched(entry, 'phonetic');
      }
    }
  }

  // Containment runs last of the local rungs: it is the loosest rule, so an
  // exact/fuzzy/phonetic hit on any entry must win over it. The most specific
  // label wins ("400 lounge" over a bare "lounge"), and a tie between two
  // different labels is left unresolved for the LLM rather than guessed at —
  // walking a blind user to the wrong room is worse than asking again.
  //
  // Two passes, strict before loose: literal token containment first, then the
  // same rule over phonetic keys. Keeping them separate means a label that
  // matches literally can never be displaced by one that only matches by
  // sound, while a request that carries an ASR slip still resolves locally
  // instead of falling through to the network.
  const bestContainment = (
    score: (label: string, requested: string) => number,
  ): ARKitNavigationTargetEntry | null => {
    let best: { entry: ARKitNavigationTargetEntry; score: number } | null = null;
    let bestIsAmbiguous = false;
    for (const entry of entries) {
      const label = normalizeSpokenLabel(entry.label);
      const value = score(label, requested);
      if (!value) continue;
      if (!best || value > best.score) {
        best = { entry, score: value };
        bestIsAmbiguous = false;
      } else if (value === best.score && label !== normalizeSpokenLabel(best.entry.label)) {
        bestIsAmbiguous = true;
      }
    }
    return best && !bestIsAmbiguous ? best.entry : null;
  };

  const literal = bestContainment(containmentScore);
  if (literal) return matched(literal, 'contains');

  const sounded = bestContainment(phoneticContainmentScore);
  if (sounded) return matched(sounded, 'phonetic_contains');

  return { status: 'no_match', availableTargets };
};

/**
 * Full grounding: native vocabulary fetch, local cascade, then LLM label
 * resolution. Best-effort — any failure degrades to 'no_vocabulary' so the
 * caller falls through to native-side matching.
 */
export const groundNavigationTarget = async (rawTarget: string): Promise<GroundingResult> => {
  let entries: ARKitNavigationTargetEntry[] = [];
  try {
    entries = (await ARKitNavigationBridge.availableNavigationTargets()) || [];
  } catch {
    entries = [];
  }
  if (!entries.length) {
    return { status: 'no_vocabulary', availableTargets: [] };
  }

  const local = matchTargetAgainstVocabulary(rawTarget, entries);
  if (local.status === 'matched') return local;

  try {
    const label = await groqIntentClient.resolveTargetLabel(rawTarget, local.availableTargets);
    if (label) {
      const entry = entries.find(e => e.label.toLowerCase() === label.toLowerCase());
      if (entry) {
        return {
          status: 'matched',
          label: entry.label,
          mapId: entry.mapId,
          mapName: entry.mapName,
          method: 'llm',
          availableTargets: local.availableTargets,
        };
      }
    }
  } catch {
    // LLM grounding is optional; fall through to the no-match result.
  }

  return local;
};
