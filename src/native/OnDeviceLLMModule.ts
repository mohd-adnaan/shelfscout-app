import { NativeModules, Platform } from 'react-native';
import { WATCHDOG_TIMEOUTS, nativeCall } from '../utils/asyncWatchdog';

// 'groq' is produced by GroqIntentClient, which resolves the same
// LocalLLMNativeResult shape as the native providers. Omitting it here made
// the `provider === 'groq'` checks in MobileOrchestrator look unreachable to
// the compiler even though they fire at runtime.
export type LocalLLMProvider =
  | 'apple_foundation_models'
  | 'groq'
  | 'heuristic'
  | 'none';

export interface LocalLLMNativeResult {
  available: boolean;
  usedProvider: LocalLLMProvider;
  confidence: number;
  needsBackend: boolean;
  json?: string;
  rawText?: string;
  fallbackReason?: string;
  appleFmAvailable?: boolean;
  appleFmUnavailableReason?: string;
}

interface NativeOnDeviceLLMModule {
  isAvailable(): Promise<LocalLLMNativeResult>;
  classifyIntent(payload: { text: string; hasImage?: boolean }): Promise<LocalLLMNativeResult>;
  detectTurnEnd(payload: {
    transcript: string;
    silenceDurationMs: number;
    silenceThresholdMs: number;
  }): Promise<LocalLLMNativeResult>;
  rewriteGuidance(payload: {
    instruction: string;
    routeStatus?: string;
    isInstructionSafe?: boolean;
  }): Promise<LocalLLMNativeResult>;
}

const nativeModule = NativeModules.OnDeviceLLMModule as NativeOnDeviceLLMModule | undefined;

const unavailable: NativeOnDeviceLLMModule = {
  async isAvailable() {
    return {
      available: false,
      usedProvider: 'none',
      confidence: 0,
      needsBackend: true,
      fallbackReason: Platform.OS === 'ios'
        ? 'on_device_llm_not_linked'
        : 'on_device_llm_ios_only',
      appleFmAvailable: false,
      appleFmUnavailableReason: Platform.OS === 'ios'
        ? 'on_device_llm_not_linked'
        : 'on_device_llm_ios_only',
    };
  },
  async classifyIntent() {
    return unavailable.isAvailable();
  },
  async detectTurnEnd() {
    return unavailable.isAvailable();
  },
  async rewriteGuidance() {
    return unavailable.isAvailable();
  },
};

/**
 * Timed-out result. `needsBackend: true` is the important part — a stalled
 * on-device model degrades to the backend/heuristic path exactly as an absent
 * one does, instead of stranding the caller.
 */
const timedOut = (method: string): LocalLLMNativeResult => ({
  available: false,
  usedProvider: 'none',
  confidence: 0,
  needsBackend: true,
  fallbackReason: `on_device_llm_timeout:${method}`,
  appleFmAvailable: false,
  appleFmUnavailableReason: `on_device_llm_timeout:${method}`,
});

/**
 * Every native call, bounded.
 *
 * Apple Foundation Models inference runs in another process and can stall —
 * on resource pressure, on a model unload, or on a guardrail evaluation that
 * never returns. The bridge promise then never settles. Because these calls
 * sit inside `handleVoiceCommand`, which holds `isProcessingRef` until its
 * `finally` runs, a single stalled inference used to take the whole app down
 * until it was force-quit: every later tap hit the "already processing" guard
 * and returned silently.
 *
 * Wrapping here rather than at each call site means no consumer can forget.
 */
const bounded = (native: NativeOnDeviceLLMModule): NativeOnDeviceLLMModule => ({
  isAvailable: () =>
    nativeCall(
      () => native.isAvailable(),
      WATCHDOG_TIMEOUTS.ON_DEVICE_LLM,
      'OnDeviceLLM.isAvailable',
      timedOut('isAvailable'),
    ),
  classifyIntent: payload =>
    nativeCall(
      () => native.classifyIntent(payload),
      WATCHDOG_TIMEOUTS.ON_DEVICE_LLM,
      'OnDeviceLLM.classifyIntent',
      timedOut('classifyIntent'),
    ),
  detectTurnEnd: payload =>
    nativeCall(
      () => native.detectTurnEnd(payload),
      WATCHDOG_TIMEOUTS.ON_DEVICE_LLM,
      'OnDeviceLLM.detectTurnEnd',
      timedOut('detectTurnEnd'),
    ),
  rewriteGuidance: payload =>
    nativeCall(
      () => native.rewriteGuidance(payload),
      WATCHDOG_TIMEOUTS.ON_DEVICE_LLM,
      'OnDeviceLLM.rewriteGuidance',
      timedOut('rewriteGuidance'),
    ),
});

export const OnDeviceLLMBridge: NativeOnDeviceLLMModule =
  Platform.OS === 'ios' && nativeModule ? bounded(nativeModule) : unavailable;
