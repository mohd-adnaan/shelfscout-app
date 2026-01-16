/**
 * src/services/SpeachesSentenceChunker.ts
 * 
 * WCAG 2.1 Level AA Compliant Sentence-by-Sentence TTS with Smart Chunking
 * 
 * Compliance Features:
 * - 1.4.2 Audio Control: Users can stop audio at any time
 * - 3.3.1 Error Identification: Clear error messages for TTS failures
 * - 4.1.3 Status Messages: Announces when speech is interrupted
 * 
 * Provides fast perceived response by playing text in chunks
 * Critical for blind users who depend on audio feedback
 */

import { speachesTTS } from './speachesTtsClient';
import { AccessibilityService } from './AccessibilityService';

class SpeachesSentenceChunker {
  private isStopped: boolean = false;
  private isPlaying: boolean = false;
  private currentChunkIndex: number = 0;
  private totalChunks: number = 0;

  /**
   * Split text into smart chunks and speak sequentially
   * 
   * WCAG 1.4.2: Audio can be stopped at any time via stop()
   * WCAG 3.3.1: Provides clear error handling
   * WCAG 4.1.3: Announces when playback fails
   * 
   * Starts playing first chunk immediately for fast feedback.
   * Critical for blind users who rely on timely audio responses.
   * 
   * @param text - Text to speak in chunks
   * @throws Error with user-friendly message if chunking/playback fails
   */
  async synthesizeSpeechChunked(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    
    // WCAG 3.3.1: Validate input
    if (!trimmed) {
      console.warn('⚠️ No text provided for chunked TTS');
      return;
    }

    this.isStopped = false;
    this.isPlaying = true;
    this.currentChunkIndex = 0;

    try {
      // Split into smart chunks (sentences, but not too long)
      const chunks = this.splitIntoChunks(trimmed);
      this.totalChunks = chunks.length;
      
      console.log(`📝 Split into ${chunks.length} chunks for playback`);

      // WCAG 4.1.3: Announce that we're starting to speak
      // (This is handled by calling code, not duplicated here)

      // Play each chunk
      for (let i = 0; i < chunks.length; i++) {
        // WCAG 1.4.2: Check if user stopped playback
        if (this.isStopped) {
          console.log('⚠️ Playback stopped by user during chunk', i + 1);
          
          // WCAG 4.1.3: Announce interruption
          AccessibilityService.announce('Speech interrupted');
          
          break;
        }

        this.currentChunkIndex = i;
        const chunk = chunks[i];
        
        const preview = chunk.length > 40 
          ? chunk.substring(0, 40) + '...' 
          : chunk;
        
        console.log(`🎙️ Playing chunk ${i + 1}/${chunks.length}: "${preview}"`);

        try {
          // Use existing blocking TTS client for each chunk
          await speachesTTS.synthesizeSpeech(chunk);
          
          console.log(`✅ Chunk ${i + 1}/${chunks.length} played successfully`);
          
        } catch (error: any) {
          // WCAG 3.3.1: Handle chunk-specific errors
          console.error(`❌ Error playing chunk ${i + 1}:`, error);
          
          // Don't stop entire playback for one failed chunk
          // Continue with next chunk instead
          console.log(`ℹ️ Continuing with next chunk after error`);
          
          // If first chunk fails, announce the error
          if (i === 0) {
            const message = 'Audio playback issue. Trying to continue.';
            AccessibilityService.announceWarning(message);
          }
          
          // Continue loop to try next chunk
        }

        // WCAG 1.4.2: Check again after chunk finishes
        if (this.isStopped) {
          console.log('⚠️ Playback stopped by user after chunk', i + 1);
          AccessibilityService.announce('Speech interrupted');
          break;
        }

        // Small delay between chunks for natural flow
        if (i < chunks.length - 1 && !this.isStopped) {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }

      if (!this.isStopped) {
        console.log('✅ All chunks played successfully');
      }
      
    } catch (error: any) {
      // WCAG 3.3.1: Handle top-level errors
      console.error('❌ Chunked playback error:', error);
      
      // Format user-friendly error message
      let userMessage = 'Speech playback failed.';
      
      if (error.message?.includes('network')) {
        userMessage = 'Network error during speech playback. Please try again.';
      } else if (error.message?.includes('audio')) {
        userMessage = 'Audio playback error. Please check your device audio settings.';
      } else if (error.message) {
        userMessage = `Speech error: ${error.message}`;
      }
      
      // WCAG 4.1.3: Announce error
      AccessibilityService.announceError(userMessage, false);
      
      // Re-throw with user-friendly message
      throw new Error(userMessage);
      
    } finally {
      this.isPlaying = false;
      this.currentChunkIndex = 0;
      this.totalChunks = 0;
    }
  }

  /**
   * Split text into smart chunks for playback
   * 
   * - Prioritizes sentence boundaries
   * - Limits chunk size for faster initial response
   * - Handles edge cases gracefully
   * 
   * @param text - Text to split
   * @returns Array of text chunks
   * @private
   */
  private splitIntoChunks(text: string): string[] {
    const MAX_CHUNK_LENGTH = 200; // Characters per chunk for fast response
    const chunks: string[] = [];

    try {
      // First try to split by sentences
      const sentences = this.splitIntoSentences(text);

      let currentChunk = '';

      for (const sentence of sentences) {
        // If adding this sentence would make chunk too long, flush current chunk
        if (currentChunk.length > 0 && 
            currentChunk.length + sentence.length > MAX_CHUNK_LENGTH) {
          chunks.push(currentChunk.trim());
          currentChunk = sentence;
        } else {
          currentChunk += (currentChunk.length > 0 ? ' ' : '') + sentence;
        }
      }

      // Add remaining chunk
      if (currentChunk.trim().length > 0) {
        chunks.push(currentChunk.trim());
      }

      // If we still have no chunks (no sentence boundaries), split by length
      if (chunks.length === 0) {
        return this.splitByLength(text, MAX_CHUNK_LENGTH);
      }

      return chunks;
      
    } catch (error: any) {
      // WCAG 3.3.1: Fallback to simple splitting if smart splitting fails
      console.warn('⚠️ Smart chunking failed, using simple split:', error);
      return this.splitByLength(text, MAX_CHUNK_LENGTH);
    }
  }

  /**
   * Split text into sentences using multiple delimiters
   * 
   * FIXED: Uses ASCII quotes only, no Unicode characters
   * 
   * @param text - Text to split into sentences
   * @returns Array of sentences
   * @private
   */
  private splitIntoSentences(text: string): string[] {
    try {
      // Match sentences ending with . ! ? followed by space or end of string
      // Handles regular quotes and parentheses with ASCII characters only
      const sentenceRegex = /[^.!?]+[.!?]+(?:\s|$|(?=['"()]))|[^.!?]+$/g;
      const matches = text.match(sentenceRegex) || [];
      
      if (matches.length === 0) {
        return [text];
      }

      return matches
        .map(s => s.trim())
        .filter(s => s.length > 0);
        
    } catch (error: any) {
      // WCAG 3.3.1: Fallback if regex fails
      console.warn('⚠️ Sentence splitting failed, using full text:', error);
      return [text];
    }
  }

  /**
   * Split text by length when no sentence boundaries available
   * 
   * @param text - Text to split
   * @param maxLength - Maximum chunk length
   * @returns Array of text chunks
   * @private
   */
  private splitByLength(text: string, maxLength: number): string[] {
    const chunks: string[] = [];
    let currentIndex = 0;

    try {
      while (currentIndex < text.length) {
        let chunkEnd = Math.min(currentIndex + maxLength, text.length);

        // Try to break at word boundary if not at end
        if (chunkEnd < text.length) {
          const lastSpace = text.lastIndexOf(' ', chunkEnd);
          if (lastSpace > currentIndex) {
            chunkEnd = lastSpace;
          }
        }

        chunks.push(text.substring(currentIndex, chunkEnd).trim());
        currentIndex = chunkEnd + 1; // +1 to skip the space
      }

      return chunks.filter(c => c.length > 0);
      
    } catch (error: any) {
      // WCAG 3.3.1: Last resort - return full text as single chunk
      console.warn('⚠️ Length splitting failed, using full text:', error);
      return [text];
    }
  }

  /**
   * Stop playback
   * 
   * WCAG 1.4.2: Allows users to stop audio at any time
   * WCAG 4.1.3: Announces that speech was stopped
   */
  async stop(): Promise<void> {
    try {
      console.log('🛑 Stopping chunked TTS playback');
      
      this.isStopped = true;
      this.isPlaying = false;
      
      // Stop the underlying TTS client
      await speachesTTS.stop();
      
      console.log('✅ Chunked TTS stopped');
      
      // WCAG 4.1.3: Announce interruption
      // (This is handled by calling code to avoid duplicate announcements)
      
    } catch (error: any) {
      // WCAG 3.3.1: Handle stop errors gracefully
      console.warn('⚠️ Error stopping chunked TTS:', error);
      
      // Force stopped state anyway
      this.isStopped = true;
      this.isPlaying = false;
      
      // Don't throw - stopping is best-effort
    }
  }

  /**
   * Reset for new request
   * 
   * Call this before starting a new synthesis request
   */
  reset(): void {
    console.log('🔄 Resetting sentence chunker');
    this.isStopped = false;
    this.isPlaying = false;
    this.currentChunkIndex = 0;
    this.totalChunks = 0;
  }

  /**
   * Check if currently playing
   * 
   * @returns true if audio is playing, false otherwise
   */
  isCurrentlyPlaying(): boolean {
    return this.isPlaying;
  }

  /**
   * Get current playback progress
   * 
   * @returns Object with current chunk index and total chunks
   */
  getProgress(): { current: number; total: number; percentage: number } {
    const percentage = this.totalChunks > 0 
      ? Math.round((this.currentChunkIndex / this.totalChunks) * 100)
      : 0;
    
    return {
      current: this.currentChunkIndex + 1, // 1-indexed for display
      total: this.totalChunks,
      percentage,
    };
  }
}

export const speachesSentenceChunker = new SpeachesSentenceChunker();