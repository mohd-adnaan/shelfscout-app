import RNFS from 'react-native-fs';
import AudioRecord from 'react-native-audio-record';

/**
 * Configuration matching N8N STT workflow
 */
const SPEACHES_STT_CONFIG = {
  // ✅ Public endpoint for transcription
  sttUrl: 'https://cybersight.cim.mcgill.ca/speaches/v1/audio/transcriptions',
  
  // ✅ STT Parameters (from N8N workflow)
  model: 'Systran/faster-distil-whisper-small.en',
  language: 'en',
  
  // ✅ API Key (same as TTS)
  apiKey: 'dev-test-key-change-in-production',
};

/**
 * Speaches STT Client
 * * Records audio and sends to Speaches API for transcription.
 * Used on Android only (iOS uses native voice recognition).
 */
class SpeachesSttClient {
  private currentRecordingPath: string = '';
  private isRecording: boolean = false;

  constructor() {
    console.log('✅ Speaches STT Client initialized (Android)');
  }

  /**
   * Start recording audio
   * * @returns Promise that resolves when recording starts
   */
  async startRecording(): Promise<void> {
    try {
      if (this.isRecording) {
        console.warn('⚠️ Already recording');
        return;
      }

      // ✅ Use a simple filename, NOT a full path
      // react-native-audio-record on Android expects a filename in the files directory
      const timestamp = Date.now();
      const filename = `recording_${timestamp}.wav`;
      
      // Store the expected full path just in case we need it, but rely on stop() return
      this.currentRecordingPath = `${RNFS.DocumentDirectoryPath}/${filename}`;

      console.log('🎤 Starting audio recording...');
      console.log('📁 Target filename:', filename);

      const options = {
        sampleRate: 16000,  // 16kHz for speech recognition
        channels: 1,         // Mono
        bitsPerSample: 16,
        audioSource: 6,      // VOICE_RECOGNITION
        wavFile: filename,   // ✅ FIX: Pass ONLY the filename
      };
      
      AudioRecord.init(options);

      // ✅ Start recording
      AudioRecord.start();
      this.isRecording = true;

      console.log('✅ Recording started');
    } catch (error) {
      console.error('❌ Start recording error:', error);
      throw error;
    }
  }

  /**
   * Stop recording and transcribe audio
   * * @returns Promise that resolves with transcript text
   */
  async stopRecordingAndTranscribe(): Promise<string> {
    try {
      if (!this.isRecording) {
        console.warn('⚠️ Not recording');
        return '';
      }

      console.log('🛑 Stopping audio recording...');

      // ✅ FIX: Stop recording and GET THE ACTUAL FILE PATH
      const audioFile = await AudioRecord.stop();
      this.isRecording = false;

      console.log('✅ Recording stopped');
      console.log('📁 Recorded file path:', audioFile);

      // ✅ Use the path returned by the library
      let filePathToUse = audioFile;
      
      if (!filePathToUse) {
          console.warn('⚠️ No path returned from stop(), using fallback');
          filePathToUse = this.currentRecordingPath;
      }
      
      // Ensure we don't have double file:// if the library returns it
      if (filePathToUse.startsWith('file://')) {
          filePathToUse = filePathToUse.replace('file://', '');
      }

      // ✅ Verify file exists
      const exists = await RNFS.exists(filePathToUse);
      if (!exists) {
        console.error('❌ File not found at:', filePathToUse);
        
        // Debug directory
        try {
            const files = await RNFS.readDir(RNFS.DocumentDirectoryPath);
            console.log('📂 Files in directory:', files.map(f => f.name));
        } catch (e) { }
        
        throw new Error(`Audio file not found: ${filePathToUse}`);
      }

      // ✅ Check file size
      const stat = await RNFS.stat(filePathToUse);
      console.log('📊 File size:', stat.size, 'bytes');

      // ✅ Transcribe the audio file
      const transcript = await this.transcribeAudioFile(filePathToUse);

      // ✅ Cleanup audio file
      await this.cleanup(filePathToUse);

      return transcript;
    } catch (error) {
      console.error('❌ Stop recording error:', error);
      throw error;
    }
  }

  /**
   * Transcribe an audio file using Speaches API
   * * @param audioPath - Path to audio file
   * @returns Promise that resolves with transcript text
   */
  private async transcribeAudioFile(audioPath: string): Promise<string> {
    try {
      console.log('🎤 Transcribing audio:', audioPath);

      // ✅ Create FormData (multipart/form-data)
      const formData = new FormData();
      
      formData.append('model', SPEACHES_STT_CONFIG.model);

      // ✅ Add audio file
      formData.append('file', {
        uri: `file://${audioPath}`, // Ensure URI scheme is present for FormData
        type: 'audio/wav',
        name: 'audio.wav',
      } as any);

      // ✅ Build headers
      const headers: Record<string, string> = {
        'Content-Type': 'multipart/form-data',
        'accept': 'application/json',
      };

      if (SPEACHES_STT_CONFIG.apiKey) {
        headers['Authorization'] = `Bearer ${SPEACHES_STT_CONFIG.apiKey}`;
        headers['X-API-Key'] = SPEACHES_STT_CONFIG.apiKey;
      }

      console.log('📤 Sending transcription request to:', SPEACHES_STT_CONFIG.sttUrl);

      const response = await fetch(SPEACHES_STT_CONFIG.sttUrl, {
        method: 'POST',
        headers,
        body: formData,
      });

      if (!response.ok) {
        const errorBody = await response.text().catch(() => '');
        throw new Error(`Speaches STT failed: ${response.status} ${errorBody}`);
      }

      const result = await response.json();
      console.log('✅ Transcription result:', result);

      const transcript = result.text || '';
      console.log('📝 Transcript:', transcript);

      return transcript;
    } catch (error) {
      console.error('❌ Transcription error:', error);
      throw error;
    }
  }

  /**
   * Cancel current recording
   */
  async cancelRecording(): Promise<void> {
    try {
      if (this.isRecording) {
        const file = await AudioRecord.stop();
        this.isRecording = false;
        if (file) await this.cleanup(file);
      }
    } catch (error) {
      console.error('❌ Cancel recording error:', error);
    }
  }

  private async cleanup(filePath: string): Promise<void> {
    try {
      const exists = await RNFS.exists(filePath);
      if (exists) {
        await RNFS.unlink(filePath);
        console.log('🗑️ Deleted audio file:', filePath);
      }
    } catch (error) {
      console.warn('⚠️ Could not delete audio file:', error);
    }
  }

  isCurrentlyRecording(): boolean {
    return this.isRecording;
  }
}

export const speachesSTT = new SpeachesSttClient();