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
import { orchestratorConfig } from './OrchestratorConfig';
import { groqIntentClient } from './GroqIntentClient';
import { groqVisionClient } from './GroqVisionClient';
import { AppLanguage, getAppLanguage, strings } from '../i18n';

type SessionMode = 'default' | 'navigation' | 'reaching' | 'reaching_ios';

/// Leading phrasings that unambiguously mean "guide me there". Ordered longest
/// first so "take me back to" is consumed before "take me to".
const EXPLICIT_NAVIGATION_PREFIXES = [
  'take me back to',
  'can you take me to',
  'please take me to',
  'i want to go to',
  'i need to get to',
  'take me to',
  'guide me to',
  'navigate me to',
  'navigate to',
  'lead me to',
  'walk me to',
  'bring me to',
  'go to',
];

/// Trailing filler that survives dictation ("take me to the bananas please").
const NAVIGATION_TRAILING_NOISE = /\s*(please|now|thanks|thank you)\s*$/i;

/**
 * Deterministic navigation-intent parser. Returns the destination when the
 * utterance is an explicit "take me to X" style command, otherwise null so the
 * LLM classifier keeps its normal role. Kept dependency-free and synchronous:
 * the whole point is that the app's primary command cannot fail because a model
 * call was slow, offline, or misclassified.
 */
export function parseExplicitNavigationCommand(
  rawText: string | undefined,
): { target: string } | null {
  const text = rawText?.trim().toLowerCase().replace(/[.!?]+$/, '');
  if (!text) return null;

  for (const prefix of EXPLICIT_NAVIGATION_PREFIXES) {
    if (!text.startsWith(`${prefix} `)) continue;
    let target = text.slice(prefix.length).trim();
    target = target.replace(NAVIGATION_TRAILING_NOISE, '').trim();
    // Strip a leading article: destinations are stored as "Bananas", not
    // "the bananas", and grounding matches better without it.
    target = target.replace(/^(the|a|an|my)\s+/i, '').trim();
    if (!target) return null;
    return { target };
  }

  return null;
}

/// "Is this the milk bag?" — the user has something in their hand and wants it
/// checked. Per language, the openings that can only be that.
///
/// Pilot, 14 Aug 2026: three of these, all transcribed perfectly, all answered
/// with "I did not catch that". The classifier is one network call on a store
/// wifi away from returning `unknown`, and when it does the user is told their
/// speech failed — which is the one thing that did not. So this decision is
/// taken off the model, exactly as `parseExplicitNavigationCommand` takes
/// navigation off it: a verification question is a question about the frame,
/// and the frame is already in hand.
const VERIFICATION_QUESTION_PATTERNS: Record<AppLanguage, RegExp[]> = {
  en: [
    /^(?:is|are)\s+(?:this|that|it|these|those|they)\b/,
    /^(?:am|are)\s+i\b/,
    /^(?:do|does|did|have|had)\s+i\b/,
    /^(?:what|which)\b[^?]*\b(?:this|that|it|i|holding|hand)\b/,
    /^(?:is|are)\s+(?:the|a|an|my)\b[^?]*\b(?:right|correct|one)\b/,
  ],
  fr: [
    /^(?:est-ce|est\s+ce|c(?:'|’)est|es-tu\s+s[ûu]r)\b/,
    /^(?:ai-je|j(?:'|’)ai|est-ce\s+que\s+j(?:'|’)ai)\b/,
    /^qu(?:'|’)est-ce\s+que\s+je\b/,
    /^(?:quel|quelle)\b[^?]*\b(?:je|main|tiens|ceci|cela|[çc]a)\b/,
  ],
};

/// Broader net: anything shaped like a question at all. Only consulted on the
/// classifier's `unknown`, where the alternative is telling the user we did not
/// hear them.
const QUESTION_OPENERS: Record<AppLanguage, RegExp> = {
  en: /^(?:is|are|am|was|were|do|does|did|have|has|can|could|should|would|will|what|what's|where|which|who|whose|how|why|any)\b/,
  fr: /^(?:est-ce|est|sont|c(?:'|’)est|ai-je|as-tu|y\s+a-t-il|qu(?:'|’)est-ce|que|quoi|quel|quelle|quels|quelles|o[uù]|comment|pourquoi|combien|qui|puis-je|peux-tu)\b/,
};

/// Guidance verbs, per language. A question is only answered from the frame
/// when it contains none of these: « est-ce que tu peux m'amener au lait ? »
/// is question-shaped and is still a navigation request. English has
/// `parseExplicitNavigationCommand` to catch that on the way past; French has
/// no deterministic parser and leans entirely on the classifier, so a question
/// net without this guard would swallow a French destination request whole.
const GUIDANCE_REQUEST_PATTERNS: Record<AppLanguage, RegExp> = {
  en: /\b(?:take|bring|guide|lead|walk|navigate|escort)\s+(?:me|us)\b|\b(?:reach|grab|pick\s+up)\b/,
  fr: /\b(?:am[èe]ne|emm[èe]ne|conduis|guide|accompagne|dirige)[-\s]?(?:moi|nous)\b|\b(?:prends|attrape|saisis|donne)\b/,
};

const normalizedUtterance = (rawText: string | undefined): string =>
  rawText?.trim().toLowerCase().replace(/[.!]+$/, '') ?? '';

/** True when the utterance asks to be guided somewhere or to something. */
const asksForGuidance = (text: string): boolean =>
  GUIDANCE_REQUEST_PATTERNS[getAppLanguage()].test(text);

/**
 * True when the utterance asks the app to confirm or identify what the camera
 * is looking at ("is this the milk bag", « c'est bien le lait »). Such a turn
 * is always answered against the current frame, whatever the classifier said.
 */
export function looksLikeVerificationQuestion(rawText: string | undefined): boolean {
  const text = normalizedUtterance(rawText).replace(/\?+$/, '').trim();
  if (!text || asksForGuidance(text)) return false;
  return VERIFICATION_QUESTION_PATTERNS[getAppLanguage()].some(pattern => pattern.test(text));
}

/** True when the utterance is question-shaped in the active language. */
export function looksLikeQuestion(rawText: string | undefined): boolean {
  const text = normalizedUtterance(rawText);
  if (!text || asksForGuidance(text)) return false;
  if (text.endsWith('?')) return true;
  return QUESTION_OPENERS[getAppLanguage()].test(text.replace(/\?+$/, '').trim());
}

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

    // ── In-device mode: resolve everything locally, never touch the backend ──
    if (orchestratorConfig.inDeviceMode) {
      return this.processInDevice(request, signal, options);
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

  // ───────────────────────────────────────────────────────────────────────────
  // In-device mode: transcript → local intent → native ARKit pipeline flags.
  // Never calls options.backendWorkflowProvider. Continuous iterations (image
  // present) are no-ops here because the native reaching/navigation modules run
  // their own on-device loops once launched.
  // ───────────────────────────────────────────────────────────────────────────
  private async processInDevice(
    request: WorkflowRequest,
    signal: AbortSignal | undefined,
    options: MobileOrchestratorProcessOptions,
  ): Promise<WorkflowResponse> {
    if (signal?.aborted) throw new Error('Request cancelled');

    const sessionId = options.getSessionId();
    const trace: ProviderTraceEntry[] = [];
    const memory = await this.loadMemory(sessionId);
    const continuous = isContinuousRequest(request);

    // A continuous-loop tick arriving while a native pipeline owns the loop:
    // return a neutral, no-op response so the JS loop simply idles.
    if (continuous || !request.text?.trim()) {
      trace.push({
        provider: 'in_device_noop',
        ok: true,
        confidence: 1,
        needsRemote: false,
        diagnostics: { reason: continuous ? 'native_pipeline_owns_loop' : 'no_transcript' },
      });
      return this.neutralInDeviceResponse(sessionId, trace);
    }

    const localIntent = await this.classifyIntentInDevice(request, trace);
    await this.persistRequestState(memory, request, localIntent, sessionId, continuous);

    // "Take me to X" is THE primary command of this app. Routing it through an
    // LLM classifier means a misfire answers a navigation request with "I could
    // not analyze the image" or "I did not catch that", which strands a blind
    // user mid-store. Explicit navigation phrasings are therefore resolved
    // deterministically and override the classifier; anything not matching
    // still falls through to the model exactly as before.
    const explicitNav = parseExplicitNavigationCommand(request.text);

    // Same reasoning one level down, for the other command the classifier must
    // not be allowed to lose: "is this the milk bag?" is a question about the
    // frame we are already holding, and misrouting it either strands the user
    // ("I did not catch that") or — worse — reads as `reaching` and launches a
    // guidance session they did not ask for.
    const verification =
      !explicitNav &&
      Boolean(request.imageUri) &&
      looksLikeVerificationQuestion(request.text);
    if (verification) {
      trace.push({
        provider: 'verification_question',
        ok: true,
        confidence: 1,
        needsRemote: false,
        diagnostics: { overrodeIntent: localIntent.json?.intent ?? 'none' },
      });
    }

    const intent = explicitNav
      ? 'navigation'
      : verification
        ? 'chat'
        : localIntent.json?.intent;
    const target = explicitNav
      ? explicitNav.target
      : verification
        ? undefined
        : localIntent.json?.target?.trim() || undefined;
    const provider = localIntent.usedProvider;

    // ── Reaching → in-device spatial-target ARKit reaching (bbox-free) ───────
    if (intent === 'reaching' && target) {
      const response: WorkflowResponse = {
        text: '',
        navigation: false,
        reaching_flag: false,
        reaching_ios: true,
        object: target,
        loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
        session_id: sessionId,
        local_orchestrator_used: true,
        local_llm_used: provider === 'apple_foundation_models' || provider === 'groq',
        llm_provider: provider,
        intent_provider: provider,
        provider_trace: trace,
      };
      await this.persistResponseSummary(memory, response, 'in_device_reaching');
      return response;
    }

    // ── Navigation → in-device ARKit route navigation ────────────────────────
    if (intent === 'navigation' && target) {
      const response: WorkflowResponse = {
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
        local_llm_used: provider === 'apple_foundation_models' || provider === 'groq',
        llm_provider: provider,
        intent_provider: provider,
        provider_trace: trace,
      };
      await this.persistResponseSummary(memory, response, 'in_device_navigation');
      return response;
    }

    // ── Stop → neutral (App-level stop handling takes over on the UI side) ────
    if (intent === 'stop') {
      return this.neutralInDeviceResponse(sessionId, trace, '');
    }

    // ── Scene / chat / informational image question → on-device Groq vision ──
    if (
      intent === 'scene' ||
      intent === 'chat' ||
      (localIntent.json?.needsImage === true && Boolean(request.imageUri))
    ) {
      const answer = await this.visionAnswerInDevice(request, intent, trace);
      if (answer) {
        return this.neutralInDeviceResponse(sessionId, trace, answer);
      }
      const why = request.imageUri
        ? strings().assistant.couldNotAnalyzeImage
        : strings().assistant.pointCameraFirst;
      return this.neutralInDeviceResponse(sessionId, trace, why);
    }

    // ── Unknown, but still a question, and we are holding a frame ────────────
    //
    // The last defence for a turn the classifier gave up on. A question we
    // cannot route is still a question, and answering it from the frame is
    // strictly better than telling a user whose speech was transcribed
    // perfectly that they were not heard.
    if (request.imageUri && looksLikeQuestion(request.text)) {
      const answer = await this.visionAnswerInDevice(request, 'chat', trace);
      if (answer) {
        return this.neutralInDeviceResponse(sessionId, trace, answer);
      }
    }

    // ── Unknown / no clear action ────────────────────────────────────────────
    return this.neutralInDeviceResponse(sessionId, trace, strings().assistant.didNotCatch);
  }

  // Scene → full-surroundings description; chat/other → question answered
  // against the current frame. Returns spoken text or null on failure.
  private async visionAnswerInDevice(
    request: WorkflowRequest,
    intent: IntentClassification['intent'] | undefined,
    trace: ProviderTraceEntry[],
  ): Promise<string | null> {
    if (!request.imageUri || !groqVisionClient.isConfigured()) {
      trace.push({
        provider: 'groq_vision',
        ok: false,
        confidence: 0,
        needsRemote: false,
        fallbackReason: !request.imageUri ? 'no_image' : 'groq_vision_not_configured',
      });
      return null;
    }

    const result =
      intent === 'scene'
        ? await groqVisionClient.describeScene(request.imageUri, request.text)
        : await groqVisionClient.answerQuestion(request.imageUri, request.text || '');

    trace.push({
      provider: 'groq_vision',
      ok: result.ok,
      confidence: result.ok ? 0.9 : 0,
      needsRemote: false,
      fallbackReason: result.fallbackReason,
      diagnostics: {
        intent,
        spokenChars: result.text?.length,
        // Present only when the answer overran the spoken budget: `shortened`
        // false means the third pass ran and was rejected for not actually
        // shortening, which is the one case worth reading the log over.
        ...(result.lengthBeforeShorten !== undefined
          ? { lengthBeforeShorten: result.lengthBeforeShorten, shortened: result.shortened }
          : {}),
      },
    });

    if (!result.ok) {
      // The trace alone is not enough: the user hears a generic apology and the
      // session log shows nothing, so a broken vision path looks identical to a
      // bad camera frame. Say why in the console.
      console.warn(`[Orchestrator] Vision failed (intent=${intent}): ${result.fallbackReason}`);
    }

    return result.ok ? result.text || null : null;
  }

  private neutralInDeviceResponse(
    sessionId: string,
    trace: ProviderTraceEntry[],
    text = '',
  ): WorkflowResponse {
    return {
      text,
      navigation: false,
      reaching_flag: false,
      reaching_ios: false,
      loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
      session_id: sessionId,
      local_orchestrator_used: true,
      provider_trace: trace,
    };
  }

  private async classifyIntentInDevice(
    request: WorkflowRequest,
    trace: ProviderTraceEntry[],
  ): Promise<LocalLLMResult<IntentClassification>> {
    const hasImage = Boolean(request.imageUri);

    // Groq first (reliable, mirrors backend Extract Intent), then on-device
    // Apple FM / heuristic fallback via llmRouter.
    if (groqIntentClient.isConfigured()) {
      try {
        const groq = await groqIntentClient.classifyIntent({ text: request.text, hasImage });
        trace.push({
          provider: 'groq',
          ok: Boolean(groq.json?.intent),
          confidence: groq.confidence,
          needsRemote: groq.needsBackend,
          fallbackReason: groq.fallbackReason,
          diagnostics: { intent: groq.json?.intent, target: groq.json?.target },
        });
        if (groq.available && groq.json?.intent) return groq;
      } catch (error: any) {
        trace.push({
          provider: 'groq',
          ok: false,
          confidence: 0,
          needsRemote: true,
          fallbackReason: error?.message || String(error),
        });
      }
    }

    const local = await llmRouter.classifyIntent({ text: request.text, hasImage });
    trace.push({
      provider: local.usedProvider,
      ok: Boolean(local.json?.intent),
      confidence: local.confidence,
      needsRemote: local.needsBackend,
      fallbackReason: local.fallbackReason,
      diagnostics: { intent: local.json?.intent, target: local.json?.target },
    });
    return local;
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