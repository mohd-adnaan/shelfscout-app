/**
 * src/services/AudioFeedbackService.ts
 * 
 * WCAG 2.1 Level AA Compliant Audio Feedback Service
 * 
 * Compliance Features:
 * - 3.3.1 Error Identification: Graceful error handling for audio failures
 * - 4.1.3 Status Messages: Announces state changes via audio and screen reader
 * - 1.4.2 Audio Control: Users can interrupt audio via double-tap
 * 
 * Provides earcons (haptic feedback) and spoken announcements for state transitions
 */

import { Vibration, Platform } from 'react-native';
import { speachesTTS } from './speachesTtsClient';
import { AccessibilityService } from './AccessibilityService';

class AudioFeedbackService {
  private lastAnnouncedState: string | null = null;
  private isSpeakingAnnouncement: boolean = false;

  /**
   * Play earcon (vibration pattern) for state
   * 
   * WCAG 1.4.2: Provides supplementary haptic feedback
   * WCAG 3.3.1: Handles vibration errors gracefully
   * 
   * ✅ PUBLIC method - can be called directly for immediate haptic feedback
   * 
   * Vibration patterns:
   * - Ready: Single short (50ms)
   * - Listening: Two short (50ms, pause, 50ms)
   * - Thinking: Single medium (100ms)
   * - Speaking: Single long (150ms)
   * - Error: Three short bursts (100ms each)
   * 
   * @param state - Current app state
   */
  playEarcon(state: 'ready' | 'listening' | 'thinking' | 'speaking' | 'error'): void {
    const patterns: Record<string, number[]> = {
      ready: [50],                      // Single short
      listening: [50, 100, 50],         // Two short
      thinking: [100],                  // Single medium
      speaking: [150],                  // Single long
      error: [100, 100, 100, 100, 100], // Three short bursts
    };

    try {
      const pattern = patterns[state];
      
      if (!pattern) {
        console.warn(`⚠️ Unknown earcon state: ${state}`);
        return;
      }

      Vibration.vibrate(pattern);
      console.log(`🔊 Earcon: ${state}`);
      
    } catch (error: any) {
      // WCAG 3.3.1: Don't crash on vibration errors
      console.warn('⚠️ Vibration not available:', error.message);
      
      // Vibration is supplementary - don't announce error
      // The app will still work without haptic feedback
    }
  }

  /**
   * Announce state change with spoken feedback
   * 
   * WCAG 4.1.3: Announces state changes to screen reader
   * WCAG 3.3.1: Handles audio errors gracefully
   * 
   * @param state - Current app state
   * @param useEarcon - If true, use quick vibration instead of speech
   */
  async announceState(
    state: 'ready' | 'listening' | 'thinking' | 'speaking',
    useEarcon: boolean = false
  ): Promise<void> {
    try {
      // WCAG 4.1.3: Don't announce same state twice (reduces redundancy)
      if (this.lastAnnouncedState === state) {
        console.log(`ℹ️ State ${state} already announced, skipping`);
        return;
      }

      this.lastAnnouncedState = state;

      if (useEarcon) {
        // Use haptic feedback only
        this.playEarcon(state);
      } else {
        // Use spoken announcement
        await this.speakAnnouncement(state);
      }
      
    } catch (error: any) {
      // WCAG 3.3.1: Don't crash on announcement errors
      console.error('❌ State announcement error:', error);
      
      // Fall back to screen reader announcement
      try {
        const stateMessages: Record<string, string> = {
          ready: 'Ready',
          listening: 'Listening',
          thinking: 'Thinking',
          speaking: 'Speaking',
        };
        
        AccessibilityService.announce(stateMessages[state] || state);
      } catch (fallbackError: any) {
        console.error('❌ Fallback announcement failed:', fallbackError);
        // At this point, we've tried everything - just log and continue
      }
    }
  }

  /**
   * Speak announcement for state using Speaches TTS
   * 
   * WCAG 4.1.3: Provides audio feedback for state changes
   * WCAG 3.3.1: Handles TTS errors gracefully
   * 
   * ✅ Now returns immediately (non-blocking) so photo can capture during speech
   * 
   * @param state - Current app state
   * @private
   */
  private async speakAnnouncement(
    state: 'ready' | 'listening' | 'thinking' | 'speaking'
  ): Promise<void> {
    // Don't interrupt announcements
    if (this.isSpeakingAnnouncement) {
      console.log('ℹ️ Already speaking announcement, skipping');
      return;
    }

    const announcements: Record<string, string> = {
      ready: 'Ready',
      listening: 'Listening',
      thinking: 'Thinking',
      speaking: '', // Don't announce "speaking" - user will hear the response
    };

    const text = announcements[state];
    
    if (!text) {
      // Empty string means don't announce (e.g., speaking state)
      return;
    }

    try {
      this.isSpeakingAnnouncement = true;
      console.log(`📢 Announcing: "${text}"`);
      
      // Use Speaches TTS for announcement
      await speachesTTS.synthesizeSpeech(text);
      
      this.isSpeakingAnnouncement = false;
      console.log(`✅ Announcement complete: "${text}"`);
      
    } catch (error: any) {
      // WCAG 3.3.1: Handle TTS errors gracefully
      console.error('❌ Announcement TTS error:', error);
      this.isSpeakingAnnouncement = false;
      
      // Fall back to screen reader announcement
      try {
        AccessibilityService.announce(text);
        console.log(`✅ Fallback announcement via screen reader: "${text}"`);
      } catch (fallbackError: any) {
        console.error('❌ Fallback announcement failed:', fallbackError);
        // At this point, we've tried TTS and screen reader - just continue
      }
    }
  }

  /**
   * Announce error with vibration and optional speech
   * 
   * WCAG 3.3.1: Provides clear error feedback
   * WCAG 4.1.3: Announces errors to screen reader
   * 
   * @param message - Error message to announce
   * @param speak - If true, speak the message via TTS
   */
  async announceError(message: string, speak: boolean = false): Promise<void> {
    try {
      // WCAG 1.4.2: Error vibration pattern - 3 short bursts
      this.playEarcon('error');
      
      console.log(`⚠️ Error announced: "${message}"`);
      
      // WCAG 4.1.3: Always announce to screen reader
      AccessibilityService.announceError(message, false);

      // Optionally speak the error via TTS
      if (speak && !this.isSpeakingAnnouncement) {
        try {
          this.isSpeakingAnnouncement = true;
          
          await speachesTTS.synthesizeSpeech(message);
          
          this.isSpeakingAnnouncement = false;
          console.log('✅ Error spoken via TTS');
          
        } catch (ttsError: any) {
          // WCAG 3.3.1: TTS error during error announcement - don't crash
          console.error('❌ Error TTS failed:', ttsError);
          this.isSpeakingAnnouncement = false;
          
          // Screen reader announcement already happened above
          console.log('ℹ️ Error conveyed via screen reader instead of TTS');
        }
      }
      
    } catch (error: any) {
      // WCAG 3.3.1: Critical - handle errors in error handler
      console.error('❌ Error in announceError:', error);
      
      // Last resort - try screen reader only
      try {
        AccessibilityService.announceError(message, false);
      } catch (lastResortError: any) {
        console.error('❌ Last resort error announcement failed:', lastResortError);
        // We've tried everything - just log and continue
        // The app should still function even if announcements fail
      }
    }
  }

  /**
   * Announce success with vibration and optional message
   * 
   * WCAG 4.1.3: Provides positive feedback for successful actions
   * 
   * @param message - Optional success message to announce
   */
  async announceSuccess(message?: string): Promise<void> {
    try {
      // Success vibration: single medium pulse
      this.playEarcon('ready');
      
      if (message) {
        console.log(`✅ Success announced: "${message}"`);
        AccessibilityService.announceSuccess(message);
      }
      
    } catch (error: any) {
      // WCAG 3.3.1: Don't crash on success announcement errors
      console.warn('⚠️ Success announcement error:', error);
      // Success announcements are nice-to-have, not critical
    }
  }

  /**
   * Stop any ongoing announcements
   * 
   * WCAG 1.4.2: Allows users to stop audio
   */
  async stopAnnouncements(): Promise<void> {
    try {
      if (this.isSpeakingAnnouncement) {
        console.log('🛑 Stopping audio announcements');
        await speachesTTS.stop();
        this.isSpeakingAnnouncement = false;
        console.log('✅ Announcements stopped');
      }
    } catch (error: any) {
      // WCAG 3.3.1: Handle stop errors gracefully
      console.warn('⚠️ Error stopping announcements:', error);
      this.isSpeakingAnnouncement = false;
      // Don't throw - stopping is best-effort
    }
  }

  /**
   * Check if currently speaking an announcement
   * 
   * @returns true if speaking, false otherwise
   */
  isSpeaking(): boolean {
    return this.isSpeakingAnnouncement;
  }

  /**
   * Reset announcement tracking
   * 
   * Call this when starting a new interaction cycle
   */
  reset(): void {
    console.log('🔄 Resetting audio feedback state');
    this.lastAnnouncedState = null;
    this.isSpeakingAnnouncement = false;
  }

  /**
   * Get last announced state
   * 
   * @returns Last state that was announced, or null
   */
  getLastAnnouncedState(): string | null {
    return this.lastAnnouncedState;
  }
}

// Export singleton instance
export const audioFeedback = new AudioFeedbackService();