// src/services/SpeachesSentenceChunker.ts
// ----------------------------------------------------------------------
// Sentence-by-Sentence TTS with Smart Chunking
// Provides fast perceived response by playing text in chunks
// ----------------------------------------------------------------------

import { speachesTTS } from './speachesTtsClient';

class SpeachesSentenceChunker {
  private isStopped: boolean = false;
  private isPlaying: boolean = false;

  /**
   * Split text into smart chunks and speak sequentially
   * Starts playing first chunk immediately for fast feedback
   */
  async synthesizeSpeechChunked(text: string): Promise<void> {
    const trimmed = (text || '').trim();
    if (!trimmed) return;

    this.isStopped = false;
    this.isPlaying = true;

    // Split into smart chunks (sentences, but not too long)
    const chunks = this.splitIntoChunks(trimmed);
    console.log(`📝 Split into ${chunks.length} chunks for playback`);

    try {
      // Play each chunk
      for (let i = 0; i < chunks.length; i++) {
        if (this.isStopped) {
          console.log('⚠️ Stopped during chunk playback');
          break;
        }

        const chunk = chunks[i];
        console.log(`🎙️ Playing chunk ${i + 1}/${chunks.length}: "${chunk.substring(0, 40)}..."`);

        try {
          // Use existing blocking TTS client for each chunk
          await speachesTTS.synthesizeSpeech(chunk);
        } catch (error) {
          console.error(`❌ Error playing chunk ${i}:`, error);
          // Continue with next chunk instead of stopping
        }

        // Small delay between chunks for natural flow
        if (i < chunks.length - 1 && !this.isStopped) {
          await new Promise(resolve => setTimeout(resolve, 100));
        }
      }

      console.log('✅ All chunks played successfully');
    } catch (error) {
      console.error('❌ Chunked playback error:', error);
      throw error;
    } finally {
      this.isPlaying = false;
    }
  }

  /**
   * Split text into smart chunks for playback
   * - Prioritizes sentence boundaries
   * - Limits chunk size for faster initial response
   * - Handles edge cases gracefully
   */
  private splitIntoChunks(text: string): string[] {
    const MAX_CHUNK_LENGTH = 200; // Characters per chunk for fast response
    const chunks: string[] = [];

    // First try to split by sentences
    const sentences = this.splitIntoSentences(text);

    let currentChunk = '';

    for (const sentence of sentences) {
      // If adding this sentence would make chunk too long, flush current chunk
      if (currentChunk.length > 0 && currentChunk.length + sentence.length > MAX_CHUNK_LENGTH) {
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
  }

  /**
   * Split text into sentences using multiple delimiters
   * FIXED: Uses ASCII quotes only, no Unicode characters
   */
  private splitIntoSentences(text: string): string[] {
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
  }

  /**
   * Split text by length when no sentence boundaries available
   */
  private splitByLength(text: string, maxLength: number): string[] {
    const chunks: string[] = [];
    let currentIndex = 0;

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
  }

  /**
   * Stop playback
   */
  async stop(): Promise<void> {
    this.isStopped = true;
    this.isPlaying = false;
    
    // Stop the underlying TTS client
    await speachesTTS.stop();
  }

  /**
   * Reset for new request
   */
  reset(): void {
    this.isStopped = false;
    this.isPlaying = false;
  }

  /**
   * Check if currently playing
   */
  isCurrentlyPlaying(): boolean {
    return this.isPlaying;
  }
}

export const speachesSentenceChunker = new SpeachesSentenceChunker();