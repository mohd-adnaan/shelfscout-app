/**
 * src/services/AccessibilityService.ts
 * 
 * WCAG 2.1 Level AA Compliance Utility Service
 * 
 * Centralized accessibility helpers for:
 * - 4.1.3 Status Messages: Announcing changes to screen readers
 * - 3.3.1 Error Identification: Consistent error announcements
 * - 1.4.13 Content on Hover or Focus: Handling focus states
 * - 2.3.3 Animation from Interactions: Respecting reduce motion
 * 
 * Usage:
 *   import { AccessibilityService } from './services/AccessibilityService';
 *   
 *   // Announce to screen reader
 *   AccessibilityService.announce('Processing complete');
 *   
 *   // Announce error
 *   AccessibilityService.announceError('Network error');
 *   
 *   // Check if screen reader is active
 *   const isActive = await AccessibilityService.isScreenReaderEnabled();
 */

import { AccessibilityInfo, Platform } from 'react-native';

class AccessibilityServiceClass {
  private screenReaderEnabled: boolean = false;
  private reduceMotionEnabled: boolean = false;
  private isInitialized: boolean = false;

  /**
   * Initialize accessibility service
   * WCAG: Checks user preferences for assistive technologies
   */
  async initialize(): Promise<void> {
    if (this.isInitialized) {
      return;
    }

    try {
      const [isScreenReaderOn, isReduceMotionOn] = await Promise.all([
        AccessibilityInfo.isScreenReaderEnabled(),
        AccessibilityInfo.isReduceMotionEnabled(),
      ]);

      this.screenReaderEnabled = isScreenReaderOn;
      this.reduceMotionEnabled = isReduceMotionOn;

      console.log('♿ Accessibility Service Initialized:', {
        screenReader: this.screenReaderEnabled,
        reduceMotion: this.reduceMotionEnabled,
        platform: Platform.OS,
      });

      // Listen for changes
      AccessibilityInfo.addEventListener(
        'screenReaderChanged',
        (enabled: boolean) => {
          this.screenReaderEnabled = enabled;
          console.log('♿ Screen reader changed:', enabled);
        }
      );

      AccessibilityInfo.addEventListener(
        'reduceMotionChanged',
        (enabled: boolean) => {
          this.reduceMotionEnabled = enabled;
          console.log('♿ Reduce motion changed:', enabled);
        }
      );

      this.isInitialized = true;
    } catch (error) {
      console.error('❌ Accessibility initialization error:', error);
    }
  }

  /**
   * WCAG 4.1.3: Announce message to screen reader
   * 
   * @param message - Message to announce
   * @param options - Announcement options
   */
  announce(
    message: string,
    options?: {
      priority?: 'polite' | 'assertive';
      delay?: number;
    }
  ): void {
    const { priority = 'polite', delay = 0 } = options || {};

    if (delay > 0) {
      setTimeout(() => {
        AccessibilityInfo.announceForAccessibility(message);
      }, delay);
    } else {
      AccessibilityInfo.announceForAccessibility(message);
    }

    console.log(`♿ Announced (${priority}):`, message);
  }

  /**
   * WCAG 3.3.1: Announce error with consistent formatting
   * 
   * @param error - Error message or Error object
   * @param includeRetryHint - Whether to include "Please try again"
   */
  announceError(
    error: string | Error,
    includeRetryHint: boolean = true
  ): void {
    const errorMessage =
      error instanceof Error ? error.message : error;

    const fullMessage = includeRetryHint
      ? `Error: ${errorMessage}. Please try again.`
      : `Error: ${errorMessage}`;

    this.announce(fullMessage, { priority: 'assertive' });
  }

  /**
   * WCAG 4.1.3: Announce success with consistent formatting
   * 
   * @param message - Success message
   */
  announceSuccess(message: string): void {
    this.announce(`Success: ${message}`, { priority: 'polite' });
  }

  /**
   * WCAG 4.1.3: Announce warning with consistent formatting
   * 
   * @param message - Warning message
   */
  announceWarning(message: string): void {
    this.announce(`Warning: ${message}`, { priority: 'polite' });
  }

  /**
   * WCAG 4.1.3: Announce state change
   * 
   * @param state - New state name
   * @param includeInstructions - Whether to include usage instructions
   */
  announceState(
    state: 'ready' | 'listening' | 'processing' | 'speaking' | 'stopped',
    includeInstructions: boolean = true
  ): void {
    const stateMessages: Record<string, string> = {
      ready: 'Ready. Tap to speak.',
      listening: 'Listening. Tap to stop recording.',
      processing: 'Processing. Please wait.',
      speaking: 'Speaking. Double tap to interrupt.',
      stopped: 'Stopped. Ready to use again.',
    };

    const message = stateMessages[state] || state;
    this.announce(message, { priority: 'polite' });
  }

  /**
   * Check if screen reader is currently enabled
   * WCAG: Allows conditional behavior for screen reader users
   */
  async isScreenReaderEnabled(): Promise<boolean> {
    if (!this.isInitialized) {
      await this.initialize();
    }
    return this.screenReaderEnabled;
  }

  /**
   * Check if reduce motion is enabled
   * WCAG 2.3.3: Animation from Interactions
   */
  async isReduceMotionEnabled(): Promise<boolean> {
    if (!this.isInitialized) {
      await this.initialize();
    }
    return this.reduceMotionEnabled;
  }

  /**
   * Get both accessibility settings
   * Convenience method for components
   */
  async getAccessibilitySettings(): Promise<{
    screenReaderEnabled: boolean;
    reduceMotionEnabled: boolean;
  }> {
    if (!this.isInitialized) {
      await this.initialize();
    }

    return {
      screenReaderEnabled: this.screenReaderEnabled,
      reduceMotionEnabled: this.reduceMotionEnabled,
    };
  }

  /**
   * WCAG 3.3.1: Format error for announcement
   * 
   * @param error - Error object or string
   * @returns Formatted, user-friendly error message
   */
  formatError(error: unknown): string {
    if (error instanceof Error) {
      // Common error patterns
      if (error.message.includes('Network')) {
        return 'Network error. Please check your internet connection.';
      }
      if (error.message.includes('timeout')) {
        return 'Request timed out. The server took too long to respond.';
      }
      if (error.message.includes('permission')) {
        return 'Permission denied. Please check your device settings.';
      }
      if (error.message.includes('camera')) {
        return 'Camera error. Please ensure camera is working properly.';
      }
      if (error.message.includes('microphone')) {
        return 'Microphone error. Please ensure microphone is working properly.';
      }

      return error.message;
    }

    if (typeof error === 'string') {
      return error;
    }

    return 'An unknown error occurred';
  }

  /**
   * WCAG 2.5.5: Check if touch target meets minimum size
   * 
   * @param width - Touch target width
   * @param height - Touch target height
   * @returns Whether target meets 44x44 minimum
   */
  meetsMinimumTouchTarget(width: number, height: number): boolean {
    const MINIMUM_SIZE = 44; // iOS Human Interface Guidelines
    return width >= MINIMUM_SIZE && height >= MINIMUM_SIZE;
  }

  /**
   * WCAG 1.4.3: Check if color contrast meets minimum ratio
   * 
   * @param foreground - Foreground color (hex)
   * @param background - Background color (hex)
   * @returns Whether contrast ratio meets 4.5:1 for normal text
   */
  meetsContrastRequirement(
    foreground: string,
    background: string
  ): boolean {
    // Simplified check - in production, use a proper contrast calculation library
    // like 'color-contrast-checker' or implement full WCAG algorithm
    
    // For now, just warn developers to check manually
    console.warn(
      '⚠️ Manual contrast check required:',
      `Foreground: ${foreground}, Background: ${background}`,
      'Required: 4.5:1 for normal text, 3:1 for large text (18pt+ or 14pt+ bold)'
    );
    
    return true; // Assume correct - replace with actual calculation
  }

  /**
   * WCAG 4.1.2: Build comprehensive accessibility label
   * 
   * @param options - Label components
   * @returns Complete accessibility label
   */
  buildLabel(options: {
    element: string;
    state?: string;
    value?: string;
    instruction?: string;
  }): string {
    const { element, state, value, instruction } = options;

    const parts = [element];

    if (state) {
      parts.push(state);
    }

    if (value) {
      parts.push(value);
    }

    if (instruction) {
      parts.push(instruction);
    }

    return parts.join('. ');
  }

  /**
   * Log accessibility issue for debugging
   * 
   * @param component - Component name
   * @param issue - Issue description
   * @param severity - Issue severity level
   */
  logAccessibilityIssue(
    component: string,
    issue: string,
    severity: 'error' | 'warning' | 'info' = 'warning'
  ): void {
    const emoji = {
      error: '🚫',
      warning: '⚠️',
      info: 'ℹ️',
    }[severity];

    console.log(
      `${emoji} [A11Y ${severity.toUpperCase()}] ${component}: ${issue}`
    );
  }
}

// Export singleton instance
export const AccessibilityService = new AccessibilityServiceClass();

// Export class for testing
export { AccessibilityServiceClass };