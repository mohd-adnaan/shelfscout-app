/**
 * Audio session category selection.
 *
 * One boolean — `mixWithOthers` — is the whole reason blind users heard no
 * sound cues. `Sound.setCategory('Playback', false)` requests the session
 * EXCLUSIVELY, which interrupts VoiceOver and produced the '!pri' errors that
 * led to cues being suppressed entirely whenever a screen reader was running.
 *
 * Requesting a mixable session instead lets cues play alongside VoiceOver, so
 * the suppression is no longer needed. This test pins that: with screen-reader
 * mode on, the app must never ask for the session exclusively.
 *
 * @format
 */

import Sound from 'react-native-sound';
import {
  initSounds,
  prepareForRecording,
  setScreenReaderMode,
  setWearablesMode,
} from '../src/utils/soundEffects';

const setCategory = () => Sound.setCategory as unknown as jest.Mock;

describe('audio session category', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    setWearablesMode(false);
    setScreenReaderMode(false);
  });

  it('takes the session exclusively when no screen reader is running', async () => {
    await initSounds();

    expect(setCategory()).toHaveBeenCalledWith('Playback', false);
  });

  it('mixes rather than interrupting when a screen reader is running', async () => {
    setScreenReaderMode(true);
    await initSounds();

    expect(setCategory()).toHaveBeenCalledWith('Playback', true);
    expect(setCategory()).not.toHaveBeenCalledWith('Playback', false);
  });

  it('mixes on the recording category too', () => {
    setScreenReaderMode(true);
    prepareForRecording();

    expect(setCategory()).toHaveBeenCalledWith('PlayAndRecord', true);
  });

  it('never touches the category in glasses mode', async () => {
    // BluetoothHFP owns the session for the glasses microphone; any
    // setCategory call corrupts it and silently kills the mic.
    setWearablesMode(true);
    setScreenReaderMode(true);
    await initSounds();

    expect(setCategory()).not.toHaveBeenCalled();
  });
});
