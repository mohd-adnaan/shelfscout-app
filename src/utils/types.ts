/**
 * src/utils/types.ts
 * 
 * Type definitions for CyberSight application
 * 
 * UPDATED: Added navigation and reaching_flag support (Jan 26, 2026)
 */

// =============================================================================
// Workflow Types
// =============================================================================

/**
 * Request to N8N workflow
 * 
 * UPDATED: Added navigation and reaching_flag for continuous mode
 */
export interface WorkflowRequest {
  /** User's voice transcript (empty string for navigation/reaching loop iterations) */
  text: string;
  /** Path to captured image file */
  imageUri: string;
  /** 
   * Navigation mode flag
   * - false (default): Normal user-initiated request
   * - true: Part of navigation loop (no user input needed)
   */
  navigation?: boolean;
  /**
   * Reaching mode flag
   * - false (default): Normal request
   * - true: Part of reaching loop (object guidance mode)
   */
  reaching_flag?: boolean;
}

/**
 * Response from N8N workflow
 * 
 * UPDATED: Added navigation flag, reaching_flag, and loopDelay
 */
export interface WorkflowResponse {
  /** Text to be spoken via TTS */
  text: string;
  /** 
   * Navigation loop control flag
   * - true: Continue navigation loop (capture photo → send → speak → repeat)
   * - false: Stop navigation loop, return to ready state
   */
  navigation?: boolean;
  /**
   * Reaching loop control flag
   * - true: Continue reaching loop (object guidance mode)
   * - false: Stop reaching loop, return to ready state
   */
  reaching_flag?: boolean;
  /**
   * Optional delay between loop iterations (ms)
   * Default: 1000ms (from NAVIGATION_CONFIG.DEFAULT_LOOP_DELAY_MS)
   */
  loopDelay?: number;
}

// =============================================================================
// State Types
// =============================================================================

/**
 * Application state
 * 
 * UPDATED: Added 'navigation' and 'reaching' states
 */
export type AppState = 
  | 'ready'       // Waiting for user input
  | 'listening'   // Recording user's voice
  | 'processing'  // Sending to backend, waiting for response
  | 'speaking'    // Playing TTS response
  | 'navigation'  // Active navigation loop
  | 'reaching';   // Active reaching/guidance loop

/**
 * Continuous mode state (navigation OR reaching)
 */
export interface ContinuousModeState {
  /** Whether continuous mode (navigation or reaching) is currently active */
  isActive: boolean;
  /** Type of continuous mode */
  mode: 'navigation' | 'reaching' | null;
  /** Current iteration count */
  iterationCount: number;
  /** Timestamp of last request */
  lastRequestTime: number;
  /** Current delay between iterations */
  currentLoopDelay: number;
}

// =============================================================================
// Speech Types
// =============================================================================

/**
 * Speech recognition result
 */
export interface SpeechResult {
  transcript: string;
  isFinal: boolean;
  confidence?: number;
}

/**
 * TTS options
 */
export interface TTSOptions {
  rate?: number;
  pitch?: number;
  voice?: string;
}

// =============================================================================
// Accessibility Types
// =============================================================================

/**
 * Accessibility announcement options
 */
export interface AnnouncementOptions {
  /** Whether to speak the announcement via TTS */
  speak?: boolean;
  /** Priority level */
  priority?: 'polite' | 'assertive';
}

/**
 * Earcon sound types
 */
export type EarconType = 
  | 'ready'
  | 'listening'
  | 'thinking'
  | 'speaking'
  | 'success'
  | 'error'
  | 'cancel'
  | 'navigation'  // Navigation loop earcon
  | 'reaching';   // Reaching/guidance loop earcon

// =============================================================================
// Error Types
// =============================================================================

/**
 * Application error with user-friendly message
 */
export interface AppError {
  code: string;
  message: string;
  userMessage: string;
  recoverable: boolean;
}

// =============================================================================
// Export
// =============================================================================

export default {
  // Types are exported inline above
};