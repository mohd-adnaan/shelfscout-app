import { Platform } from 'react-native';
import { LocalLLMNativeResult, LocalLLMProvider, OnDeviceLLMBridge } from '../native/OnDeviceLLMModule';

export interface LocalLLMResult<T = unknown> {
  available: boolean;
  usedProvider: LocalLLMProvider;
  confidence: number;
  needsBackend: boolean;
  json?: T;
  rawText?: string;
  fallbackReason?: string;
}

export interface IntentClassification {
  intent: 'navigation' | 'reaching' | 'scene' | 'chat' | 'stop' | 'unknown';
  target: string | null;
  needsImage: boolean;
  confidence: number;
}

export interface TurnEndDecision {
  shouldAutoSubmit: boolean;
  confidence: number;
  reason: string;
}

export interface GuidanceRewrite {
  text: string;
  confidence: number;
}

const BACKEND_REQUIRED_INTENTS = new Set(['scene', 'reaching']);

function clampConfidence(value: unknown, fallback = 0.5): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? Math.max(0, Math.min(1, parsed)) : fallback;
}

function extractJsonObject(text?: string): string | null {
  if (!text) return null;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return null;
  return text.slice(start, end + 1);
}

function parseNativeJson<T>(result: LocalLLMNativeResult): T | undefined {
  const jsonText = result.json || extractJsonObject(result.rawText);
  if (!jsonText) return undefined;
  try {
    return JSON.parse(jsonText) as T;
  } catch {
    return undefined;
  }
}

function fromNative<T>(result: LocalLLMNativeResult, parsed?: T): LocalLLMResult<T> {
  return {
    available: result.available,
    usedProvider: result.usedProvider,
    confidence: clampConfidence(result.confidence, 0),
    needsBackend: result.needsBackend,
    json: parsed,
    rawText: result.rawText,
    fallbackReason: result.fallbackReason,
  };
}

function classifyIntentHeuristically(text: string, hasImage: boolean): LocalLLMResult<IntentClassification> {
  const normalized = text.trim().toLowerCase();
  const stopIntent = /\b(stop|cancel|emergency stop|pause)\b/.test(normalized);
  if (stopIntent) {
    const json: IntentClassification = {
      intent: 'stop',
      target: null,
      needsImage: false,
      confidence: 0.86,
    };
    return { available: true, usedProvider: 'heuristic', confidence: json.confidence, needsBackend: false, json };
  }

  const navigationMatch = normalized.match(/\b(?:take|guide|lead|walk|navigate|bring)\s+(?:me\s+)?to\s+(.+)$/);
  if (navigationMatch?.[1]) {
    const target = navigationMatch[1].replace(/[.?!]+$/g, '').trim();
    const json: IntentClassification = {
      intent: 'navigation',
      target: target || null,
      needsImage: false,
      confidence: target ? 0.78 : 0.55,
    };
    return {
      available: true,
      usedProvider: 'heuristic',
      confidence: json.confidence,
      needsBackend: hasImage || !target,
      json,
      fallbackReason: hasImage ? 'image_request_requires_backend' : undefined,
    };
  }

  const reaching = /\b(reach|grab|get|pick up|find)\b/.test(normalized);
  const json: IntentClassification = {
    intent: reaching ? 'reaching' : hasImage ? 'scene' : 'unknown',
    target: null,
    needsImage: hasImage || reaching,
    confidence: reaching ? 0.64 : 0.46,
  };
  return {
    available: true,
    usedProvider: 'heuristic',
    confidence: json.confidence,
    needsBackend: true,
    json,
    fallbackReason: BACKEND_REQUIRED_INTENTS.has(json.intent)
      ? 'vision_or_reaching_requires_backend'
      : 'low_confidence_intent',
  };
}

function localTurnEndHeuristic(
  transcript: string,
  silenceDurationMs: number,
  silenceThresholdMs: number,
): LocalLLMResult<TurnEndDecision> {
  const trimmed = transcript.trim();
  const looksIncomplete = /\b(and|or|to|the|a|an|for|with|near|at|turn)\s*$/i.test(trimmed);
  const enoughSilence = silenceDurationMs >= silenceThresholdMs;
  const shouldAutoSubmit = Boolean(trimmed) && enoughSilence && !looksIncomplete;
  const confidence = shouldAutoSubmit ? 0.76 : enoughSilence ? 0.58 : 0.34;
  const json: TurnEndDecision = {
    shouldAutoSubmit,
    confidence,
    reason: shouldAutoSubmit
      ? 'Local silence threshold met and transcript looks complete.'
      : looksIncomplete
        ? 'Transcript looks incomplete.'
        : 'Waiting for enough silence.',
  };
  return {
    available: true,
    usedProvider: 'heuristic',
    confidence,
    needsBackend: false,
    json,
  };
}

function numbersIn(text: string): Set<string> {
  return new Set((text.match(/\b\d+(?:\.\d+)?\b/g) || []).map((value) => String(Number(value))));
}

function containsUnapprovedNavigationFact(rewrite: string, source: string): boolean {
  const sourceLower = source.toLowerCase();
  const rewriteLower = rewrite.toLowerCase();
  const sourceNumbers = numbersIn(source);
  for (const number of numbersIn(rewrite)) {
    if (!sourceNumbers.has(number)) return true;
  }

  const directionalTerms = ['left', 'right', 'straight', 'forward', 'back', 'around', 'arrived'];
  return directionalTerms.some((term) => rewriteLower.includes(term) && !sourceLower.includes(term));
}

class LLMRouter {
  async classifyIntent(input: { text: string; hasImage?: boolean }): Promise<LocalLLMResult<IntentClassification>> {
    const text = input.text.trim();
    if (!text) {
      return {
        available: false,
        usedProvider: 'none',
        confidence: 0,
        needsBackend: true,
        fallbackReason: 'empty_text',
      };
    }

    if (Platform.OS === 'ios') {
      try {
        const native = await OnDeviceLLMBridge.classifyIntent({ text, hasImage: input.hasImage === true });
        const parsed = parseNativeJson<IntentClassification>(native);
        if (native.available && parsed?.intent) {
          const confidence = clampConfidence(parsed.confidence, native.confidence);
          const needsBackend = input.hasImage === true || BACKEND_REQUIRED_INTENTS.has(parsed.intent) || confidence < 0.70;
          return fromNative({ ...native, confidence, needsBackend }, { ...parsed, confidence });
        }
      } catch {
        // Fall through to deterministic local routing.
      }
    }

    return classifyIntentHeuristically(text, input.hasImage === true);
  }

  async detectTurnEnd(input: {
    transcript: string;
    silenceDurationMs: number;
    silenceThresholdMs: number;
  }): Promise<LocalLLMResult<TurnEndDecision>> {
    const transcript = input.transcript.trim();
    if (Platform.OS === 'ios' && transcript) {
      try {
        const native = await OnDeviceLLMBridge.detectTurnEnd(input);
        const parsed = parseNativeJson<TurnEndDecision>(native);
        if (native.available && typeof parsed?.shouldAutoSubmit === 'boolean') {
          const confidence = clampConfidence(parsed.confidence, native.confidence);
          return fromNative({ ...native, confidence, needsBackend: confidence < 0.55 }, { ...parsed, confidence });
        }
      } catch {
        // Fall through to deterministic local turn detection.
      }
    }

    return localTurnEndHeuristic(transcript, input.silenceDurationMs, input.silenceThresholdMs);
  }

  async rewriteGuidance(input: {
    instruction: string;
    routeStatus?: string;
    isInstructionSafe?: boolean;
  }): Promise<LocalLLMResult<GuidanceRewrite>> {
    const instruction = input.instruction.trim();
    if (!instruction) {
      return {
        available: false,
        usedProvider: 'none',
        confidence: 0,
        needsBackend: true,
        fallbackReason: 'empty_instruction',
      };
    }

    if (input.isInstructionSafe === false) {
      const text = input.routeStatus?.toLowerCase().includes('lost')
        ? 'Route uncertain. Pause and scan slowly.'
        : 'Pause and scan slowly.';
      return {
        available: true,
        usedProvider: 'heuristic',
        confidence: 0.92,
        needsBackend: false,
        json: { text, confidence: 0.92 },
      };
    }

    if (Platform.OS === 'ios') {
      try {
        const native = await OnDeviceLLMBridge.rewriteGuidance(input);
        const parsed = parseNativeJson<GuidanceRewrite>(native);
        const text = typeof parsed?.text === 'string' ? parsed.text.trim() : '';
        if (native.available && text && !containsUnapprovedNavigationFact(text, instruction)) {
          const confidence = clampConfidence(parsed?.confidence, native.confidence);
          return fromNative({ ...native, confidence, needsBackend: confidence < 0.65 }, { text, confidence });
        }
        if (text) {
          return {
            available: native.available,
            usedProvider: native.usedProvider,
            confidence: 0,
            needsBackend: false,
            json: { text: instruction, confidence: 1 },
            fallbackReason: 'local_guidance_hallucinated_navigation_fact',
          };
        }
      } catch {
        // Fall through to deterministic guidance.
      }
    }

    return {
      available: true,
      usedProvider: 'heuristic',
      confidence: 1,
      needsBackend: false,
      json: { text: instruction, confidence: 1 },
    };
  }
}

export const llmRouter = new LLMRouter();