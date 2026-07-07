// src/services/GroqVisionClient.ts
//
// On-device vision orchestration via Groq — the frontend equivalent of the
// backend Scene / Object / Chat vision nodes, now with EXACT two-pass parity:
//
//   Pass 1 (vision):     llama-4-scout returns structured JSON, using the same
//                        system/user prompts as the backend Config nodes plus
//                        the user's profile traits.
//   Pass 2 (synthesize): a fast text model turns that JSON into a short spoken
//                        answer, styled by trait_comm_style — mirroring the
//                        backend "Synthesize result" node.
//
// Before Pass 1 the captured frame is DOWNSCALED via the native
// ImageOrientationFixer (max 768px, q0.7) so the base64 upload is small and
// fast. If the resizer is unavailable we fall back to the full frame.
//
// Profile traits are copied from the backend Profile/Style/Mode nodes and are
// tunable here (or via optional exports in groq.secrets.ts).

import { NativeModules, Platform } from 'react-native';
import RNFS from 'react-native-fs';

let GROQ_API_KEYS: string[] = [];
let GROQ_VISION_MODEL = 'meta-llama/llama-4-scout-17b-16e-instruct';
let GROQ_TEXT_MODEL = 'llama-3.3-70b-versatile';
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const secrets = require('../config/groq.secrets');
  GROQ_API_KEYS = Array.isArray(secrets.GROQ_API_KEYS) ? secrets.GROQ_API_KEYS : [];
  if (typeof secrets.GROQ_VISION_MODEL === 'string') GROQ_VISION_MODEL = secrets.GROQ_VISION_MODEL;
  if (typeof secrets.GROQ_INTENT_MODEL === 'string') GROQ_TEXT_MODEL = secrets.GROQ_INTENT_MODEL;
} catch {
  // groq.secrets.ts absent — client reports unconfigured; caller degrades.
}

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
const VISION_TIMEOUT_MS = 20000;
const SYNTH_TIMEOUT_MS = 8000;

// Downscale target for the vision upload. 768px is plenty for scene/object
// description and cuts a ~1152x2048 (~600KB) frame to well under ~150KB.
const VISION_MAX_DIM = 768;
const VISION_JPEG_QUALITY = 0.7;

// ── Profile traits (backend Profile/Style/Mode defaults; tunable) ───────────
const TRAIT_VISION_PROFILE =
  'The user is completely blind. Avoid visual references like colors or lighting unless they impact safety. Emphasize tactile details (texture, shape, size) and auditory cues.';
const TRAIT_COMM_STYLE =
  'Respond in a direct, efficient manner. Keep answers short and focused to key relevant information.';
const TRAIT_NAV_MODE =
  'Provide cautious, descriptive guidance. actively warn about potential hazards (flimsy shelves, edges) and describe the layout broadly.';

// ── Backend Config prompts (verbatim intent) ────────────────────────────────
const SYS_SCENE = `${TRAIT_VISION_PROFILE}

You are a vision assistant analyzing an environment. Focus on extracting navigable space, major obstacles, and layout data.

Output Format:
Return a JSON object with exactly these keys:
- "layout_data": List visible pathways, aisles, or open spaces with approximate dimensions if possible.
- "hazard_data": List immediate hazards (boxes on floor, people, poles) with location.
- "environment_summary": A dense, factual summary of the room's content.`;

const USR_SCENE =
  "You are helping a blind shopper understand their environment. Your job is to describe the user's immediate surroundings using only information that is clearly visible in the image. Guidelines: - Only describe areas and articles if they are definitely visible. - State the approximate position: left, right, front, behind etc., of the areas/products you described. - Estimate distance in steps or meters (e.g., 'The shelf is about 3 meters ahead'). - Mention any visible obstructions or people nearby. - If you are unsure about part of the scene, say so clearly. - Keep explanations simple, concise, and actionable for someone who cannot see.";

const SYS_CHAT = `${TRAIT_VISION_PROFILE}

You are a precise vision assistant. Your goal is to answer the user's question based strictly on visual evidence from the image.

Output Format:
Return a JSON object with exactly these keys:
- "visual_reasoning": A short internal thought checking if the user's question can be answered by the image. If not, state why.
- "pointers": A brief response to the user's question, looking at image if needed.
- "visual_data": A detailed, objective description of the visual elements relevant to the question.`;

const USR_CHAT = (transcript: string) =>
  `You are a virtual AI assistant for a blind or low-vision user. Your responses must always be clear, concise, verbally accessible, and helpful. Avoid descriptions about irrelevant details like lighting, scene colors, layouts, etc., unless directly necessary to answer the user's question.\n\nAnswer this question by the user: "${transcript}".`;

const SYS_SYNTHESIZE = `${TRAIT_COMM_STYLE}

You are a helpful assistant for a blind user. Your goal is to synthesize the provided technical data into a helpful, natural spoken response.

TASK:
1. Interpret the JSON data.
2. Formulate a response that adheres to the User's Profile: ${TRAIT_VISION_PROFILE}
3. Adjust your tone and length according to: ${TRAIT_COMM_STYLE}

RULES:
- Only summarize the given input in a clear and understandable manner. Do not add unspecified content.
- Use natural spoken language. No JSON or technical jargon in the output.
- Keep responses brief and concise.`;

const USR_SYNTHESIZE = (content: string) => `VISUAL INFORMATION:\n${content}\nNow Begin!`;

export interface GroqVisionResult {
  ok: boolean;
  text?: string;
  provider: 'groq_vision' | 'none';
  fallbackReason?: string;
  twoPass?: boolean;
}

let keyCursor = 0;
const nextKey = (): string | null => {
  if (GROQ_API_KEYS.length === 0) return null;
  const key = GROQ_API_KEYS[keyCursor % GROQ_API_KEYS.length];
  keyCursor += 1;
  return key;
};

const stripFileScheme = (uri: string): string =>
  uri.startsWith('file://') ? uri.replace('file://', '') : uri;

const guessMime = (path: string): string => {
  const lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
};

const extractJson = (text?: string): string | null => {
  if (!text) return null;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return text.trim() || null;
  return text.slice(start, end + 1);
};

class GroqVisionClient {
  isConfigured(): boolean {
    return GROQ_API_KEYS.length > 0;
  }

  /**
   * Downscale the captured frame for a small/fast upload, then read as a
   * base64 data URL. Reuses the native ImageOrientationFixer resizer (already
   * shipped); falls back to the full-size original if resizing is unavailable.
   */
  private async toDataUrl(imageUri: string): Promise<string | null> {
    let path = stripFileScheme(imageUri);
    try {
      const fixer = (NativeModules as any).ImageOrientationFixer;
      if (Platform.OS === 'ios' && fixer?.fixOrientation) {
        const resized = await fixer.fixOrientation(imageUri, VISION_MAX_DIM, VISION_JPEG_QUALITY);
        if (resized?.path || resized?.uri) {
          path = stripFileScheme(resized.path || resized.uri);
        }
      }
    } catch (error: any) {
      console.warn('[GroqVision] Downscale failed, using full frame:', error?.message || error);
      path = stripFileScheme(imageUri);
    }

    try {
      const base64 = await RNFS.readFile(path, 'base64');
      if (!base64) return null;
      return `data:${guessMime(path)};base64,${base64}`;
    } catch (error: any) {
      console.warn('[GroqVision] Image read failed:', error?.message || error);
      return null;
    }
  }

  async describeScene(imageUri: string, transcript?: string): Promise<GroqVisionResult> {
    const userText = (transcript && transcript.trim()) || USR_SCENE;
    return this.twoPass(SYS_SCENE, userText, imageUri);
  }

  async answerQuestion(imageUri: string, transcript: string): Promise<GroqVisionResult> {
    return this.twoPass(SYS_CHAT, USR_CHAT(transcript.trim()), imageUri);
  }

  // Pass 1: vision → structured JSON. Pass 2: JSON → spoken text.
  private async twoPass(
    visionSystem: string,
    visionUserText: string,
    imageUri: string,
  ): Promise<GroqVisionResult> {
    if (!this.isConfigured()) return { ok: false, provider: 'none', fallbackReason: 'groq_not_configured' };
    if (!imageUri) return { ok: false, provider: 'none', fallbackReason: 'no_image' };

    const dataUrl = await this.toDataUrl(imageUri);
    if (!dataUrl) return { ok: false, provider: 'none', fallbackReason: 'image_read_failed' };

    // ── Pass 1: vision ──
    const vision = await this.post(
      GROQ_VISION_MODEL,
      [
        { role: 'system', content: visionSystem },
        {
          role: 'user',
          content: [
            { type: 'text', text: visionUserText },
            { type: 'image_url', image_url: { url: dataUrl } },
          ],
        },
      ],
      { jsonMode: true, timeout: VISION_TIMEOUT_MS, maxTokens: 400 },
    );
    if (!vision.ok || !vision.text) {
      return { ok: false, provider: 'none', fallbackReason: vision.fallbackReason || 'vision_failed' };
    }

    const structured = extractJson(vision.text) || vision.text;

    // ── Pass 2: synthesize to speech ──
    const synth = await this.post(
      GROQ_TEXT_MODEL,
      [
        { role: 'system', content: SYS_SYNTHESIZE },
        { role: 'user', content: USR_SYNTHESIZE(structured) },
      ],
      { jsonMode: false, timeout: SYNTH_TIMEOUT_MS, maxTokens: 200 },
    );

    // If synthesize fails, fall back to a best-effort read of the structured JSON.
    if (!synth.ok || !synth.text) {
      const fallback = this.flattenStructured(structured);
      if (fallback) return { ok: true, provider: 'groq_vision', text: fallback, twoPass: false };
      return { ok: false, provider: 'none', fallbackReason: synth.fallbackReason || 'synthesize_failed' };
    }

    return { ok: true, provider: 'groq_vision', text: synth.text.trim(), twoPass: true };
  }

  // Best-effort spoken fallback if the synthesize pass fails.
  private flattenStructured(jsonText: string): string | null {
    try {
      const o = JSON.parse(jsonText);
      const parts = [
        o.pointers,
        o.environment_summary,
        o.visual_data,
        Array.isArray(o.hazard_data) ? o.hazard_data.join('. ') : o.hazard_data,
      ].filter((v) => typeof v === 'string' && v.trim());
      return parts.length ? parts.join(' ') : null;
    } catch {
      return jsonText && jsonText.length < 600 ? jsonText : null;
    }
  }

  private async post(
    model: string,
    messages: unknown[],
    opts: { jsonMode: boolean; timeout: number; maxTokens: number },
  ): Promise<{ ok: boolean; text?: string; fallbackReason?: string }> {
    for (let attempt = 0; attempt < Math.min(2, GROQ_API_KEYS.length + 1); attempt += 1) {
      const key = nextKey();
      if (!key) return { ok: false, fallbackReason: 'groq_no_key' };

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), opts.timeout);
      try {
        const res = await fetch(GROQ_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
          body: JSON.stringify({
            model,
            temperature: 0.2,
            max_tokens: opts.maxTokens,
            ...(opts.jsonMode ? { response_format: { type: 'json_object' } } : {}),
            messages,
          }),
          signal: controller.signal,
        });
        clearTimeout(timer);
        if (res.status === 429) continue;
        if (!res.ok) return { ok: false, fallbackReason: `groq_http_${res.status}` };
        const data = await res.json();
        const content: string | undefined = data?.choices?.[0]?.message?.content;
        const text = typeof content === 'string' ? content.trim() : '';
        if (!text) return { ok: false, fallbackReason: 'groq_empty_content' };
        return { ok: true, text };
      } catch (error: any) {
        clearTimeout(timer);
        const aborted = error?.name === 'AbortError';
        if (attempt >= 1) {
          return { ok: false, fallbackReason: aborted ? 'groq_timeout' : `groq_error:${error?.message || 'unknown'}` };
        }
      }
    }
    return { ok: false, fallbackReason: 'groq_exhausted' };
  }
}

export const groqVisionClient = new GroqVisionClient();