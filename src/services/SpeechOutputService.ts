// src/services/SpeechOutputService.ts

import { AccessibilityInfo } from 'react-native';
import { iOSTts } from './iOSTtsClient';

const MIN_VOICEOVER_WAIT_MS = 900;
const MAX_VOICEOVER_WAIT_MS = 6500;
const VOICEOVER_WORDS_PER_MINUTE = 175;
const DEFAULT_ANNOUNCEMENT_DEDUPE_MS = 1200;

function estimateVoiceOverWaitMs(text: string): number {
  const words = text.trim().split(/\s+/).filter(Boolean).length;
  const spokenMs = (words / VOICEOVER_WORDS_PER_MINUTE) * 60_000;
  return Math.max(
    MIN_VOICEOVER_WAIT_MS,
    Math.min(MAX_VOICEOVER_WAIT_MS, Math.round(spokenMs)),
  );
}

function wait(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

class SpeechOutputService {
  private lastAnnouncementText = '';
  private lastAnnouncementAt = 0;

  async isScreenReaderEnabled(): Promise<boolean> {
    try {
      return await AccessibilityInfo.isScreenReaderEnabled();
    } catch (error) {
      console.warn('⚠️ Could not read screen reader state:', error);
      return false;
    }
  }

  async speak(text: string, options?: { waitForScreenReader?: boolean }): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      console.warn('⚠️ No text provided for speech output');
      return;
    }

    const screenReaderEnabled = await this.isScreenReaderEnabled();

    if (screenReaderEnabled) {
      await this.announce(trimmed, {
        dedupeWindowMs: DEFAULT_ANNOUNCEMENT_DEDUPE_MS,
        stopNativeSpeech: true,
      });

      if (options?.waitForScreenReader ?? true) {
        await wait(estimateVoiceOverWaitMs(trimmed));
      }
      return;
    }

    await iOSTts.synthesizeSpeech(trimmed);
  }

  async announce(
    text: string,
    options?: {
      dedupeWindowMs?: number;
      stopNativeSpeech?: boolean;
    },
  ): Promise<boolean> {
    const trimmed = (text || '').trim();
    if (!trimmed) {
      return false;
    }

    const now = Date.now();
    const dedupeWindowMs = options?.dedupeWindowMs ?? DEFAULT_ANNOUNCEMENT_DEDUPE_MS;

    if (
      trimmed === this.lastAnnouncementText &&
      now - this.lastAnnouncementAt < dedupeWindowMs
    ) {
      if (options?.stopNativeSpeech) {
        await this.stopNativeSpeech();
      }
      console.log('♿ Skipping duplicate announcement:', trimmed);
      return false;
    }

    this.lastAnnouncementText = trimmed;
    this.lastAnnouncementAt = now;

    if (options?.stopNativeSpeech) {
      await this.stopNativeSpeech();
    }

    AccessibilityInfo.announceForAccessibility(trimmed);
    return true;
  }

  async stopNativeSpeech(): Promise<void> {
    try {
      await iOSTts.stop();
    } catch (error) {
      console.warn('⚠️ Could not stop native TTS:', error);
    }
  }
}

export const speechOutput = new SpeechOutputService();
