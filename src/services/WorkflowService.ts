/**
 * src/services/WorkflowService.ts
 * 
 * WCAG 2.1 Level AA Compliant Workflow Service
 * 
 */

import axios, { AxiosError } from 'axios';
import { Platform, Alert, NativeModules } from 'react-native';
import { WORKFLOW_URL, SMART_GUIDANCE_URL, CONFIG, NAVIGATION_CONFIG } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse, ContinuousModeState } from '../utils/types';
import { AccessibilityService } from './AccessibilityService';
import { debugLogger } from './DebugLogger';

// =============================================================================
// iOS ARKit Native Module Bridge
// =============================================================================

// This will be the bridge to Swift ViewController
const { ReachingModule: CybsGuidanceModule } = NativeModules;

let dav2PrewarmStarted = false;

const looksLikeReachingRequest = (text?: string): boolean => {
  const normalized = (text || '').toLowerCase();
  return /\b(take|guide|lead|walk|navigate|bring)\s+(me\s+)?to\b/.test(normalized)
    || /\b(reach|grab|get)\b/.test(normalized);
};

const prewarmDAv2InBackground = (reason: string) => {
  if (Platform.OS !== 'ios' || dav2PrewarmStarted || !CybsGuidanceModule?.prewarmDAv2) return;

  dav2PrewarmStarted = true;
  console.log(`🔥 [Workflow] Pre-warming DAv2 model (${reason})`);
  CybsGuidanceModule.prewarmDAv2()
    .catch((e: any) => {
      dav2PrewarmStarted = false;
      console.warn('⚠️ [Workflow] DAv2 prewarm failed:', e?.message || e);
    });
};

/**
 * Trigger iOS ARKit reaching with bounding box data
 * 
 * @deprecated Use App.tsx handleiOSReaching() instead — it passes all required
 *             params (ttsRate, mode, distanceUnit, detectionUrl, imageWidth,
 *             imageHeight) from SettingsContext. This function is kept only as
 *             a minimal fallback.
 * 
 * @param bbox - [xmin, ymin, xmax, ymax] from Qwen detection
 * @param objectName - Name of the detected object
 * @param options - Optional: ttsRate, mode, distanceUnit, depth, imageWidth, imageHeight, detectionUrl
 */
export const triggerIOSReaching = async (
  bbox: [number, number, number, number],
  objectName: string,
  options?: {
    ttsRate?: number;
    mode?: 'handFree' | 'withHand';
    distanceUnit?: 'steps' | 'cm';
    depth?: number;
    imageWidth?: number;
    imageHeight?: number;
    detectionUrl?: string;
    acquisitionUrl?: string;
  }
): Promise<boolean> => {
  if (Platform.OS !== 'ios') {
    console.warn('🚫 triggerIOSReaching called on non-iOS platform');
    return false;
  }

  try {
    console.log('🎯 [iOS ARKit] Triggering reaching for:', objectName);
    console.log('📦 [iOS ARKit] Bounding box:', bbox);

    // If the native module exists, call it
    if (CybsGuidanceModule?.startReaching) {
      await CybsGuidanceModule.startReaching({
        bbox: bbox,
        object: objectName,
        ttsRate: options?.ttsRate ?? 0.5,
        mode: options?.mode ?? 'handFree',
        distanceUnit: options?.distanceUnit ?? 'steps',
        ...(options?.depth != null && { depth: options.depth }),
        ...(options?.imageWidth != null && { imageWidth: options.imageWidth }),
        ...(options?.imageHeight != null && { imageHeight: options.imageHeight }),
        ...(options?.detectionUrl != null && { detectionUrl: options.detectionUrl }),
        ...(options?.acquisitionUrl != null && { acquisitionUrl: options.acquisitionUrl }),
      });
      console.log('✅ [iOS ARKit] Reaching started successfully');
      return true;
    } else {
      console.warn('⚠️ CybsGuidanceModule not available - is the native module linked?');

      // Fallback: Announce to user
      AccessibilityService.announceForAccessibility(
        `Guiding you to ${objectName}. ARKit module initializing.`
      );
      return false;
    }
  } catch (error) {
    console.error('❌ [iOS ARKit] Failed to start reaching:', error);
    return false;
  }
};

// =============================================================================
// RESETTABLE PERSISTENT SESSION ID
// =============================================================================

const generateSessionId = (): string => {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
};

let SESSION_ID = generateSessionId();
console.log('📱 [Workflow] Session initialized:', SESSION_ID);

// ─── session_start signal (Melody's tracker reinit) ─────────────────────────
// True at app launch and after every resetSessionId(). Cleared after the
// first request that successfully advertises it. Backend reads this on
// the first request of a new session and reinitializes Melody's tracker
// so it doesn't stay locked on a stale target from the previous session.
let isNewSession = true;

export const resetSessionId = (): string => {
  SESSION_ID = generateSessionId();
  isNewSession = true;
  console.log('🔄 [Workflow] Session RESET:', SESSION_ID);
  return SESSION_ID;
};

export const getSessionId = (): string => {
  return SESSION_ID;
};

// =============================================================================
// CONTINUOUS MODE STATE
// =============================================================================

let continuousModeState: ContinuousModeState = {
  isActive: false,
  mode: null,
  iterationCount: 0,
  lastRequestTime: 0,
  currentLoopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
};

// =============================================================================
// CONTINUOUS MODE CONTROL FUNCTIONS
// =============================================================================

export const isContinuousModeActive = (): boolean => {
  return continuousModeState.isActive;
};

export const getCurrentMode = (): 'navigation' | 'reaching' | null => {
  return continuousModeState.mode;
};

export const getContinuousModeIteration = (): number => {
  return continuousModeState.iterationCount;
};

export const getCurrentLoopDelay = (): number => {
  return continuousModeState.currentLoopDelay;
};

export const getContinuousModeRateLimitDelay = (minIntervalMs?: number): number => {
  const { lastRequestTime } = continuousModeState;
  if (lastRequestTime <= 0) return 0;

  const minInterval = minIntervalMs ?? NAVIGATION_CONFIG.MIN_REQUEST_INTERVAL_MS;
  const timeSinceLastRequest = Date.now() - lastRequestTime;
  return Math.max(0, minInterval - timeSinceLastRequest);
};

export const startContinuousMode = (
  mode: 'navigation' | 'reaching',
  loopDelay?: number
): void => {
  console.log(`🔄 [${mode}] Continuous mode STARTED`);

  continuousModeState.isActive = true;
  continuousModeState.mode = mode;
  continuousModeState.iterationCount = 0;
  continuousModeState.lastRequestTime = Date.now() - 5000;
  continuousModeState.currentLoopDelay = loopDelay || NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS;
};

export const incrementContinuousMode = (): void => {
  continuousModeState.iterationCount++;
  continuousModeState.lastRequestTime = Date.now();
  console.log(`🔄 [${continuousModeState.mode}] Iteration ${continuousModeState.iterationCount}`);
};

export const updateLoopDelay = (delay: number): void => {
  if (delay > 0) {
    continuousModeState.currentLoopDelay = delay;
  }
};

export const stopContinuousMode = (reason?: string, resetSession: boolean = false): void => {
  const iterations = continuousModeState.iterationCount;
  const mode = continuousModeState.mode;

  continuousModeState = {
    isActive: false,
    mode: null,
    iterationCount: 0,
    lastRequestTime: 0,
    currentLoopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
  };

  console.log(`🛑 [${mode}] Continuous mode STOPPED after ${iterations} iterations`);
  if (reason) {
    console.log(`🛑 Reason: ${reason}`);
  }

  if (resetSession) {
    resetSessionId();
  }
};

export const shouldPreventInfiniteLoop = (_minIntervalMs?: number): boolean => {
  const { iterationCount } = continuousModeState;

  if (iterationCount >= NAVIGATION_CONFIG.MAX_LOOP_ITERATIONS) {
    console.warn('⚠️ Max iterations reached');
    return true;
  }

  return false;
};

// =============================================================================
// MAIN WORKFLOW FUNCTION
// =============================================================================

export const sendToWorkflow = async (
  request: WorkflowRequest,
  signal?: AbortSignal
): Promise<WorkflowResponse> => {
  let requestStartTime = Date.now();
  try {
    if (signal?.aborted) {
      throw new Error('Request cancelled');
    }

    const isContinuousIteration = request.navigation === true || request.reaching_flag === true || request.reaching_ios === true;

    if (!isContinuousIteration && (!request.text || !request.text.trim())) {
      const message = 'No voice command provided. Please speak your request.';
      AccessibilityService.announceError(message, false);
      throw new Error(message);
    }

    // ========================================================================
    // Prepare FormData
    // ========================================================================
    const formData = new FormData();

    formData.append('transcript', request.text || '');

    // THREE-FLAG SYSTEM
    const navigationValue = request.navigation === true ? 'true' : 'false';
    const reachingValue = request.reaching_flag === true ? 'true' : 'false';
    const reachingIOSValue = request.reaching_ios === true ? 'true' : 'false';

    formData.append('navigation', navigationValue);
    formData.append('reaching_flag', reachingValue);
    formData.append('reaching_ios', reachingIOSValue);
    formData.append('user_id', 'mobile-user');
    formData.append('request_id', `mobile-${Date.now()}`);
    formData.append('session_id', SESSION_ID);
    formData.append('continuousMode', isContinuousIteration ? 'true' : 'false');

    // ── mode field — n8n Redis expression references $json.body.mode ────
    // Derive from the three-flag system so the backend always has it.
    const modeValue = request.reaching_ios === true
      ? 'reaching_ios'
      : request.reaching_flag === true
        ? 'reaching'
        : request.navigation === true
          ? 'navigation'
          : 'default';
    formData.append('mode', modeValue);

    // ── session_start signal — fires once per fresh session ─────────────
    // Coordinated with Melody's backend tracker container: when this is
    // true, the backend reinitializes the tracker for this session_id
    // instead of carrying over state from a previous app run.
    const sessionStartValue = (isNewSession || request.session_start === true)
      ? 'true'
      : 'false';
    formData.append('session_start', sessionStartValue);
    if (sessionStartValue === 'true') {
      console.log('🆕 [Workflow] session_start=true (fresh session, tracker reinit)');
    }
    // Clear the module-level flag — only the FIRST request after a new
    // session advertises session_start; subsequent requests in the same
    // session_id send session_start=false.
    isNewSession = false;

    // ── Image dimensions — always sent so backend JSON.stringify never
    // encounters undefined for $json.body.imageWidth / imageHeight ──────
    formData.append('imageWidth', String(request.imageWidth ?? 0));
    formData.append('imageHeight', String(request.imageHeight ?? 0));

    // Add image if provided
    if (request.imageUri) {
      let imageUri = request.imageUri;
      if (Platform.OS === 'android' && !imageUri.startsWith('file://')) {
        imageUri = `file://${imageUri}`;
      }

      formData.append('image', {
        uri: imageUri,
        type: 'image/jpeg',
        name: 'photo.jpg',
      } as any);

      if (request.imageWidth && request.imageHeight) {
        console.log(`📐 Image dimensions: ${request.imageWidth}×${request.imageHeight}`);
      }
    }


    console.log('🚀 Sending to workflow:', WORKFLOW_URL);
    console.log('📝 Transcript:', request.text || '(continuous mode)');
    console.log('🔄 Navigation:', navigationValue);
    console.log('🎯 Reaching:', reachingValue);
    console.log('🍎 Reaching iOS:', reachingIOSValue);
    console.log('🎮 Mode:', modeValue);
    console.log('🆔 Session:', SESSION_ID);

    requestStartTime = Date.now();
    debugLogger.logAPI(
      `→ POST ${WORKFLOW_URL.replace('https://cybersight.cim.mcgill.ca', '')}`,
      `transcript="${(request.text || '').substring(0, 60)}" nav=${navigationValue} reach=${reachingValue} ios=${reachingIOSValue} img=${!!request.imageUri}`,
    );

    if (signal?.aborted) {
      throw new Error('Request cancelled');
    }

    // Pre-warm DAv2 while the backend request is in flight. On the first user
    // request reaching_ios is still false because the backend has not replied,
    // so use the transcript intent too.
    if (reachingIOSValue === 'true' || looksLikeReachingRequest(request.text)) {
      prewarmDAv2InBackground(
        reachingIOSValue === 'true' ? 'reaching_ios request' : 'likely reaching transcript'
      );
    }

    // ========================================================================
    // Make request
    // ========================================================================
    const response = await axios.post<any>(
      WORKFLOW_URL,
      formData,
      {
        headers: {
          'Content-Type': 'multipart/form-data',
          'Accept': 'application/json',
        },
        timeout: CONFIG.REQUEST_TIMEOUT,
        signal,
      }
    );

    if (signal?.aborted) {
      throw new Error('Request cancelled');
    }

    console.log('✅ Workflow response received');

    const elapsed = Date.now() - requestStartTime;
    debugLogger.logAPI(
      `← ${response.status} OK (${elapsed}ms)`,
    );

    // ========================================================================
    // Parse response with THREE-FLAG support (including reaching_ios)
    // ========================================================================
    const parsedResponse = parseWorkflowResponse(response.data, {
      reachingRequest: request.reaching_flag === true,
    });

    if (parsedResponse.reaching_ios === true) {
      prewarmDAv2InBackground('reaching_ios response');
    }

    console.log('📄 Response:', {
      textLength: parsedResponse.text?.length || 0,
      navigation: parsedResponse.navigation,
      reaching_flag: parsedResponse.reaching_flag,
      reaching_ios: parsedResponse.reaching_ios,
      bbox: !!parsedResponse.bbox,
      object: parsedResponse.object,
    });

    debugLogger.logAPI(
      `← Parsed: nav=${parsedResponse.navigation} reach=${parsedResponse.reaching_flag} ios=${parsedResponse.reaching_ios} bbox=${!!parsedResponse.bbox} track=${!!parsedResponse.tracking_active} reached=${!!parsedResponse.reached}`,
      `text="${(parsedResponse.text || '').substring(0, 80)}"`,
    );

    // ========================================================================
    // Validate response
    //
    // Mansi confirmed (chat): when the backend returns null guidance_text
    // but still has navigation/reaching flags set, the app must stay
    // silent rather than emitting a hardcoded "Continue". The continuous
    // loop's TTS block at App.tsx is already guarded by `if (result.text)`,
    // so leaving text empty is the correct behaviour — TTS just skips
    // for that iteration and the next backend poll fires.
    //
    // We still keep the reaching_ios fallback intro because the ARKit
    // pipeline relies on a non-empty intro line to drive its parallel
    // handoff (introSpeechPromise).
    // ========================================================================
    if (!parsedResponse.text || !parsedResponse.text.trim()) {
      if (!isContinuousIteration && !parsedResponse.reaching_ios) {
        const message = 'Server returned empty response. Please try again.';
        AccessibilityService.announceError(message, false);
        throw new Error(message);
      } else if (parsedResponse.reaching_ios) {
        parsedResponse.text = `Guiding you to ${parsedResponse.object || 'the object'}`;
      }
      // else: continuous-mode iteration with empty guidance → leave text
      //       empty, downstream TTS guard skips speak. NO "Continue"
      //       fallback (Mansi-confirmed).
    }

    return parsedResponse;

  } catch (error: any) {
    if (signal?.aborted || error.code === 'ERR_CANCELED' || error.message?.includes('cancel')) {
      throw new Error('Request cancelled');
    }

    console.error('❌ Workflow error:', error);

    const elapsed = Date.now() - requestStartTime;
    let userMessage = 'Failed to process request.';

    if (axios.isAxiosError(error)) {
      if (error.code === 'ECONNABORTED' || error.message.includes('timeout')) {
        userMessage = 'Request timed out. Please try again.';
      }
      else if (error.code === 'ERR_NETWORK' || error.message.includes('Network')) {
        userMessage = 'Network error. Please check your connection.';
      }
      else if (error.response) {
        const status = error.response.status;
        userMessage = status >= 500
          ? 'Server error. Please try again later.'
          : `Error (${status}). Please try again.`;
      }
    }

    debugLogger.logAPIError(
      `✗ ${userMessage} (${elapsed}ms)`,
      error?.message || String(error),
    );

    AccessibilityService.announceError(userMessage, false);
    // Alert.alert('Request Failed', userMessage, [{ text: 'OK' }]);

    throw new Error(userMessage);
  }
};

// =============================================================================
// SMART GUIDANCE (tracker-driven reaching)
// =============================================================================

export interface SmartGuidanceRequest {
  object: string;
  bbox: string;
  image: string;
  annotated_image: string;
  success: boolean;
  session_id?: string;
}

export interface SmartGuidanceResponse {
  guidance?: string;
  hand_direction?: string | null;
  tracking_active?: boolean;
  reaching_completed?: boolean;
  bbox?: { x: number; y: number; width: number; height: number } | string | [number, number, number, number];
  class_name?: string;
  confidence?: number;
  depth_estimate?: number;
}

export const sendToSmartGuidance = async (
  payload: SmartGuidanceRequest,
  signal?: AbortSignal
): Promise<SmartGuidanceResponse> => {
  const requestStartTime = Date.now();

  debugLogger.logAPI(
    `→ POST ${SMART_GUIDANCE_URL.replace('https://cybersight.cim.mcgill.ca', '')}`,
    `object=${payload.object} bbox=${payload.bbox}`,
  );

  const response = await axios.post<any>(
    SMART_GUIDANCE_URL,
    {
      session: {
        object: payload.object,
        bbox: payload.bbox,
        image: payload.image,
        annotated_image: payload.annotated_image,
        success: payload.success,
        // Always include session_id — the tracker container keys its
        // per-session state on it. Fall back to the current session id
        // rather than dropping the field entirely.
        session_id: payload.session_id || getSessionId(),
      },
    },
    {
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      },
      timeout: CONFIG.REQUEST_TIMEOUT,
      signal,
    }
  );

  const elapsed = Date.now() - requestStartTime;
  debugLogger.logAPI(
    `← ${response.status} OK (${elapsed}ms)`,
  );

  const data = response.data;
  const payloadData = Array.isArray(data) ? data[0] : data;
  if (payloadData && typeof payloadData === 'object' && payloadData.json) {
    return payloadData.json as SmartGuidanceResponse;
  }
  return payloadData as SmartGuidanceResponse;
};

// =============================================================================
// RESPONSE PARSER (with reaching_ios support)
// =============================================================================

function parseWorkflowResponse(
  data: any,
  opts: { reachingRequest?: boolean } = {},
): WorkflowResponse {
  const defaultResponse: WorkflowResponse = {
    text: '',
    navigation: false,
    reaching_flag: false,
    reaching_ios: false,
    loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
    session_id: SESSION_ID,
  };

  const parseBoolean = (value: any): boolean | null => {
    if (value === true || value === false) {
      return value;
    }
    if (value === null || value === undefined) {
      return null;
    }
    if (typeof value === 'number') {
      return value !== 0;
    }
    if (typeof value === 'string') {
      const normalized = value.trim().toLowerCase();
      if (normalized === 'true' || normalized === '1' || normalized === 'yes' || normalized === 'y') {
        return true;
      }
      if (
        normalized === 'false' ||
        normalized === '0' ||
        normalized === 'no' ||
        normalized === 'n' ||
        normalized === 'null' ||
        normalized === 'undefined' ||
        normalized === ''
      ) {
        return false;
      }
    }
    return null;
  };

  if (!data) {
    console.warn('⚠️ Empty response data');
    return defaultResponse;
  }

  const rawItems = Array.isArray(data) ? data : [data];
  const normalizedPayloads = rawItems
    .filter((item: any) => item && typeof item === 'object')
    .map((item: any) => {
      let jsonPayload: any | null = null;
      if (typeof item.json === 'string') {
        try {
          jsonPayload = JSON.parse(item.json);
        } catch (e) {
          console.warn('⚠️ Failed to parse payload.json string');
        }
      } else if (item.json && typeof item.json === 'object') {
        jsonPayload = item.json;
      }

      return jsonPayload ? { ...item, ...jsonPayload } : item;
    });

  if (normalizedPayloads.length === 0) {
    console.warn('⚠️ No payload after unwrap');
    return defaultResponse;
  }

  const parseBboxValue = (value: any): [number, number, number, number] | null => {
    if (Array.isArray(value) && value.length === 4) {
      const parsed = value.map((v: any) => Number(v));
      if (parsed.every((n: number) => !Number.isNaN(n))) {
        return parsed as [number, number, number, number];
      }
    }
    if (typeof value === 'string') {
      try {
        let bboxString = value.trim();
        if (bboxString.startsWith('[') && bboxString.endsWith(']')) {
          bboxString = bboxString.slice(1, -1);
        }
        const parts = bboxString.split(',').map((v: string) => Number(v.trim()));
        if (parts.length === 4 && parts.every((n: number) => !Number.isNaN(n))) {
          return parts as [number, number, number, number];
        }
      } catch (e) {
        return null;
      }
    }
    return null;
  };

  const scorePayload = (payload: any): number => {
    let score = 0;

    if (
      parseBoolean(payload.reaching_ios) === true ||
      parseBoolean(payload.reachingIos) === true
    ) {
      score += 4;
    }
    if (
      parseBoolean(payload.reaching_flag) === true ||
      parseBoolean(payload.reachingFlag) === true ||
      parseBoolean(payload.reaching) === true
    ) {
      score += 3;
    }
    if (
      parseBoolean(payload.navigation) === true ||
      parseBoolean(payload.navigation_flag) === true
    ) {
      score += 2;
    }

    const bboxCandidate = parseBboxValue(payload.bbox);
    if (bboxCandidate && bboxCandidate.some((value) => value !== 0)) {
      score += 2;
    }

    if (typeof payload.response === 'string' && payload.response.trim()) {
      score += 1;
    }
    if (typeof payload.text === 'string' && payload.text.trim()) {
      score += 1;
    }
    if (typeof payload.message === 'string' && payload.message.trim()) {
      score += 1;
    }

    return score;
  };

  const orderedPayloads = [...normalizedPayloads].sort(
    (a, b) => scorePayload(b) - scorePayload(a),
  );

  const pickString = (keys: string[]): string => {
    for (const payload of orderedPayloads) {
      for (const key of keys) {
        const value = payload[key];
        if (typeof value === 'string' && value.trim()) {
          return value.trim();
        }
      }
    }
    return '';
  };

  const pickStringByKeyPriority = (keys: string[]): string => {
    for (const key of keys) {
      for (const payload of orderedPayloads) {
        const value = payload[key];
        if (typeof value === 'string' && value.trim()) {
          return value.trim();
        }
      }
    }
    return '';
  };

  const pickNumber = (keys: string[]): number | undefined => {
    for (const payload of orderedPayloads) {
      for (const key of keys) {
        const value = payload[key];
        if (typeof value === 'number' && !Number.isNaN(value)) {
          return value;
        }
        if (typeof value === 'string' && value.trim()) {
          const parsed = Number(value);
          if (!Number.isNaN(parsed)) {
            return parsed;
          }
        }
      }
    }
    return undefined;
  };

  const pickBbox = (): [number, number, number, number] | undefined => {
    const isNonZero = (bbox: [number, number, number, number]) =>
      bbox.some((value) => value !== 0);

    for (const payload of orderedPayloads) {
      const candidate = parseBboxValue(payload.bbox);
      if (candidate && isNonZero(candidate)) {
        return candidate;
      }
    }

    for (const payload of orderedPayloads) {
      const candidate = parseBboxValue(payload.bbox);
      if (candidate) {
        return candidate;
      }
    }

    return undefined;
  };

  // ─── Normalize values that come from the n8n backend ─────────────────────
  // Mansi's standard reaching path writes `hand_direction` to Redis via
  // JSON.stringify(...). That means populated values arrive at the app
  // wrapped in literal escaped quotes (e.g. `"\"top left\""`) and null
  // arrives as the literal 4-char string `"null"`. Strip those artifacts
  // so downstream TTS doesn't speak the word "null" or pronounce the
  // surrounding quote characters. Safe to apply to plain strings too —
  // it only strips a leading+trailing `"` pair if both are present.
  const normalizeBackendString = (value: string): string => {
    if (!value) return '';
    let s = value.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.slice(1, -1).trim();
    }
    const lower = s.toLowerCase();
    if (lower === 'null' || lower === 'undefined' || lower === 'none' || lower === '') {
      return '';
    }
    return s;
  };

  // =========================================================================
  // FLAG EXTRACTION
  // =========================================================================

  // Navigation flag
  const navigation = normalizedPayloads.some((payload) =>
    parseBoolean(payload.navigation) === true ||
    parseBoolean(payload.navigation_flag) === true
  );

  // Reaching flag (Android LLM-based)
  const reaching_flag = normalizedPayloads.some((payload) =>
    parseBoolean(payload.reaching_flag) === true ||
    parseBoolean(payload.reachingFlag) === true ||
    parseBoolean(payload.reaching) === true
  );

  // reaching_ios flag (iOS native ARKit) - HIGHEST PRIORITY
  const reaching_ios = normalizedPayloads.some((payload) =>
    parseBoolean(payload.reaching_ios) === true ||
    parseBoolean(payload.reachingIos) === true
  );

  // tracking_active flag — Melody's tracker is locked on the target.
  const tracking_active = normalizedPayloads.some((payload) =>
    parseBoolean(payload.tracking_active) === true ||
    parseBoolean(payload.trackingActive) === true
  );

  // reached flag — RTAB navigation completion (Kasra).
  const reached = normalizedPayloads.some((payload) =>
    parseBoolean(payload.reached) === true ||
    parseBoolean(payload.navigation_completed) === true
  );

  // reaching_completed flag — standard/Melody reaching pipeline says the
  // object has been reached. Used to end a reacquisition loop cleanly.
  const reaching_completed = normalizedPayloads.some((payload) =>
    parseBoolean(payload.reaching_completed) === true ||
    parseBoolean(payload.reachingCompleted) === true
  );

  // Extract guidance text with hand-direction precedence.
  const hand_direction = normalizeBackendString(
    pickString(['hand_direction', 'handDirection']),
  );

  const reachingText = normalizeBackendString(
    pickString(['reaching', 'guidance']),
  );

  const nonReachingText = normalizeBackendString(
    pickStringByKeyPriority(['response', 'text', 'message']),
  );

  let text = '';
  if (opts.reachingRequest === true) {
    // Outgoing reaching loops speak reaching-only guidance. The backend can
    // also set reaching/tracking flags on the initial scene-description
    // response, so those response flags must not decide the spoken field.
    text = hand_direction || reachingText || normalizeBackendString(pickString(['text', 'message', 'response']));
  } else {
    text = nonReachingText || reachingText;
  }

  // =========================================================================
  // BBOX extraction (when reaching_ios is true)
  // =========================================================================
  const bbox = pickBbox();

  // =========================================================================
  // Object name extraction
  // =========================================================================
  const object = pickString(['object', 'objectName']) || undefined;

  const annotatedImageRaw = normalizeBackendString(
    pickString(['annotated_image', 'annotatedImage', 'annotated_image_base64', 'annotatedImageBase64']),
  );
  const annotated_image = annotatedImageRaw || undefined;

  // Depth from backend (meters)
  const depthValue = pickNumber(['depth']);
  const depth = depthValue !== undefined ? String(depthValue) : undefined;

  // Loop delay
  let loopDelay: number = NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS;
  const loopDelayValue = pickNumber(['loopDelay']);
  if (loopDelayValue && loopDelayValue > 0) {
    loopDelay = loopDelayValue;
  }

  // Session ID from response (or use current)
  const session_id = pickString(['session_id']) || SESSION_ID;

  console.log('📋 Parsed:', {
    text: text.substring(0, 50),
    hand_direction: hand_direction || 'none',
    navigation,
    reaching_flag,
    reaching_ios,
    bbox: bbox ? `[${bbox.join(', ')}]` : 'none',
    object,
    depth,
    tracking_active,
    reached,
  });

  return {
    text,
    navigation,
    reaching_flag,
    reaching_ios,
    bbox,
    object,
    depth,
    hand_direction: hand_direction || undefined,
    annotated_image,
    tracking_active,
    reaching_completed,
    reached,
    loopDelay,
    session_id,
  };
}

// =============================================================================
// ★★★ NEW: Determine action mode with PRIORITY for reaching_ios ★★★
// =============================================================================

export type ActionMode =
  | { type: 'reaching_ios'; bbox: [number, number, number, number]; object: string }
  | { type: 'reaching'; loopDelay: number }
  | { type: 'navigation'; loopDelay: number }
  | { type: 'none' };

/**
 * Determine what action to take based on response flags
 * 
 * PRIORITY ORDER:
 * 1. reaching_ios (iOS ARKit) - HIGHEST PRIORITY
 * 2. reaching_flag (Android LLM loop)
 * 3. navigation (Navigation loop)
 * 4. none (No continuous action)
 */
export const determineActionMode = (response: WorkflowResponse): ActionMode => {
  // =========================================================================
  // PRIORITY 1: iOS ARKit Reaching (only on iOS, requires bbox)
  // =========================================================================
  if (Platform.OS === 'ios' && response.reaching_ios && response.bbox) {
    console.log('🎯 [Priority] iOS ARKit reaching takes priority');
    return {
      type: 'reaching_ios',
      bbox: response.bbox,
      object: response.object || 'object',
    };
  }

  // =========================================================================
  // PRIORITY 2: Reaching flag (continuous loop)
  // =========================================================================
  if (response.reaching_flag) {
    console.log('🔄 [Priority] Reaching continuous mode');
    return {
      type: 'reaching',
      loopDelay: response.loopDelay || NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
    };
  }

  // =========================================================================
  // PRIORITY 3: Navigation flag (continuous loop)
  // =========================================================================
  if (response.navigation) {
    console.log('🗺️ [Priority] Navigation continuous mode');
    return {
      type: 'navigation',
      loopDelay: response.loopDelay || NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
    };
  }

  // =========================================================================
  // PRIORITY 4: No continuous action
  // =========================================================================
  console.log('✅ [Priority] No continuous mode needed');
  return { type: 'none' };
};

// =============================================================================
// EXPORT
// =============================================================================

export default {
  sendToWorkflow,
  getSessionId,
  resetSessionId,
  isContinuousModeActive,
  getCurrentMode,
  getContinuousModeIteration,
  getCurrentLoopDelay,
  getContinuousModeRateLimitDelay,
  startContinuousMode,
  stopContinuousMode,
  incrementContinuousMode,
  updateLoopDelay,
  shouldPreventInfiniteLoop,
  determineActionMode,
  triggerIOSReaching,
  sendToSmartGuidance,
};
