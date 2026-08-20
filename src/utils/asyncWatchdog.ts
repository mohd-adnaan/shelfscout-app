/**
 * src/utils/asyncWatchdog.ts
 *
 * Bounded-time primitives for every call that leaves JavaScript.
 *
 * Why this file exists
 * ────────────────────
 * A React Native promise returned by a native module settles only when native
 * code calls its resolver. If a delegate never fires, a view controller is
 * dismissed by something other than our own callback, or an audio session is
 * yanked mid-utterance, the resolver is simply never invoked. The `await` then
 * waits forever — and because every turn in this app is gated by a boolean
 * latch that is cleared in a `finally`, a `finally` that never runs leaves the
 * latch stuck true. Every subsequent tap hits `if (isProcessingRef.current)
 * return` and is silently swallowed.
 *
 * That is the "app is hung, closing and reopening fixes it" report from the
 * pilot studies. It is not a performance problem; the process is idle. It is a
 * liveness problem: nothing guarantees forward progress.
 *
 * The rule this file enforces: no `await` on a bounded native call without a
 * deadline. `withTimeout` when the caller needs to know it failed,
 * `nativeCall` when it should degrade quietly and let the turn keep moving.
 *
 * Deliberately NOT covered here: the long-running AR sessions. Navigation and
 * reaching run for as long as the user walks, so a fixed timeout would abort a
 * session that is working perfectly. Those are kept live by watchdogs on the
 * native side instead (see ARKitNavigationModule.presentationWatchdog), plus
 * the turn watchdog in App.tsx, which exempts an active AR session and catches
 * everything else.
 */

/** Thrown when a bounded call misses its deadline. */
export class TimeoutError extends Error {
  readonly label: string;
  readonly timeoutMs: number;

  constructor(label: string, timeoutMs: number) {
    super(`${label} timed out after ${timeoutMs}ms`);
    this.name = 'TimeoutError';
    this.label = label;
    this.timeoutMs = timeoutMs;
  }
}

export const isTimeoutError = (error: unknown): error is TimeoutError =>
  error instanceof TimeoutError ||
  (error as { name?: string } | null)?.name === 'TimeoutError';

/**
 * Default deadlines, in milliseconds.
 *
 * These are deliberately generous — roughly 3-5x the observed p99 — because a
 * timeout that fires on a merely-slow call is worse than the hang it replaces:
 * it would cut off speech the user is still listening to. The point is to
 * convert "forever" into "eventually", not to make the app twitchy.
 */
export const WATCHDOG_TIMEOUTS = {
  /** Native audio-session category switch, stop/cancel calls, earcons. */
  AUDIO_CONTROL: 4_000,
  /** One TTS chunk. Long chunks are ~20 words; 45s is far beyond worst case. */
  TTS_CHUNK: 45_000,
  /** Speech recognizer start/stop/cancel. */
  STT_CONTROL: 6_000,
  /** A single photo capture, including camera reactivation. */
  CAMERA_CAPTURE: 15_000,
  /** On-device Apple Foundation Models inference. */
  ON_DEVICE_LLM: 20_000,
  /** Tearing down an AR screen. */
  AR_TEARDOWN: 8_000,
} as const;

/**
 * Race `promise` against a deadline.
 *
 * The underlying promise is NOT cancelled — JS cannot cancel a native call.
 * Its eventual settlement is swallowed so it cannot surface as an unhandled
 * rejection. The caller gets control back on time; the orphaned native work
 * finishes into the void.
 *
 * @throws TimeoutError when the deadline passes first.
 */
export function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  label: string,
): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    let settled = false;

    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      console.warn(`⏱️ [watchdog] ${label} exceeded ${timeoutMs}ms — abandoning`);
      reject(new TimeoutError(label, timeoutMs));
    }, timeoutMs);

    promise.then(
      value => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      },
      error => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

/**
 * Bounded native call that degrades instead of throwing.
 *
 * Most native calls in this app are best-effort side effects — stop a sound,
 * switch an audio category, cancel a recognizer. If one wedges we want the
 * turn to keep moving, not to explode. `nativeCall` returns `fallback` on
 * timeout *or* on error, and never rejects.
 *
 * Use this for anything whose failure should not abort the user's turn. Use
 * `withTimeout` directly when the caller genuinely needs to know it failed.
 */
export async function nativeCall<T>(
  run: () => Promise<T>,
  timeoutMs: number,
  label: string,
  fallback: T,
): Promise<T> {
  try {
    return await withTimeout(Promise.resolve().then(run), timeoutMs, label);
  } catch (error: any) {
    if (isTimeoutError(error)) {
      console.warn(`⏱️ [watchdog] ${label} timed out — continuing with fallback`);
    } else {
      console.warn(`⚠️ [watchdog] ${label} failed: ${error?.message ?? error}`);
    }
    return fallback;
  }
}
