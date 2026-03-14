// src/screens/SettingsScreen.tsx


import React, { useState, useCallback, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Switch,
  TouchableOpacity,
  ScrollView,
  AccessibilityInfo,
  Platform,
  Animated,
  PanResponder,
  Dimensions,
  StatusBar,
} from 'react-native';
import { useSettings } from '../context/SettingsContext';
import { iOSTts } from '../services/iOSTtsClient';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const SLIDER_TRACK_WIDTH = SCREEN_WIDTH - 80; // 40px padding each side

// ─────────────────────────────────────────────────────────────────────────────
// Colour palette – matches existing CyberSight dark theme
// ─────────────────────────────────────────────────────────────────────────────
const C = {
  bg: '#0A0A0F',
  surface: '#13131A',
  card: '#1C1C28',
  border: '#2A2A3D',
  primary: '#4F6EF7',    // blue accent
  primaryDim: '#2D3F9A',
  success: '#34C759',    // ARKit = green
  warning: '#FF9F0A',    // standard pipeline = amber
  text: '#FFFFFF',
  textSecondary: '#8E8EA0',
  textMuted: '#52526A',
  sliderTrack: '#2A2A3D',
  sliderFill: '#4F6EF7',
  sliderThumb: '#FFFFFF',
  divider: '#1E1E2E',
};

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function rateLabel(rate: number): string {
  if (rate <= 0.25) return 'Very Slow';
  if (rate <= 0.45) return 'Slow';
  if (rate <= 0.60) return 'Normal';
  if (rate <= 0.75) return 'Fast';
  return 'Very Fast';
}

function ratePercent(rate: number): string {
  return `${Math.round(rate * 100)}%`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Accessible Slider component (no external dependency)
// ─────────────────────────────────────────────────────────────────────────────

interface SliderProps {
  value: number;           // 0.1 – 1.0
  min?: number;
  max?: number;
  step?: number;
  onChange: (v: number) => void;
  onChangeEnd?: (v: number) => void;
  accessibilityLabel: string;
}

function AccessibleSlider({
  value,
  min = 0.1,
  max = 1.0,
  step = 0.05,
  onChange,
  onChangeEnd,
  accessibilityLabel,
}: SliderProps) {
  const thumbX = useRef(new Animated.Value(0)).current;
  const [trackWidth, setTrackWidth] = useState(SLIDER_TRACK_WIDTH);

  // Map value → pixel offset
  const valueToX = useCallback(
    (v: number) => ((v - min) / (max - min)) * trackWidth,
    [min, max, trackWidth],
  );

  // Map pixel offset → stepped value
  const xToValue = useCallback(
    (x: number) => {
      const raw = (x / trackWidth) * (max - min) + min;
      const stepped = Math.round(raw / step) * step;
      return Math.max(min, Math.min(max, parseFloat(stepped.toFixed(2))));
    },
    [min, max, step, trackWidth],
  );

  // Sync animated thumb when value prop changes
  React.useEffect(() => {
    thumbX.setValue(valueToX(value));
  }, [value, trackWidth]);

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: (_, gs) => {
        // Start from current pixel position
        thumbX.setOffset((thumbX as any)._value);
        thumbX.setValue(0);
      },
      onPanResponderMove: (_, gs) => {
        const raw = (thumbX as any)._offset + gs.dx;
        const clamped = Math.max(0, Math.min(trackWidth, raw));
        thumbX.setValue(clamped - (thumbX as any)._offset);
        onChange(xToValue(clamped));
      },
      onPanResponderRelease: (_, gs) => {
        thumbX.flattenOffset();
        const clamped = Math.max(
          0,
          Math.min(trackWidth, (thumbX as any)._value),
        );
        const v = xToValue(clamped);
        thumbX.setValue(clamped);
        onChangeEnd?.(v);
      },
    }),
  ).current;

  const fillWidth = thumbX.interpolate({
    inputRange: [0, trackWidth],
    outputRange: [0, trackWidth],
    extrapolate: 'clamp',
  });

  return (
    <View
      accessible={true}
      accessibilityRole="adjustable"
      accessibilityLabel={accessibilityLabel}
      accessibilityValue={{
        min: Math.round(min * 100),
        max: Math.round(max * 100),
        now: Math.round(value * 100),
        text: `${rateLabel(value)}, ${ratePercent(value)}`,
      }}
      accessibilityActions={[
        { name: 'increment', label: 'Increase' },
        { name: 'decrement', label: 'Decrease' },
      ]}
      onAccessibilityAction={event => {
        const delta = step;
        if (event.nativeEvent.actionName === 'increment') {
          onChangeEnd?.(Math.min(max, parseFloat((value + delta).toFixed(2))));
        } else if (event.nativeEvent.actionName === 'decrement') {
          onChangeEnd?.(Math.max(min, parseFloat((value - delta).toFixed(2))));
        }
      }}
      style={styles.sliderContainer}
      onLayout={e => setTrackWidth(e.nativeEvent.layout.width)}
      {...panResponder.panHandlers}
    >
      {/* Track */}
      <View style={[styles.sliderTrack, { width: trackWidth }]}>
        {/* Fill */}
        <Animated.View style={[styles.sliderFill, { width: fillWidth }]} />
        {/* Thumb */}
        <Animated.View
          style={[styles.sliderThumb, { transform: [{ translateX: thumbX }] }]}
        />
      </View>
    </View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Section wrapper
// ─────────────────────────────────────────────────────────────────────────────

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle} accessibilityRole="header">
        {title}
      </Text>
      <View style={styles.card}>{children}</View>
    </View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Main screen
// ─────────────────────────────────────────────────────────────────────────────

interface SettingsScreenProps {
  onClose: () => void;
}

export default function SettingsScreen({ onClose }: SettingsScreenProps) {
  const { settings, updatePreferAlternativeReaching, updateTtsRate, updateDeveloperMode } =
    useSettings();

  const [localRate, setLocalRate] = useState(settings.ttsRate);

  // ── Reaching toggle ───────────────────────────────────────────────────────

  const handleReachingToggle = useCallback(
    async (value: boolean) => {
      await updatePreferAlternativeReaching(value);
      const label = value
        ? 'Standard reaching pipeline enabled.'
        : 'A R Kit reaching pipeline enabled. This is the default.';
      AccessibilityInfo.announceForAccessibility(label);
    },
    [updatePreferAlternativeReaching],
  );

  // ── TTS rate ──────────────────────────────────────────────────────────────

  const handleRateChange = useCallback((v: number) => {
    setLocalRate(v);
  }, []);

  const handleRateChangeEnd = useCallback(
    async (v: number) => {
      setLocalRate(v);
      await updateTtsRate(v);

      // ✅ Preview new rate through singleton (avoids BOOL crash)
      if (Platform.OS === 'ios') {
        await iOSTts.stop();
        iOSTts.synthesizeSpeech(`Voice speed set to ${rateLabel(v)}.`);
      }

      AccessibilityInfo.announceForAccessibility(
        `Voice speed changed to ${rateLabel(v)}, ${ratePercent(v)}.`,
      );
    },
    [updateTtsRate],
  );

  // ── Speed preset buttons ──────────────────────────────────────────────────

  const presets: { label: string; value: number }[] = [
    { label: 'Slow', value: 0.35 },
    { label: 'Normal', value: 0.5 },
    { label: 'Fast', value: 0.75 },
  ];

  // ─────────────────────────────────────────────────────────────────────────
  // Render
  // ─────────────────────────────────────────────────────────────────────────

  return (
    <View style={styles.root}>
      <StatusBar barStyle="light-content" backgroundColor={C.bg} />

      {/* ── Header ── */}
      <View style={styles.header}>
        <TouchableOpacity
          style={styles.backBtn}
          onPress={onClose}
          accessible={true}
          accessibilityRole="button"
          accessibilityLabel="Back to main screen"
          accessibilityHint="Double tap to close settings"
        >
          <Text style={styles.backArrow}>‹</Text>
        </TouchableOpacity>
        <Text style={styles.headerTitle} accessibilityRole="header">
          Settings
        </Text>
        {/* Spacer to centre the title */}
        <View style={styles.backBtn} />
      </View>

      <ScrollView
        style={styles.scroll}
        contentContainerStyle={styles.scrollContent}
        showsVerticalScrollIndicator={false}
      >

        {/* ══════════════════════════════════════════
            SECTION 1 — Reaching Pipeline
        ══════════════════════════════════════════ */}
        <Section title="Reaching Pipeline">
          {/* Active pipeline badge */}
          <View style={styles.pipelineBadgeRow}>
            <View
              style={[
                styles.pipelineBadge,
                settings.preferAlternativeReaching
                  ? styles.badgeStandard
                  : styles.badgeArkit,
              ]}
            >
              <Text style={styles.pipelineBadgeText}>
                {settings.preferAlternativeReaching
                  ? '⚙  Standard Pipeline'
                  : '✦  ARKit  (default)'}
              </Text>
            </View>
          </View>

          {/* Description */}
          <Text style={styles.settingDescription}>
            By default, CyberSight uses Apple's{' '}
            <Text style={styles.emphasisText}>ARKit</Text> for object-reaching
            guidance on iOS. Toggle this to switch to the{' '}
            <Text style={styles.emphasisText}>Standard</Text> reaching pipeline
            instead.
          </Text>

          {/* Toggle row */}
          <View style={styles.settingRow}>
            <View style={styles.settingLabelBlock}>
              <Text style={styles.settingLabel}>Use Standard Pipeline</Text>
              <Text style={styles.settingSubLabel}>
                {settings.preferAlternativeReaching
                  ? 'Standard reaching active'
                  : 'ARKit reaching active'}
              </Text>
            </View>
            <Switch
              value={settings.preferAlternativeReaching}
              onValueChange={handleReachingToggle}
              trackColor={{ false: C.border, true: C.warning }}
              thumbColor={
                settings.preferAlternativeReaching ? C.warning : C.sliderThumb
              }
              ios_backgroundColor={C.border}
              accessible={true}
              accessibilityRole="switch"
              accessibilityLabel="Use Standard Reaching Pipeline"
              accessibilityHint={
                settings.preferAlternativeReaching
                  ? 'Currently using Standard pipeline. Double tap to switch to ARKit.'
                  : 'Currently using ARKit. Double tap to switch to Standard pipeline.'
              }
              accessibilityValue={{
                text: settings.preferAlternativeReaching
                  ? 'Standard pipeline active'
                  : 'ARKit pipeline active',
              }}
            />
          </View>

          {/* Pipeline comparison */}
          <View style={styles.comparisonRow}>
            <View
              style={[
                styles.pipelineOption,
                !settings.preferAlternativeReaching && styles.pipelineOptionActive,
              ]}
              accessible={true}
              accessibilityLabel={`ARKit pipeline${!settings.preferAlternativeReaching ? ', currently selected' : ''}`}
            >
              <Text style={styles.pipelineOptionIcon}>✦</Text>
              <Text style={styles.pipelineOptionName}>ARKit</Text>
              <Text style={styles.pipelineOptionDesc}>
                Depth-aware 3D guidance
              </Text>
              {!settings.preferAlternativeReaching && (
                <View style={styles.activeDot} />
              )}
            </View>

            <View style={styles.pipelineDivider} />

            <View
              style={[
                styles.pipelineOption,
                settings.preferAlternativeReaching && styles.pipelineOptionActiveAlt,
              ]}
              accessible={true}
              accessibilityLabel={`Standard pipeline${settings.preferAlternativeReaching ? ', currently selected' : ''}`}
            >
              <Text style={styles.pipelineOptionIcon}>⚙</Text>
              <Text style={styles.pipelineOptionName}>Standard</Text>
              <Text style={styles.pipelineOptionDesc}>
                Vision-based guidance
              </Text>
              {settings.preferAlternativeReaching && (
                <View style={[styles.activeDot, { backgroundColor: C.warning }]} />
              )}
            </View>
          </View>
        </Section>

        {/* ══════════════════════════════════════════
            SECTION 2 — Voice Speed
        ══════════════════════════════════════════ */}
        <Section title="Voice Speed">
          <Text style={styles.settingDescription}>
            Control how fast CyberSight speaks responses. Changes apply
            immediately — tap a preset or drag the slider.
          </Text>

          {/* Current value display */}
          <View style={styles.rateDisplayRow}>
            <Text style={styles.rateValue}>{ratePercent(localRate)}</Text>
            <Text style={styles.rateLabel}>{rateLabel(localRate)}</Text>
          </View>

          {/* Slider */}
          <AccessibleSlider
            value={localRate}
            min={0.1}
            max={1.0}
            step={0.05}
            onChange={handleRateChange}
            onChangeEnd={handleRateChangeEnd}
            accessibilityLabel="Voice speed slider"
          />

          {/* Min / Max labels */}
          <View style={styles.sliderEndLabels}>
            <Text style={styles.sliderEndLabel}>Slowest</Text>
            <Text style={styles.sliderEndLabel}>Fastest</Text>
          </View>

          {/* Preset buttons */}
          <View style={styles.presetRow}>
            {presets.map(p => (
              <TouchableOpacity
                key={p.label}
                style={[
                  styles.presetBtn,
                  Math.abs(localRate - p.value) < 0.03 && styles.presetBtnActive,
                ]}
                onPress={() => handleRateChangeEnd(p.value)}
                accessible={true}
                accessibilityRole="button"
                accessibilityLabel={`${p.label} speed, ${ratePercent(p.value)}`}
                accessibilityHint="Double tap to set this voice speed"
                accessibilityState={{
                  selected: Math.abs(localRate - p.value) < 0.03,
                }}
              >
                <Text
                  style={[
                    styles.presetBtnText,
                    Math.abs(localRate - p.value) < 0.03 &&
                      styles.presetBtnTextActive,
                  ]}
                >
                  {p.label}
                </Text>
                <Text style={styles.presetBtnSub}>{ratePercent(p.value)}</Text>
              </TouchableOpacity>
            ))}
          </View>

          {/* Test button — uses singleton to avoid BOOL crash */}
          <TouchableOpacity
            style={styles.testBtn}
            onPress={async () => {
              if (Platform.OS === 'ios') {
                await iOSTts.stop();
                iOSTts.synthesizeSpeech(
                  'This is how your voice guide will sound at this speed.',
                );
              }
            }}
            accessible={true}
            accessibilityRole="button"
            accessibilityLabel="Preview voice speed"
            accessibilityHint="Double tap to hear a sample at the current speed"
          >
            <Text style={styles.testBtnText}>▶  Preview Voice</Text>
          </TouchableOpacity>
        </Section>

        {/* ══════════════════════════════════════════
            SECTION 3 — Developer Options
        ══════════════════════════════════════════ */}
        <Section title="Developer Options">
          <Text style={styles.settingDescription}>
            Enable the debug overlay to inspect API calls, backend responses,
            errors, and timing in real-time. Use with{' '}
            <Text style={styles.emphasisText}>VoiceOver OFF</Text> during
            testing.
          </Text>

          <View style={styles.settingRow}>
            <View style={styles.settingLabelBlock}>
              <Text style={styles.settingLabel}>Developer Mode</Text>
              <Text style={styles.settingSubLabel}>
                {settings.developerMode
                  ? 'Debug overlay active — 🐛 button visible'
                  : 'Debug overlay hidden'}
              </Text>
            </View>
            <Switch
              value={settings.developerMode}
              onValueChange={async (value: boolean) => {
                await updateDeveloperMode(value);
              }}
              trackColor={{ false: C.border, true: C.primary }}
              thumbColor={settings.developerMode ? C.primary : C.sliderThumb}
              ios_backgroundColor={C.border}
            />
          </View>
        </Section>

        {/* Footer padding */}
        <View style={{ height: 48 }} />
      </ScrollView>
    </View>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Styles
// ─────────────────────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  root: {
    flex: 1,
    backgroundColor: C.bg,
  },

  // ── Header ──
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingTop: Platform.OS === 'ios' ? 56 : 24,
    paddingBottom: 16,
    paddingHorizontal: 20,
    borderBottomWidth: 1,
    borderBottomColor: C.divider,
  },
  backBtn: {
    width: 44,
    height: 44,
    alignItems: 'center',
    justifyContent: 'center',
  },
  backArrow: {
    color: C.primary,
    fontSize: 34,
    lineHeight: 40,
    fontWeight: '300',
  },
  headerTitle: {
    color: C.text,
    fontSize: 17,
    fontWeight: '600',
    letterSpacing: 0.3,
  },

  // ── Scroll ──
  scroll: { flex: 1 },
  scrollContent: { paddingTop: 24, paddingHorizontal: 20 },

  // ── Section ──
  section: { marginBottom: 32 },
  sectionTitle: {
    color: C.textMuted,
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 1.2,
    textTransform: 'uppercase',
    marginBottom: 10,
    marginLeft: 4,
  },
  card: {
    backgroundColor: C.card,
    borderRadius: 16,
    padding: 20,
    borderWidth: 1,
    borderColor: C.border,
  },

  // ── Pipeline badge ──
  pipelineBadgeRow: {
    alignItems: 'flex-start',
    marginBottom: 14,
  },
  pipelineBadge: {
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  badgeArkit: {
    backgroundColor: 'rgba(79, 110, 247, 0.18)',
    borderWidth: 1,
    borderColor: C.primary,
  },
  badgeStandard: {
    backgroundColor: 'rgba(255, 159, 10, 0.18)',
    borderWidth: 1,
    borderColor: C.warning,
  },
  pipelineBadgeText: {
    color: C.text,
    fontSize: 13,
    fontWeight: '600',
    letterSpacing: 0.2,
  },

  // ── Setting description ──
  settingDescription: {
    color: C.textSecondary,
    fontSize: 14,
    lineHeight: 20,
    marginBottom: 18,
  },
  emphasisText: {
    color: C.text,
    fontWeight: '600',
  },

  // ── Setting row ──
  settingRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 20,
    paddingVertical: 4,
  },
  settingLabelBlock: { flex: 1, marginRight: 16 },
  settingLabel: {
    color: C.text,
    fontSize: 16,
    fontWeight: '500',
  },
  settingSubLabel: {
    color: C.textMuted,
    fontSize: 12,
    marginTop: 2,
  },

  // ── Pipeline comparison ──
  comparisonRow: {
    flexDirection: 'row',
    alignItems: 'stretch',
    borderRadius: 12,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: C.border,
  },
  pipelineOption: {
    flex: 1,
    padding: 14,
    backgroundColor: C.surface,
    alignItems: 'center',
    position: 'relative',
  },
  pipelineOptionActive: {
    backgroundColor: 'rgba(79, 110, 247, 0.12)',
  },
  pipelineOptionActiveAlt: {
    backgroundColor: 'rgba(255, 159, 10, 0.12)',
  },
  pipelineDivider: {
    width: 1,
    backgroundColor: C.border,
  },
  pipelineOptionIcon: {
    fontSize: 20,
    marginBottom: 4,
    color: C.text,
  },
  pipelineOptionName: {
    color: C.text,
    fontSize: 14,
    fontWeight: '700',
    marginBottom: 4,
  },
  pipelineOptionDesc: {
    color: C.textMuted,
    fontSize: 11,
    textAlign: 'center',
    lineHeight: 15,
  },
  activeDot: {
    position: 'absolute',
    top: 8,
    right: 8,
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: C.primary,
  },

  // ── Rate display ──
  rateDisplayRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
    marginBottom: 20,
    gap: 10,
  },
  rateValue: {
    color: C.primary,
    fontSize: 36,
    fontWeight: '700',
    letterSpacing: -1,
  },
  rateLabel: {
    color: C.textSecondary,
    fontSize: 16,
    fontWeight: '500',
  },

  // ── Slider ──
  sliderContainer: {
    height: 44,
    justifyContent: 'center',
    marginBottom: 8,
  },
  sliderTrack: {
    height: 6,
    backgroundColor: C.sliderTrack,
    borderRadius: 3,
    position: 'relative',
    justifyContent: 'center',
  },
  sliderFill: {
    position: 'absolute',
    left: 0,
    height: 6,
    backgroundColor: C.sliderFill,
    borderRadius: 3,
  },
  sliderThumb: {
    position: 'absolute',
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: C.sliderThumb,
    top: -11,
    marginLeft: -14,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 3 },
    shadowOpacity: 0.3,
    shadowRadius: 6,
    elevation: 4,
  },

  sliderEndLabels: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginBottom: 20,
  },
  sliderEndLabel: {
    color: C.textMuted,
    fontSize: 11,
  },

  // ── Presets ──
  presetRow: {
    flexDirection: 'row',
    gap: 10,
    marginBottom: 16,
  },
  presetBtn: {
    flex: 1,
    paddingVertical: 12,
    paddingHorizontal: 8,
    borderRadius: 10,
    backgroundColor: C.surface,
    borderWidth: 1,
    borderColor: C.border,
    alignItems: 'center',
  },
  presetBtnActive: {
    backgroundColor: C.primaryDim,
    borderColor: C.primary,
  },
  presetBtnText: {
    color: C.textSecondary,
    fontSize: 14,
    fontWeight: '600',
  },
  presetBtnTextActive: {
    color: C.text,
  },
  presetBtnSub: {
    color: C.textMuted,
    fontSize: 11,
    marginTop: 2,
  },

  // ── Test button ──
  testBtn: {
    paddingVertical: 14,
    borderRadius: 12,
    backgroundColor: 'rgba(79, 110, 247, 0.12)',
    borderWidth: 1,
    borderColor: C.primary,
    alignItems: 'center',
  },
  testBtnText: {
    color: C.primary,
    fontSize: 15,
    fontWeight: '600',
    letterSpacing: 0.3,
  },
});