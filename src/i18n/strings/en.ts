// src/i18n/strings/en.ts
//
// English string catalog. This file is the SOURCE OF TRUTH for the catalog
// shape: `fr.ts` is typed as `StringCatalog`, so TypeScript fails the build if
// a French key is missing or its interpolation signature drifts. Add keys here
// first, then translate.
//
// Only strings the user can HEAR or READ belong here. Console logs stay inline
// in English — they are developer output, not product copy.

export const en = {
  // ── Spoken + VoiceOver-announced runtime strings ─────────────────────────
  speech: {
    tapToSpeak: 'Tap to speak.',
    thinking: 'Thinking.',
    stopping: 'Stopping.',
    stoppingMode: (mode: string) => `Stopping ${mode}.`,
    noVoiceInput: 'No voice input detected. Tap to try again.',
    errorStartingVoice: 'Error starting voice. Tap to try again.',
    processingWithoutPhoto: 'Processing without photo.',
    photoCaptureFailed:
      'Warning: Failed to capture photo. Continuing with voice only.',
    stoppedTimeLimit: 'Stopped due to time limit.',
    requestFailed: 'Error processing your request. Try again.',
    genericError: (detail: string) => `Error: ${detail}`,
  },

  // ── App-shell status, announced through VoiceOver ────────────────────────
  //
  // These are announceForAccessibility calls, not TTS. They still have to be
  // localized: a blind Quebec participant runs VoiceOver in French, and an
  // English string handed to a French voice is read with French phonetics.
  status: {
    welcome:
      'ShelfScout activated. Use the voice button to start recording. Double tap the button to take a photo immediately.',
    permissionsRequiredTitle: 'Permissions Required',
    grantPermissionsButton: 'Grant Permissions',
    grantPermissionsHint: 'Use the Grant Permissions button to enable access.',
    permissionsGranted: 'Permissions granted. ShelfScout is ready to use.',
    permissionsDeniedDetail:
      'ShelfScout needs microphone and camera access to function properly. Please grant these permissions in your device settings.',
    permissionsMissing:
      'Please grant microphone and camera permissions to use ShelfScout.',
    permissionsCheckFailed:
      'Error checking permissions. Please try again or check your device settings.',
    stoppingSpeech: 'Stopping speech.',
    speechStoppedReady: 'Speech stopped. ShelfScout is ready. Tap to speak.',
    processingPleaseWait:
      'ShelfScout is processing. Please wait, or double tap to cancel.',
    stoppingRecording: 'Stopping recording and processing your command.',
    emergencyStop: 'Emergency stop. Stopping speech.',
    stoppedReady: 'Stopped. ShelfScout is ready. Tap to speak.',
    cannotInterrupt: 'Cannot interrupt while processing. Please wait for the response.',
    takingPhoto: 'Taking photo.',
    photoCaptured: 'Photo captured. Continue speaking your command.',
    photoCaptureFailedDetail: (detail: string) =>
      `Photo capture failed: ${detail}. Continue with voice command.`,
    speechRecognitionErrorTitle: 'Speech Recognition Error',
    speechRecognitionError: (detail: string) =>
      `Speech recognition error: ${detail}. Please try again.`,
    processingRequest: 'Processing your request. Please wait.',
    responseReceived: 'Response received. Speaking now.',
    responseCompleteReady: 'Response complete. ShelfScout is ready. Tap to speak.',
    errorTitle: 'Error',
  },

  // ── Reaching guidance ────────────────────────────────────────────────────
  reaching: {
    // Two clauses. "Follow the audio beeps" described what was already
    // audible and pushed the tap instruction — the one thing the user has to
    // remember to end the session — to the tail of a long sentence.
    guidingTo: (target: string) =>
      `Guiding you to ${target}. Tap the screen when you have it.`,
    reached: (object: string) => `${object} reached!`,
    ended: 'Reaching guidance ended.',
    error: (detail: string) => `Reaching error: ${detail}`,
    unknownError: 'Unknown error',
    relocalizationTimeout:
      'I could not match the saved map here. Move closer to the mapped shelf and try again.',
    mapNotFound:
      'The saved AR map for this target was not found on this device.',
    spatialTargetUnavailable:
      'Spatial Target reaching is not available. Please rebuild the app.',
    moduleUnavailable:
      'Reaching module not available. Please rebuild the app.',
    noPreciseCoordinates: (object: string) =>
      `I can detect the ${object} in the scene, but I could not get precise coordinates for guidance. Try pointing your camera more directly at it and ask again.`,
    defaultObjectName: 'object',
    /** Short form used where the beeps/tap instructions are spoken separately. */
    guidingToShort: (target: string) => `Guiding you to ${target}.`,
    guidingToInitializing: (target: string) =>
      `Guiding you to ${target}. ARKit module initializing.`,
    emptyResponse: 'Server returned empty response. Please try again.',
    navigationStopped: 'Navigation stopped. ShelfScout is ready.',
  },

  // ── ARKit route navigation ───────────────────────────────────────────────
  //
  // Everything here used to be an English literal in App.tsx, which meant a
  // French participant asking for « les oignons » and missing heard the refusal
  // — the longest, most confusing sentence in the whole session — in English,
  // read out by a French voice. Pilot, 11 Aug 2026.
  navigation: {
    targetNotFoundWithList: (target: string, known: string) =>
      `I could not find ${target} in your saved routes. Saved destinations include: ${known}.`,
    targetNotFoundNoMap: (target: string) =>
      `I could not find ${target} in your saved routes. Map it first from Settings.`,
    targetUnclear:
      'I could not identify the navigation target. Please ask for the destination again.',
    arrivedAt: (target: string) => `Arrived at ${target}.`,
    arrivedSwitchingToReaching: (target: string, object: string) =>
      `Arrived at ${target}. Switching to reaching guidance for ${object}.`,
    couldNotStartReaching: (object: string) =>
      `I could not start reaching guidance for ${object}.`,
    holdPhoneStraight:
      'Hold the phone straight with the camera facing forward, then ask again.',
    unavailableFallback:
      'ARKit navigation is not available on this device. Falling back to Rtab navigation.',
    mapNotFound: (target: string) =>
      `No saved AR route map was found for ${target}. Open Settings, Manage AR Route Maps, and map the route first.`,
    targetNotInMaps: (target: string) =>
      `${target} is not in the saved AR route maps. Add it as a destination or landmark, then try again.`,
    relocalizationFailed:
      'I could not relocalize against the saved AR map. Walk to any spot on the mapped route, hold the phone at chest height, and slowly scan the shelves.',
    arrivalUnverified: (target: string) =>
      `I could not confirm your position at ${target}. Walk along the mapped route and ask again.`,
    cancelled: 'ARKit navigation cancelled.',
    ended: 'ARKit navigation ended.',
    endedWithError: 'ARKit navigation ended with an error.',
  },

  // ── In-device orchestrator replies ───────────────────────────────────────
  //
  // What the app says when a spoken turn resolves to no action. These were
  // English literals inside MobileOrchestrator, so a French participant heard
  // them in English — and they are exactly the moments where being understood
  // matters most, because the user is already unsure whether they were heard.
  assistant: {
    didNotCatch:
      'I did not catch that. Try, for example, reach the water bottle, take me to the door, or what is in front of me.',
    couldNotAnalyzeImage: 'I could not analyze the image just now. Please try again.',
    pointCameraFirst: 'Point your camera at what you want described, then ask again.',
  },

  // ── Settings: language section ───────────────────────────────────────────
  settings: {
    languageSection: 'Language',
    languageDescription:
      'Choose the language ShelfScout speaks and listens in. Voice guidance, wake word, and on-screen text all follow this setting.',
    languageChanged: 'Language set to English.',
    languageOptionAccessibilityLabel: (language: string, selected: boolean) =>
      `${language}${selected ? ', currently selected' : ''}`,
    languageOptionAccessibilityHint: 'Double tap to select',
  },
};

/**
 * Catalog shape every language must satisfy. Derived from English so the
 * compiler enforces parity instead of a runtime check.
 */
export type StringCatalog = typeof en;
