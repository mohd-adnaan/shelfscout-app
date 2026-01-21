/**
 * src/services/WorkflowService.ts
 * 
 * WCAG 2.1 Level AA Compliant Workflow Service
 * 
 * NEW: Supports request cancellation via AbortController
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Clear, actionable error messages
 * - 3.3.2 Labels or Instructions: Provides guidance for common errors
 * - 4.1.3 Status Messages: Announces errors to screen reader
 * 
 * Handles communication with N8N workflow backend
 */

import axios, { AxiosError } from 'axios';
import { Platform, Alert } from 'react-native';
import { WORKFLOW_URL, CONFIG } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse } from '../utils/types';
import { AccessibilityService } from './AccessibilityService';

/**
 * Send request to N8N workflow
 * 
 * WCAG 3.3.1: Provides clear error identification and user-friendly messages
 * WCAG 4.1.3: Announces errors to screen reader for blind users
 * 
 * ✅ NEW: Supports request cancellation via AbortSignal
 * 
 * @param request - Workflow request with text and image
 * @param signal - Optional AbortSignal for cancelling the request
 * @returns Promise<WorkflowResponse> - Response from workflow
 * @throws Error with user-friendly message
 */
export const sendToWorkflow = async (
  request: WorkflowRequest,
  signal?: AbortSignal // ✅ NEW: Optional abort signal
): Promise<WorkflowResponse> => {
  try {
    // ========================================================================
    // ✅ NEW: Check if already aborted before starting
    // ========================================================================
    if (signal?.aborted) {
      console.log('⚠️ Request aborted before starting');
      throw new Error('Request cancelled');
    }

    // ========================================================================
    // WCAG 3.3.1: Validate input
    // ========================================================================
    if (!request.text || !request.text.trim()) {
      const message = 'No voice command provided. Please speak your request.';
      
      AccessibilityService.announceError(message, false);
      
      throw new Error(message);
    }

    // ✅ UPDATED: Image is optional (can work without photo)
    if (!request.imageUri) {
      console.warn('⚠️ No photo provided - continuing with voice-only mode');
      // Don't throw error - allow voice-only processing
    }

    // ========================================================================
    // Prepare FormData
    // ========================================================================
    const formData = new FormData();
    
    // Change 'text' to 'transcript' for N8N
    formData.append('transcript', request.text);
    
    // Add required fields for N8N
    formData.append('user_id', 'mobile-user');
    formData.append('request_id', `mobile-${Date.now()}`);
    formData.append('session_id', `mobile-session-${Date.now()}`);
    formData.append('continuousMode', 'false');

    // ✅ UPDATED: Only add image if provided
    if (request.imageUri) {
      // Fix Android image URI
      let imageUri = request.imageUri;
      if (Platform.OS === 'android' && !imageUri.startsWith('file://')) {
        imageUri = `file://${imageUri}`;
      }

      // Add image file
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
    console.log('📝 Transcript:', request.text);

    // ========================================================================
    // ✅ NEW: Check if aborted before network request
    // ========================================================================
    if (signal?.aborted) {
      console.log('⚠️ Request aborted before network call');
      throw new Error('Request cancelled');
    }

    // ========================================================================
    // WCAG 3.3.1: Make request with comprehensive error handling
    // ✅ NEW: Pass abort signal to axios
    // ========================================================================
    const response = await axios.post<WorkflowResponse>(
      WORKFLOW_URL,
      formData,
      {
        headers: {
          'Content-Type': 'multipart/form-data',
          'Accept': 'application/json',
        },
        timeout: CONFIG.REQUEST_TIMEOUT,
        signal, // ✅ NEW: Pass abort signal (axios 0.22.0+ supports this)
      }
    );

    // ========================================================================
    // ✅ NEW: Check if aborted after network request
    // ========================================================================
    if (signal?.aborted) {
      console.log('⚠️ Request aborted after receiving response');
      throw new Error('Request cancelled');
    }

    console.log('✅ Workflow response received');
    console.log('📄 Response length:', response.data?.text?.length || 0, 'characters');

    // ========================================================================
    // WCAG 3.3.1: Validate response
    // ========================================================================
    if (!response.data) {
      const message = 'No response received from server. Please try again.';
      
      AccessibilityService.announceError(message, false);
      
      throw new Error(message);
    }

    if (!response.data.text || !response.data.text.trim()) {
      const message = 'Server returned empty response. Please try again.';
      
      AccessibilityService.announceError(message, false);
      
      throw new Error(message);
    }

    // ✅ NEW: Final abort check before returning
    if (signal?.aborted) {
      console.log('⚠️ Request aborted before returning response');
      throw new Error('Request cancelled');
    }

    return response.data;

  } catch (error: any) {
    // ========================================================================
    // ✅ NEW: Handle abort errors gracefully (don't announce to user)
    // ========================================================================
    if (signal?.aborted || error.code === 'ERR_CANCELED' || error.message?.includes('cancel')) {
      console.log('✅ Request cancelled successfully');
      throw new Error('Request cancelled');
    }

    console.error('❌ Workflow request error:', error);
    
    // ========================================================================
    // WCAG 3.3.1: Format errors with clear, actionable messages
    // ========================================================================
    let userMessage = 'Failed to process request.';
    let shouldShowAlert = true;

    if (axios.isAxiosError(error)) {
      // Network errors
      if (error.code === 'ECONNABORTED' || error.message.includes('timeout')) {
        userMessage = 'Request timed out. The server took too long to respond. Please try again.';
      } 
      else if (error.code === 'ERR_NETWORK' || error.message.includes('Network')) {
        userMessage = 'Network error. Please check your internet connection and try again.';
      }
      else if (error.code === 'ENOTFOUND' || error.message.includes('getaddrinfo')) {
        userMessage = 'Cannot reach server. Please check your internet connection.';
      }
      // Server errors
      else if (error.response) {
        const status = error.response.status;
        
        console.error('📄 Response status:', status);
        console.error('📄 Response data:', error.response.data);
        
        if (status === 400) {
          userMessage = 'Invalid request. Please try again.';
        } else if (status === 401 || status === 403) {
          userMessage = 'Authentication error. Please check your settings.';
        } else if (status === 404) {
          userMessage = 'Server endpoint not found. Please check your configuration.';
        } else if (status === 413) {
          userMessage = 'Image too large. Please try again with a smaller photo.';
        } else if (status === 429) {
          userMessage = 'Too many requests. Please wait a moment and try again.';
        } else if (status >= 500) {
          userMessage = 'Server error. Please try again later.';
        } else {
          userMessage = `Server error (${status}). Please try again.`;
        }
      }
      // Request setup errors
      else if (error.request) {
        userMessage = 'No response from server. Please check your internet connection.';
      }
    } 
    // File/image errors
    else if (error.message?.includes('image') || error.message?.includes('photo')) {
      userMessage = error.message; // Already formatted
    }
    // Validation errors (already formatted)
    else if (error.message?.includes('voice command') || 
             error.message?.includes('photo captured')) {
      userMessage = error.message; // Already formatted
      shouldShowAlert = false; // Already announced
    }
    // Generic errors
    else if (error.message) {
      userMessage = `Error: ${error.message}`;
    }

    // ========================================================================
    // WCAG 4.1.3: Announce error to screen reader
    // ========================================================================
    AccessibilityService.announceError(userMessage, false);

    // ========================================================================
    // Show visual alert for sighted users
    // ========================================================================
    if (shouldShowAlert) {
      Alert.alert(
        'Request Failed',
        userMessage,
        [{ text: 'OK', style: 'default' }]
      );
    }

    // Re-throw with user-friendly message
    throw new Error(userMessage);
  }
};

/**
 * Check if workflow service is reachable
 * 
 * ✅ NEW: Supports cancellation via AbortSignal
 * 
 * @param signal - Optional AbortSignal for cancelling the health check
 * @returns Promise<boolean> - true if service is reachable
 */
export const checkWorkflowHealth = async (signal?: AbortSignal): Promise<boolean> => {
  try {
    console.log('🏥 Checking workflow health...');
    
    // ✅ NEW: Check if already aborted
    if (signal?.aborted) {
      console.log('⚠️ Health check aborted');
      return false;
    }
    
    const response = await axios.get(WORKFLOW_URL, {
      timeout: 5000, // 5 second timeout for health check
      signal, // ✅ NEW: Pass abort signal
    });
    
    // ✅ NEW: Check if aborted after request
    if (signal?.aborted) {
      console.log('⚠️ Health check aborted after response');
      return false;
    }
    
    console.log('✅ Workflow service is reachable');
    return response.status === 200;
    
  } catch (error: any) {
    // ✅ NEW: Don't log errors for cancelled requests
    if (signal?.aborted || error.code === 'ERR_CANCELED') {
      console.log('✅ Health check cancelled');
      return false;
    }
    
    console.error('❌ Workflow health check failed:', error.message);
    
    // Don't announce health check failures - these are background checks
    return false;
  }
};

/**
 * Format error message for user display
 * Helper function for consistent error formatting
 * 
 * WCAG 3.3.1: Ensures consistent, user-friendly error messages
 * 
 * @param error - Error object
 * @returns User-friendly error message
 */
export const formatWorkflowError = (error: any): string => {
  // ✅ NEW: Handle cancelled requests
  if (error.code === 'ERR_CANCELED' || error.message?.includes('cancel')) {
    return 'Request cancelled';
  }
  
  if (axios.isAxiosError(error)) {
    if (error.code === 'ECONNABORTED' || error.message.includes('timeout')) {
      return 'Request timed out. Please try again.';
    }
    if (error.code === 'ERR_NETWORK') {
      return 'Network error. Please check your connection.';
    }
    if (error.response) {
      const status = error.response.status;
      if (status >= 500) {
        return 'Server error. Please try again later.';
      }
      if (status === 404) {
        return 'Service not found. Please check configuration.';
      }
      return `Server error (${status}). Please try again.`;
    }
  }
  
  return error.message || 'Unknown error occurred. Please try again.';
};

/**
 * ✅ NEW: Test connection to workflow with detailed diagnostics
 * 
 * Useful for debugging connectivity issues
 * 
 * @param signal - Optional AbortSignal for cancelling the test
 * @returns Promise with detailed connection info
 */
export const testWorkflowConnection = async (
  signal?: AbortSignal
): Promise<{
  reachable: boolean;
  responseTime: number;
  statusCode?: number;
  error?: string;
}> => {
  const startTime = Date.now();
  
  try {
    if (signal?.aborted) {
      return {
        reachable: false,
        responseTime: 0,
        error: 'Test cancelled',
      };
    }
    
    console.log('🧪 Testing workflow connection...');
    
    const response = await axios.get(WORKFLOW_URL, {
      timeout: 10000, // 10 second timeout
      signal,
    });
    
    const responseTime = Date.now() - startTime;
    
    if (signal?.aborted) {
      return {
        reachable: false,
        responseTime,
        error: 'Test cancelled',
      };
    }
    
    console.log(`✅ Connection test passed (${responseTime}ms)`);
    
    return {
      reachable: true,
      responseTime,
      statusCode: response.status,
    };
    
  } catch (error: any) {
    const responseTime = Date.now() - startTime;
    
    if (signal?.aborted || error.code === 'ERR_CANCELED') {
      console.log('✅ Connection test cancelled');
      return {
        reachable: false,
        responseTime,
        error: 'Test cancelled',
      };
    }
    
    console.error(`❌ Connection test failed (${responseTime}ms):`, error.message);
    
    return {
      reachable: false,
      responseTime,
      statusCode: error.response?.status,
      error: formatWorkflowError(error),
    };
  }
};

/**
 * ✅ NEW: Cancel all pending workflow requests
 * 
 * This is a utility function to cancel all requests if needed
 * (though in practice, each request should manage its own AbortController)
 */
export const cancelAllRequests = (): void => {
  console.log('🛑 Cancelling all workflow requests');
  // Note: Individual requests should be cancelled via their own AbortControllers
  // This is just a placeholder for future enhancement if needed
};

// ============================================================================
// Export all functions
// ============================================================================
export default {
  sendToWorkflow,
  checkWorkflowHealth,
  formatWorkflowError,
  testWorkflowConnection,
  cancelAllRequests,
};