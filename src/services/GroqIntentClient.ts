// src/services/GroqIntentClient.ts
//
// On-device intent extraction via Groq chat completions. This is the frontend
// equivalent of the backend n8n "Extract Intent" node: transcript in →
// { intent, target, needsImage, confidence } out. It exists so in-device mode
// no longer depends on Apple Foundation Models (unreliable / region-gated on
// the iPhone 16 test device) for the one LLM step reaching/navigation need.
//
// Failure is always soft: any error returns available:false so the caller
// falls back to Apple FM / heuristics rather than throwing.

import { IntentClassification, LocalLLMResult } from './LLMRouter';

// The real key list lives in the gitignored groq.secrets.ts. We import lazily
// via require so the bundle still builds when only the example file is present.
let GROQ_API_KEYS: string[] = [];
let GROQ_INTENT_MODEL = 'llama-3.3-70b-versatile';
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const secrets = require('../config/groq.secrets');
  GROQ_API_KEYS = Array.isArray(secrets.GROQ_API_KEYS) ? secrets.GROQ_API_KEYS : [];
  if (typeof secrets.GROQ_INTENT_MODEL === 'string') {
    GROQ_INTENT_MODEL = secrets.GROQ_INTENT_MODEL;
  }
} catch {
  // groq.secrets.ts not present — client reports unconfigured and caller
  // falls back to on-device Apple FM / heuristics.
}

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
const REQUEST_TIMEOUT_MS = 6000;

// Kept intentionally close to the backend Extract Intent contract so behavior
// matches between backend mode and in-device mode.
const SYSTEM_PROMPT = `You are the intent router for ShelfScout, a voice assistant for blind and low-vision users that guides them to reach objects and navigate indoors.
Classify the user's utterance into exactly one intent and extract the target.

Return ONLY a compact JSON object, no prose, no markdown, with these keys:
- "intent": one of "reaching" | "navigation" | "scene" | "chat" | "stop" | "unknown"
- "target": the object or destination as a short noun phrase, or null
- "needsImage": true if answering requires looking at the camera, else false
- "confidence": a number 0..1

Rules:
- "reaching": user wants to physically grab / pick up / be guided by hand to an object ("reach the water bottle", "help me grab the cereal", "guide me to the mug"). target = the object.
- "navigation": user wants to be guided to a place/landmark ("take me to the kitchen", "walk me to the door", "go to aisle 3"). target = the destination.
- "scene": user wants a general description of their surroundings ("what's in front of me", "describe the scene", "what's around me"). target = null, needsImage = true.
- "chat": user asks an informational question about what the camera sees, without wanting hand guidance ("is there yogurt here", "what's the price of this", "where is the milk", "what am I holding", "read this label"). target = the object if named, else null. needsImage = true.
- "stop": cancel / stop / pause / emergency. target = null.
- "unknown": anything else or too ambiguous. Keep confidence low.
Distinguish carefully: naming an object with a grab/guide verb is "reaching"; naming an object with an ask/where/is-there/price/read verb is "chat".
If the user only names an object or an object-with-location fragment with NO verb at all (e.g. "bottle on the table", "the milk carton", "cereal box"), classify as "chat" with that object as target and needsImage true — do NOT use "unknown". Reserve "unknown" for utterances with no identifiable object, place, or question.`;

let keyCursor = 0;
const nextKey = (): string | null => {
  if (GROQ_API_KEYS.length === 0) return null;
  const key = GROQ_API_KEYS[keyCursor % GROQ_API_KEYS.length];
  keyCursor += 1;
  return key;
};

const clamp01 = (v: unknown, fallback = 0.5): number => {
  const n = Number(v);
  return Number.isFinite(n) ? Math.max(0, Math.min(1, n)) : fallback;
};

const extractJson = (text?: string): any | null => {
  if (!text) return null;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return null;
  try {
    return JSON.parse(text.slice(start, end + 1));
  } catch {
    return null;
  }
};

const normalizeTarget = (raw: unknown): string | null => {
  if (typeof raw !== 'string') return null;
  const t = raw.trim().replace(/^(the|a|an)\s+/i, '').replace(/[.?!]+$/g, '').trim();
  return t.length ? t : null;
};

const unconfigured = (reason: string): LocalLLMResult<IntentClassification> => ({
  available: false,
  usedProvider: 'none',
  confidence: 0,
  needsBackend: true,
  fallbackReason: reason,
});

class GroqIntentClient {
  isConfigured(): boolean {
    return GROQ_API_KEYS.length > 0;
  }

  /**
   * Maps a spoken/transcribed target to one of the saved destination labels
   * (synonyms, misrecognitions, singular/plural). Returns the chosen label
   * verbatim from `candidates`, or null when nothing plausibly matches or
   * the request fails — grounding is always best-effort.
   */
  async resolveTargetLabel(target: string, candidates: string[]): Promise<string | null> {
    const trimmed = target?.trim();
    if (!trimmed || !candidates.length || !this.isConfigured()) return null;
    const key = nextKey();
    if (!key) return null;

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    try {
      const res = await fetch(GROQ_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${key}`,
        },
        body: JSON.stringify({
          model: GROQ_INTENT_MODEL,
          temperature: 0,
          max_tokens: 60,
          response_format: { type: 'json_object' },
          messages: [
            {
              role: 'system',
              content:
                'You match a possibly misheard shopping destination to a saved label. ' +
                'Pick the label the user most plausibly meant (synonym, plural/singular, or speech-recognition slip). ' +
                'Return ONLY {"label": "<one of the provided labels>"} or {"label": null} if none plausibly match.',
            },
            {
              role: 'user',
              content: `Requested: "${trimmed}"\nSaved labels: ${JSON.stringify(candidates)}`,
            },
          ],
        }),
        signal: controller.signal,
      });
      clearTimeout(timer);
      if (!res.ok) return null;

      const data = await res.json();
      const parsed = extractJson(data?.choices?.[0]?.message?.content);
      const label = typeof parsed?.label === 'string' ? parsed.label.trim() : null;
      if (!label) return null;
      // Only trust labels that are actually in the candidate list.
      return candidates.find(c => c.toLowerCase() === label.toLowerCase()) ?? null;
    } catch {
      clearTimeout(timer);
      return null;
    }
  }

  async classifyIntent(input: { text: string; hasImage?: boolean }): Promise<LocalLLMResult<IntentClassification>> {
    const text = input.text?.trim();
    if (!text) return unconfigured('empty_text');
    if (!this.isConfigured()) return unconfigured('groq_not_configured');

    // One retry on 429 with a rotated key.
    for (let attempt = 0; attempt < Math.min(2, GROQ_API_KEYS.length + 1); attempt += 1) {
      const key = nextKey();
      if (!key) return unconfigured('groq_no_key');

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
      try {
        const res = await fetch(GROQ_URL, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${key}`,
          },
          body: JSON.stringify({
            model: GROQ_INTENT_MODEL,
            temperature: 0,
            max_tokens: 120,
            response_format: { type: 'json_object' },
            messages: [
              { role: 'system', content: SYSTEM_PROMPT },
              {
                role: 'user',
                content: `Utterance: "${text}"\nHas camera image available: ${input.hasImage ? 'yes' : 'no'}`,
              },
            ],
          }),
          signal: controller.signal,
        });
        clearTimeout(timer);

        if (res.status === 429) {
          // rotate key and retry once
          continue;
        }
        if (!res.ok) {
          return {
            available: false,
            usedProvider: 'none',
            confidence: 0,
            needsBackend: true,
            fallbackReason: `groq_http_${res.status}`,
          };
        }

        const data = await res.json();
        const content: string | undefined = data?.choices?.[0]?.message?.content;
        const parsed = extractJson(content);
        const intent = parsed?.intent as IntentClassification['intent'] | undefined;

        const validIntents: IntentClassification['intent'][] = [
          'reaching',
          'navigation',
          'scene',
          'chat',
          'stop',
          'unknown',
        ];
        if (!intent || !validIntents.includes(intent)) {
          return {
            available: false,
            usedProvider: 'none',
            confidence: 0,
            needsBackend: true,
            fallbackReason: 'groq_unparseable_intent',
          };
        }

        const confidence = clamp01(parsed?.confidence, 0.7);
        const json: IntentClassification = {
          intent,
          target: normalizeTarget(parsed?.target),
          needsImage: parsed?.needsImage === true || intent === 'scene' || intent === 'chat',
          confidence,
        };

        return {
          available: true,
          usedProvider: 'groq',
          confidence,
          // scene/chat need vision; handled on-device by GroqVisionClient.
          needsBackend: json.intent === 'scene' || json.intent === 'chat',
          json,
          rawText: content,
        };
      } catch (error: any) {
        clearTimeout(timer);
        const aborted = error?.name === 'AbortError';
        // On timeout/network error, degrade to fallback (do not throw).
        if (attempt >= 1) {
          return {
            available: false,
            usedProvider: 'none',
            confidence: 0,
            needsBackend: true,
            fallbackReason: aborted ? 'groq_timeout' : `groq_error:${error?.message || 'unknown'}`,
          };
        }
      }
    }

    return unconfigured('groq_exhausted');
  }
}

export const groqIntentClient = new GroqIntentClient();