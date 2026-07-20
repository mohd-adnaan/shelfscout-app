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
//   4. Groq LLM label resolution against the candidate list
//
// The pure matching functions are exported separately so they are testable
// without the native bridge.

import { ARKitNavigationBridge, ARKitNavigationTargetEntry } from '../native/ARKitNavigationModule';
import { groqIntentClient } from './GroqIntentClient';

export type GroundingMethod = 'exact' | 'fuzzy' | 'phonetic' | 'llm';

export interface GroundingResult {
  status: 'matched' | 'no_match' | 'no_vocabulary';
  label?: string;
  mapId?: string;
  mapName?: string;
  method?: GroundingMethod;
  /** Distinct saved labels, for spoken "saved destinations include…" feedback. */
  availableTargets: string[];
}

export const normalizeSpokenLabel = (raw: string): string =>
  raw
    .toLowerCase()
    .replace(/[_-]/g, ' ')
    .replace(/[^a-z0-9 ]/g, ' ')
    .split(/\s+/)
    .filter(Boolean)
    .filter((token, index) => !(index === 0 && ['the', 'a', 'an'].includes(token)))
    .join(' ');

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

// Mirrors SemanticRouteNavigator.phoneticKey so JS grounding and native
// fallback matching agree on what counts as "the same word".
export const phoneticKey = (raw: string): string =>
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
        .replace(/^kn/, 'n');
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
