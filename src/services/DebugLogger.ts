/**
 * src/services/DebugLogger.ts
 *
 * Singleton debug logger for ShelfScout mobile app.
 * Intercepts console.log / console.error / console.warn and stores
 * timestamped entries. Provides a subscriber pattern so the
 * DebugOverlay can update in real-time.
 *
 * ── Design notes ──
 * - Max 500 entries kept in memory (oldest pruned automatically).
 * - No TTS or accessibility announcements — purely visual debugging.
 * - Safe to import anywhere; the interceptors are installed once via init().
 */

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export type LogLevel = 'log' | 'warn' | 'error' | 'api' | 'api-error';

export interface LogEntry {
  id: number;
  timestamp: number;       // Date.now()
  level: LogLevel;
  message: string;
  /** Optional truncated detail (e.g. response body preview) */
  detail?: string;
}

type Subscriber = (entries: LogEntry[]) => void;

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const MAX_ENTRIES = 500;
const MAX_MSG_LENGTH = 300;

// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

class DebugLoggerClass {
  private entries: LogEntry[] = [];
  private subscribers: Set<Subscriber> = new Set();
  private nextId = 1;
  private initialized = false;

  /** Original console methods — never lost */
  private origLog = console.log;
  private origWarn = console.warn;
  private origError = console.error;

  // ── Public API ──────────────────────────────────────────────────────────

  /**
   * Install the console interceptors. Safe to call multiple times —
   * only the first call takes effect.
   */
  init(): void {
    if (this.initialized) return;
    this.initialized = true;

    // Intercept console.log
    console.log = (...args: any[]) => {
      this.origLog(...args);
      this.push('log', args);
    };

    // Intercept console.warn
    console.warn = (...args: any[]) => {
      this.origWarn(...args);
      this.push('warn', args);
    };

    // Intercept console.error
    console.error = (...args: any[]) => {
      this.origError(...args);
      this.push('error', args);
    };

    this.origLog('[DebugLogger] Initialized — interceptors installed');
  }

  /**
   * Manually add an API-level log (for explicit fetch/axios tracking).
   */
  logAPI(message: string, detail?: string): void {
    this.addEntry('api', message, detail);
  }

  /**
   * Manually add an API error log.
   */
  logAPIError(message: string, detail?: string): void {
    this.addEntry('api-error', message, detail);
  }

  /** Get all current entries (newest last). */
  getAll(): LogEntry[] {
    return this.entries;
  }

  /** Clear all entries. */
  clear(): void {
    this.entries = [];
    this.notify();
  }

  /** Subscribe to live updates. Returns an unsubscribe function. */
  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    return () => {
      this.subscribers.delete(fn);
    };
  }

  // ── Internals ───────────────────────────────────────────────────────────

  private push(level: LogLevel, args: any[]): void {
    const message = args
      .map(a => {
        if (typeof a === 'string') return a;
        try {
          return JSON.stringify(a);
        } catch {
          return String(a);
        }
      })
      .join(' ');

    this.addEntry(level, message);
  }

  private addEntry(level: LogLevel, message: string, detail?: string): void {
    const truncated =
      message.length > MAX_MSG_LENGTH
        ? message.slice(0, MAX_MSG_LENGTH) + '…'
        : message;

    const entry: LogEntry = {
      id: this.nextId++,
      timestamp: Date.now(),
      level,
      message: truncated,
      detail: detail
        ? detail.length > MAX_MSG_LENGTH
          ? detail.slice(0, MAX_MSG_LENGTH) + '…'
          : detail
        : undefined,
    };

    this.entries.push(entry);

    // Prune oldest when over limit
    if (this.entries.length > MAX_ENTRIES) {
      this.entries = this.entries.slice(this.entries.length - MAX_ENTRIES);
    }

    this.notify();
  }

  private notify(): void {
    const snapshot = this.entries;
    this.subscribers.forEach(fn => {
      try {
        fn(snapshot);
      } catch {
        // Subscriber errors must never crash the logger
      }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Export singleton
// ─────────────────────────────────────────────────────────────────────────────

export const debugLogger = new DebugLoggerClass();