import { NativeModules, Platform } from 'react-native';

export type LocalLLMProvider = 'apple_foundation_models' | 'heuristic' | 'none';

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

export const OnDeviceLLMBridge: NativeOnDeviceLLMModule =
  Platform.OS === 'ios' && nativeModule ? nativeModule : unavailable;
