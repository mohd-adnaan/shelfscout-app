import { AccessibilityInfo } from 'react-native';
import { iOSTts } from '../src/services/iOSTtsClient';
import { speechOutput } from '../src/services/SpeechOutputService';

describe('SpeechOutputService', () => {
  let screenReaderSpy: jest.SpyInstance;
  let announceSpy: jest.SpyInstance;
  let stopSpy: jest.SpyInstance;
  let speakSpy: jest.SpyInstance;

  beforeEach(() => {
    screenReaderSpy = jest
      .spyOn(AccessibilityInfo, 'isScreenReaderEnabled')
      .mockResolvedValue(false);
    announceSpy = jest
      .spyOn(AccessibilityInfo, 'announceForAccessibility')
      .mockImplementation(jest.fn());
    stopSpy = jest.spyOn(iOSTts, 'stop').mockResolvedValue(undefined);
    speakSpy = jest.spyOn(iOSTts, 'synthesizeSpeech').mockResolvedValue(undefined);
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  it('routes speech through VoiceOver when a screen reader is enabled', async () => {
    screenReaderSpy.mockResolvedValue(true);

    await speechOutput.speak('Proceed to the shelf', { waitForScreenReader: false });

    expect(stopSpy).toHaveBeenCalledTimes(1);
    expect(announceSpy).toHaveBeenCalledWith('Proceed to the shelf');
    expect(speakSpy).not.toHaveBeenCalled();
  });

  it('uses native TTS when a screen reader is not enabled', async () => {
    screenReaderSpy.mockResolvedValue(false);
    announceSpy.mockClear();
    speakSpy.mockClear();

    await speechOutput.speak('Proceed to the shelf');

    expect(announceSpy).not.toHaveBeenCalled();
    expect(speakSpy).toHaveBeenCalledWith('Proceed to the shelf');
  });

  it('suppresses duplicate announcements inside the dedupe window', async () => {
    await speechOutput.announce('Navigation started', { dedupeWindowMs: 5000 });
    const announcedAgain = await speechOutput.announce('Navigation started', {
      dedupeWindowMs: 5000,
    });

    expect(announcedAgain).toBe(false);
    expect(announceSpy).toHaveBeenCalledTimes(1);
  });
});
