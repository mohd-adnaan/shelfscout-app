// src/i18n/strings/fr.ts
//
// Quebec French (fr-CA) catalog.
//
// Translation notes for anyone editing this file:
//  - These strings are SPOKEN to blind and low-vision users, so they are
//    written to be heard, not read: short sentences, no abbreviations, no
//    parentheses, and no symbols a synthesizer reads awkwardly.
//  - Quebec usage is preferred over European French where they differ.
//  - French typography normally puts a narrow space before « ! » and « : ».
//    We use a plain space before the colon and none before the exclamation
//    mark, because AVSpeechSynthesizer inserts an audible pause on a
//    non-breaking space.
//
// Typed as StringCatalog: the build fails if a key is missing or a function
// signature drifts from en.ts.

import type { StringCatalog } from './en';

export const fr: StringCatalog = {
  speech: {
    tapToSpeak: 'Touchez pour parler.',
    thinking: 'Je réfléchis.',
    stopping: 'Arrêt.',
    stoppingMode: (mode: string) => `Arrêt : ${mode}.`,
    noVoiceInput: 'Aucune parole détectée. Touchez pour réessayer.',
    errorStartingVoice: 'Erreur au démarrage du micro. Touchez pour réessayer.',
    processingWithoutPhoto: 'Traitement sans photo.',
    photoCaptureFailed:
      'Attention : la photo n’a pas pu être prise. Je continue avec la voix seulement.',
    stoppedTimeLimit: 'Arrêt : limite de temps atteinte.',
    requestFailed: 'Erreur lors du traitement de votre demande. Réessayez.',
    genericError: (detail: string) => `Erreur : ${detail}`,
  },

  status: {
    welcome:
      'ShelfScout est activé. Utilisez le bouton vocal pour commencer l’enregistrement. Touchez deux fois le bouton pour prendre une photo immédiatement.',
    permissionsRequiredTitle: 'Autorisations requises',
    // The button's own visible label comes from this key, so the hint below
    // names whatever the user actually sees rather than an English label.
    grantPermissionsButton: 'Accorder les autorisations',
    grantPermissionsHint:
      'Utilisez le bouton Accorder les autorisations pour activer l’accès.',
    permissionsGranted: 'Autorisations accordées. ShelfScout est prêt.',
    permissionsDeniedDetail:
      'ShelfScout a besoin d’accéder au micro et à la caméra pour fonctionner. Accordez ces autorisations dans les réglages de votre appareil.',
    permissionsMissing:
      'Accordez les autorisations du micro et de la caméra pour utiliser ShelfScout.',
    permissionsCheckFailed:
      'Erreur lors de la vérification des autorisations. Réessayez ou vérifiez les réglages de votre appareil.',
    stoppingSpeech: 'Arrêt de la parole.',
    speechStoppedReady: 'Parole arrêtée. ShelfScout est prêt. Touchez pour parler.',
    processingPleaseWait:
      'ShelfScout traite votre demande. Patientez, ou touchez deux fois pour annuler.',
    stoppingRecording:
      'Arrêt de l’enregistrement et traitement de votre commande.',
    emergencyStop: 'Arrêt d’urgence. Arrêt de la parole.',
    stoppedReady: 'Arrêté. ShelfScout est prêt. Touchez pour parler.',
    cannotInterrupt:
      'Impossible d’interrompre pendant le traitement. Attendez la réponse.',
    takingPhoto: 'Prise de photo.',
    photoCaptured: 'Photo prise. Continuez à dicter votre commande.',
    photoCaptureFailedDetail: (detail: string) =>
      `Échec de la prise de photo : ${detail}. Continuez avec la commande vocale.`,
    speechRecognitionErrorTitle: 'Erreur de reconnaissance vocale',
    speechRecognitionError: (detail: string) =>
      `Erreur de reconnaissance vocale : ${detail}. Réessayez.`,
    processingRequest: 'Traitement de votre demande. Patientez.',
    responseReceived: 'Réponse reçue. Lecture en cours.',
    responseCompleteReady:
      'Réponse terminée. ShelfScout est prêt. Touchez pour parler.',
    errorTitle: 'Erreur',
  },

  reaching: {
    // "quand vous l'avez" fixes the object as singular; a plural target ("les
    // céréales") needs "les avez". Naming the article dodges the clitic.
    guidingTo: (target: string) =>
      `Je vous guide vers ${target}. Touchez l’écran quand vous l’avez.`,
    // NOT `${object} atteint!` — the participle would have to agree with the
    // object's gender and number, and "la bouteille atteint" also reads as the
    // present tense of atteindre. After "avoir" no agreement is required.
    reached: (object: string) => `Vous avez atteint ${object}!`,
    ended: 'Guidage terminé.',
    error: (detail: string) => `Erreur de guidage : ${detail}`,
    unknownError: 'erreur inconnue',
    // "tablette", not "étagère": in a Quebec grocery store the shelf a shopper
    // reaches for is a tablette; étagère reads as a piece of furniture.
    relocalizationTimeout:
      'Je ne reconnais pas la carte enregistrée ici. Approchez-vous de la tablette cartographiée et réessayez.',
    mapNotFound:
      'La carte AR enregistrée pour cette cible est introuvable sur cet appareil.',
    spatialTargetUnavailable:
      'Le guidage par cible spatiale n’est pas disponible. Veuillez recompiler l’application.',
    moduleUnavailable:
      'Le module de guidage n’est pas disponible. Veuillez recompiler l’application.',
    // The target arrives with its article already stripped (see
    // normalizeTarget in GroqIntentClient), so "Je détecte ${object}" produces
    // "Je détecte céréales". The colon turns it into an apposition, which is
    // grammatical for a bare noun and for one that kept its article.
    noPreciseCoordinates: (object: string) =>
      `Je détecte la cible : ${object}. Je n’ai pas pu obtenir de coordonnées précises pour le guidage. Pointez la caméra plus directement vers l’objet et redemandez.`,
    defaultObjectName: 'l’objet',
    guidingToShort: (target: string) => `Je vous guide vers ${target}.`,
    guidingToInitializing: (target: string) =>
      `Je vous guide vers ${target}. Initialisation du module ARKit.`,
    emptyResponse: 'Le serveur a renvoyé une réponse vide. Réessayez.',
    navigationStopped: 'Navigation arrêtée. ShelfScout est prêt.',
  },

  // ── Navigation par trajet ARKit ──────────────────────────────────────────
  //
  // Les libellés de destination sont interpolés tels qu’ils ont été
  // enregistrés à la cartographie, souvent en anglais (« Onions »). D’où
  // « vers Onions » plutôt qu’un tour de phrase qui exigerait le genre du
  // nom : aucune de ces formules ne doit s’accorder avec l’étiquette.
  navigation: {
    targetNotFoundWithList: (target: string, known: string) =>
      `Je ne trouve pas ${target} dans vos trajets enregistrés. Destinations disponibles : ${known}.`,
    targetNotFoundNoMap: (target: string) =>
      `Je ne trouve pas ${target} dans vos trajets enregistrés. Cartographiez-le d’abord dans les réglages.`,
    targetUnclear:
      'Je n’ai pas compris la destination. Redemandez-la, s’il vous plaît.',
    arrivedAt: (target: string) => `Vous êtes arrivé à ${target}.`,
    arrivedSwitchingToReaching: (target: string, object: string) =>
      `Vous êtes arrivé à ${target}. Je passe au guidage de préhension pour ${object}.`,
    couldNotStartReaching: (object: string) =>
      `Je n’ai pas pu démarrer le guidage de préhension pour ${object}.`,
    holdPhoneStraight:
      'Tenez le téléphone droit, caméra vers l’avant, puis redemandez.',
    unavailableFallback:
      'La navigation ARKit n’est pas disponible sur cet appareil. Je bascule sur la navigation Rtab.',
    mapNotFound: (target: string) =>
      `Aucune carte de trajet AR enregistrée pour ${target}. Ouvrez les réglages, Gérer les cartes de trajet AR, et cartographiez le trajet d’abord.`,
    targetNotInMaps: (target: string) =>
      `${target} ne figure pas dans les cartes de trajet AR enregistrées. Ajoutez-le comme destination ou point de repère, puis réessayez.`,
    relocalizationFailed:
      'Je n’arrive pas à me repérer sur la carte AR enregistrée. Placez-vous n’importe où sur le trajet cartographié, tenez le téléphone à hauteur de poitrine et balayez lentement les tablettes.',
    arrivalUnverified: (target: string) =>
      `Je n’ai pas pu confirmer votre position à ${target}. Marchez le long du trajet cartographié et redemandez.`,
    cancelled: 'Navigation ARKit annulée.',
    ended: 'Navigation ARKit terminée.',
    endedWithError: 'La navigation ARKit s’est terminée par une erreur.',
  },

  // ── Réponses de l’orchestrateur en mode local ────────────────────────────
  //
  // Les exemples de « didNotCatch » sont des commandes que l’utilisateur peut
  // répéter telles quelles : ce sont donc de vraies commandes françaises, pas
  // la traduction des exemples anglais.
  assistant: {
    didNotCatch:
      'Je n’ai pas bien compris. Essayez, par exemple : prends la bouteille d’eau, amène-moi à la porte, ou qu’est-ce qu’il y a devant moi.',
    couldNotAnalyzeImage: 'Je n’ai pas pu analyser l’image. Réessayez.',
    pointCameraFirst:
      'Pointez la caméra vers ce que vous voulez faire décrire, puis redemandez.',
  },

  settings: {
    languageSection: 'Langue',
    languageDescription:
      'Choisissez la langue dans laquelle ShelfScout parle et vous écoute. Le guidage vocal, le mot d’activation et le texte à l’écran suivent ce réglage.',
    languageChanged: 'Langue réglée sur le français.',
    languageOptionAccessibilityLabel: (language: string, selected: boolean) =>
      `${language}${selected ? ', actuellement sélectionné' : ''}`,
    languageOptionAccessibilityHint: 'Touchez deux fois pour sélectionner',
  },
};
