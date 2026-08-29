/**
 * The spoken-length gate.
 *
 * The regression this guards: a scene description that ran close to a minute
 * of speech on 25 Aug 2026. A sighted reader skims a long paragraph; the user
 * this app is built for stands still through every word of it with no way to
 * skip ahead. `GroqVisionClient` had a 300-character cap that covered one
 * pipeline and gave up whenever its shorten pass failed, and the n8n backend
 * had none — so the guarantee has to live somewhere that every answer passes
 * through, and it has to be code rather than a prompt.
 *
 * @format
 */

import { SPOKEN_ANSWER_MAX_CHARS, trimSpokenAnswer } from '../src/utils/spokenAnswer';

describe('trimSpokenAnswer', () => {
  it('leaves an answer inside the budget exactly as it was', () => {
    const answer = 'The door is at your two o\'clock, about three steps ahead.';
    expect(trimSpokenAnswer(answer)).toBe(answer);
  });

  it('keeps whole sentences up to the budget and drops the rest', () => {
    const first = 'There is a desk directly ahead of you.';
    const second = 'A chair sits to its left, pushed in.';
    const filler = 'The wall behind carries a framed poster of a coastline.';
    const answer = `${first} ${second} ${filler} ${filler} ${filler} ${filler}`;

    const trimmed = trimSpokenAnswer(answer);

    expect(trimmed.length).toBeLessThanOrEqual(SPOKEN_ANSWER_MAX_CHARS);
    expect(trimmed.startsWith(first)).toBe(true);
    // Cut on a sentence boundary, never mid-word.
    expect(answer.startsWith(trimmed)).toBe(true);
    expect(trimmed).toMatch(/[.!?]$/);
  });

  it('never returns nothing, even when the first sentence alone overruns', () => {
    // No sentence boundary anywhere: the whole answer is one run-on clause,
    // which is precisely the shape a summarizer produces when it ignores its
    // instructions. Dropping it entirely would leave the user with silence.
    const answer = `${'a wide open room with '.repeat(40)}nothing else`;

    const trimmed = trimSpokenAnswer(answer);

    expect(trimmed.length).toBeGreaterThan(0);
    expect(trimmed.length).toBeLessThanOrEqual(SPOKEN_ANSWER_MAX_CHARS + 1);
    expect(trimmed).toMatch(/[.!?]$/);
    // Word boundary, not a slice through the middle of a word.
    expect(answer.startsWith(trimmed.replace(/\.$/, ''))).toBe(true);
  });

  it('preserves a decimal point rather than treating it as a sentence end', () => {
    const answer = `The shelf edge is 1.5 meters away. ${'Extra detail that does not fit. '.repeat(12)}`;
    const trimmed = trimSpokenAnswer(answer);
    expect(trimmed.startsWith('The shelf edge is 1.5 meters away.')).toBe(true);
  });

  it('survives a non-string answer without throwing', () => {
    expect(trimSpokenAnswer(undefined as unknown as string)).toBe('');
  });
});
