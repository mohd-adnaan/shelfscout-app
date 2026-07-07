/**
 * src/services/DebugLogger.ts
 *
 * Singleton debug logger for ShelfScout / CyberSight mobile app.
 * Intercepts console.log / console.error / console.warn, stores
 * timestamped entries, and supports structured export for research.
 *
 * ── Design notes ──
 * - Max 5 000 entries in memory (oldest pruned automatically).
 * - Stores full-length raw messages for export; UI gets truncated view.
 * - Session tracking with auto-increment + manual markers.
 * - Export as JSON (structured metadata envelope) or CSV (flat tabular).
 * - No TTS or accessibility announcements — purely visual debugging.
 * - Safe to import anywhere; interceptors install once via init().
 */

import { Platform } from 'react-native';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export type LogLevel = 'log' | 'warn' | 'error' | 'api' | 'api-error' | 'session';

export interface LogEntry {
  id: number;
  timestamp: number;           // Date.now()
  level: LogLevel;
  /** Truncated for UI display (≤ 300 chars) */
  message: string;
  /** Full-length message preserved for export */
  rawMessage: string;
  /** Optional detail (truncated for UI) */
  detail?: string;
  /** Full-length detail preserved for export */
  rawDetail?: string;
  /** Session number this entry belongs to (1-based) */
  session: number;
}

/** Metadata included in every JSON export. */
export interface ExportMetadata {
  format_version: string;
  app_name: string;
  export_timestamp: string;
  export_timestamp_ms: number;
  platform: string;
  os_version: string;
  total_entries: number;
  total_sessions: number;
  first_entry_at: string | null;
  last_entry_at: string | null;
  duration_ms: number;
  filter_applied: string;
}

export interface ExportEnvelope {
  metadata: ExportMetadata;
  summary: {
    counts_by_level: Record<string, number>;
    counts_by_session: Record<number, number>;
    api_calls: number;
    errors: number;
  };
  entries: Array<{
    id: number;
    timestamp: string;       // ISO 8601
    timestamp_ms: number;
    elapsed_ms: number;      // ms since first entry
    session: number;
    level: string;
    message: string;
    detail: string | null;
  }>;
}

type Subscriber = (entries: LogEntry[]) => void;

// ─────────────────────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────────────────────

const MAX_ENTRIES = 5000;
const MAX_UI_LENGTH = 300;
const FORMAT_VERSION = '2.0.0';
const APP_NAME = 'CyberSight/ShelfScout';
const GOOGLE_SHEETS_WEB_APP_URL = 'https://script.google.com/macros/s/AKfycbx5gE1hVEs7oqXQCqRyRz4lExsjq5-Le-QoUuimiZNPYo-JYIe4KeGrWQKXztrrTuHVOw/exec';
// ─────────────────────────────────────────────────────────────────────────────
// Singleton
// ─────────────────────────────────────────────────────────────────────────────

class DebugLoggerClass {
  private entries: LogEntry[] = [];
  private subscribers: Set<Subscriber> = new Set();
  private nextId = 1;
  private initialized = false;
  private currentSession = 1;

  private uploadQueue: LogEntry[] = [];
  private isUploading = false;

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

    console.log = (...args: any[]) => {
      this.origLog(...args);
      this.push('log', args);
    };

    console.warn = (...args: any[]) => {
      this.origWarn(...args);
      this.push('warn', args);
    };

    console.error = (...args: any[]) => {
      this.origError(...args);
      this.push('error', args);
    };

    this.origLog('[DebugLogger] Initialized — interceptors installed (v' + FORMAT_VERSION + ')');
  }

  // ── Session management ────────────────────────────────────────────────

  /** Current session number (1-based). */
  getSession(): number {
    return this.currentSession;
  }

  /**
   * Start a new session. Inserts a visible "session" marker entry
   * so session boundaries are clear in both the UI and exports.
   */
  markNewSession(label?: string): void {
    this.currentSession++;
    const msg = label
      ? `── Session ${this.currentSession}: ${label} ──`
      : `── Session ${this.currentSession} ──`;
    this.addEntry('session', msg, undefined, msg);
  }

  // ── Logging ───────────────────────────────────────────────────────────

  logAPI(message: string, detail?: string): void {
    this.addEntry('api', message, detail);
  }

  logAPIError(message: string, detail?: string): void {
    this.addEntry('api-error', message, detail);
  }

  // ── Read / Clear ──────────────────────────────────────────────────────

  getAll(): LogEntry[] {
    return this.entries;
  }

  clear(): void {
    this.entries = [];
    this.nextId = 1;
    this.notify();
  }

  subscribe(fn: Subscriber): () => void {
    this.subscribers.add(fn);
    return () => { this.subscribers.delete(fn); };
  }

  // ════════════════════════════════════════════════════════════════════════
  // EXPORT — JSON (research-grade, self-documenting)
  //
  // Output format designed for:
  //   - Python:  pandas.read_json() / json.load()
  //   - R:       jsonlite::fromJSON()
  //   - NVivo / Atlas.ti (qualitative analysis)
  //   - Custom analysis scripts
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Build a structured JSON export envelope.
   * @param filterLevel — 'all' or a specific LogLevel to include
   */
  exportAsJSON(filterLevel: LogLevel | 'all' = 'all'): string {
    const filtered = filterLevel === 'all'
      ? this.entries
      : this.entries.filter(e => e.level === filterLevel);

    const firstTs = filtered.length > 0 ? filtered[0].timestamp : null;
    const lastTs = filtered.length > 0 ? filtered[filtered.length - 1].timestamp : null;

    const countsByLevel: Record<string, number> = {};
    const countsBySession: Record<number, number> = {};
    let apiCalls = 0;
    let errors = 0;

    for (const e of filtered) {
      countsByLevel[e.level] = (countsByLevel[e.level] || 0) + 1;
      countsBySession[e.session] = (countsBySession[e.session] || 0) + 1;
      if (e.level === 'api') apiCalls++;
      if (e.level === 'error' || e.level === 'api-error') errors++;
    }

    const envelope: ExportEnvelope = {
      metadata: {
        format_version: FORMAT_VERSION,
        app_name: APP_NAME,
        export_timestamp: new Date().toISOString(),
        export_timestamp_ms: Date.now(),
        platform: Platform.OS,
        os_version: String(Platform.Version),
        total_entries: filtered.length,
        total_sessions: this.currentSession,
        first_entry_at: firstTs ? new Date(firstTs).toISOString() : null,
        last_entry_at: lastTs ? new Date(lastTs).toISOString() : null,
        duration_ms: firstTs && lastTs ? lastTs - firstTs : 0,
        filter_applied: filterLevel,
      },
      summary: {
        counts_by_level: countsByLevel,
        counts_by_session: countsBySession,
        api_calls: apiCalls,
        errors,
      },
      entries: filtered.map(e => ({
        id: e.id,
        timestamp: new Date(e.timestamp).toISOString(),
        timestamp_ms: e.timestamp,
        elapsed_ms: firstTs ? e.timestamp - firstTs : 0,
        session: e.session,
        level: e.level,
        message: e.rawMessage,
        detail: e.rawDetail ?? null,
      })),
    };

    return JSON.stringify(envelope, null, 2);
  }

  // ════════════════════════════════════════════════════════════════════════
  // EXPORT — CSV (flat tabular, for spreadsheets / SPSS / R)
  //
  // Follows RFC 4180 (quoted fields, CRLF line endings).
  // Compatible with:
  //   - Excel / Google Sheets (direct import)
  //   - Python:  pandas.read_csv()
  //   - R:       read.csv()
  //   - SPSS:    File → Read Text Data
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Build a CSV string.
   * @param filterLevel — 'all' or a specific LogLevel to include
   */
  exportAsCSV(filterLevel: LogLevel | 'all' = 'all'): string {
    const filtered = filterLevel === 'all'
      ? this.entries
      : this.entries.filter(e => e.level === filterLevel);

    const firstTs = filtered.length > 0 ? filtered[0].timestamp : 0;
    const CRLF = '\r\n';

    const header = [
      'id',
      'timestamp_iso',
      'timestamp_ms',
      'elapsed_ms',
      'session',
      'level',
      'message',
      'detail',
    ].join(',');

    const rows = filtered.map(e => {
      const cols = [
        String(e.id),
        new Date(e.timestamp).toISOString(),
        String(e.timestamp),
        String(firstTs ? e.timestamp - firstTs : 0),
        String(e.session),
        e.level,
        csvEscape(e.rawMessage),
        csvEscape(e.rawDetail ?? ''),
      ];
      return cols.join(',');
    });

    return header + CRLF + rows.join(CRLF) + CRLF;
  }

  // ════════════════════════════════════════════════════════════════════════
  // EXPORT — Google Sheets
  // ════════════════════════════════════════════════════════════════════════

  /**
   * Upload the logs to a Google Sheets Web App via HTTP POST.
   */
  async uploadToGoogleSheets(filterLevel: LogLevel | 'all' = 'all'): Promise<void> {
    const payload = this.exportAsJSON(filterLevel);

    const response = await fetch(GOOGLE_SHEETS_WEB_APP_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'text/plain',
      },
      body: payload,
    });

    if (!response.ok) {
      throw new Error(`Google Sheets upload failed with status ${response.status}`);
    }
  }

  // ── Background Auto-Upload ──────────────────────────────────────────────

  private async processUploadQueue() {
    if (this.isUploading || this.uploadQueue.length === 0) return;
    this.isUploading = true;

    while (this.uploadQueue.length > 0) {
      const entry = this.uploadQueue.shift();
      if (!entry) continue;

      try {
        const payload = JSON.stringify({
          timestamp: entry.timestamp,
          level: entry.level,
          message: entry.message,
          detail: entry.detail || ''
        });

        const response = await fetch(GOOGLE_SHEETS_WEB_APP_URL, {
          method: 'POST',
          headers: {
            'Content-Type': 'text/plain',
          },
          body: payload,
        });
        
        const responseText = await response.text();
        
        if (!response.ok) {
           this.origError('[DebugLogger] Google Sheets HTTP Error:', response.status, responseText);
        } else {
           if (responseText.includes('"error"')) {
               this.origError('[DebugLogger] Google Sheets Apps Script Error:', responseText);
           } else {
               this.origLog('[DebugLogger] Uploaded -> Google Sheets:', entry.message);
           }
        }
      } catch (err) {
        this.origError('[DebugLogger] Network error uploading to Google Sheets:', err);
      }

      // Delay to avoid Google Apps Script rate limits (concurrent executions)
      await new Promise(resolve => setTimeout(resolve, 500));
    }

    this.isUploading = false;
  }

  // ── Internals ───────────────────────────────────────────────────────────

  private push(level: LogLevel, args: any[]): void {
    const raw = args
      .map(a => {
        if (typeof a === 'string') return a;
        try { return JSON.stringify(a); }
        catch { return String(a); }
      })
      .join(' ');

    this.addEntry(level, raw);
  }

  private addEntry(
    level: LogLevel,
    rawMessage: string,
    rawDetail?: string,
    /** If provided, used directly as truncated UI message */
    forcedUiMsg?: string,
  ): void {
    const message = forcedUiMsg
      ? forcedUiMsg
      : rawMessage.length > MAX_UI_LENGTH
        ? rawMessage.slice(0, MAX_UI_LENGTH) + '…'
        : rawMessage;

    const detail = rawDetail
      ? rawDetail.length > MAX_UI_LENGTH
        ? rawDetail.slice(0, MAX_UI_LENGTH) + '…'
        : rawDetail
      : undefined;

    const entry: LogEntry = {
      id: this.nextId++,
      timestamp: Date.now(),
      level,
      message,
      rawMessage,
      detail,
      rawDetail: rawDetail,
      session: this.currentSession,
    };

    this.entries.push(entry);

    if (this.entries.length > MAX_ENTRIES) {
      this.entries = this.entries.slice(this.entries.length - MAX_ENTRIES);
    }

    this.uploadQueue.push(entry);
    this.processUploadQueue();

    this.notify();
  }

  private notify(): void {
    const snapshot = this.entries;
    this.subscribers.forEach(fn => {
      try { fn(snapshot); }
      catch { /* Subscriber errors must never crash the logger */ }
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CSV helper (RFC 4180)
// ─────────────────────────────────────────────────────────────────────────────

function csvEscape(value: string): string {
  if (!value) return '""';
  if (/[,"\r\n]/.test(value)) {
    return '"' + value.replace(/"/g, '""') + '"';
  }
  return value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Export singleton
// ─────────────────────────────────────────────────────────────────────────────

export const debugLogger = new DebugLoggerClass();