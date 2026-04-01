/**
 * src/services/WorkflowService.ts
 * 
 * WCAG 2.1 Level AA Compliant Workflow Service
 * 
 */

import axios, { AxiosError } from 'axios';
import { Platform, Alert, NativeModules } from 'react-native';
import { WORKFLOW_URL, CONFIG, NAVIGATION_CONFIG } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse, ContinuousModeState } from '../utils/types';
import { AccessibilityService } from './AccessibilityService';
import { debugLogger } from './DebugLogger';

// =============================================================================
// iOS ARKit Native Module Bridge
// =============================================================================

// This will be the bridge to Swift ViewController
const { ReachingModule: CybsGuidanceModule } = NativeModules;

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

export const resetSessionId = (): string => {
  SESSION_ID = generateSessionId();
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

export const shouldPreventInfiniteLoop = (): boolean => {
  const { iterationCount, lastRequestTime } = continuousModeState;

  if (iterationCount >= NAVIGATION_CONFIG.MAX_LOOP_ITERATIONS) {
    console.warn('⚠️ Max iterations reached');
    return true;
  }

  const timeSinceLastRequest = Date.now() - lastRequestTime;
  if (lastRequestTime > 0 && timeSinceLastRequest < NAVIGATION_CONFIG.MIN_REQUEST_INTERVAL_MS) {
    console.warn('⚠️ Request rate too high');
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

    const isContinuousIteration = request.navigation === true || request.reaching_flag === true;

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

      // send image dimensions
      if (request.imageWidth && request.imageHeight) {
        formData.append('imageWidth', String(request.imageWidth));
        formData.append('imageHeight', String(request.imageHeight));
        console.log(`📐 Image dimensions: ${request.imageWidth}×${request.imageHeight}`);
      }
    }


    console.log('🚀 Sending to workflow:', WORKFLOW_URL);
    console.log('📝 Transcript:', request.text || '(continuous mode)');
    console.log('🔄 Navigation:', navigationValue);
    console.log('🎯 Reaching:', reachingValue);
    console.log('🍎 Reaching iOS:', reachingIOSValue);
    console.log('🆔 Session:', SESSION_ID);

    requestStartTime = Date.now();
    debugLogger.logAPI(
      `→ POST ${WORKFLOW_URL.replace('https://cybersight.cim.mcgill.ca', '')}`,
      `transcript="${(request.text || '').substring(0, 60)}" nav=${navigationValue} reach=${reachingValue} ios=${reachingIOSValue} img=${!!request.imageUri}`,
    );

    if (signal?.aborted) {
      throw new Error('Request cancelled');
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
    const parsedResponse = parseWorkflowResponse(response.data);

    console.log('📄 Response:', {
      textLength: parsedResponse.text?.length || 0,
      navigation: parsedResponse.navigation,
      reaching_flag: parsedResponse.reaching_flag,
      reaching_ios: parsedResponse.reaching_ios,
      bbox: !!parsedResponse.bbox,
      object: parsedResponse.object,
    });

    debugLogger.logAPI(
      `← Parsed: nav=${parsedResponse.navigation} reach=${parsedResponse.reaching_flag} ios=${parsedResponse.reaching_ios} bbox=${!!parsedResponse.bbox}`,
      `text="${(parsedResponse.text || '').substring(0, 80)}"`,
    );

    // ========================================================================
    // Validate response
    // ========================================================================
    if (!parsedResponse.text || !parsedResponse.text.trim()) {
      if (!isContinuousIteration && !parsedResponse.reaching_ios) {
        const message = 'Server returned empty response. Please try again.';
        AccessibilityService.announceError(message, false);
        throw new Error(message);
      } else {
        parsedResponse.text = parsedResponse.navigation || parsedResponse.reaching_flag
          ? 'Continue'
          : parsedResponse.reaching_ios
            ? `Guiding you to ${parsedResponse.object || 'the object'}`
            : 'Task complete';
      }
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
// RESPONSE PARSER (with reaching_ios support)
// =============================================================================

function parseWorkflowResponse(data: any): WorkflowResponse {
  const defaultResponse: WorkflowResponse = {
    text: '',
    navigation: false,
    reaching_flag: false,
    reaching_ios: false,
    loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
    session_id: SESSION_ID,
  };

  if (!data) {
    console.warn('⚠️ Empty response data');
    return defaultResponse;
  }

  const payload = Array.isArray(data) ? data[0] : data;
  if (!payload) {
    console.warn('⚠️ No payload after unwrap');
    return defaultResponse;
  }

  const innerPayload = payload.json || payload;

  // Extract text
  let text = '';
  if (typeof innerPayload.text === 'string') {
    text = innerPayload.text.trim();
  } else if (typeof innerPayload.response === 'string') {
    text = innerPayload.response.trim();
  } else if (typeof innerPayload.message === 'string') {
    text = innerPayload.message.trim();
  }

  // =========================================================================
  // THREE-FLAG EXTRACTION
  // =========================================================================

  // Navigation flag
  let navigation = false;
  if (typeof innerPayload.navigation === 'boolean') {
    navigation = innerPayload.navigation;
  } else if (typeof innerPayload.navigation === 'string') {
    navigation = innerPayload.navigation.toLowerCase() === 'true';
  }

  // Reaching flag (Android LLM-based)
  let reaching_flag = false;
  if (typeof innerPayload.reaching_flag === 'boolean') {
    reaching_flag = innerPayload.reaching_flag;
  } else if (typeof innerPayload.reaching_flag === 'string') {
    reaching_flag = innerPayload.reaching_flag.toLowerCase() === 'true';
  }
  if (!reaching_flag && typeof innerPayload.reachingFlag === 'boolean') {
    reaching_flag = innerPayload.reachingFlag;
  }

  // =========================================================================
  // reaching_ios flag (iOS native ARKit) - HIGHEST PRIORITY
  // =========================================================================
  let reaching_ios = false;
  if (typeof innerPayload.reaching_ios === 'boolean') {
    reaching_ios = innerPayload.reaching_ios;
  } else if (typeof innerPayload.reaching_ios === 'string') {
    reaching_ios = innerPayload.reaching_ios.toLowerCase() === 'true';
  }
  // Also check camelCase variant
  if (!reaching_ios && typeof innerPayload.reachingIos === 'boolean') {
    reaching_ios = innerPayload.reachingIos;
  }

  // =========================================================================
  // BBOX extraction (when reaching_ios is true)
  // =========================================================================
  let bbox: [number, number, number, number] | undefined;

  if (innerPayload.bbox) {
    if (Array.isArray(innerPayload.bbox) && innerPayload.bbox.length === 4) {
      bbox = innerPayload.bbox.map((v: any) => Number(v)) as [number, number, number, number];
    } else if (typeof innerPayload.bbox === 'string') {
      try {
        // Handle both "[1,2,3,4]" and "1,2,3,4" formats
        let bboxString = innerPayload.bbox.trim();
        if (bboxString.startsWith('[') && bboxString.endsWith(']')) {
          bboxString = bboxString.slice(1, -1);
        }
        const parts = bboxString.split(',').map((v: string) => Number(v.trim()));
        if (parts.length === 4 && parts.every((n: number) => !isNaN(n))) {
          bbox = parts as [number, number, number, number];
        }
      } catch (e) {
        console.warn('⚠️ Failed to parse bbox string:', innerPayload.bbox);
      }
    }
  }

  // =========================================================================
  // Object name extraction
  // =========================================================================
  let object: string | undefined;
  if (typeof innerPayload.object === 'string' && innerPayload.object.trim()) {
    object = innerPayload.object.trim();
  } else if (typeof innerPayload.objectName === 'string' && innerPayload.objectName.trim()) {
    object = innerPayload.objectName.trim();
  }

  // Depth from backend (meters)
  let depth: string | undefined;
  if (innerPayload.depth !== undefined && innerPayload.depth !== null) {
    depth = String(innerPayload.depth);
  }

  // Loop delay
  let loopDelay = NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS;
  if (typeof innerPayload.loopDelay === 'number' && innerPayload.loopDelay > 0) {
    loopDelay = innerPayload.loopDelay;
  }

  // Session ID from response (or use current)
  const session_id = innerPayload.session_id || SESSION_ID;

  console.log('📋 Parsed:', {
    text: text.substring(0, 50),
    navigation,
    reaching_flag,
    reaching_ios,
    bbox: bbox ? `[${bbox.join(', ')}]` : 'none',
    object,
    depth,
  });

  return {
    text,
    navigation,
    reaching_flag,
    reaching_ios,
    bbox,
    object,
    depth,
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
  startContinuousMode,
  stopContinuousMode,
  incrementContinuousMode,
  updateLoopDelay,
  shouldPreventInfiniteLoop,
  determineActionMode,
  triggerIOSReaching,
};