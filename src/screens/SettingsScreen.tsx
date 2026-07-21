// src/screens/SettingsScreen.tsx

import React, { useState, useCallback, useEffect, useRef } from 'react';
import {
  View,
  Text,
  StyleSheet,
  Switch,
  TouchableOpacity,
  ScrollView,
  Alert,
  Platform,
  Animated,
  PanResponder,
  Dimensions,
  StatusBar,
} from 'react-native';
import { useSettings } from '../context/SettingsContext';
import {
  AppLanguage,
  LANGUAGE_ENDONYMS,
  LANGUAGE_LOCALES,
  SUPPORTED_LANGUAGES,
  strings,
  useStrings,
} from '../i18n';
import { speechOutput } from '../services/SpeechOutputService';
import { wearablesCamera, WearablesCameraStatus } from '../services/WearablesCamera';
import {
  ARKitNavigationBridge,
  isARKitNavigationModuleLinked,
} from '../native/ARKitNavigationModule';

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

const WEARABLES_SETTINGS_PREWARM_RETRY_DELAYS_MS = [0, 2500, 5000, 8000];

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
  }, [thumbX, value, valueToX]);

  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => true,
      onMoveShouldSetPanResponder: () => true,
      onPanResponderGrant: (_, _gs) => {
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
      onPanResponderRelease: (_, _gs) => {
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
  const {
    settings,
    updateInDeviceMode,
    updateReachingPipeline,
    updateNavigationPipeline,
    updateUseWearablesCamera,
    updateWearablesMicrophoneSource,
    updateTtsRate,
    updateDeveloperMode,
    updateReachingMode,
    updateDistanceUnit,
    updateEnableAcquisitionAutoExit,
    updateNavigationErrorRecovery,
    updateNavigationClockFaceDirections,
    updateLanguage,
    effectiveReachingPipeline,
  } =
    useSettings();

  // Guidance-style options belong to the ARKit reaching engines (Vision Box
  // and Spatial Target), not to Melody's Standard loop. Read the *effective*
  // pipeline so In-Device Mode — which forces Spatial Target — keeps them
  // visible even when the backend-mode preference underneath is Standard.
  const arkitReachingActive =
    Platform.OS === 'ios' && effectiveReachingPipeline !== 'standard';
  // Auto-exit is backend acquisition validation; Spatial Target never calls a
  // backend, so the toggle would be a dead switch there.
  const acquisitionAutoExitApplies =
    arkitReachingActive && effectiveReachingPipeline !== 'spatialTarget';

  const [localRate, setLocalRate] = useState(settings.ttsRate);
  const [wearablesStatus, setWearablesStatus] = useState<WearablesCameraStatus>('unknown');

  // Re-renders this screen when the language changes, so the switch and every
  // localized label below it update in place.
  const t = useStrings();

  // ── Language ──────────────────────────────────────────────────────────────

  const handleLanguageChange = useCallback(
    async (language: AppLanguage) => {
      if (language === settings.language) return;
      await updateLanguage(language);
      // updateLanguage publishes to the i18n store before resolving, so this
      // confirmation is already spoken in the language just selected — which
      // is the confirmation the user needs to hear.
      await speechOutput.announce(strings().settings.languageChanged);
    },
    [settings.language, updateLanguage],
  );

  // ── In-Device Mode (master) ───────────────────────────────────────────────

  const handleInDeviceModeToggle = useCallback(
    async (value: boolean) => {
      await updateInDeviceMode(value);
      await speechOutput.announce(
        value
          ? 'In-Device Mode on. Navigation and reaching run fully on your phone.'
          : 'In-Device Mode off. Using the online backend.',
      );
    },
    [updateInDeviceMode],
  );

  // ── Reaching toggle ───────────────────────────────────────────────────────

  const handleReachingPipelineChange = useCallback(
    async (pipeline: 'visionBox' | 'spatialTarget' | 'standard') => {
      await updateReachingPipeline(pipeline);
      const label =
        pipeline === 'spatialTarget'
          ? 'Spatial Target reaching enabled.'
          : pipeline === 'visionBox'
            ? 'Vision Box reaching enabled.'
            : 'Standard pipeline enabled.';
      await speechOutput.announce(label);
    },
    [updateReachingPipeline],
  );

  // ── Navigation toggle ─────────────────────────────────────────────────────

  const handleNavigationPipelineToggle = useCallback(
    async (useARKit: boolean) => {
      const nextPipeline = useARKit ? 'arkit' : 'rtab';
      await updateNavigationPipeline(nextPipeline);
      await speechOutput.announce(
        useARKit
          ? 'ARKit on-device navigation enabled.'
          : 'Rtab RTAB navigation enabled.',
      );
    },
    [updateNavigationPipeline],
  );

  const handleManageARRoutes = useCallback(async () => {
    try {
      if (Platform.OS !== 'ios' || !isARKitNavigationModuleLinked) {
        Alert.alert(
          'ARKit module not linked',
          'Rebuild and reinstall the iOS app so the native ARKit navigation module is included.',
        );
        return;
      }

      const available = await ARKitNavigationBridge.isAvailable();
      if (!available) {
        Alert.alert(
          'ARKit unavailable',
          'ARKit route mapping is available on iPhone or iPad devices that support ARKit.',
        );
        return;
      }
      await ARKitNavigationBridge.presentRouteManager();
    } catch (error: any) {
      Alert.alert(
        'Could not open AR Route Maps',
        error?.message || 'Rebuild the iOS app with the ARKit navigation module linked.',
      );
    }
  }, []);

  // Guard: prevent overlapping connect/disconnect operations on the Meta SDK.
  // Rapid OFF→ON toggling without this creates zombie sessions that cause
  // ActivityManagerError (error: 11): "A session already exists for this device".
  const wearablesTransitioningRef = useRef(false);

  const refreshWearablesStatus = useCallback(async () => {
    try {
      const status = await wearablesCamera.getStatus();
      setWearablesStatus(status);
    } catch (error) {
      console.warn('[Wearables] Status refresh failed:', error);
      setWearablesStatus('unknown');
    }
  }, []);

  const handleAcquisitionToggle = useCallback(
    async (value: boolean) => {
      await updateEnableAcquisitionAutoExit(value);
      const label = value
        ? 'Auto-exit enabled.'
        : 'Auto-exit disabled. Manual exit only.';
      await speechOutput.announce(label);
    },
    [updateEnableAcquisitionAutoExit],
  );

  const handleErrorRecoveryToggle = useCallback(
    async (value: boolean) => {
      await updateNavigationErrorRecovery(value);
      await speechOutput.announce(
        value
          ? 'Navigation error recovery enabled.'
          : 'Navigation error recovery disabled.',
      );
    },
    [updateNavigationErrorRecovery],
  );

  const handleClockFaceDirectionsToggle = useCallback(
    async (value: boolean) => {
      await updateNavigationClockFaceDirections(value);
      await speechOutput.announce(
        value
          ? 'Clock face directions enabled. Turns are spoken as clock hours, like turn to 2 o\'clock.'
          : 'Clock face directions disabled. Turns are spoken as left and right.',
      );
    },
    [updateNavigationClockFaceDirections],
  );

  const handleWearablesMicrophoneToggle = useCallback(
    async (useGlassesMic: boolean) => {
      const nextSource = useGlassesMic ? 'wearables' : 'phone';
      await updateWearablesMicrophoneSource(nextSource);

      const label = useGlassesMic
        ? 'Meta Ray-Ban microphone selected for Hey ShelfScout.'
        : 'iPhone microphone selected for Hey ShelfScout.';
      await speechOutput.announce(label);
    },
    [updateWearablesMicrophoneSource],
  );

  const handleWearablesToggle = useCallback(
    async (value: boolean) => {
      // Prevent re-entrant calls while a connect/disconnect is in flight
      if (wearablesTransitioningRef.current) {
        console.warn('[Wearables] Toggle ignored — transition in progress');
        return;
      }
      wearablesTransitioningRef.current = true;

      try {
        // When turning OFF, disconnect FIRST and wait for it to complete
        // before updating the setting. This ensures the Meta SDK session
        // is fully torn down before any new session can be created.
        if (!value && Platform.OS === 'ios') {
          try {
            await wearablesCamera.disconnect();
          } catch (disconnectErr: any) {
            console.warn('[Wearables] Disconnect error (non-fatal):', disconnectErr?.message);
          }
          // Small cooldown to let the Meta SDK release the device session
          await new Promise<void>(resolve => setTimeout(() => resolve(), 500));
        }

        await updateUseWearablesCamera(value);

        if (value && Platform.OS === 'ios') {
          try {
            await wearablesCamera.startRegistration();

            // Pre-warm: grant permission → wait for device → start session/stream.
            // The Meta SDK can report "paired" before the glasses are actually
            // active, so retry briefly instead of making the user toggle OFF/ON.
            let preWarmErr: any = null;
            for (let i = 0; i < WEARABLES_SETTINGS_PREWARM_RETRY_DELAYS_MS.length; i += 1) {
              const delayMs = WEARABLES_SETTINGS_PREWARM_RETRY_DELAYS_MS[i];
              if (delayMs > 0) {
                await new Promise<void>((resolve) => setTimeout(() => resolve(), delayMs));
              }

              try {
                await wearablesCamera.preWarm();
                preWarmErr = null;
                // Refresh status pill so it flips from "Not connected" to "Connected"
                await refreshWearablesStatus();
                break;
              } catch (error: any) {
                preWarmErr = error;
                console.warn(
                  `[Wearables] Pre-warm attempt ${i + 1}/${WEARABLES_SETTINGS_PREWARM_RETRY_DELAYS_MS.length} failed:`,
                  error?.message || error,
                );
              }
            }

            if (preWarmErr) {
              const msg =
                preWarmErr?.message ||
                'Could not start the glasses camera stream.';
              await speechOutput.announce(msg);
              Alert.alert('Glasses Camera', msg, [{ text: 'OK', style: 'default' }]);
              // Don't auto-revert the toggle — capturePhoto will retry on next tap
              // and the user might fix the issue (open Meta AI, grant perm) in between.
            }
          } catch (error: any) {
            console.warn('[Wearables] Registration error:', error);
            const message =
              error?.message ||
              'Unable to start glasses registration. Open the Meta AI app and try again.';
            await speechOutput.announce(message);
            Alert.alert('Glasses Registration', message, [{ text: 'OK', style: 'default' }]);
          }

          await refreshWearablesStatus();
        }

        const label = value
          ? 'Meta Ray-Ban camera enabled. Make sure the Meta AI app is open in the background and ShelfScout has camera permission for your glasses.'
          : 'Phone camera enabled.';
        await speechOutput.announce(label);
      } finally {
        wearablesTransitioningRef.current = false;
      }
    },
    [updateUseWearablesCamera, refreshWearablesStatus],
  );

  useEffect(() => {
    refreshWearablesStatus();
  }, [refreshWearablesStatus, settings.useWearablesCamera]);

  // ── TTS rate ──────────────────────────────────────────────────────────────

  const handleRateChange = useCallback((v: number) => {
    setLocalRate(v);
  }, []);

  const handleRateChangeEnd = useCallback(
    async (v: number) => {
      setLocalRate(v);
      await updateTtsRate(v);

      const label = `Voice speed changed to ${rateLabel(v)}, ${ratePercent(v)}.`;
      const screenReaderEnabled = await speechOutput.isScreenReaderEnabled();

      if (screenReaderEnabled) {
        await speechOutput.announce(label);
        return;
      }

      // ✅ Preview new rate through singleton (avoids BOOL crash)
      if (Platform.OS === 'ios') {
        await speechOutput.speak(`Voice speed set to ${rateLabel(v)}.`);
      }

      await speechOutput.announce(label);
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
            SECTION 0 — Language
            First section on purpose: it governs every spoken cue below it,
            and a user who opened Settings because the app is speaking the
            wrong language should reach it without hunting.
        ══════════════════════════════════════════ */}
        <Section title={t.settings.languageSection}>
          <Text style={styles.settingDescription}>
            {t.settings.languageDescription}
          </Text>

          <View style={styles.comparisonRow}>
            {SUPPORTED_LANGUAGES.map((code, index) => {
              const isSelected = settings.language === code;
              // Endonyms: each option names itself in its own language, so
              // "Français" stays findable to someone who cannot read the
              // language currently active. Same convention as iOS Settings.
              const label = LANGUAGE_ENDONYMS[code];

              return (
                <React.Fragment key={code}>
                  {index > 0 && <View style={styles.pipelineDivider} />}
                  <TouchableOpacity
                    style={[
                      styles.pipelineOption,
                      isSelected && styles.pipelineOptionActive,
                    ]}
                    accessible={true}
                    accessibilityRole="button"
                    accessibilityLabel={t.settings.languageOptionAccessibilityLabel(
                      label,
                      isSelected,
                    )}
                    accessibilityHint={t.settings.languageOptionAccessibilityHint}
                    onPress={() => handleLanguageChange(code)}
                  >
                    <Text style={styles.pipelineOptionIcon}>
                      {code === 'fr' ? '🇨🇦' : '🇬🇧'}
                    </Text>
                    <Text style={styles.pipelineOptionName}>{label}</Text>
                    <Text style={styles.pipelineOptionDesc}>
                      {LANGUAGE_LOCALES[code].bcp47}
                    </Text>
                    {isSelected && <View style={styles.activeDot} />}
                  </TouchableOpacity>
                </React.Fragment>
              );
            })}
          </View>
        </Section>

        {/* ══════════════════════════════════════════
            SECTION 0 — Mode (master switch)
        ══════════════════════════════════════════ */}
        <Section title="Mode">
          <View style={styles.pipelineBadgeRow}>
            <View
              style={[
                styles.pipelineBadge,
                settings.inDeviceMode ? styles.badgeArkit : styles.badgeStandard,
              ]}
            >
              <Text style={styles.pipelineBadgeText}>
                {settings.inDeviceMode ? 'In-Device' : 'Backend'}
              </Text>
            </View>
          </View>

          <Text style={styles.settingDescription}>
            <Text style={styles.emphasisText}>In-Device Mode</Text> runs navigation and
            reaching fully on your phone with ARKit — no network needed. Turn it off to use
            the online backend (Kasra navigation and backend reaching).
          </Text>

          <View style={styles.settingRow}>
            <View style={styles.settingLabelBlock}>
              <Text style={styles.settingLabel}>In-Device Mode</Text>
              <Text style={styles.settingSubLabel}>
                {settings.inDeviceMode
                  ? 'On-device ARKit + local orchestration'
                  : 'Online backend orchestration'}
              </Text>
            </View>
            <Switch
              value={settings.inDeviceMode}
              onValueChange={handleInDeviceModeToggle}
              accessibilityLabel="In-Device Mode"
              accessibilityHint="Double tap to run navigation and reaching fully on device"
            />
          </View>

          {settings.inDeviceMode && Platform.OS === 'ios' && (
            <>
              <View style={styles.settingRow}>
                <View style={styles.settingLabelBlock}>
                  <Text style={styles.settingLabel}>Navigation error recovery</Text>
                  <Text style={styles.settingSubLabel}>
                    {settings.navigationErrorRecovery
                      ? 'Off-route and lost-tracking recovery cues on'
                      : 'Recovery cues off (study condition)'}
                  </Text>
                </View>
                <Switch
                  value={settings.navigationErrorRecovery}
                  onValueChange={handleErrorRecoveryToggle}
                  trackColor={{ false: C.border, true: C.success }}
                  thumbColor={settings.navigationErrorRecovery ? C.success : C.sliderThumb}
                  ios_backgroundColor={C.border}
                  accessible={true}
                  accessibilityRole="switch"
                  accessibilityLabel="Navigation error recovery"
                  accessibilityHint={
                    settings.navigationErrorRecovery
                      ? 'Double tap to disable route error recovery during guidance.'
                      : 'Double tap to enable route error recovery during guidance.'
                  }
                />
              </View>

              <View style={styles.settingRow}>
                <View style={styles.settingLabelBlock}>
                  <Text style={styles.settingLabel}>Clock-face directions</Text>
                  <Text style={styles.settingSubLabel}>
                    {settings.navigationClockFaceDirections
                      ? 'Turns spoken as clock hours (2 o\'clock)'
                      : 'Turns spoken as left and right'}
                  </Text>
                </View>
                <Switch
                  value={settings.navigationClockFaceDirections}
                  onValueChange={handleClockFaceDirectionsToggle}
                  trackColor={{ false: C.border, true: C.success }}
                  thumbColor={settings.navigationClockFaceDirections ? C.success : C.sliderThumb}
                  ios_backgroundColor={C.border}
                  accessible={true}
                  accessibilityRole="switch"
                  accessibilityLabel="Clock-face directions"
                  accessibilityHint={
                    settings.navigationClockFaceDirections
                      ? 'Double tap to speak turns as left and right.'
                      : 'Double tap to speak turns as clock hours.'
                  }
                />
              </View>

              <Text style={styles.settingDescription}>
                Set up and manage the saved ARKit maps used by on-device
                navigation and Spatial Target reaching.
              </Text>
              <TouchableOpacity
                style={styles.testBtn}
                onPress={handleManageARRoutes}
                accessible={true}
                accessibilityRole="button"
                accessibilityLabel="Manage AR route maps"
                accessibilityHint="Double tap to open the ARKit route mapping screen"
              >
                <Text style={styles.testBtnText}>Manage AR Route Maps</Text>
              </TouchableOpacity>
            </>
          )}
        </Section>

        {!settings.inDeviceMode && (
          <>
        {/* ══════════════════════════════════════════
            SECTION 1 — Navigation Pipeline
        ══════════════════════════════════════════ */}
        <Section title="Navigation Pipeline">
          <View style={styles.pipelineBadgeRow}>
            <View
              style={[
                styles.pipelineBadge,
                settings.navigationPipeline === 'arkit'
                  ? styles.badgeArkit
                  : styles.badgeStandard,
              ]}
            >
              <Text style={styles.pipelineBadgeText}>
                {settings.navigationPipeline === 'arkit'
                  ? 'ARKit On-Device'
                  : 'RTAB'}
              </Text>
            </View>
          </View>

          <Text style={styles.settingDescription}>
            Choose how ShelfScout handles indoor route guidance. RTAB stays the default.
          </Text>

          <View style={styles.settingRow}>
            <View style={styles.settingLabelBlock}>
              <Text style={styles.settingLabel}>Use ARKit navigation</Text>
              <Text style={styles.settingSubLabel}>
                {settings.navigationPipeline === 'arkit'
                  ? 'On-device route maps and guidance'
                  : 'Server RTAB route guidance'}
              </Text>
            </View>
            <Switch
              value={settings.navigationPipeline === 'arkit'}
              onValueChange={handleNavigationPipelineToggle}
              trackColor={{ false: C.border, true: C.success }}
              thumbColor={settings.navigationPipeline === 'arkit' ? C.success : C.sliderThumb}
              ios_backgroundColor={C.border}
              accessible={true}
              accessibilityRole="switch"
              accessibilityLabel="Use ARKit navigation"
              accessibilityHint={
                settings.navigationPipeline === 'arkit'
                  ? 'Double tap to switch back to Rtab RTAB navigation.'
                  : 'Double tap to use on-device ARKit navigation.'
              }
              accessibilityValue={{
                text: settings.navigationPipeline === 'arkit'
                  ? 'ARKit on-device navigation active'
                  : 'Rtab RTAB navigation active',
              }}
            />
          </View>

          {settings.navigationPipeline === 'arkit' && (
            <View style={styles.settingRow}>
              <View style={styles.settingLabelBlock}>
                <Text style={styles.settingLabel}>Navigation error recovery</Text>
                <Text style={styles.settingSubLabel}>
                  {settings.navigationErrorRecovery
                    ? 'Off-route and lost-tracking recovery cues on'
                    : 'Recovery cues off (study condition)'}
                </Text>
              </View>
              <Switch
                value={settings.navigationErrorRecovery}
                onValueChange={handleErrorRecoveryToggle}
                trackColor={{ false: C.border, true: C.success }}
                thumbColor={settings.navigationErrorRecovery ? C.success : C.sliderThumb}
                ios_backgroundColor={C.border}
                accessible={true}
                accessibilityRole="switch"
                accessibilityLabel="Navigation error recovery"
                accessibilityHint={
                  settings.navigationErrorRecovery
                    ? 'Double tap to disable route error recovery during guidance.'
                    : 'Double tap to enable route error recovery during guidance.'
                }
              />
            </View>
          )}

          {settings.navigationPipeline === 'arkit' && (
            <View style={styles.settingRow}>
              <View style={styles.settingLabelBlock}>
                <Text style={styles.settingLabel}>Clock-face directions</Text>
                <Text style={styles.settingSubLabel}>
                  {settings.navigationClockFaceDirections
                    ? 'Turns spoken as clock hours (2 o\'clock)'
                    : 'Turns spoken as left and right'}
                </Text>
              </View>
              <Switch
                value={settings.navigationClockFaceDirections}
                onValueChange={handleClockFaceDirectionsToggle}
                trackColor={{ false: C.border, true: C.success }}
                thumbColor={settings.navigationClockFaceDirections ? C.success : C.sliderThumb}
                ios_backgroundColor={C.border}
                accessible={true}
                accessibilityRole="switch"
                accessibilityLabel="Clock-face directions"
                accessibilityHint={
                  settings.navigationClockFaceDirections
                    ? 'Double tap to speak turns as left and right.'
                    : 'Double tap to speak turns as clock hours.'
                }
              />
            </View>
          )}

          {Platform.OS === 'ios' && (
            <TouchableOpacity
              style={styles.testBtn}
              onPress={handleManageARRoutes}
              accessible={true}
              accessibilityRole="button"
              accessibilityLabel="Manage AR route maps"
              accessibilityHint="Double tap to open the ARKit route mapping screen"
            >
              <Text style={styles.testBtnText}>Manage AR Route Maps</Text>
            </TouchableOpacity>
          )}
        </Section>

        {/* ══════════════════════════════════════════
            SECTION 1.1 — Reaching Pipeline
        ══════════════════════════════════════════ */}
        <Section title="Reaching Pipeline">
          {/* Active pipeline badge */}
          <View style={styles.pipelineBadgeRow}>
            <View
              style={[
                styles.pipelineBadge,
                settings.reachingPipeline === 'standard'
                  ? styles.badgeStandard
                  : styles.badgeArkit,
              ]}
            >
              <Text style={styles.pipelineBadgeText}>
                {settings.reachingPipeline === 'spatialTarget'
                  ? 'Spatial Target'
                  : settings.reachingPipeline === 'standard'
                    ? 'Standard Pipeline'
                    : 'Vision Box'}
              </Text>
            </View>
          </View>

          <Text style={styles.settingDescription}>
            Backend reaching engine. <Text style={styles.emphasisText}>Vision Box</Text> uses
            a backend bounding box with ARKit depth; <Text style={styles.emphasisText}>Standard</Text> is
            Melody's tracker loop. For on-device reaching, use In-Device Mode above.
          </Text>

          <View style={styles.comparisonRow}>
            {settings.developerMode && (
            <TouchableOpacity
              style={[
                styles.pipelineOption,
                settings.reachingPipeline === 'spatialTarget' && styles.pipelineOptionActive,
              ]}
              accessible={true}
              accessibilityRole="button"
              accessibilityLabel={`Spatial Target reaching${settings.reachingPipeline === 'spatialTarget' ? ', currently selected' : ''}`}
              accessibilityHint="Double tap to select"
              onPress={() => handleReachingPipelineChange('spatialTarget')}
            >
              <Text style={styles.pipelineOptionIcon}>◎</Text>
              <Text style={styles.pipelineOptionName}>Spatial Target</Text>
              <Text style={styles.pipelineOptionDesc}>
                Map target{'\n'}on device
              </Text>
              {settings.reachingPipeline === 'spatialTarget' && (
                <View style={styles.activeDot} />
              )}
            </TouchableOpacity>
            )}

            {settings.developerMode && <View style={styles.pipelineDivider} />}

            <TouchableOpacity
              style={[
                styles.pipelineOption,
                settings.reachingPipeline === 'visionBox' && styles.pipelineOptionActive,
              ]}
              accessible={true}
              accessibilityRole="button"
              accessibilityLabel={`Vision Box reaching${settings.reachingPipeline === 'visionBox' ? ', currently selected' : ''}`}
              accessibilityHint="Double tap to select"
              onPress={() => handleReachingPipelineChange('visionBox')}
            >
              <Text style={styles.pipelineOptionIcon}>□</Text>
              <Text style={styles.pipelineOptionName}>Vision Box</Text>
              <Text style={styles.pipelineOptionDesc}>
                Backend box{'\n'}ARKit depth
              </Text>
              {settings.reachingPipeline === 'visionBox' && (
                <View style={styles.activeDot} />
              )}
            </TouchableOpacity>

            <View style={styles.pipelineDivider} />

            <TouchableOpacity
              style={[
                styles.pipelineOption,
                settings.reachingPipeline === 'standard' && styles.pipelineOptionActiveAlt,
              ]}
              accessible={true}
              accessibilityRole="button"
              accessibilityLabel={`Standard reaching${settings.reachingPipeline === 'standard' ? ', currently selected' : ''}`}
              accessibilityHint="Double tap to select"
              onPress={() => handleReachingPipelineChange('standard')}
            >
              <Text style={styles.pipelineOptionIcon}>↻</Text>
              <Text style={styles.pipelineOptionName}>Standard</Text>
              <Text style={styles.pipelineOptionDesc}>
                Existing{'\n'}loop
              </Text>
              {settings.reachingPipeline === 'standard' && (
                <View style={[styles.activeDot, { backgroundColor: C.warning }]} />
              )}
            </TouchableOpacity>
          </View>

        </Section>
          </>
        )}

        {/* ══════════════════════════════════════════
            SECTION 1.25 — Meta Ray-Ban Glasses
        ══════════════════════════════════════════ */}
        <Section title="Meta Ray-Ban Glasses">
          <Text style={styles.settingDescription}>
            Use the glasses camera feed when connected via the Meta AI app.
            Hey ShelfScout listens through the glasses microphone by default.
          </Text>

          <View style={styles.settingRow}>
            <View style={styles.settingLabelBlock}>
              <Text style={styles.settingLabel}>Use glasses camera feed</Text>
              <Text style={styles.settingSubLabel}>
                {settings.useWearablesCamera
                  ? 'Glasses feed selected'
                  : 'iPhone camera active'}
              </Text>
            </View>
            <Switch
              value={settings.useWearablesCamera}
              onValueChange={handleWearablesToggle}
              trackColor={{ false: C.border, true: C.primary }}
              thumbColor={settings.useWearablesCamera ? C.primary : C.sliderThumb}
              ios_backgroundColor={C.border}
              accessible={true}
              accessibilityRole="switch"
              accessibilityLabel="Use Meta Ray-Ban camera feed"
              accessibilityHint={
                settings.useWearablesCamera
                  ? 'Double tap to switch back to the iPhone camera.'
                  : 'Double tap to use the glasses camera feed.'
              }
              accessibilityValue={{
                text: settings.useWearablesCamera
                  ? 'Glasses camera enabled'
                  : 'Phone camera enabled',
              }}
            />
          </View>

          <View style={styles.settingRow}>
            <View style={styles.settingLabelBlock}>
              <Text style={styles.settingLabel}>Use glasses microphone</Text>
              <Text style={styles.settingSubLabel}>
                {settings.wearablesMicrophoneSource === 'wearables'
                  ? 'Default for Hey ShelfScout'
                  : 'iPhone microphone selected'}
              </Text>
            </View>
            <Switch
              value={settings.wearablesMicrophoneSource === 'wearables'}
              onValueChange={handleWearablesMicrophoneToggle}
              trackColor={{ false: C.border, true: C.primary }}
              thumbColor={
                settings.wearablesMicrophoneSource === 'wearables'
                  ? C.primary
                  : C.sliderThumb
              }
              ios_backgroundColor={C.border}
              accessible={true}
              accessibilityRole="switch"
              accessibilityLabel="Use Meta Ray-Ban microphone"
              accessibilityHint={
                settings.wearablesMicrophoneSource === 'wearables'
                  ? 'Double tap to use the iPhone microphone instead.'
                  : 'Double tap to use the glasses microphone for Hey ShelfScout.'
              }
              accessibilityValue={{
                text: settings.wearablesMicrophoneSource === 'wearables'
                  ? 'Glasses microphone selected'
                  : 'iPhone microphone selected',
              }}
            />
          </View>

          <View
            style={styles.statusRow}
            accessible={true}
            accessibilityRole="text"
            accessibilityLabel={`Glasses connection status: ${wearablesStatus}`}
          >
            <View
              style={[
                styles.statusDot,
                wearablesStatus === 'connected'
                  ? styles.statusDotConnected
                  : wearablesStatus === 'paired'
                    ? styles.statusDotPaired
                    : wearablesStatus === 'disconnected'
                      ? styles.statusDotDisconnected
                      : styles.statusDotUnknown,
              ]}
            />
            <Text style={styles.statusText}>
              {wearablesStatus === 'connected'
                ? 'Connected'
                : wearablesStatus === 'paired'
                  ? 'Paired'
                  : wearablesStatus === 'disconnected'
                    ? 'Not connected'
                    : wearablesStatus === 'unsupported'
                      ? 'Unsupported'
                      : 'Status unknown'}
            </Text>
          </View>
        </Section>

        {/* ══════════════════════════════════════════
            SECTION 1.5 — Reaching Mode (Hand-free vs With Hand)
        ══════════════════════════════════════════ */}
        {arkitReachingActive && (
          <Section title="Reaching Mode">
            <Text style={styles.settingDescription}>
              Choose how guidance works: <Text style={styles.emphasisText}>Hands-free</Text> or <Text style={styles.emphasisText}>With hand</Text>.
              {' '}Applies to {effectiveReachingPipeline === 'spatialTarget'
                ? 'on-device Spatial Target reaching'
                : 'Vision Box reaching'}.
            </Text>

            {/* Mode comparison */}
            <View style={styles.comparisonRow}>
              <TouchableOpacity
                style={[
                  styles.pipelineOption,
                  settings.reachingMode === 'handFree' && styles.pipelineOptionActive,
                ]}
                accessible={true}
                accessibilityRole="button"
                accessibilityLabel={`Hands-free mode${settings.reachingMode === 'handFree' ? ', currently selected' : ''}`}
                accessibilityHint="Double tap to select"
                onPress={async () => {
                  await updateReachingMode('handFree');
                  await speechOutput.announce('Hands-free mode enabled.');
                }}
              >
                <Text style={styles.pipelineOptionIcon}>📱</Text>
                <Text style={styles.pipelineOptionName}>Hands-free</Text>
                <Text style={styles.pipelineOptionDesc}>
                  Camera direction{'\n'}guides you
                </Text>
                {settings.reachingMode === 'handFree' && (
                  <View style={styles.activeDot} />
                )}
              </TouchableOpacity>

              <View style={styles.pipelineDivider} />

              <TouchableOpacity
                style={[
                  styles.pipelineOption,
                  settings.reachingMode === 'withHand' && styles.pipelineOptionActiveAlt,
                ]}
                accessible={true}
                accessibilityRole="button"
                accessibilityLabel={`With hand mode${settings.reachingMode === 'withHand' ? ', currently selected' : ''}`}
                accessibilityHint="Double tap to select"
                onPress={async () => {
                  await updateReachingMode('withHand');
                  await speechOutput.announce('With hand mode enabled.');
                }}
              >
                <Text style={styles.pipelineOptionIcon}>✋</Text>
                <Text style={styles.pipelineOptionName}>With hand</Text>
                <Text style={styles.pipelineOptionDesc}>
                  Hand tracking{'\n'}guides your reach
                </Text>
                {settings.reachingMode === 'withHand' && (
                  <View style={[styles.activeDot, { backgroundColor: C.warning }]} />
                )}
              </TouchableOpacity>
            </View>

            {!acquisitionAutoExitApplies && (
              <Text style={styles.settingSubLabel}>
                On-device reaching always ends on your tap — there is no backend
                to confirm the grab.
              </Text>
            )}

            {acquisitionAutoExitApplies && (
            <View style={styles.settingRow}>
              <View style={styles.settingLabelBlock}>
                <Text style={styles.settingLabel}>Auto-exit on reach</Text>
                <Text style={styles.settingSubLabel}>
                  {settings.enableAcquisitionAutoExit
                    ? 'Enabled (uses backend validation)'
                    : 'Manual exit only'}
                </Text>
              </View>
              <Switch
                value={settings.enableAcquisitionAutoExit}
                onValueChange={handleAcquisitionToggle}
                trackColor={{ false: C.border, true: C.success }}
                thumbColor={settings.enableAcquisitionAutoExit ? C.success : C.sliderThumb}
                ios_backgroundColor={C.border}
                accessible={true}
                accessibilityRole="switch"
                accessibilityLabel="Auto-exit when the object is reached"
                accessibilityHint={
                  settings.enableAcquisitionAutoExit
                    ? 'Double tap to require manual confirmation.'
                    : 'Double tap to enable automatic exit.'
                }
                accessibilityValue={{
                  text: settings.enableAcquisitionAutoExit
                    ? 'Auto-exit enabled'
                    : 'Manual exit only',
                }}
              />
            </View>
            )}
          </Section>
        )}

        {/* ══════════════════════════════════════════
            SECTION 1.6 — Distance Unit
        ══════════════════════════════════════════ */}
        {arkitReachingActive && (
          <Section title="Distance Feedback">
            <Text style={styles.settingDescription}>
              Choose how distance is spoken during guidance.
            </Text>

            <View style={styles.comparisonRow}>
              <TouchableOpacity
                style={[
                  styles.pipelineOption,
                  settings.distanceUnit === 'steps' && styles.pipelineOptionActive,
                ]}
                accessible={true}
                accessibilityRole="button"
                accessibilityLabel={`Steps${settings.distanceUnit === 'steps' ? ', currently selected' : ''}`}
                accessibilityHint="Double tap to select"
                onPress={async () => {
                  await updateDistanceUnit('steps');
                  await speechOutput.announce('Distance set to steps.');
                }}
              >
                <Text style={styles.pipelineOptionIcon}>👣</Text>
                <Text style={styles.pipelineOptionName}>Steps</Text>
                <Text style={styles.pipelineOptionDesc}>
                  "About 3 steps"
                </Text>
                {settings.distanceUnit === 'steps' && (
                  <View style={styles.activeDot} />
                )}
              </TouchableOpacity>

              <View style={styles.pipelineDivider} />

              <TouchableOpacity
                style={[
                  styles.pipelineOption,
                  settings.distanceUnit === 'cm' && styles.pipelineOptionActiveAlt,
                ]}
                accessible={true}
                accessibilityRole="button"
                accessibilityLabel={`Centimeters${settings.distanceUnit === 'cm' ? ', currently selected' : ''}`}
                accessibilityHint="Double tap to select"
                onPress={async () => {
                  await updateDistanceUnit('cm');
                  await speechOutput.announce('Distance set to centimeters.');
                }}
              >
                <Text style={styles.pipelineOptionIcon}>📏</Text>
                <Text style={styles.pipelineOptionName}>Centimeters</Text>
                <Text style={styles.pipelineOptionDesc}>
                  "150 centimeters"
                </Text>
                {settings.distanceUnit === 'cm' && (
                  <View style={[styles.activeDot, { backgroundColor: C.warning }]} />
                )}
              </TouchableOpacity>
            </View>
          </Section>
        )}

        {/* ══════════════════════════════════════════
            SECTION 2 — Voice Speed
        ══════════════════════════════════════════ */}
        <Section title="Voice Speed">
          <Text style={styles.settingDescription}>
            Adjust speaking speed. Changes apply immediately.
          </Text>

          <View style={styles.rateDisplayCompact}>
            <Text style={styles.rateLabelCompact}>Current speed</Text>
            <Text style={styles.rateValueCompact}>
              {ratePercent(localRate)} • {rateLabel(localRate)}
            </Text>
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
            <Text style={styles.sliderEndLabel}>🐢 Slow</Text>
            <Text style={styles.sliderEndLabel}>Fast 🐇</Text>
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
                accessibilityHint="Double tap to set speed"
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
                await speechOutput.speak(
                  'This is how your voice guide will sound at this speed.',
                );
              }
            }}
            accessible={true}
            accessibilityRole="button"
            accessibilityLabel="Preview voice"
            accessibilityHint="Double tap to hear a sample"
          >
            <Text style={styles.testBtnText}>▶  Preview Voice</Text>
          </TouchableOpacity>
        </Section>

        {/* ══════════════════════════════════════════
            SECTION 3 — Developer Options
        ══════════════════════════════════════════ */}
        <Section title="Developer Options">
          <Text style={styles.settingDescription}>
            Show the debug overlay during testing. Use with <Text style={styles.emphasisText}>VoiceOver off</Text>.
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
        <View style={styles.footerSpacer} />
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
    fontWeight: '700',
    letterSpacing: 0.6,
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
    letterSpacing: 0.9,
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
  statusRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: 4,
  },
  statusDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    marginRight: 8,
  },
  statusDotConnected: {
    backgroundColor: C.success,
  },
  statusDotPaired: {
    backgroundColor: C.primary,
  },
  statusDotDisconnected: {
    backgroundColor: C.warning,
  },
  statusDotUnknown: {
    backgroundColor: C.textMuted,
  },
  statusText: {
    color: C.textSecondary,
    fontSize: 12,
  },
  settingLabelBlock: { flex: 1, marginRight: 16 },
  settingLabel: {
    color: C.text,
    fontSize: 16,
    fontWeight: '600',
    letterSpacing: 0.2,
  },
  settingSubLabel: {
    color: C.textMuted,
    fontSize: 12,
    marginTop: 2,
    letterSpacing: 0.15,
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
  rateDisplayCompact: {
    marginBottom: 12,
  },
  rateLabelCompact: {
    color: C.textMuted,
    fontSize: 12,
    marginBottom: 2,
  },
  rateValueCompact: {
    color: C.primary,
    fontSize: 24,
    fontWeight: '700',
    letterSpacing: -0.3,
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

  footerSpacer: {
    height: 48,
  },
});