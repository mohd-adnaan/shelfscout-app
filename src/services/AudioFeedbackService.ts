// src/services/AudioFeedbackService.ts
// ----------------------------------------------------------------------
// Audio Feedback for Accessibility - UPDATED
// Provides earcons and spoken announcements for state transitions
// ----------------------------------------------------------------------

import { speachesTTS } from './speachesTtsClient';
import { Vibration } from 'react-native';

class AudioFeedbackService {
  private lastAnnouncedState: string | null = null;
  private isSpeakingAnnouncement: boolean = false;

  /**
   * Play earcon (vibration pattern) for state
   * ✅ PUBLIC method - can be called directly for immediate haptic feedback
   * 
   * Vibration patterns:
   * - Ready: Single short (50ms)
   * - Listening: Two short (50ms, pause, 50ms)
   * - Thinking: Single medium (100ms)
   * - Speaking: Single long (150ms)
   */
  playEarcon(state: 'ready' | 'listening' | 'thinking' | 'speaking'): void {
    const patterns = {
      ready: [50],                    // Single short
      listening: [50, 100, 50],       // Two short
      thinking: [100],                // Single medium
      speaking: [150],                // Single long
    };

    try {
      Vibration.vibrate(patterns[state]);
      console.log(`🔊 Earcon: ${state}`);
    } catch (error) {
      console.warn('⚠️ Vibration not available:', error);
    }
  }

  /**
   * Announce state change with spoken feedback
   * 
   * @param state - Current app state
   * @param useEarcon - If true, use quick vibration instead of speech
   */
  async announceState(
    state: 'ready' | 'listening' | 'thinking' | 'speaking',
    useEarcon: boolean = false
  ): Promise<void> {
    // Don't announce same state twice
    if (this.lastAnnouncedState === state) {
      return;
    }

    this.lastAnnouncedState = state;

    if (useEarcon) {
      this.playEarcon(state);
    } else {
      // ✅ Don't wait for announcement - let it play in background
      this.speakAnnouncement(state);
    }
  }

  /**
   * Speak announcement for state using Speaches TTS
   * ✅ Now returns immediately (non-blocking) so photo can capture during speech
   * 
   * @param state - Current app state
   */
  private async speakAnnouncement(state: 'ready' | 'listening' | 'thinking' | 'speaking'): Promise<void> {
    if (this.isSpeakingAnnouncement) {
      return; // Don't interrupt announcements
    }

    const announcements = {
      ready: 'Ready',
      listening: 'Listening',
      thinking: 'Thinking',
      speaking: '', // Don't announce "speaking" - user will hear the response
    };

    const text = announcements[state];
    if (!text) return;

    try {
      this.isSpeakingAnnouncement = true;
      console.log(`📢 Announcing: "${text}"`);
      
      // Use Speaches TTS for announcement
      await speachesTTS.synthesizeSpeech(text);
      
      this.isSpeakingAnnouncement = false;
    } catch (error) {
      console.error('❌ Announcement error:', error);
      this.isSpeakingAnnouncement = false;
    }
  }

  /**
   * Announce error with vibration and optional speech
   * 
   * @param message - Error message to announce
   * @param speak - If true, speak the message
   */
  async announceError(message: string, speak: boolean = false): Promise<void> {
    // Error vibration: 3 short bursts
    try {
      Vibration.vibrate([100, 100, 100, 100, 100]);
    } catch (error) {
      console.warn('⚠️ Vibration not available:', error);
    }

    if (speak && !this.isSpeakingAnnouncement) {
      try {
        this.isSpeakingAnnouncement = true;
        await speachesTTS.synthesizeSpeech(message);
        this.isSpeakingAnnouncement = false;
      } catch (error) {
        console.error('❌ Error announcement failed:', error);
        this.isSpeakingAnnouncement = false;
      }
    }
  }

  /**
   * Reset announcement tracking
   */
  reset(): void {
    this.lastAnnouncedState = null;
    this.isSpeakingAnnouncement = false;
  }
}

// Export singleton instance
export const audioFeedback = new AudioFeedbackService();