/**
 * src/services/WorkflowService.ts
 * 
 * WCAG 2.1 Level AA Compliant Workflow Service
 * 
 * UPDATED: Two-Flag System with Session Reset (Jan 26, 2026)
 * - navigation flag: Navigation loop control
 * - reaching_flag: Object guidance/reaching control
 * - Session ID resets when BOTH flags become false
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear, actionable error messages
 * - 3.3.2 Labels or Instructions: Provides guidance for common errors
 * - 4.1.3 Status Messages: Announces errors to screen reader
 */

import axios, { AxiosError } from 'axios';
import { Platform, Alert } from 'react-native';
import { WORKFLOW_URL, CONFIG, NAVIGATION_CONFIG } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse, ContinuousModeState } from '../utils/types';
import { AccessibilityService } from './AccessibilityService';

// =============================================================================
// RESETTABLE PERSISTENT SESSION ID
// =============================================================================

/**
 * Generate a UUID v4 session ID
 */
const generateSessionId = (): string => {
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = Math.random() * 16 | 0;
    const v = c === 'x' ? r : (r & 0x3 | 0x8);
    return v.toString(16);
  });
};

/**
 * Resettable session ID
 * - Stays the same during continuous mode (navigation OR reaching)
 * - Resets when BOTH flags become false
 */
let SESSION_ID = generateSessionId();
console.log('📱 [Workflow] Session initialized:', SESSION_ID);

/**
 * Reset the session ID (called when continuous mode ends completely)
 */
export const resetSessionId = (): string => {
  SESSION_ID = generateSessionId();
  console.log('🔄 [Workflow] Session RESET:', SESSION_ID);
  return SESSION_ID;
};

// =============================================================================
// CONTINUOUS MODE STATE (NAVIGATION OR REACHING)
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

/**
 * Check if continuous mode (navigation OR reaching) is active
 */
export const isContinuousModeActive = (): boolean => {
  return continuousModeState.isActive;
};

/**
 * Get the current mode (navigation or reaching)
 */
export const getCurrentMode = (): 'navigation' | 'reaching' | null => {
  return continuousModeState.mode;
};

/**
 * Get current iteration count
 */
export const getContinuousModeIteration = (): number => {
  return continuousModeState.iterationCount;
};

/**
 * Get the current session ID (for debugging)
 */
export const getSessionId = (): string => {
  return SESSION_ID;
};

/**
 * Get the current loop delay
 */
export const getCurrentLoopDelay = (): number => {
  return continuousModeState.currentLoopDelay;
};

/**
 * Start continuous mode (navigation OR reaching)
 */
export const startContinuousMode = (mode: 'navigation' | 'reaching', loopDelay?: number): void => {
  continuousModeState = {
    isActive: true,
    mode,
    iterationCount: 0,
    lastRequestTime: Date.now(),
    currentLoopDelay: loopDelay || NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
  };
  console.log(`🔄 [${mode}] Continuous mode STARTED`);
  console.log(`🔄 [${mode}] Loop delay:`, continuousModeState.currentLoopDelay, 'ms');
};

/**
 * Increment continuous mode iteration
 */
export const incrementContinuousMode = (): void => {
  continuousModeState.iterationCount++;
  continuousModeState.lastRequestTime = Date.now();
  console.log(`🔄 [${continuousModeState.mode}] Iteration ${continuousModeState.iterationCount}`);
};

/**
 * Update loop delay
 */
export const updateLoopDelay = (delay: number): void => {
  if (delay > 0) {
    continuousModeState.currentLoopDelay = delay;
    console.log(`🔄 [${continuousModeState.mode}] Loop delay updated:`, delay, 'ms');
  }
};

/**
 * Stop continuous mode and optionally reset session
 * @param resetSession - If true, generates new session ID
 */
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
    console.log(`🛑 [${mode}] Reason: ${reason}`);
  }
  
  // Reset session ID if requested (when BOTH flags are false)
  if (resetSession) {
    resetSessionId();
  }
};

/**
 * Check if we should prevent infinite loops
 */
export const shouldPreventInfiniteLoop = (): boolean => {
  const { iterationCount, lastRequestTime } = continuousModeState;
  
  if (iterationCount >= NAVIGATION_CONFIG.MAX_LOOP_ITERATIONS) {
    console.warn('⚠️ [ContinuousMode] Max iterations reached, stopping loop');
    return true;
  }

  const timeSinceLastRequest = Date.now() - lastRequestTime;
  if (lastRequestTime > 0 && timeSinceLastRequest < NAVIGATION_CONFIG.MIN_REQUEST_INTERVAL_MS) {
    console.warn('⚠️ [ContinuousMode] Request rate too high, throttling');
    return true;
  }

  return false;
};

// =============================================================================
// MAIN WORKFLOW FUNCTION
// =============================================================================

/**
 * Send request to N8N workflow
 * 
 * UPDATED: Supports both navigation and reaching_flag
 */
export const sendToWorkflow = async (
  request: WorkflowRequest,
  signal?: AbortSignal
): Promise<WorkflowResponse> => {
  try {
    if (signal?.aborted) {
      console.log('⚠️ Request aborted before starting');
      throw new Error('Request cancelled');
    }

    // ========================================================================
    // Determine if this is a continuous mode iteration
    // ========================================================================
    const isContinuousIteration = request.navigation === true || request.reaching_flag === true;

    // ========================================================================
    // Validate input (allow empty text for continuous mode)
    // ========================================================================
    if (!isContinuousIteration && (!request.text || !request.text.trim())) {
      const message = 'No voice command provided. Please speak your request.';
      AccessibilityService.announceError(message, false);
      throw new Error(message);
    }

    if (!request.imageUri) {
      console.warn('⚠️ No photo provided - continuing with voice-only mode');
    }

    // ========================================================================
    // Prepare FormData
    // ========================================================================
    const formData = new FormData();
    
    // Transcript: User's speech OR empty string for continuous mode iterations
    formData.append('transcript', request.text || '');
    
    // ========================================================================
    // TWO-FLAG SYSTEM: Send both navigation and reaching_flag
    // ========================================================================
    const navigationValue = request.navigation === true ? 'true' : 'false';
    const reachingValue = request.reaching_flag === true ? 'true' : 'false';
    
    formData.append('navigation', navigationValue);
    formData.append('reaching_flag', reachingValue);
    
    // ========================================================================
    // Persistent session ID (reset when both flags become false)
    // ========================================================================
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
      
      console.log('📸 Image URI:', imageUri);
    } else {
      console.log('📸 No image - voice-only mode');
    }

    console.log('🚀 Sending to workflow:', WORKFLOW_URL);
    console.log('📝 Transcript:', request.text || '(empty - continuous mode)');
    console.log('🔄 Navigation flag:', navigationValue);
    console.log('🎯 Reaching flag:', reachingValue);
    console.log('🆔 Session ID:', SESSION_ID);

    if (signal?.aborted) {
      console.log('⚠️ Request aborted before network call');
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
      console.log('⚠️ Request aborted after receiving response');
      throw new Error('Request cancelled');
    }

    console.log('✅ Workflow response received');

    // ========================================================================
    // Parse response with TWO-FLAG support
    // ========================================================================
    const parsedResponse = parseWorkflowResponse(response.data);
    
    console.log('📄 Response:', {
      textLength: parsedResponse.text?.length || 0,
      navigation: parsedResponse.navigation,
      reaching_flag: parsedResponse.reaching_flag,
      loopDelay: parsedResponse.loopDelay,
    });

    // ========================================================================
    // Validate response
    // ========================================================================
    if (!parsedResponse.text || !parsedResponse.text.trim()) {
      if (!isContinuousIteration) {
        const message = 'Server returned empty response. Please try again.';
        AccessibilityService.announceError(message, false);
        throw new Error(message);
      } else {
        // During continuous mode, empty text might mean "keep going"
        console.warn('⚠️ [ContinuousMode] Empty response text, using default');
        parsedResponse.text = parsedResponse.navigation || parsedResponse.reaching_flag
          ? 'Continue'
          : 'Task complete';
      }
    }

    if (signal?.aborted) {
      console.log('⚠️ Request aborted before returning response');
      throw new Error('Request cancelled');
    }

    return parsedResponse;

  } catch (error: any) {
    // Handle abort errors gracefully
    if (signal?.aborted || error.code === 'ERR_CANCELED' || error.message?.includes('cancel')) {
      console.log('✅ Request cancelled successfully');
      throw new Error('Request cancelled');
    }

    console.error('❌ Workflow request error:', error);
    
    // Format user-friendly error messages
    let userMessage = 'Failed to process request.';
    let shouldShowAlert = true;

    if (axios.isAxiosError(error)) {
      if (error.code === 'ECONNABORTED' || error.message.includes('timeout')) {
        userMessage = 'Request timed out. The server took too long to respond. Please try again.';
      } 
      else if (error.code === 'ERR_NETWORK' || error.message.includes('Network')) {
        userMessage = 'Network error. Please check your internet connection and try again.';
      }
      else if (error.response) {
        const status = error.response.status;
        if (status === 400) {
          userMessage = 'Invalid request. Please try again.';
        } else if (status >= 500) {
          userMessage = 'Server error. Please try again later.';
        } else {
          userMessage = `Server error (${status}). Please try again.`;
        }
      }
    }

    AccessibilityService.announceError(userMessage, false);

    if (shouldShowAlert) {
      Alert.alert('Request Failed', userMessage, [{ text: 'OK', style: 'default' }]);
    }

    throw new Error(userMessage);
  }
};

// =============================================================================
// RESPONSE PARSER
// =============================================================================

/**
 * Parse N8N workflow response
 * UPDATED: Extracts both navigation and reaching_flag
 */
function parseWorkflowResponse(data: any): WorkflowResponse {
  const defaultResponse: WorkflowResponse = {
    text: '',
    navigation: false,
    reaching_flag: false,
    loopDelay: NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS,
  };

  if (!data) {
    console.warn('⚠️ [Workflow] Empty response data');
    return defaultResponse;
  }

  const payload = Array.isArray(data) ? data[0] : data;
  if (!payload) {
    console.warn('⚠️ [Workflow] No payload after array unwrap');
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
  // TWO-FLAG EXTRACTION
  // =========================================================================
  
  // Navigation flag
  let navigation = false;
  if (typeof innerPayload.navigation === 'boolean') {
    navigation = innerPayload.navigation;
  } else if (typeof innerPayload.navigation === 'string') {
    navigation = innerPayload.navigation.toLowerCase() === 'true';
  }
  
  // Reaching flag
  let reaching_flag = false;
  if (typeof innerPayload.reaching_flag === 'boolean') {
    reaching_flag = innerPayload.reaching_flag;
  } else if (typeof innerPayload.reaching_flag === 'string') {
    reaching_flag = innerPayload.reaching_flag.toLowerCase() === 'true';
  }
  // Also check for alternative names
  if (!reaching_flag && typeof innerPayload.reachingFlag === 'boolean') {
    reaching_flag = innerPayload.reachingFlag;
  } else if (!reaching_flag && typeof innerPayload.reachingFlag === 'string') {
    reaching_flag = innerPayload.reachingFlag.toLowerCase() === 'true';
  }

  // Loop delay
  let loopDelay = NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS;
  if (typeof innerPayload.loopDelay === 'number' && innerPayload.loopDelay > 0) {
    loopDelay = innerPayload.loopDelay;
  }

  console.log('📋 [Workflow] Parsed response:', { 
    text: text.substring(0, 50), 
    navigation, 
    reaching_flag,
    loopDelay 
  });

  return { text, navigation, reaching_flag, loopDelay };
}

// =============================================================================
// EXPORT
// =============================================================================

export default {
  sendToWorkflow,
  getSessionId,
  resetSessionId,
  // Continuous mode functions
  isContinuousModeActive,
  getCurrentMode,
  getContinuousModeIteration,
  getCurrentLoopDelay,
  startContinuousMode,
  stopContinuousMode,
  incrementContinuousMode,
  updateLoopDelay,
  shouldPreventInfiniteLoop,
};