/**
 * src/components/DebugOverlay.tsx
 *
 * Floating debug panel for ShelfScout / CyberSight mobile app.
 *
 * ── Behaviour ──
 * - 🐛 button at bottom-right toggles a scrollable log panel.
 * - Color-coded entries by level; filter tabs.
 * - "Export" button → pick JSON or CSV → writes file → opens iOS share sheet.
 * - "Session" button → inserts a labeled session marker.
 * - "Clear" button wipes all entries.
 * - No accessibility announcements — for sighted developer testing only.
 */

import React, { useState, useEffect, useRef, useCallback } from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  Dimensions,
  Platform,
  Share,
  Alert,
} from 'react-native';
import RNFS from 'react-native-fs';
import { debugLogger, LogEntry, LogLevel } from '../services/DebugLogger';

// ─────────────────────────────────────────────────────────────────────────────
// Colours (match CyberSight dark palette)
// ─────────────────────────────────────────────────────────────────────────────

const C = {
  panelBg: 'rgba(10, 10, 15, 0.94)',
  border: '#2A2A3D',
  timestamp: '#52526A',
  log: '#CCCCCC',
  warn: '#FF9F0A',
  error: '#FF453A',
  api: '#64D2FF',
  'api-error': '#FF6B6B',
  session: '#34C759',
  btnBg: 'rgba(79, 110, 247, 0.85)',
  btnBgActive: '#FF453A',
  clearBg: 'rgba(255, 69, 58, 0.15)',
  clearBorder: '#FF453A',
  exportBg: 'rgba(52, 199, 89, 0.15)',
  exportBorder: '#34C759',
  sessionBtnBg: 'rgba(79, 110, 247, 0.15)',
  sessionBtnBorder: '#4F6EF7',
};

const LEVEL_COLORS: Record<LogLevel, string> = {
  log: C.log,
  warn: C.warn,
  error: C.error,
  api: C.api,
  'api-error': C['api-error'],
  session: C.session,
};

const LEVEL_LABELS: Record<LogLevel, string> = {
  log: 'LOG',
  warn: 'WRN',
  error: 'ERR',
  api: 'API',
  'api-error': 'API✗',
  session: '▸▸▸',
};

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function formatTime(ts: number): string {
  const d = new Date(ts);
  const h = d.getHours().toString().padStart(2, '0');
  const m = d.getMinutes().toString().padStart(2, '0');
  const s = d.getSeconds().toString().padStart(2, '0');
  const ms = d.getMilliseconds().toString().padStart(3, '0');
  return `${h}:${m}:${s}.${ms}`;
}

function fileTimestamp(): string {
  const d = new Date();
  return `${d.getFullYear()}${(d.getMonth() + 1).toString().padStart(2, '0')}${d.getDate().toString().padStart(2, '0')}_${d.getHours().toString().padStart(2, '0')}${d.getMinutes().toString().padStart(2, '0')}${d.getSeconds().toString().padStart(2, '0')}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────────────────────────────────

const { height: SCREEN_H } = Dimensions.get('window');
const PANEL_HEIGHT = SCREEN_H * 0.55;

export function DebugOverlay(): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const [entries, setEntries] = useState<LogEntry[]>(debugLogger.getAll());
  const scrollRef = useRef<ScrollView>(null);
  const [filter, setFilter] = useState<LogLevel | 'all'>('all');
  const [showFormatPicker, setShowFormatPicker] = useState(false);
  const [exporting, setExporting] = useState(false);

  // Subscribe to live log updates
  useEffect(() => {
    const unsub = debugLogger.subscribe((newEntries) => {
      setEntries([...newEntries]);
    });
    return unsub;
  }, []);

  // Auto-scroll when new entries arrive (only when expanded)
  useEffect(() => {
    if (expanded && scrollRef.current) {
      const t = setTimeout(() => {
        scrollRef.current?.scrollToEnd({ animated: true });
      }, 80);
      return () => clearTimeout(t);
    }
  }, [entries.length, expanded]);

  const togglePanel = useCallback(() => {
    setExpanded(prev => !prev);
    setShowFormatPicker(false);
  }, []);

  const handleClear = useCallback(() => {
    debugLogger.clear();
  }, []);

  // ── Session marker ──────────────────────────────────────────────────────

  const handleNewSession = useCallback(() => {
    debugLogger.markNewSession();
  }, []);

  // ── Export ──────────────────────────────────────────────────────────────

  const handleExport = useCallback(async (format: 'json' | 'csv') => {
    setShowFormatPicker(false);
    setExporting(true);
    try {
      const ts = fileTimestamp();
      const ext = format;
      const filename = `cybersight_logs_${ts}.${ext}`;
      const filePath = `${RNFS.DocumentDirectoryPath}/${filename}`;

      const content = format === 'json'
        ? debugLogger.exportAsJSON(filter)
        : debugLogger.exportAsCSV(filter);

      await RNFS.writeFile(filePath, content, 'utf8');

      const fileUrl = `file://${filePath}`;

      if (Platform.OS === 'ios') {
        // iOS Share sheet supports file URLs → AirDrop, Mail, Files, etc.
        await Share.share({ url: fileUrl });
      } else {
        // Android fallback: share content as text (file sharing needs extra deps)
        await Share.share({
          message: content,
          title: filename,
        });
      }

      // Clean up the temp file after sharing
      try { await RNFS.unlink(filePath); } catch { /* ignore */ }

    } catch (err: any) {
      if (err?.message?.includes('User did not share')) {
        // User cancelled share sheet — not an error
      } else {
        Alert.alert('Export failed', err?.message || 'Unknown error');
      }
    } finally {
      setExporting(false);
    }
  }, [filter]);

  // ── Derived ─────────────────────────────────────────────────────────────

  const filteredEntries =
    filter === 'all' ? entries : entries.filter(e => e.level === filter);

  const filters: Array<{ key: LogLevel | 'all'; label: string }> = [
    { key: 'all', label: 'All' },
    { key: 'api', label: 'API' },
    { key: 'error', label: 'Err' },
    { key: 'warn', label: 'Wrn' },
    { key: 'log', label: 'Log' },
  ];

  const sessionNum = debugLogger.getSession();

  // ── Render ──────────────────────────────────────────────────────────────

  return (
    <View
      style={styles.root}
      pointerEvents="box-none"
      accessible={false}
      importantForAccessibility="no-hide-descendants"
      accessibilityElementsHidden={true}
    >
      {/* ── Expanded panel ───────────────────────────────────────────────── */}
      {expanded && (
        <View style={styles.panel}>
          {/* Header bar */}
          <View style={styles.panelHeader}>
            <Text style={styles.panelTitle}>Debug Logs</Text>
            <Text style={styles.entryCount}>
              S{sessionNum} · {filteredEntries.length}
            </Text>

            {/* Session marker button */}
            <TouchableOpacity
              style={styles.sessionBtn}
              onPress={handleNewSession}
              activeOpacity={0.7}
            >
              <Text style={styles.sessionBtnText}>+Session</Text>
            </TouchableOpacity>

            {/* Export button */}
            <TouchableOpacity
              style={styles.exportBtn}
              onPress={() => setShowFormatPicker(prev => !prev)}
              activeOpacity={0.7}
              disabled={exporting}
            >
              <Text style={styles.exportBtnText}>
                {exporting ? '…' : 'Export'}
              </Text>
            </TouchableOpacity>

            {/* Clear button */}
            <TouchableOpacity
              style={styles.clearBtn}
              onPress={handleClear}
              activeOpacity={0.7}
            >
              <Text style={styles.clearBtnText}>Clear</Text>
            </TouchableOpacity>
          </View>

          {/* ── Format picker (appears when Export is tapped) ──────────── */}
          {showFormatPicker && (
            <View style={styles.formatPickerRow}>
              <Text style={styles.formatLabel}>Format:</Text>
              <TouchableOpacity
                style={styles.formatOption}
                onPress={() => handleExport('json')}
                activeOpacity={0.7}
              >
                <Text style={styles.formatOptionText}>JSON</Text>
                <Text style={styles.formatOptionSub}>Research</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={styles.formatOption}
                onPress={() => handleExport('csv')}
                activeOpacity={0.7}
              >
                <Text style={styles.formatOptionText}>CSV</Text>
                <Text style={styles.formatOptionSub}>Spreadsheet</Text>
              </TouchableOpacity>
            </View>
          )}

          {/* Filter tabs */}
          <View style={styles.filterRow}>
            {filters.map(f => (
              <TouchableOpacity
                key={f.key}
                style={[
                  styles.filterTab,
                  filter === f.key && styles.filterTabActive,
                ]}
                onPress={() => setFilter(f.key)}
                activeOpacity={0.7}
              >
                <Text
                  style={[
                    styles.filterTabText,
                    filter === f.key && styles.filterTabTextActive,
                  ]}
                >
                  {f.label}
                </Text>
              </TouchableOpacity>
            ))}
          </View>

          {/* Log entries */}
          <ScrollView
            ref={scrollRef}
            style={styles.scrollArea}
            contentContainerStyle={styles.scrollContent}
            showsVerticalScrollIndicator={true}
          >
            {filteredEntries.length === 0 ? (
              <Text style={styles.emptyText}>No logs yet.</Text>
            ) : (
              filteredEntries.map(entry => {
                // Session markers get a full-width highlight
                if (entry.level === 'session') {
                  return (
                    <View key={entry.id} style={styles.sessionMarkerRow}>
                      <Text style={styles.sessionMarkerText}>
                        {entry.message}
                      </Text>
                    </View>
                  );
                }

                return (
                  <View key={entry.id} style={styles.entryRow}>
                    <Text style={styles.entryTimestamp}>
                      {formatTime(entry.timestamp)}
                    </Text>
                    <Text
                      style={[
                        styles.entryBadge,
                        { color: LEVEL_COLORS[entry.level] },
                      ]}
                    >
                      {LEVEL_LABELS[entry.level]}
                    </Text>
                    <Text
                      style={[
                        styles.entryMessage,
                        { color: LEVEL_COLORS[entry.level] },
                      ]}
                      numberOfLines={3}
                    >
                      {entry.message}
                    </Text>
                    {entry.detail && (
                      <Text style={styles.entryDetail} numberOfLines={2}>
                        {entry.detail}
                      </Text>
                    )}
                  </View>
                );
              })
            )}
          </ScrollView>
        </View>
      )}

      {/* ── Bug Button (always visible when developerMode is on) ─────────── */}
      <TouchableOpacity
        style={[styles.bugBtn, expanded && styles.bugBtnActive]}
        onPress={togglePanel}
        activeOpacity={0.7}
      >
        <Text style={styles.bugBtnText}>🐛</Text>
        {entries.some(e => e.level === 'error' || e.level === 'api-error') &&
          !expanded && <View style={styles.errorDot} />}
      </TouchableOpacity>
    </View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Styles
// ─────────────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  root: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 9999,
    elevation: 9999,
  },

  // ── Bug button ──
  bugBtn: {
    position: 'absolute',
    bottom: Platform.OS === 'ios' ? 50 : 30,
    right: 16,
    width: 48,
    height: 48,
    borderRadius: 24,
    backgroundColor: C.btnBg,
    alignItems: 'center',
    justifyContent: 'center',
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.4,
    shadowRadius: 8,
    elevation: 10,
  },
  bugBtnActive: {
    backgroundColor: C.btnBgActive,
  },
  bugBtnText: {
    fontSize: 22,
  },
  errorDot: {
    position: 'absolute',
    top: 4,
    right: 4,
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: C.error,
    borderWidth: 1.5,
    borderColor: 'rgba(10, 10, 15, 0.9)',
  },

  // ── Panel ──
  panel: {
    position: 'absolute',
    bottom: Platform.OS === 'ios' ? 110 : 90,
    left: 10,
    right: 10,
    height: PANEL_HEIGHT,
    backgroundColor: C.panelBg,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: C.border,
    overflow: 'hidden',
  },

  // ── Panel header ──
  panelHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },
  panelTitle: {
    color: '#FFFFFF',
    fontSize: 13,
    fontWeight: '700',
    letterSpacing: 0.3,
    marginRight: 6,
  },
  entryCount: {
    color: C.timestamp,
    fontSize: 10,
    flex: 1,
  },

  // ── Session button ──
  sessionBtn: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 5,
    backgroundColor: C.sessionBtnBg,
    borderWidth: 1,
    borderColor: C.sessionBtnBorder,
    marginRight: 5,
  },
  sessionBtnText: {
    color: '#4F6EF7',
    fontSize: 9,
    fontWeight: '700',
  },

  // ── Export button ──
  exportBtn: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 5,
    backgroundColor: C.exportBg,
    borderWidth: 1,
    borderColor: C.exportBorder,
    marginRight: 5,
  },
  exportBtnText: {
    color: C.exportBorder,
    fontSize: 9,
    fontWeight: '700',
  },

  // ── Clear button ──
  clearBtn: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 5,
    backgroundColor: C.clearBg,
    borderWidth: 1,
    borderColor: C.clearBorder,
  },
  clearBtnText: {
    color: C.error,
    fontSize: 9,
    fontWeight: '700',
  },

  // ── Format picker ──
  formatPickerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: C.border,
    backgroundColor: 'rgba(52, 199, 89, 0.06)',
  },
  formatLabel: {
    color: C.timestamp,
    fontSize: 10,
    fontWeight: '600',
    marginRight: 8,
  },
  formatOption: {
    paddingHorizontal: 14,
    paddingVertical: 5,
    borderRadius: 6,
    backgroundColor: 'rgba(255,255,255,0.06)',
    borderWidth: 1,
    borderColor: C.border,
    marginRight: 8,
    alignItems: 'center',
  },
  formatOptionText: {
    color: '#FFFFFF',
    fontSize: 11,
    fontWeight: '700',
  },
  formatOptionSub: {
    color: C.timestamp,
    fontSize: 8,
    marginTop: 1,
  },

  // ── Filter row ──
  filterRow: {
    flexDirection: 'row',
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },
  filterTab: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
    backgroundColor: 'rgba(255,255,255,0.05)',
    marginRight: 6,
  },
  filterTabActive: {
    backgroundColor: 'rgba(79, 110, 247, 0.3)',
  },
  filterTabText: {
    color: C.timestamp,
    fontSize: 11,
    fontWeight: '600',
  },
  filterTabTextActive: {
    color: '#FFFFFF',
  },

  // ── Scroll area ──
  scrollArea: {
    flex: 1,
  },
  scrollContent: {
    paddingHorizontal: 10,
    paddingVertical: 6,
  },

  // ── Session marker ──
  sessionMarkerRow: {
    paddingVertical: 6,
    paddingHorizontal: 8,
    marginVertical: 4,
    borderRadius: 6,
    backgroundColor: 'rgba(52, 199, 89, 0.1)',
    borderLeftWidth: 3,
    borderLeftColor: C.session,
  },
  sessionMarkerText: {
    color: C.session,
    fontSize: 10,
    fontWeight: '800',
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    letterSpacing: 0.5,
  },

  // ── Entry row ──
  entryRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'flex-start',
    paddingVertical: 3,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: 'rgba(42, 42, 61, 0.5)',
  },
  entryTimestamp: {
    color: C.timestamp,
    fontSize: 9,
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    marginRight: 6,
    minWidth: 72,
    lineHeight: 16,
  },
  entryBadge: {
    fontSize: 9,
    fontWeight: '800',
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    marginRight: 6,
    minWidth: 30,
    lineHeight: 16,
  },
  entryMessage: {
    flex: 1,
    fontSize: 10,
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    lineHeight: 15,
  },
  entryDetail: {
    width: '100%',
    fontSize: 9,
    color: C.timestamp,
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    lineHeight: 14,
    marginTop: 2,
    paddingLeft: 108,
  },

  // ── Empty state ──
  emptyText: {
    color: C.timestamp,
    fontSize: 12,
    textAlign: 'center',
    marginTop: 40,
  },
});