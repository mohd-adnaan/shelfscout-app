// src/services/SpeachesSentenceChunker.ts

import { AccessibilityService } from './AccessibilityService';
import { iOSTts } from './iOSTtsClient';
import { speechOutput } from './SpeechOutputService';

class SpeachesSentenceChunker {
  private isStopped: boolean = false;
  private isPlaying: boolean = false;
  private currentChunkIndex: number = 0;
  private totalChunks: number = 0;

  /**
   * SESSION ID — the key to the race condition fix.
   *
   * Incremented on every new synthesizeSpeechChunked() call.
   * Each loop iteration captures its own `mySession` snapshot.
   * If `this.sessionId !== mySession`, the loop knows it has been
   * superseded by a newer call and bails out immediately.
   */
  private sessionId: number = 0;

  // ──────────────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────────────

  /**
   * Split text into smart chunks and speak them sequentially.
   *
   * CRITICAL ORDERING (prevents race condition):
   *   1. Increment sessionId  ← invalidates any running loop immediately
   *   2. await this.stop()    ← stops underlying audio & sets isStopped=true
   *   3. Capture mySession    ← snapshot for this call's loop
   *   4. Reset isStopped=false ← safe now, old loops have already exited
   *   5. Enter chunk loop     ← guarded by BOTH isStopped AND sessionId check
   */
  async synthesizeSpeechChunked(text: string): Promise<void> {
    const trimmed = (text || '').trim();

    if (!trimmed) {
      console.warn('⚠️ No text provided for chunked TTS');
      return;
    }

    // ── STEP 1: Invalidate any running loop IMMEDIATELY ──────────────────────
    this.sessionId++;
    const mySession = this.sessionId;
    console.log(`🆕 TTS session ${mySession} starting`);

    // ── STEP 2: Stop previous audio BEFORE touching isStopped ────────────────
    // stop() sets this.isStopped = true.
    // Any loop still running from a previous session will see isStopped=true
    // and bail out on its next guard check — BEFORE we reset it below.
    await this.stop();

    // ── STEP 3: Guard — if another call snuck in while we were stopping ───────
    if (this.sessionId !== mySession) {
      console.log(`⏩ Session ${mySession} superseded before starting — aborting`);
      return;
    }

    if (await speechOutput.isScreenReaderEnabled()) {
      this.isStopped = false;
      this.isPlaying = true;
      this.currentChunkIndex = 0;
      this.totalChunks = 1;

      try {
        console.log(`♿ Session ${mySession}: routing speech through screen reader`);
        await speechOutput.speak(trimmed);
      } finally {
        if (this.sessionId === mySession) {
          this.isPlaying = false;
        }
      }
      return;
    }

    // ── STEP 4: Safe to reset now. Old loops have exited. ─────────────────────
    this.isStopped = false;
    this.isPlaying = true;
    this.currentChunkIndex = 0;

    try {
      const chunks = this.splitIntoChunks(trimmed);
      this.totalChunks = chunks.length;
      console.log(`📝 Session ${mySession}: split into ${chunks.length} chunk(s)`);

      // ── STEP 5: Chunk loop guarded by BOTH isStopped AND sessionId ───────────
      for (let i = 0; i < chunks.length; i++) {

        // Guard A: explicit stop() was called
        if (this.isStopped) {
          console.log(`🛑 Session ${mySession}: isStopped=true at chunk ${i + 1} — breaking`);
          AccessibilityService.announce('Speech interrupted');
          break;
        }

        // Guard B: a newer call started — this session is stale
        if (this.sessionId !== mySession) {
          console.log(`⏩ Session ${mySession} superseded at chunk ${i + 1} — breaking`);
          break;
        }

        this.currentChunkIndex = i;
        const chunk = chunks[i];
        const preview = chunk.length > 40 ? chunk.substring(0, 40) + '...' : chunk;
        console.log(`🎙️ Session ${mySession} — chunk ${i + 1}/${chunks.length}: "${preview}"`);

        try {
          await iOSTts.synthesizeSpeech(chunk);
          console.log(`✅ Session ${mySession} — chunk ${i + 1}/${chunks.length} done`);
        } catch (chunkError: any) {
          console.error(`❌ Session ${mySession} — chunk ${i + 1} error:`, chunkError);
          if (i === 0) {
            AccessibilityService.announceWarning('Audio playback issue. Trying to continue.');
          }
          // Don't abort entire session for one chunk error — continue to next
        }

        // Post-chunk guards (stop() may have been called during playback)
        if (this.isStopped || this.sessionId !== mySession) {
          console.log(`🛑 Session ${mySession}: invalidated after chunk ${i + 1} — breaking`);
          if (this.isStopped) AccessibilityService.announce('Speech interrupted');
          break;
        }

        // Small natural gap between chunks
        if (i < chunks.length - 1) {
          await new Promise<void>(resolve => setTimeout(() => resolve(), 100));
        }
      }

      if (this.sessionId === mySession && !this.isStopped) {
        console.log(`✅ Session ${mySession}: all chunks complete`);
      }

    } catch (error: any) {
      console.error(`❌ Session ${mySession}: top-level error:`, error);

      let userMessage = 'Speech playback failed.';
      if (error.message?.includes('network')) {
        userMessage = 'Network error during speech playback. Please try again.';
      } else if (error.message?.includes('audio')) {
        userMessage = 'Audio playback error. Please check your device audio settings.';
      }

      if (this.sessionId === mySession) {
        AccessibilityService.announceError(userMessage, false);
      }
    } finally {
      // Only update shared isPlaying if this session is still the active one
      if (this.sessionId === mySession) {
        this.isPlaying = false;
      }
    }
  }

  /**
   * Stop all playback immediately.
   *
   * Sets isStopped=true FIRST so that any running chunk loop sees it
   * on its next iteration.
   */
  async stop(): Promise<void> {
    try {
      console.log('🛑 SpeachesSentenceChunker: stop() called');

      // Flag first — loop checks this between every chunk
      this.isStopped = true;
      this.isPlaying = false;

      // Stop underlying audio
      await iOSTts.stop();

      console.log('✅ SpeachesSentenceChunker: stopped');
    } catch (error: any) {
      console.warn('⚠️ Error stopping chunked TTS (non-fatal):', error);
      // Force state regardless
      this.isStopped = true;
      this.isPlaying = false;
    }
  }

  /**
   * Reset for a brand-new interaction cycle.
   * NOTE: Do NOT reset sessionId — it must keep incrementing globally.
   */
  reset(): void {
    console.log('🔄 SpeachesSentenceChunker: reset');
    this.isStopped = false;
    this.isPlaying = false;
    this.currentChunkIndex = 0;
    this.totalChunks = 0;
  }

  isCurrentlyPlaying(): boolean {
    return this.isPlaying;
  }

  getProgress(): { current: number; total: number; percentage: number } {
    const percentage = this.totalChunks > 0
      ? Math.round((this.currentChunkIndex / this.totalChunks) * 100)
      : 0;
    return {
      current: this.currentChunkIndex + 1,
      total: this.totalChunks,
      percentage,
    };
  }

  // ──────────────────────────────────────────────────────────────────────────
  // Text splitting helpers
  // ──────────────────────────────────────────────────────────────────────────

  private splitIntoChunks(text: string): string[] {
    const MAX_CHUNK_LENGTH = 200;

    try {
      if (text.length <= MAX_CHUNK_LENGTH) {
        return [text];
      }

      const sentences = this.splitIntoSentences(text);

      if (sentences.length <= 1) {
        return this.splitByLength(text, MAX_CHUNK_LENGTH);
      }

      const chunks: string[] = [];
      let currentChunk = '';

      for (const sentence of sentences) {
        if (currentChunk.length + sentence.length + 1 <= MAX_CHUNK_LENGTH) {
          currentChunk = currentChunk ? `${currentChunk} ${sentence}` : sentence;
        } else {
          if (currentChunk) {
            chunks.push(currentChunk.trim());
          }
          if (sentence.length > MAX_CHUNK_LENGTH) {
            const subChunks = this.splitByLength(sentence, MAX_CHUNK_LENGTH);
            chunks.push(...subChunks.slice(0, -1));
            currentChunk = subChunks[subChunks.length - 1] || '';
          } else {
            currentChunk = sentence;
          }
        }
      }

      if (currentChunk.trim()) {
        chunks.push(currentChunk.trim());
      }

      return chunks.filter(c => c.length > 0);

    } catch (error: any) {
      console.warn('⚠️ Chunk splitting failed, using full text:', error);
      return [text];
    }
  }

  private splitIntoSentences(text: string): string[] {
    try {
      const sentenceRegex = /[^.!?]+[.!?]+(?:\s|$|(?=['"()]))|[^.!?]+$/g;
      const matches = text.match(sentenceRegex) || [];
      if (matches.length === 0) return [text];
      return matches.map(s => s.trim()).filter(s => s.length > 0);
    } catch {
      return [text];
    }
  }

  private splitByLength(text: string, maxLength: number): string[] {
    const chunks: string[] = [];
    let currentIndex = 0;

    try {
      while (currentIndex < text.length) {
        let chunkEnd = Math.min(currentIndex + maxLength, text.length);
        if (chunkEnd < text.length) {
          const lastSpace = text.lastIndexOf(' ', chunkEnd);
          if (lastSpace > currentIndex) chunkEnd = lastSpace;
        }
        chunks.push(text.substring(currentIndex, chunkEnd).trim());
        currentIndex = chunkEnd + 1;
      }
      return chunks.filter(c => c.length > 0);
    } catch {
      return [text];
    }
  }
}

export const speachesSentenceChunker = new SpeachesSentenceChunker();
