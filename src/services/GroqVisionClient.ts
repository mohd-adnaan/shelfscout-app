// src/services/GroqVisionClient.ts
//
// On-device vision orchestration via Groq (llama-4-scout multimodal) — the
// frontend equivalent of the backend's Scene / Object / Chat vision nodes.
//
// The backend runs a two-pass pattern (vision model returns structured JSON →
// a second "synthesize" LLM turns it into speech). On-device we collapse that
// into ONE call that returns brief spoken text directly: same user-facing
// content, roughly half the latency, and no dependency on the Redis-stored
// profile/comm-style traits. If exact backend fidelity (structured JSON +
// separate synthesize pass + profile traits) is ever needed, this is the file
// to split.
//
// Prompts are adapted from the backend Config nodes (sys_scene / usr_scene,
// sys_chat / usr_chat) but instructed to answer in plain spoken sentences.

import RNFS from 'react-native-fs';

let GROQ_API_KEYS: string[] = [];
let GROQ_VISION_MODEL = 'meta-llama/llama-4-scout-17b-16e-instruct';
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const secrets = require('../config/groq.secrets');
  GROQ_API_KEYS = Array.isArray(secrets.GROQ_API_KEYS) ? secrets.GROQ_API_KEYS : [];
  if (typeof secrets.GROQ_VISION_MODEL === 'string') {
    GROQ_VISION_MODEL = secrets.GROQ_VISION_MODEL;
  }
} catch {
  // groq.secrets.ts absent — client reports unconfigured; caller degrades.
}

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
const REQUEST_TIMEOUT_MS = 20000; // vision + base64 upload needs headroom

const SCENE_SYSTEM = `You are a vision assistant for a blind or low-vision shopper. Describe the user's immediate surroundings using only what is clearly visible in the image.
- State approximate positions (left, right, ahead, behind) for the areas and products you mention.
- Estimate distance in steps or meters (e.g. "about 3 meters ahead").
- Mention any visible obstacles or people nearby.
- If part of the scene is unclear, say so plainly.
Reply with 1 to 3 short spoken sentences. No JSON, no markdown, no bullet lists.`;

const CHAT_SYSTEM = `You are a vision assistant for a blind or low-vision user. Answer the user's question using visual evidence from the image.
Be clear, concise and spoken-friendly. Avoid irrelevant detail such as colours, lighting or layout unless it is needed to answer. If the image cannot answer the question, say so briefly.
Reply with 1 to 2 short spoken sentences. No JSON, no markdown.`;

let keyCursor = 0;
const nextKey = (): string | null => {
  if (GROQ_API_KEYS.length === 0) return null;
  const key = GROQ_API_KEYS[keyCursor % GROQ_API_KEYS.length];
  keyCursor += 1;
  return key;
};

export interface GroqVisionResult {
  ok: boolean;
  text?: string;
  provider: 'groq_vision' | 'none';
  fallbackReason?: string;
}

const stripFileScheme = (uri: string): string =>
  uri.startsWith('file://') ? uri.replace('file://', '') : uri;

const guessMime = (path: string): string => {
  const lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
};

class GroqVisionClient {
  isConfigured(): boolean {
    return GROQ_API_KEYS.length > 0;
  }

  /** Read an on-device image path into a base64 data URL for the Groq API. */
  private async toDataUrl(imageUri: string): Promise<string | null> {
    try {
      const path = stripFileScheme(imageUri);
      const base64 = await RNFS.readFile(path, 'base64');
      if (!base64) return null;
      return `data:${guessMime(path)};base64,${base64}`;
    } catch (error: any) {
      console.warn('[GroqVision] Failed to read image:', error?.message || error);
      return null;
    }
  }

  async describeScene(imageUri: string, transcript?: string): Promise<GroqVisionResult> {
    const userText =
      (transcript && transcript.trim()) ||
      'What is in front of me? Describe my immediate surroundings.';
    return this.visionCall(SCENE_SYSTEM, userText, imageUri);
  }

  async answerQuestion(imageUri: string, transcript: string): Promise<GroqVisionResult> {
    const userText = `Answer this question about the image: "${transcript.trim()}"`;
    return this.visionCall(CHAT_SYSTEM, userText, imageUri);
  }

  private async visionCall(
    system: string,
    userText: string,
    imageUri: string,
  ): Promise<GroqVisionResult> {
    if (!this.isConfigured()) {
      return { ok: false, provider: 'none', fallbackReason: 'groq_not_configured' };
    }
    if (!imageUri) {
      return { ok: false, provider: 'none', fallbackReason: 'no_image' };
    }

    const dataUrl = await this.toDataUrl(imageUri);
    if (!dataUrl) {
      return { ok: false, provider: 'none', fallbackReason: 'image_read_failed' };
    }

    for (let attempt = 0; attempt < Math.min(2, GROQ_API_KEYS.length + 1); attempt += 1) {
      const key = nextKey();
      if (!key) return { ok: false, provider: 'none', fallbackReason: 'groq_no_key' };

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
            model: GROQ_VISION_MODEL,
            temperature: 0.2,
            max_tokens: 320,
            messages: [
              { role: 'system', content: system },
              {
                role: 'user',
                content: [
                  { type: 'text', text: userText },
                  { type: 'image_url', image_url: { url: dataUrl } },
                ],
              },
            ],
          }),
          signal: controller.signal,
        });
        clearTimeout(timer);

        if (res.status === 429) continue; // rotate key + retry
        if (!res.ok) {
          return { ok: false, provider: 'none', fallbackReason: `groq_http_${res.status}` };
        }

        const data = await res.json();
        const content: string | undefined = data?.choices?.[0]?.message?.content;
        const text = typeof content === 'string' ? content.trim() : '';
        if (!text) {
          return { ok: false, provider: 'none', fallbackReason: 'groq_empty_content' };
        }
        return { ok: true, provider: 'groq_vision', text };
      } catch (error: any) {
        clearTimeout(timer);
        const aborted = error?.name === 'AbortError';
        if (attempt >= 1) {
          return {
            ok: false,
            provider: 'none',
            fallbackReason: aborted ? 'groq_timeout' : `groq_error:${error?.message || 'unknown'}`,
          };
        }
      }
    }

    return { ok: false, provider: 'none', fallbackReason: 'groq_exhausted' };
  }
}

export const groqVisionClient = new GroqVisionClient();