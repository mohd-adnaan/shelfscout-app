/**
 * src/components/DebugOverlay.tsx
 *
 * Floating debug panel for ShelfScout mobile app.
 *
 * ── Behaviour ──
 * - Renders a small 🐛 button at the bottom-right corner.
 * - Tapping the button toggles a scrollable log panel.
 * - Log entries are color coded by level.
 * - Auto-scrolls to newest entry.
 * - "Clear" button wipes the log.
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
} from 'react-native';
import { debugLogger, LogEntry, LogLevel } from '../services/DebugLogger';

// ─────────────────────────────────────────────────────────────────────────────
// Colours (match CyberSight dark palette)
// ─────────────────────────────────────────────────────────────────────────────

const C = {
  panelBg: 'rgba(10, 10, 15, 0.94)',
  entryBg: 'rgba(28, 28, 40, 0.6)',
  border: '#2A2A3D',
  text: '#E0E0E0',
  timestamp: '#52526A',
  log: '#CCCCCC',
  warn: '#FF9F0A',
  error: '#FF453A',
  api: '#64D2FF',
  'api-error': '#FF6B6B',
  btnBg: 'rgba(79, 110, 247, 0.85)',
  btnBgActive: '#FF453A',
  clearBg: 'rgba(255, 69, 58, 0.15)',
  clearBorder: '#FF453A',
};

const LEVEL_COLORS: Record<LogLevel, string> = {
  log: C.log,
  warn: C.warn,
  error: C.error,
  api: C.api,
  'api-error': C['api-error'],
};

const LEVEL_LABELS: Record<LogLevel, string> = {
  log: 'LOG',
  warn: 'WRN',
  error: 'ERR',
  api: 'API',
  'api-error': 'API✗',
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

// ─────────────────────────────────────────────────────────────────────────────
// Component
// ─────────────────────────────────────────────────────────────────────────────

const { width: SCREEN_W, height: SCREEN_H } = Dimensions.get('window');
const PANEL_HEIGHT = SCREEN_H * 0.55;

export function DebugOverlay(): React.JSX.Element {
  const [expanded, setExpanded] = useState(false);
  const [entries, setEntries] = useState<LogEntry[]>(debugLogger.getAll());
  const scrollRef = useRef<ScrollView>(null);
  const [filter, setFilter] = useState<LogLevel | 'all'>('all');

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
      // Small delay so the ScrollView has time to lay out new content
      const t = setTimeout(() => {
        scrollRef.current?.scrollToEnd({ animated: true });
      }, 80);
      return () => clearTimeout(t);
    }
  }, [entries.length, expanded]);

  const togglePanel = useCallback(() => {
    setExpanded(prev => !prev);
  }, []);

  const handleClear = useCallback(() => {
    debugLogger.clear();
  }, []);

  const filteredEntries =
    filter === 'all' ? entries : entries.filter(e => e.level === filter);

  // ── Filter tabs ─────────────────────────────────────────────────────────

  const filters: Array<{ key: LogLevel | 'all'; label: string }> = [
    { key: 'all', label: 'All' },
    { key: 'api', label: 'API' },
    { key: 'error', label: 'Err' },
    { key: 'warn', label: 'Wrn' },
    { key: 'log', label: 'Log' },
  ];

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
              {filteredEntries.length} entries
            </Text>
            <TouchableOpacity
              style={styles.clearBtn}
              onPress={handleClear}
              activeOpacity={0.7}
            >
              <Text style={styles.clearBtnText}>Clear</Text>
            </TouchableOpacity>
          </View>

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
              filteredEntries.map(entry => (
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
              ))
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
        {/* Red dot if there are errors */}
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
    // NOTE: pointerEvents is a View PROP, not a style — set on the <View> directly
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
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: C.border,
  },
  panelTitle: {
    color: '#FFFFFF',
    fontSize: 14,
    fontWeight: '700',
    letterSpacing: 0.3,
    flex: 1,
  },
  entryCount: {
    color: C.timestamp,
    fontSize: 11,
    marginRight: 10,
  },
  clearBtn: {
    paddingHorizontal: 10,
    paddingVertical: 4,
    borderRadius: 6,
    backgroundColor: C.clearBg,
    borderWidth: 1,
    borderColor: C.clearBorder,
  },
  clearBtnText: {
    color: C.error,
    fontSize: 11,
    fontWeight: '600',
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
    paddingLeft: 108, // align under message
  },

  // ── Empty state ──
  emptyText: {
    color: C.timestamp,
    fontSize: 12,
    textAlign: 'center',
    marginTop: 40,
  },
});