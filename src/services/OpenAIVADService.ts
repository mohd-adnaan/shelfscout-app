// src/services/OpenAIVADService.ts
import { llmRouter } from './LLMRouter';

/**
 * OpenAI-backed end-of-utterance detector.
 *
 * Notes:
 * - This is used as a network VAD/turn-detector signal for auto-submit.
 * - If the key is missing or the network fails, callers should fallback
 *   to local silence detection to keep UX responsive.
 */

const OPENAI_API_URL = 'https://api.openai.com/v1/responses';
const OPENAI_MODEL = 'gpt-4o-mini';

let OPENAI_API_KEY = '';

try {
  // Intentionally optional so this repo can build even before local setup.
  const secrets = require('../config/openai.secrets') as { OPENAI_API_KEY?: string };
  const rawKey = typeof secrets?.OPENAI_API_KEY === 'string' ? secrets.OPENAI_API_KEY.trim() : '';
  if (rawKey && rawKey !== 'your_openAPI_key_here') {
    OPENAI_API_KEY = rawKey;
  }
} catch {
  // Missing local secrets file: caller will fallback to local logic.
}

export interface OpenAIVADRequest {
  transcript: string;
  silenceDurationMs: number;
  silenceThresholdMs: number;
}

export interface OpenAIVADResult {
  shouldAutoSubmit: boolean;
  confidence: number;
  reason: string;
}

function extractJsonObject(text: string): string | null {
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return null;
  return text.slice(start, end + 1);
}

class OpenAIVADService {
  isConfigured(): boolean {
    return OPENAI_API_KEY.length > 0;
  }

  async detectEndOfUtterance(input: OpenAIVADRequest): Promise<OpenAIVADResult> {
    const transcript = (input.transcript || '').trim();
    if (!transcript) {
      return {
        shouldAutoSubmit: false,
        confidence: 0,
        reason: 'Empty transcript',
      };
    }

    const localDecision = await llmRouter.detectTurnEnd({
      transcript,
      silenceDurationMs: input.silenceDurationMs,
      silenceThresholdMs: input.silenceThresholdMs,
    });

    if (!localDecision.needsBackend && localDecision.json) {
      return {
        shouldAutoSubmit: Boolean(localDecision.json.shouldAutoSubmit),
        confidence: localDecision.confidence,
        reason: `${localDecision.usedProvider}: ${localDecision.json.reason}`,
      };
    }

    if (!this.isConfigured()) {
      if (localDecision.json) {
        return {
          shouldAutoSubmit: Boolean(localDecision.json.shouldAutoSubmit),
          confidence: localDecision.confidence,
          reason: `${localDecision.usedProvider}: ${localDecision.json.reason}`,
        };
      }
      throw new Error('OpenAI API key not configured');
    }

    const body = {
      model: OPENAI_MODEL,
      temperature: 0,
      max_output_tokens: 120,
      input: [
        {
          role: 'system',
          content: [
            {
              type: 'input_text',
              text: [
                'You are a turn detector for a voice assistant.',
                'Decide if the user has finished speaking.',
                'Return strict JSON only with keys:',
                'shouldAutoSubmit (boolean), confidence (number 0..1), reason (string).',
                'Treat silence >= threshold as likely end of utterance unless transcript clearly looks incomplete.',
              ].join(' '),
            },
          ],
        },
        {
          role: 'user',
          content: [
            {
              type: 'input_text',
              text: JSON.stringify({
                transcript,
                silenceDurationMs: input.silenceDurationMs,
                silenceThresholdMs: input.silenceThresholdMs,
              }),
            },
          ],
        },
      ],
    };

    const response = await fetch(OPENAI_API_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${OPENAI_API_KEY}`,
      },
      body: JSON.stringify(body),
    });

    if (!response.ok) {
      const errText = await response.text();
      throw new Error(`OpenAI VAD request failed (${response.status}): ${errText}`);
    }

    const data = await response.json();

    const outputText: string =
      data?.output_text ||
      data?.output?.[0]?.content?.find((c: any) => c?.type === 'output_text')?.text ||
      '';

    const jsonChunk = extractJsonObject(outputText);
    if (!jsonChunk) {
      throw new Error(`Invalid OpenAI VAD response: ${outputText || 'empty response'}`);
    }

    const parsed = JSON.parse(jsonChunk);
    const shouldAutoSubmit = Boolean(parsed?.shouldAutoSubmit);
    const confidenceRaw = Number(parsed?.confidence);
    const confidence = Number.isFinite(confidenceRaw)
      ? Math.max(0, Math.min(1, confidenceRaw))
      : 0.5;

    return {
      shouldAutoSubmit,
      confidence,
      reason: typeof parsed?.reason === 'string' ? parsed.reason : 'No reason provided',
    };
  }
}

export const openAIVADService = new OpenAIVADService();
