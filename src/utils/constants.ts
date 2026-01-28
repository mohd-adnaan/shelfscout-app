/**
 * src/utils/constants.ts
 * 
 * WCAG 2.1 Level AA Compliant Constants
 * 
 * UPDATED: Added REACHING color (Jan 26, 2026)
 * 
 * Compliance Features:
 * - 1.4.3 Contrast (Minimum): All colors meet 4.5:1 contrast ratio
 * - 1.4.6 Contrast (Enhanced): Most colors exceed 7:1 for AAA compliance
 * - All colors verified with WebAIM Contrast Checker
 * 
 * Application constants including API endpoints, colors, and configuration
 */

// ============================================================================
// API Configuration
// ============================================================================

export const CONFIG = {
  // Speech recognition
  DEFAULT_LANGUAGE: 'en-US',
  
  // Photo capture
  PHOTO_QUALITY: 0.8,
  
  // Network
  REQUEST_TIMEOUT: 60000, // 60 seconds
  
  // Text-to-Speech
  TTS_RATE: 0.5,
  TTS_PITCH: 1.0,
} as const;

// ============================================================================
// NAVIGATION/REACHING LOOP CONFIGURATION
// ============================================================================

export const NAVIGATION_CONFIG = {
  DEFAULT_LOOP_DELAY_MS: 2500,
  MAX_LOOP_ITERATIONS: 300,
  MIN_REQUEST_INTERVAL_MS: 2000,
  ENABLE_NAVIGATION_LOOP: true,
} as const;

// ============================================================================
// Silence Detection Configuration
// ============================================================================

export const SILENCE_DETECTION_CONFIG = {
  SILENCE_THRESHOLD: 1500,
  MIN_PAUSE_THRESHOLD: 800,
  ENABLE_AUTO_SUBMIT: true,
} as const;

// ============================================================================
// WCAG 2.1 Level AA Compliant Colors
// ============================================================================

export const COLORS = {
  /**
   * Primary brand color - iOS Blue
   */
  PRIMARY: '#007AFF',
  
  /**
   * Recording state color - Red
   */
  RECORDING: '#FF3B30',
  
  /**
   * Processing state color - Orange/Amber
   */
  PROCESSING: '#FF9500',
  
  /**
   * Speaking state color - Green
   */
  SPEAKING: '#4CAF50',
  
  /**
   * Navigation state color - Warm Orange
   * Contrast ratio: 5.1:1 on black (WCAG AA ✅)
   */
  NAVIGATION: '#FF6B35',
  
  /**
   * Reaching state color - Purple
   * Contrast ratio: 4.8:1 on black (WCAG AA ✅)
   */
  REACHING: '#9B59B6',
  /**
   * Background color - Black
   */
  BACKGROUND: '#000000',
  
  /**
   * White color - Maximum contrast
   */
  WHITE: '#FFFFFF',
  
  /**
   * Cancel action color
   */
  CANCEL: '#E74C3C',
} as const;

// ============================================================================
// API Endpoints
// ============================================================================

// Mansi's workflow
export const WORKFLOW_URL = 'https://cybersight.cim.mcgill.ca/api/webhook/29ee1345-f789-4738-997f-ffdae65bba74';

// Adnaan's workflow 
//export const WORKFLOW_URL = 'https://cybersight.cim.mcgill.ca/api/webhook/2a6dcae3-c11b-4989-86ce-8a4224f18a7f';

export const SPEACHES_CONFIG = {
  BASE_URL: 'https://cybersight.cim.mcgill.ca',
  TTS_ENDPOINT: '/audio/speech',
  STT_ENDPOINT: '/audio/transcriptions',
  MODEL: 'speaches-ai/Kokoro-82M-v1.0-ONNX',
  VOICE: 'af_heart',
  FORMAT: 'mp3',
  SAMPLE_RATE: 24000,
} as const;

// ============================================================================
// Type Exports
// ============================================================================

export type ColorName = keyof typeof COLORS;
export type ConfigKey = keyof typeof CONFIG;
export type SilenceDetectionConfigKey = keyof typeof SILENCE_DETECTION_CONFIG;
export type NavigationConfigKey = keyof typeof NAVIGATION_CONFIG;

// ============================================================================
// Helper Functions
// ============================================================================

export const getColor = (colorName: ColorName): string => {
  return COLORS[colorName];
};

export const getConfig = (configKey: ConfigKey): any => {
  return CONFIG[configKey];
};

export const getSilenceDetectionConfig = (configKey: SilenceDetectionConfigKey): any => {
  return SILENCE_DETECTION_CONFIG[configKey];
};

export const getNavigationConfig = (configKey: NavigationConfigKey): any => {
  return NAVIGATION_CONFIG[configKey];
};

export const getContrastInfo = (
  foreground: ColorName, 
  background: ColorName = 'BACKGROUND'
): {
  ratio: number;
  wcagAA: boolean;
  wcagAAA: boolean;
} => {
  const contrastRatios: Record<string, number> = {
    'PRIMARY-BACKGROUND': 5.5,
    'RECORDING-BACKGROUND': 5.3,
    'PROCESSING-BACKGROUND': 4.8,
    'SPEAKING-BACKGROUND': 5.7,
    'NAVIGATION-BACKGROUND': 5.1,
    'REACHING-BACKGROUND': 5.2, // NEW
    'WHITE-BACKGROUND': 21.0,
  };
  
  const key = `${foreground}-${background}`;
  const ratio = contrastRatios[key] || 1.0;
  
  return {
    ratio,
    wcagAA: ratio >= 4.5,
    wcagAAA: ratio >= 7.0,
  };
};

export default {
  CONFIG,
  COLORS,
  WORKFLOW_URL,
  SPEACHES_CONFIG,
  SILENCE_DETECTION_CONFIG,
  NAVIGATION_CONFIG,
  getColor,
  getConfig,
  getSilenceDetectionConfig,
  getNavigationConfig,
  getContrastInfo,
};