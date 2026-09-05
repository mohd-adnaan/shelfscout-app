/**
 * The bounded-time primitives, and the two rules built on them.
 *
 * ── Why this file exists ───────────────────────────────────────────────────
 * `asyncWatchdog.ts` is the foundation of every anti-hang guarantee in this
 * app, and it had no tests at all. Its own doc comment describes the failure
 * it prevents — "the app is hung, closing and reopening fixes it" — which is
 * the bug that has come back repeatedly and is the reason the project's
 * reliability was questioned. A guarantee nobody has exercised is a belief.
 *
 * @format
 */

import {
  WATCHDOG_TIMEOUTS,
  isTimeoutError,
  nativeCall,
  withTimeout,
} from '../src/utils/asyncWatchdog';
import { isClaimFresh, isLatchStale } from '../src/utils/inputLiveness';

describe('withTimeout', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it('passes a value straight through when the call returns in time', async () => {
    await expect(withTimeout(Promise.resolve('ok'), 1000, 'fast')).resolves.toBe('ok');
  });

  it('propagates a real rejection rather than masking it as a timeout', async () => {
    const failure = new Error('native said no');
    await expect(withTimeout(Promise.reject(failure), 1000, 'failing')).rejects.toBe(failure);
  });

  it('escapes a call that never settles', async () => {
    // The whole point: a native promise whose resolver is never invoked. This
    // is what an unresponsive speech recogniser or a yanked audio session
    // looks like from JavaScript, and before the watchdog it meant the
    // enclosing `finally` never ran and the input latch stuck true forever.
    const neverSettles = new Promise<string>(() => {});
    const guarded = withTimeout(neverSettles, 5_000, 'hung native call');

    jest.advanceTimersByTime(5_000);

    await expect(guarded).rejects.toThrow(/timed out after 5000ms/);
    // Typed, not just message-matched: callers branch on this to tell "the
    // call failed" from "the call never answered".
    await guarded.catch(error => expect(isTimeoutError(error)).toBe(true));
  });

  it('does not leak an unhandled rejection when the orphan fails later', async () => {
    // The abandoned call still settles eventually, into a promise nobody is
    // waiting on. If that rejection escaped it would crash the app in dev and
    // be reported as an unrelated failure in the field.
    let rejectLate: (reason: unknown) => void = () => {};
    const late = new Promise<string>((_resolve, reject) => { rejectLate = reject; });

    const guarded = withTimeout(late, 1_000, 'late failure');
    jest.advanceTimersByTime(1_000);
    await expect(guarded).rejects.toThrow(/timed out/);

    // If `withTimeout` did not attach a rejection handler to the orphan, this
    // would surface as an unhandled rejection and take the app down in dev.
    // Settling it and letting the microtask queue drain is the assertion:
    // reaching the end of this test without an unhandled-rejection crash is
    // the proof.
    const unhandled = jest.fn();
    const globalWithProcess = globalThis as unknown as {
      process?: { on: Function; off: Function };
    };
    globalWithProcess.process?.on('unhandledRejection', unhandled);
    rejectLate(new Error('native failed long after we gave up'));
    await Promise.resolve();
    await Promise.resolve();
    globalWithProcess.process?.off('unhandledRejection', unhandled);

    expect(unhandled).not.toHaveBeenCalled();
  });
});

describe('nativeCall', () => {
  beforeEach(() => jest.useFakeTimers());
  afterEach(() => jest.useRealTimers());

  it('never rejects, whatever the native side does', async () => {
    // Every caller of this treats the result as best-effort and keeps going.
    // If it could throw, it would abort the very turn it exists to protect.
    await expect(
      nativeCall(() => Promise.reject(new Error('boom')), 1_000, 'rejecting', 'fallback'),
    ).resolves.toBe('fallback');

    await expect(
      nativeCall(() => { throw new Error('sync boom'); }, 1_000, 'throwing', 'fallback'),
    ).resolves.toBe('fallback');
  });

  it('returns the fallback when the call hangs, on time', async () => {
    const guarded = nativeCall(
      () => new Promise<string>(() => {}),
      WATCHDOG_TIMEOUTS.STT_CONTROL,
      'hung stt',
      'fallback',
    );
    jest.advanceTimersByTime(WATCHDOG_TIMEOUTS.STT_CONTROL);
    await expect(guarded).resolves.toBe('fallback');
  });
});

describe('isClaimFresh', () => {
  // The specific stale claim that disabled the turn watchdog: `sessionAlive`
  // from the AR bridge. Native pauses an offered session after ~120 s and
  // tells JavaScript nothing, so believing the claim indefinitely meant the
  // ONLY recovery path stayed switched off for the rest of the process.
  const TTL = 150_000;

  it('believes a claim inside its lifetime', () => {
    expect(isClaimFresh(1_000, TTL, 1_000 + TTL - 1)).toBe(true);
  });

  it('stops believing it the moment the lifetime is up', () => {
    expect(isClaimFresh(1_000, TTL, 1_000 + TTL)).toBe(false);
  });

  it('never believes a claim that was never made', () => {
    // The initial value. A zero timestamp must not read as "claimed at the
    // epoch and therefore ancient-but-set" or as fresh.
    expect(isClaimFresh(0, TTL, 5_000)).toBe(false);
  });
});

describe('isLatchStale', () => {
  const MAX_HOLD = 20_000;

  it('leaves a latch alone while it could still be legitimate work', () => {
    expect(isLatchStale(1_000, MAX_HOLD, 1_000 + MAX_HOLD - 1)).toBe(false);
  });

  it('reports a latch held past every bounded step inside it', () => {
    expect(isLatchStale(1_000, MAX_HOLD, 1_000 + MAX_HOLD)).toBe(true);
  });

  it('treats an unheld latch as fine', () => {
    expect(isLatchStale(0, MAX_HOLD, 10_000_000)).toBe(false);
  });
});
