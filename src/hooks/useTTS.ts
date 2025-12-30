import { useEffect } from 'react';
import { Platform } from 'react-native';
import Tts from 'react-native-tts';

export const useTTS = () => {
  useEffect(() => {
    const initTTS = async () => {
      try {
        // ✅ Configure TTS settings
        await Tts.setDefaultLanguage('en-US');
        await Tts.setDefaultRate(0.52);
        await Tts.setDefaultPitch(1.0);
        
        // ✅ iOS: Select best quality voice
        if (Platform.OS === 'ios') {
          try {
            const voices = await Tts.voices();
            console.log(`🎤 Found ${voices.length} voices`);
            
            const usVoices = voices.filter(v => v.language === 'en-US');
            console.log(`🇺🇸 US English voices: ${usVoices.length}`);
            
            // ✅ Priority: Samantha > Ava > Enhanced > Any US
            let bestVoice = usVoices.find(v => 
              v.id.toLowerCase().includes('samantha') || 
              v.name?.toLowerCase().includes('samantha')
            );
            
            if (!bestVoice) {
              bestVoice = usVoices.find(v => 
                v.id.toLowerCase().includes('ava') ||
                v.name?.toLowerCase().includes('ava')
              );
            }
            
            if (!bestVoice) {
              bestVoice = usVoices.find(v => 
                v.id.toLowerCase().includes('enhanced') ||
                v.id.toLowerCase().includes('premium')
              );
            }
            
            if (bestVoice) {
              await Tts.setDefaultVoice(bestVoice.id);
              console.log(`✅ Voice: ${bestVoice.name || bestVoice.id}`);
            } else if (usVoices[0]) {
              await Tts.setDefaultVoice(usVoices[0].id);
              console.log(`⚠️ Fallback voice: ${usVoices[0].name || usVoices[0].id}`);
            }
          } catch (voiceError) {
            console.error('⚠️ Voice selection failed:', voiceError);
          }
        }
        
        // ✅ Suppress annoying warnings
        Tts.addEventListener('tts-start', () => {});
        Tts.addEventListener('tts-progress', () => {});
        Tts.addEventListener('tts-finish', () => {});
        Tts.addEventListener('tts-cancel', () => {});
        
        console.log('✅ TTS initialized');
      } catch (error) {
        console.error('❌ TTS init error:', error);
      }
    };

    initTTS();

    return () => {
      try {
        Tts.removeAllListeners('tts-start');
        Tts.removeAllListeners('tts-progress');
        Tts.removeAllListeners('tts-finish');
        Tts.removeAllListeners('tts-cancel');
        Tts.stop();
      } catch (e) {}
    };
  }, []);

  const speak = async (text: string): Promise<void> => {
    try {
      console.log('🔊 Speaking:', text.substring(0, 50) + '...');
      
      // ✅ Stop any current speech
      await forceStop();
      
      // ✅ Wait for iOS to process
      await new Promise(resolve => setTimeout(resolve, 200));
      
      // ✅ Speak
      await Tts.speak(text);
      console.log('✅ TTS started');
      
    } catch (error) {
      console.error('❌ TTS error:', error);
    }
  };

  const stop = async (): Promise<void> => {
    await forceStop();
  };

  // ✅ NUCLEAR: Force stop TTS
  const forceStop = async (): Promise<void> => {
    try {
      console.log('🛑 Force stopping TTS...');
      
      if (Platform.OS === 'ios') {
        // ✅ Call stop 3x to be sure
        Tts.stop();
        await new Promise(resolve => setTimeout(resolve, 50));
        Tts.stop();
        await new Promise(resolve => setTimeout(resolve, 50));
        Tts.stop();
        
        // ✅ Nuclear: Speak empty to interrupt
        try {
          await Tts.speak('');
        } catch (e) {}
        
      } else {
        await Tts.stop();
      }
      
      console.log('✅ TTS stopped');
      
    } catch (error) {
      console.log('🛑 Stop complete');
    }
  };

  return { speak, stop };
};