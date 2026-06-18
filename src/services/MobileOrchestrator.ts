import AsyncStorage from '@react-native-async-storage/async-storage';
import { Platform } from 'react-native';
import { NAVIGATION_CONFIG } from '../utils/constants';
import {
  ProviderResult,
  ProviderTraceEntry,
  WorkflowRequest,
  WorkflowResponse,
} from '../utils/types';
import { LocalLLMNativeResult, OnDeviceLLMBridge } from '../native/OnDeviceLLMModule';
import { IntentClassification, LocalLLMResult, llmRouter } from './LLMRouter';

type SessionMode = 'default' | 'navigation' | 'reaching' | 'reaching_ios';

export interface MobileSessionMemory {
  sessionId: string;
  mode: SessionMode;
  navigation: boolean;
  reachingFlag: boolean;
  reachingIos: boolean;
  iterationCount: number;
  lastIntent?: IntentClassification;
  lastIntentProvider?: string;
  imageMetadata?: {
    uri: string;
    width?: number;
    height?: number;
    updatedAt: number;
  };
  lastObject?: string;
  lastResponseSummary?: {
    navigation: boolean;
    reachingFlag: boolean;
    reachingIos: boolean;
    object?: string;
    provider?: string;
    updatedAt: number;
  };
  sessionStart: boolean;
  updatedAt: number;
}

export interface MobileOrchestratorProcessOptions {
  backendWorkflowProvider: (
    request: WorkflowRequest,
    signal?: AbortSignal,
  ) => Promise<WorkflowResponse>;
  getSessionId: () => string;
}

const STORAGE_PREFIX = '@shelfscout/mobile_orchestrator/session:';
const APPLE_AVAILABILITY_CACHE_MS = 60 * 1000;

const isContinuousRequest = (request: WorkflowRequest): boolean =>
  request.navigation === true ||
  request.reaching_flag === true ||
  request.reaching_ios === true;

const requestMode = (request: WorkflowRequest): SessionMode => {
  if (request.reaching_ios === true) return 'reaching_ios';
  if (request.reaching_flag === true) return 'reaching';
  if (request.navigation === true) return 'navigation';
  return 'default';
};

const providerTrace = <T>(result: ProviderResult<T>): ProviderTraceEntry => ({
  provider: result.provider,
  ok: result.ok,
  confidence: result.confidence,
  needsRemote: result.needsRemote,
  fallbackReason: result.fallbackReason,
  diagnostics: result.diagnostics,
});

const unavailableAppleResult = (reason: string): LocalLLMNativeResult => ({
  available: false,
  usedProvider: 'none',
  confidence: 0,
  needsBackend: true,
  fallbackReason: reason,
  appleFmAvailable: false,
  appleFmUnavailableReason: reason,
});

class MobileOrchestrator {
  private appleAvailabilityCache?: {
    checkedAt: number;
    result: LocalLLMNativeResult;
  };

  async process(
    request: WorkflowRequest,
    signal: AbortSignal | undefined,
    options: MobileOrchestratorProcessOptions,
  ): Promise<WorkflowResponse> {
    if (signal?.aborted) {
      throw new Error('Request cancelled');
    }

    const sessionId = options.getSessionId();
    const trace: ProviderTraceEntry[] = [];
    const memory = await this.loadMemory(sessionId);
    const continuous = isContinuousRequest(request);
    const appleAvailability = await this.getAppleAvailability();
    const appleUnavailableReason = appleAvailability.available
      ? undefined
      : appleAvailability.appleFmUnavailableReason ||
      appleAvailability.fallbackReason ||
      'foundation_models_unavailable';

    trace.push({
      provider: 'apple_foundation_models',
      ok: appleAvailability.available,
      confidence: appleAvailability.confidence,
      needsRemote: !appleAvailability.available,
      fallbackReason: appleUnavailableReason,
    });

    const localIntent = request.text?.trim()
      ? await this.classifyIntent(request, trace)
      : null;

    const nextMemory = await this.persistRequestState(
      memory,
      request,
      localIntent,
      sessionId,
      continuous,
    );

    const localNavigation = this.localNavigationProvider(
      request,
      localIntent,
      continuous,
      sessionId,
      appleAvailability,
      trace,
    );
    trace.push(providerTrace(localNavigation));

    if (localNavigation.ok && localNavigation.data) {
      await this.persistResponseSummary(
        nextMemory,
        localNavigation.data,
        localNavigation.provider,
      );
      return localNavigation.data;
    }

    const remoteProvider = this.remoteProviderName(request, localIntent);
    trace.push({
      provider: remoteProvider,
      ok: true,
      confidence: localIntent?.confidence ?? 0,
      needsRemote: true,
      diagnostics: { delegatedTo: 'backend_workflow' },
    });

    const backendRequest = this.withObservability(
      request,
      localIntent,
      appleAvailability,
      trace,
    );

    try {
      const backendResponse = await options.backendWorkflowProvider(backendRequest, signal);
      trace.push({
        provider: 'backend_workflow',
        ok: true,
        confidence: backendResponse.confidence,
        needsRemote: true,
      });

      const decorated = this.decorateResponse(
        backendResponse,
        sessionId,
        localIntent,
        appleAvailability,
        trace,
      );
      await this.persistResponseSummary(nextMemory, decorated, 'backend_workflow');
      return decorated;
    } catch (error: any) {
      trace.push({
        provider: 'backend_workflow',
        ok: false,
        confidence: 0,
        needsRemote: true,
        fallbackReason: error?.message || String(error),
      });
      await this.persistMemory({
        ...nextMemory,
        lastResponseSummary: {
          navigation: false,
          reachingFlag: false,
          reachingIos: false,
          provider: 'backend_workflow',
          updatedAt: Date.now(),
        },
      });
      throw error;
    }
  }

  async resetSession(sessionId: string): Promise<void> {
    await this.persistMemory(this.defaultMemory(sessionId));
  }

  private async classifyIntent(
    request: WorkflowRequest,
    trace: ProviderTraceEntry[],
  ): Promise<LocalLLMResult<IntentClassification>> {
    try {
      const result = await llmRouter.classifyIntent({
        text: request.text,
        hasImage: Boolean(request.imageUri),
      });
      trace.push({
        provider: result.usedProvider,
        ok: Boolean(result.json?.intent),
        confidence: result.confidence,
        needsRemote: result.needsBackend,
        fallbackReason: result.fallbackReason,
        diagnostics: {
          intent: result.json?.intent,
          target: result.json?.target,
          needsImage: result.json?.needsImage,
        },
      });
      return result;
    } catch (error: any) {
      trace.push({
        provider: 'heuristic',
        ok: false,
        confidence: 0,
        needsRemote: true,
        fallbackReason: error?.message || String(error),
      });
      return {
        available: false,
        usedProvider: 'none',
        confidence: 0,
        needsBackend: true,
        fallbackReason: error?.message || String(error),
      };
    }
  }

  private localNavigationProvider(
    request: WorkflowRequest,
    localIntent: LocalLLMResult<IntentClassification> | null,
    continuous: boolean,
    sessionId: string,
    appleAvailability: LocalLLMNativeResult,
    trace: ProviderTraceEntry[],
  ): ProviderResult<WorkflowResponse> {
    const target = localIntent?.json?.target?.trim();
    const canStart =
      Platform.OS === 'ios' &&
      !request.imageUri &&
      !continuous &&
      localIntent?.json?.intent === 'navigation' &&
      Boolean(target) &&
      !localIntent.needsBackend &&
      localIntent.confidence >= 0.76;

    if (!canStart || !target) {
      return {
        ok: false,
        provider: 'local_navigation',
        confidence: localIntent?.confidence ?? 0,
        needsRemote: true,
        fallbackReason: this.localNavigationFallbackReason(request, localIntent, continuous),
      };
    }

    const localLlmUsed = localIntent.usedProvider === 'apple_foundation_models';
    const appleUnavailableReason = appleAvailability.available
      ? undefined
      : appleAvailability.appleFmUnavailableReason ||
      appleAvailability.fallbackReason ||
      'foundation_models_unavailable';

    return {
      ok: true,
      provider: 'local_navigation',
      confidence: localIntent.confidence,
      needsRemote: false,
      data: {
        text: '',
        navigation: true,
        navigation_ios: true,
        navigation_arkit: true,
        navigation_pipeline: 'arkit',
        navigation_target: target,
        reaching_flag: false,
        reaching_ios: false,
        loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
        session_id: sessionId,
        local_orchestrator_used: true,
        local_llm_used: localLlmUsed,
        llm_provider: localIntent.usedProvider,
        llm_fallback_reason: localIntent.fallbackReason || appleUnavailableReason,
        intent_provider: localIntent.usedProvider,
        apple_fm_available: appleAvailability.available,
        apple_fm_unavailable_reason: appleUnavailableReason,
        provider_trace: trace,
      },
    };
  }

  private localNavigationFallbackReason(
    request: WorkflowRequest,
    localIntent: LocalLLMResult<IntentClassification> | null,
    continuous: boolean,
  ): string {
    if (Platform.OS !== 'ios') return 'local_navigation_ios_only';
    if (request.imageUri) return 'image_request_requires_vision_provider';
    if (continuous) return 'continuous_request_requires_existing_backend_loop';
    if (!localIntent?.json?.intent) return 'intent_unavailable';
    if (localIntent.json.intent !== 'navigation') return 'intent_requires_remote_provider';
    if (!localIntent.json.target) return 'navigation_target_missing';
    if (localIntent.needsBackend) return localIntent.fallbackReason || 'intent_needs_backend';
    if (localIntent.confidence < 0.76) return 'low_confidence_navigation_intent';
    return 'local_navigation_unavailable';
  }

  private remoteProviderName(
    request: WorkflowRequest,
    localIntent: LocalLLMResult<IntentClassification> | null,
  ): string {
    if (
      request.imageUri ||
      localIntent?.json?.needsImage === true ||
      localIntent?.json?.intent === 'scene' ||
      localIntent?.json?.intent === 'reaching' ||
      request.reaching_flag === true ||
      request.reaching_ios === true
    ) {
      return 'vision_object_backend';
    }
    return 'backend_workflow';
  }

  private withObservability(
    request: WorkflowRequest,
    localIntent: LocalLLMResult<IntentClassification> | null,
    appleAvailability: LocalLLMNativeResult,
    trace: ProviderTraceEntry[],
  ): WorkflowRequest {
    const localLlmUsed = localIntent?.usedProvider === 'apple_foundation_models';
    const appleUnavailableReason = appleAvailability.available
      ? undefined
      : appleAvailability.appleFmUnavailableReason ||
      appleAvailability.fallbackReason ||
      'foundation_models_unavailable';

    return {
      ...request,
      local_orchestrator_used: true,
      local_llm_used: localLlmUsed,
      llm_provider: localIntent?.usedProvider || request.llm_provider,
      llm_fallback_reason: localIntent?.fallbackReason || appleUnavailableReason,
      intent_provider: localIntent?.usedProvider || request.intent_provider,
      local_intent_json: localIntent?.json,
      apple_fm_available: appleAvailability.available,
      apple_fm_unavailable_reason: appleUnavailableReason,
      provider_trace: trace,
    };
  }

  private decorateResponse(
    response: WorkflowResponse,
    sessionId: string,
    localIntent: LocalLLMResult<IntentClassification> | null,
    appleAvailability: LocalLLMNativeResult,
    trace: ProviderTraceEntry[],
  ): WorkflowResponse {
    const localLlmUsed = localIntent?.usedProvider === 'apple_foundation_models';
    const appleUnavailableReason = appleAvailability.available
      ? undefined
      : appleAvailability.appleFmUnavailableReason ||
      appleAvailability.fallbackReason ||
      'foundation_models_unavailable';

    return {
      ...response,
      session_id: response.session_id || sessionId,
      local_orchestrator_used: true,
      local_llm_used: localLlmUsed,
      llm_provider: response.llm_provider || localIntent?.usedProvider,
      llm_fallback_reason:
        response.llm_fallback_reason || localIntent?.fallbackReason || appleUnavailableReason,
      intent_provider: response.intent_provider || localIntent?.usedProvider,
      provider_trace: trace,
      apple_fm_available: appleAvailability.available,
      apple_fm_unavailable_reason: appleUnavailableReason,
    };
  }

  private async getAppleAvailability(): Promise<LocalLLMNativeResult> {
    if (Platform.OS !== 'ios') {
      return unavailableAppleResult('on_device_llm_ios_only');
    }

    const now = Date.now();
    if (
      this.appleAvailabilityCache &&
      now - this.appleAvailabilityCache.checkedAt < APPLE_AVAILABILITY_CACHE_MS
    ) {
      return this.appleAvailabilityCache.result;
    }

    try {
      const result = await OnDeviceLLMBridge.isAvailable();
      this.appleAvailabilityCache = { checkedAt: now, result };
      return result;
    } catch (error: any) {
      const result = unavailableAppleResult(error?.message || 'foundation_models_unavailable');
      this.appleAvailabilityCache = { checkedAt: now, result };
      return result;
    }
  }

  private async persistRequestState(
    memory: MobileSessionMemory,
    request: WorkflowRequest,
    localIntent: LocalLLMResult<IntentClassification> | null,
    sessionId: string,
    continuous: boolean,
  ): Promise<MobileSessionMemory> {
    const next: MobileSessionMemory = {
      ...memory,
      sessionId,
      mode: requestMode(request),
      navigation: request.navigation === true,
      reachingFlag: request.reaching_flag === true,
      reachingIos: request.reaching_ios === true,
      iterationCount: continuous ? memory.iterationCount + 1 : 0,
      lastIntent: localIntent?.json || memory.lastIntent,
      lastIntentProvider: localIntent?.usedProvider || memory.lastIntentProvider,
      imageMetadata: request.imageUri
        ? {
          uri: request.imageUri,
          width: request.imageWidth,
          height: request.imageHeight,
          updatedAt: Date.now(),
        }
        : memory.imageMetadata,
      sessionStart: false,
      updatedAt: Date.now(),
    };
    await this.persistMemory(next);
    return next;
  }

  private async persistResponseSummary(
    memory: MobileSessionMemory,
    response: WorkflowResponse,
    provider: string,
  ): Promise<void> {
    await this.persistMemory({
      ...memory,
      lastObject: response.object || memory.lastObject,
      lastResponseSummary: {
        navigation: response.navigation,
        reachingFlag: response.reaching_flag,
        reachingIos: response.reaching_ios,
        object: response.object,
        provider,
        updatedAt: Date.now(),
      },
      updatedAt: Date.now(),
    });
  }

  private async loadMemory(sessionId: string): Promise<MobileSessionMemory> {
    try {
      const raw = await AsyncStorage.getItem(this.storageKey(sessionId));
      if (!raw) return this.defaultMemory(sessionId);
      const parsed = JSON.parse(raw);
      return {
        ...this.defaultMemory(sessionId),
        ...parsed,
        sessionId,
      };
    } catch (error) {
      console.warn('[MobileOrchestrator] Failed to read session memory:', error);
      return this.defaultMemory(sessionId);
    }
  }

  private async persistMemory(memory: MobileSessionMemory): Promise<void> {
    try {
      await AsyncStorage.setItem(
        this.storageKey(memory.sessionId),
        JSON.stringify(memory),
      );
    } catch (error) {
      console.warn('[MobileOrchestrator] Failed to persist session memory:', error);
    }
  }

  private defaultMemory(sessionId: string): MobileSessionMemory {
    return {
      sessionId,
      mode: 'default',
      navigation: false,
      reachingFlag: false,
      reachingIos: false,
      iterationCount: 0,
      sessionStart: true,
      updatedAt: Date.now(),
    };
  }

  private storageKey(sessionId: string): string {
    return `${STORAGE_PREFIX}${sessionId}`;
  }
}

export const mobileOrchestrator = new MobileOrchestrator();
