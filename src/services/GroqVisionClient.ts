// src/services/GroqVisionClient.ts
//
// On-device vision orchestration via Groq — the frontend equivalent of the
// backend Scene / Object / Chat vision nodes, now with EXACT three-pass parity:
//
//   Pass 1 (vision):     the multimodal model returns structured JSON, using
//                        the same system/user prompts as the backend Config
//                        nodes plus the user's profile traits.
//   Pass 2 (synthesize): a fast text model turns that JSON into a short spoken
//                        answer, styled by trait_comm_style — mirroring the
//                        backend "Synthesize result" node.
//   Pass 3 (shorten):    ONLY if pass 2 came back over SPOKEN_MAX_CHARS, the
//                        same text model compresses it again — mirroring the
//                        backend "response length" → "If6" → "Synthesize
//                        result2" loop. Skipped entirely on short answers, so
//                        the common case still costs two calls.
//
// Before Pass 1 the captured frame is DOWNSCALED via the native
// ImageOrientationFixer (max 768px, q0.7) so the base64 upload is small and
// fast. If the resizer is unavailable we fall back to the full frame.
//
// Profile traits are copied from the backend Profile/Style/Mode nodes and are
// tunable here (or via optional exports in groq.secrets.ts).

import { NativeModules, Platform } from 'react-native';
import RNFS from 'react-native-fs';
import { AppLanguage, getAppLanguage } from '../i18n';

let GROQ_API_KEYS: string[] = [];
let GROQ_VISION_MODEL = 'qwen/qwen3.6-27b';
let GROQ_TEXT_MODEL = 'llama-3.3-70b-versatile';
try {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const secrets = require('../config/groq.secrets');
  GROQ_API_KEYS = Array.isArray(secrets.GROQ_API_KEYS) ? secrets.GROQ_API_KEYS : [];
  if (typeof secrets.GROQ_VISION_MODEL === 'string') GROQ_VISION_MODEL = secrets.GROQ_VISION_MODEL;
  if (typeof secrets.GROQ_INTENT_MODEL === 'string') GROQ_TEXT_MODEL = secrets.GROQ_INTENT_MODEL;
} catch {
  // groq.secrets.ts absent — client reports unconfigured; caller degrades.
}

const GROQ_URL = 'https://api.groq.com/openai/v1/chat/completions';
const VISION_TIMEOUT_MS = 20000;
const SYNTH_TIMEOUT_MS = 8000;

// Length gate for the shortening pass, mirroring the backend "response length"
// node (`answer.length > 300`). Kept at the backend's number so the two
// pipelines stay comparable in the study — this is a spoken-length budget, not
// a token budget: ~300 characters is about 8 seconds of TTS, which is already
// long for someone standing still in an aisle waiting to move.
const SPOKEN_MAX_CHARS = 300;

// Groq reserves max_tokens against the per-minute token budget, and the vision
// model's free-tier ceiling is 8k TPM — so this is sized to the ~450 tokens a
// scene JSON actually costs plus headroom, not set as high as it could go.
const VISION_MAX_TOKENS = 800;

// Downscale target for the vision upload. 768px is plenty for scene/object
// description and cuts a ~1152x2048 (~600KB) frame to well under ~150KB.
const VISION_MAX_DIM = 768;
const VISION_JPEG_QUALITY = 0.7;

// ── Profile traits (backend Profile/Style/Mode defaults; tunable) ───────────
const TRAIT_VISION_PROFILE =
  'The user is completely blind. Avoid visual references like colors or lighting unless they impact safety. Emphasize tactile details (texture, shape, size) and auditory cues.';
const TRAIT_COMM_STYLE =
  'Respond in a direct, efficient manner. Keep answers short and focused to key relevant information.';
const TRAIT_NAV_MODE =
  'Provide cautious, descriptive guidance. actively warn about potential hazards (flimsy shelves, edges) and describe the layout broadly.';

// ── Backend Config prompts (verbatim intent) ────────────────────────────────
const SYS_SCENE = `${TRAIT_VISION_PROFILE}

You are a vision assistant analyzing an environment. Focus on extracting navigable space, major obstacles, and layout data.

Output Format:
Return a JSON object with exactly these keys:
- "layout_data": List visible pathways, aisles, or open spaces with approximate dimensions if possible.
- "hazard_data": List immediate hazards (boxes on floor, people, poles) with location. Only things that are actually in the way — omit anything you cannot identify.
- "environment_summary": At most 2 short factual sentences, nearest thing first. Not a survey of the room.`;

// Pilot feedback, 11 Aug 2026: a minute-long description that opened with the
// floor being shiny, put the far end of the aisle before what was an arm's
// length away, and hedged about "vague cardboard boxes" that turned out to be
// nothing. Every rule below is one of those, negated. The nearest-first
// ordering and the hard sentence cap are the two that matter most — length is
// not controlled by asking for "concise", only by a number the model can count.
const USR_SCENE =
  "You are helping a blind person understand what is in front of them right now. Describe ONLY what is clearly visible. Hard rules: - AT MOST 2 short sentences. One is better. Stop there even if more is visible. - Say only what changes what they do next: what is in their path, what is within reach, and where it is. Everything else is noise — leave it out. - NEAREST FIRST. Never open with the far end of the room. - State side (left, right, ahead) and distance in metres or steps for anything you name. - Name a thing only if you can identify it. If you cannot tell what it is, say nothing about it — never \"unclear\", \"possible\", or \"appears to be\". - Never mention floors, lighting, colours, signage style, or ambience. - No preamble, no summary, no offer of help. First word is the thing itself.";

const SYS_CHAT = `${TRAIT_VISION_PROFILE}

You are a precise vision assistant. Your goal is to answer the user's question based strictly on visual evidence from the image.

Output Format:
Return a JSON object with exactly these keys:
- "visual_reasoning": A short internal thought checking if the user's question can be answered by the image. If not, state why.
- "pointers": A brief response to the user's question, looking at image if needed.
- "visual_data": A detailed, objective description of the visual elements relevant to the question.`;

// The yes/no rule is the whole answer to a verification question ("is this the
// milk bag?"). A user holding the item wants the verdict first and can stop
// listening there; a description that eventually implies the verdict makes them
// wait through it and then infer it.
const USR_CHAT = (transcript: string, subject?: string) => {
  // The subject clause is what makes a verification question answerable at
  // all. "Is this the correct object?" names nothing — without it the model
  // is handed a photo and a pronoun. See `visionAnswerInDevice`.
  const subjectClause = subject
    ? `In this session the user is looking for: "${subject}". Any "this", "it", "the object" or "the correct one" in their question means "${subject}".\n\n`
    : '';
  return `You are answering out loud for a blind user who is standing still, waiting. Every word costs them time.\n\n${subjectClause}Hard rules: - ONE short sentence. Two only if the second one is genuinely needed. - Answer the question asked and nothing else. No preamble, no restating the question, no offer of help. - Yes/no question: the FIRST word is "Yes" or "No". If No, say what it actually is in the same sentence. - If the image does not show what was asked about, say that plainly and briefly — for a price, "No price tag is visible." — and stop. Do not guess, do not describe the packaging instead, do not explain why you cannot tell. - Mention colour, lighting or layout only if that is what was asked about.\n\nThe user asked: "${transcript}".`;
};

// The "phrased EXACTLY as received" rule is a behavioral contract, not a style
// note: clock positions, distances and sequence markers are what the reaching
// and navigation layers emit, and paraphrasing them strands the user.
const SYS_SYNTHESIZE = `${TRAIT_COMM_STYLE}

You are a helpful assistant for a blind user. Your goal is to synthesize the provided technical data into a helpful, natural spoken response.

INPUT DATA:
You will receive raw JSON data describing the scene, objects, or spatial relationships.

TASK:
1. Interpret the JSON data.
2. Formulate a response that adheres to the User's Profile: ${TRAIT_VISION_PROFILE}
3. Adjust your tone and length according to: ${TRAIT_COMM_STYLE}

RULES:
- Only summarize the given input in a clear and understandable manner. Do not add unspecified content.
- Responses that deal with locating an object must be phrased EXACTLY as received with no processing (preserve clock positions, distances, and sequence markers exactly).
For other responses:
- Use natural language. No JSON or technical jargon in the output.
- AT MOST 2 short sentences, and stop. One is better. This is spoken aloud to someone standing still waiting for it: a minute of speech is a minute they cannot move.
- Nearest first. What is within reach outranks what is at the end of the aisle.
- Drop anything the input hedges about. If the data is unsure what something is, it does not get said at all.
- No preamble ("Here is what I can see…"), no closing offer of help, no restating the question.`;

const USR_SYNTHESIZE = (content: string) => `VISUAL INFORMATION:\n${content}\nNow Begin!`;

// Pass 3, the backend "Synthesize result2" node. Two things this prompt has to
// get right that the backend's version did not:
//   1. It must be STRICTLY tighter than pass 2, never looser. The backend asked
//      pass 1 for "1-3 sentences" and pass 2 for "2-3", so a long single
//      sentence could legally come back longer than it went in.
//   2. It is a compression of an already-written answer, not a fresh answer, so
//      it gets the user's question as well — without it the model cannot tell
//      which half of a two-part answer was the part actually asked about.
// The sentence cap is a number rather than "be concise" for the same reason as
// USR_SCENE: models comply with counts and ignore adjectives.
const USR_SHORTEN = (transcript: string, answer: string) =>
  `The following answer is too long to speak aloud. Compress it.\n\n${
    transcript.trim() ? `The user asked: "${transcript.trim()}"\n\n` : ''
  }Answer to compress:\n${answer}\n\nHard rules: - AT MOST 2 short sentences and under ${SPOKEN_MAX_CHARS} characters. - Your output MUST be shorter than the answer above. - Keep only what answers the question; drop every other detail. - Preserve any clock position, distance, measurement or step count EXACTLY as written. - Keep the first word if it is "Yes" or "No". - Output only the compressed answer: no preamble, no explanation, no quotes around it.`;

// ── French (fr-CA) prompts ─────────────────────────────────────────────────
//
// These are what a Quebec participant actually hears: scene descriptions and
// chat answers are free text straight from the model, so an English prompt
// produces an English answer no matter what language they asked in.
//
// Same contract split as GroqIntentClient: the JSON KEY NAMES stay English
// because parseVisionJson reads them, and only the VALUES are French. The
// prompts say so explicitly — a fully French prompt otherwise tempts the model
// to translate the keys too, which silently empties the parse.
//
// Distances are asked for in metres or steps, never feet: Quebec is metric and
// the navigation layer already speaks "mètres" / "pas".

const TRAIT_VISION_PROFILE_FR =
  'L’utilisateur est complètement aveugle. Évite les références visuelles comme les couleurs ou l’éclairage, sauf si elles touchent à la sécurité. Mets l’accent sur les détails tactiles (texture, forme, taille) et sur les repères sonores.';
const TRAIT_COMM_STYLE_FR =
  'Réponds de façon directe et efficace. Garde les réponses courtes et centrées sur l’information essentielle.';

const SYS_SCENE_FR = `${TRAIT_VISION_PROFILE_FR}

Tu es un assistant visuel qui analyse un environnement. Concentre-toi sur l’espace où l’on peut circuler, les obstacles importants et l’aménagement des lieux.

Format de sortie :
Retourne un objet JSON avec exactement ces clés. Les NOMS DES CLÉS restent en anglais ; leurs VALEURS sont rédigées en français :
- "layout_data" : les passages, allées ou espaces libres visibles, avec leurs dimensions approximatives si possible.
- "hazard_data" : les dangers immédiats (boîtes au sol, personnes, poteaux) avec leur position.
- "environment_summary" : un résumé factuel et dense de ce que contient le lieu.`;

const USR_SCENE_FR =
  'Tu aides une personne aveugle à comprendre ce qu’il y a devant elle en ce moment. Décris UNIQUEMENT ce qui est clairement visible. Règles strictes : - AU PLUS 2 phrases courtes. Une seule, c’est mieux. Arrête-toi là, même s’il reste des choses visibles. - Ne dis que ce qui change ce que la personne fera ensuite : ce qui se trouve sur son chemin, ce qui est à portée de main, et où. Le reste est du bruit : écarte-le. - LE PLUS PRÈS D’ABORD. Ne commence jamais par le fond de la pièce. - Indique le côté (à gauche, à droite, devant) et la distance en mètres ou en pas pour chaque chose que tu nommes. - Ne nomme une chose que si tu peux l’identifier. Sinon, n’en parle pas du tout : jamais « flou », « possible » ni « on dirait ». - Ne mentionne jamais le plancher, l’éclairage, les couleurs, l’allure des affiches ni l’ambiance. - Aucune introduction, aucune conclusion, aucune offre d’aide. Le premier mot est la chose elle-même.';

const SYS_CHAT_FR = `${TRAIT_VISION_PROFILE_FR}

Tu es un assistant visuel précis. Ton objectif est de répondre à la question de l’utilisateur en te fondant strictement sur ce que montre l’image.

Format de sortie :
Retourne un objet JSON avec exactement ces clés. Les NOMS DES CLÉS restent en anglais ; leurs VALEURS sont rédigées en français :
- "visual_reasoning" : une courte réflexion interne qui vérifie si l’image permet de répondre à la question. Sinon, explique pourquoi.
- "pointers" : une réponse brève à la question de l’utilisateur, en t’appuyant sur l’image au besoin.
- "visual_data" : une description objective et détaillée des éléments visuels pertinents pour la question.`;

const USR_CHAT_FR = (transcript: string, subject?: string) => {
  const subjectClause = subject
    ? `Dans cette session, l’utilisateur cherche : « ${subject} ». Tout « ceci », « ça », « l’objet » ou « le bon » dans sa question désigne « ${subject} ».\n\n`
    : '';
  return `Tu réponds à voix haute à une personne aveugle qui est debout, immobile, en train d’attendre. Chaque mot lui coûte du temps.\n\n${subjectClause}Règles strictes : - UNE phrase courte. Deux seulement si la seconde est vraiment nécessaire. - Réponds à la question posée et à rien d’autre. Aucune introduction, aucune reformulation, aucune offre d’aide. - Question par oui ou non : le PREMIER mot est « Oui » ou « Non ». Si c’est « Non », dis dans la même phrase ce que c’est réellement. - Si l’image ne montre pas ce qu’on te demande, dis-le simplement et brièvement — pour un prix : « Aucune étiquette de prix n’est visible. » — puis arrête-toi. Ne devine pas, ne décris pas l’emballage à la place, n’explique pas pourquoi tu ne peux pas voir. - Ne parle de couleur, d’éclairage ou d’agencement que si c’est précisément ce qu’on te demande.\n\nL’utilisateur a demandé : « ${transcript} ».`;
};

const SYS_SYNTHESIZE_FR = `${TRAIT_COMM_STYLE_FR}

Tu es un assistant qui aide une personne aveugle. Ton objectif est de transformer les données techniques fournies en une réponse orale naturelle et utile.

DONNÉES D’ENTRÉE :
Tu reçois des données JSON brutes décrivant la scène, des objets ou des relations spatiales.

TÂCHE :
1. Interprète les données JSON.
2. Formule une réponse conforme au profil de l’utilisateur : ${TRAIT_VISION_PROFILE_FR}
3. Ajuste ton ton et ta longueur selon : ${TRAIT_COMM_STYLE_FR}

RÈGLES :
- Réponds TOUJOURS en français. C’est la langue de l’utilisateur, même si les données d’entrée sont en anglais.
- Résume seulement ce qui est fourni, de façon claire et compréhensible. N’ajoute rien qui ne soit pas dans les données.
- Les réponses qui situent un objet doivent reprendre EXACTEMENT la formulation reçue, sans retraitement : conserve telles quelles les positions horaires, les distances et les marqueurs de séquence.
Pour les autres réponses :
- Emploie un langage naturel. Aucun JSON ni jargon technique dans la sortie.
- AU PLUS 2 phrases courtes, puis arrête-toi. Une seule, c’est mieux. C’est lu à voix haute à quelqu’un qui attend debout : une minute de parole, c’est une minute sans bouger.
- Le plus près d’abord. Ce qui est à portée de main passe avant le fond de l’allée.
- Écarte tout ce dont les données ne sont pas sûres. Si l’entrée hésite sur ce qu’est un objet, il ne se dit pas du tout.
- Aucune introduction (« Voici ce que je vois… »), aucune offre d’aide à la fin, aucune reformulation de la question.`;

const USR_SYNTHESIZE_FR = (content: string) =>
  `INFORMATION VISUELLE :\n${content}\nCommence maintenant!`;

// Pass 3 in French. This mirror is not optional: pass 3 rewrites the sentence
// the participant actually hears, so an English prompt here would hand a
// Quebec participant an English answer even though passes 1 and 2 were French —
// the exact failure this file's French block was added to prevent.
const USR_SHORTEN_FR = (transcript: string, answer: string) =>
  `La réponse suivante est trop longue à lire à voix haute. Comprime-la.\n\n${
    transcript.trim() ? `L’utilisateur a demandé : « ${transcript.trim()} »\n\n` : ''
  }Réponse à comprimer :\n${answer}\n\nRègles strictes : - AU PLUS 2 phrases courtes et moins de ${SPOKEN_MAX_CHARS} caractères. - Ta sortie DOIT être plus courte que la réponse ci-dessus. - Ne garde que ce qui répond à la question ; écarte tout le reste. - Conserve EXACTEMENT telles quelles les positions horaires, les distances, les mesures et les nombres de pas. - Garde le premier mot s’il s’agit de « Oui » ou « Non ». - Réponds en français. - Ne donne que la réponse comprimée : aucune introduction, aucune explication, aucun guillemet autour.`;

// ── Per-language prompt selection ──────────────────────────────────────────

const SYS_SCENE_BY_LANGUAGE: Record<AppLanguage, string> = {
  en: SYS_SCENE,
  fr: SYS_SCENE_FR,
};
const USR_SCENE_BY_LANGUAGE: Record<AppLanguage, string> = {
  en: USR_SCENE,
  fr: USR_SCENE_FR,
};
const SYS_CHAT_BY_LANGUAGE: Record<AppLanguage, string> = {
  en: SYS_CHAT,
  fr: SYS_CHAT_FR,
};
const USR_CHAT_BY_LANGUAGE: Record<AppLanguage, (transcript: string, subject?: string) => string> = {
  en: USR_CHAT,
  fr: USR_CHAT_FR,
};
const SYS_SYNTHESIZE_BY_LANGUAGE: Record<AppLanguage, string> = {
  en: SYS_SYNTHESIZE,
  fr: SYS_SYNTHESIZE_FR,
};
const USR_SYNTHESIZE_BY_LANGUAGE: Record<AppLanguage, (content: string) => string> = {
  en: USR_SYNTHESIZE,
  fr: USR_SYNTHESIZE_FR,
};
const USR_SHORTEN_BY_LANGUAGE: Record<
  AppLanguage,
  (transcript: string, answer: string) => string
> = {
  en: USR_SHORTEN,
  fr: USR_SHORTEN_FR,
};

export interface GroqVisionResult {
  ok: boolean;
  text?: string;
  provider: 'groq_vision' | 'none';
  fallbackReason?: string;
  /** Pass 2 produced the text. False means it failed and this is the raw-JSON fallback. */
  twoPass?: boolean;
  /** Pass 3 ran and its output was accepted (i.e. it really was shorter). */
  shortened?: boolean;
  /** Spoken length before pass 3, so a regression shows up in the trace. */
  lengthBeforeShorten?: number;
}

let keyCursor = 0;
const nextKey = (): string | null => {
  if (GROQ_API_KEYS.length === 0) return null;
  const key = GROQ_API_KEYS[keyCursor % GROQ_API_KEYS.length];
  keyCursor += 1;
  return key;
};

const stripFileScheme = (uri: string): string =>
  uri.startsWith('file://') ? uri.replace('file://', '') : uri;

const guessMime = (path: string): string => {
  const lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/jpeg';
};

const extractJson = (text?: string): string | null => {
  if (!text) return null;
  const start = text.indexOf('{');
  const end = text.lastIndexOf('}');
  if (start === -1 || end === -1 || end <= start) return text.trim() || null;
  return text.slice(start, end + 1);
};

class GroqVisionClient {
  isConfigured(): boolean {
    return GROQ_API_KEYS.length > 0;
  }

  /**
   * Downscale the captured frame for a small/fast upload, then read as a
   * base64 data URL. Reuses the native ImageOrientationFixer resizer (already
   * shipped); falls back to the full-size original if resizing is unavailable.
   */
  private async toDataUrl(imageUri: string): Promise<string | null> {
    let path = stripFileScheme(imageUri);
    try {
      const fixer = (NativeModules as any).ImageOrientationFixer;
      if (Platform.OS === 'ios' && fixer?.fixOrientation) {
        const resized = await fixer.fixOrientation(imageUri, VISION_MAX_DIM, VISION_JPEG_QUALITY);
        if (resized?.path || resized?.uri) {
          path = stripFileScheme(resized.path || resized.uri);
        }
      }
    } catch (error: any) {
      console.warn('[GroqVision] Downscale failed, using full frame:', error?.message || error);
      path = stripFileScheme(imageUri);
    }

    try {
      const base64 = await RNFS.readFile(path, 'base64');
      if (!base64) return null;
      return `data:${guessMime(path)};base64,${base64}`;
    } catch (error: any) {
      console.warn('[GroqVision] Image read failed:', error?.message || error);
      return null;
    }
  }

  async describeScene(imageUri: string, transcript?: string): Promise<GroqVisionResult> {
    const language = getAppLanguage();
    const userText = (transcript && transcript.trim()) || USR_SCENE_BY_LANGUAGE[language];
    return this.runPasses(SYS_SCENE_BY_LANGUAGE[language], userText, imageUri, transcript || '');
  }

  /// `subject` names the thing the session is about, so a question that only
  /// says "this" or "the correct object" resolves to something. Optional: a
  /// question asked cold has no subject, and the prompt then omits the clause
  /// rather than inventing one.
  async answerQuestion(
    imageUri: string,
    transcript: string,
    subject?: string,
  ): Promise<GroqVisionResult> {
    const language = getAppLanguage();
    return this.runPasses(
      SYS_CHAT_BY_LANGUAGE[language],
      USR_CHAT_BY_LANGUAGE[language](transcript.trim(), subject?.trim() || undefined),
      imageUri,
      transcript,
    );
  }

  // Pass 1: vision → structured JSON. Pass 2: JSON → spoken text.
  // Pass 3 (only when pass 2 overruns): spoken text → shorter spoken text.
  private async runPasses(
    visionSystem: string,
    visionUserText: string,
    imageUri: string,
    transcript: string,
  ): Promise<GroqVisionResult> {
    if (!this.isConfigured()) return { ok: false, provider: 'none', fallbackReason: 'groq_not_configured' };
    if (!imageUri) return { ok: false, provider: 'none', fallbackReason: 'no_image' };

    const dataUrl = await this.toDataUrl(imageUri);
    if (!dataUrl) return { ok: false, provider: 'none', fallbackReason: 'image_read_failed' };

    // ── Pass 1: vision ──
    const vision = await this.post(
      GROQ_VISION_MODEL,
      [
        { role: 'system', content: visionSystem },
        {
          role: 'user',
          content: [
            { type: 'text', text: visionUserText },
            { type: 'image_url', image_url: { url: dataUrl } },
          ],
        },
      ],
      { jsonMode: true, timeout: VISION_TIMEOUT_MS, maxTokens: VISION_MAX_TOKENS, noReasoning: true },
    );
    if (!vision.ok || !vision.text) {
      return { ok: false, provider: 'none', fallbackReason: vision.fallbackReason || 'vision_failed' };
    }

    const structured = extractJson(vision.text) || vision.text;

    // ── Pass 2: synthesize to speech ──
    // Re-read the language here rather than passing it down from the caller:
    // Pass 1 can take 20 s, and this is the pass whose output is spoken, so it
    // should follow the setting as it stands when the answer is produced.
    const synthLanguage = getAppLanguage();
    const synth = await this.post(
      GROQ_TEXT_MODEL,
      [
        { role: 'system', content: SYS_SYNTHESIZE_BY_LANGUAGE[synthLanguage] },
        { role: 'user', content: USR_SYNTHESIZE_BY_LANGUAGE[synthLanguage](structured) },
      ],
      { jsonMode: false, timeout: SYNTH_TIMEOUT_MS, maxTokens: 200 },
    );

    // If synthesize fails, fall back to a best-effort read of the structured JSON.
    if (!synth.ok || !synth.text) {
      const fallback = this.flattenStructured(structured);
      if (fallback) return { ok: true, provider: 'groq_vision', text: fallback, twoPass: false };
      return { ok: false, provider: 'none', fallbackReason: synth.fallbackReason || 'synthesize_failed' };
    }

    const spoken = synth.text.trim();
    if (spoken.length <= SPOKEN_MAX_CHARS) {
      return { ok: true, provider: 'groq_vision', text: spoken, twoPass: true };
    }

    // ── Pass 3: shorten ──
    const shortened = await this.shorten(spoken, transcript);
    return {
      ok: true,
      provider: 'groq_vision',
      text: shortened ?? spoken,
      twoPass: true,
      shortened: shortened !== null,
      lengthBeforeShorten: spoken.length,
    };
  }

  /**
   * Compress an over-long spoken answer. Returns null — meaning "keep what you
   * had" — whenever the pass cannot be trusted, so this can only ever shorten
   * the utterance, never lengthen it, empty it, or block it.
   *
   * The result is checked in code as well as asked for in the prompt. That
   * belt-and-braces is deliberate: the backend relied on the prompt alone and
   * its shortening pass silently ran with the wrong instructions for weeks
   * without anybody noticing, because a summarizer that returns the text
   * unchanged looks exactly like a summarizer that is working.
   */
  private async shorten(answer: string, transcript: string): Promise<string | null> {
    const language = getAppLanguage();
    const pass = await this.post(
      GROQ_TEXT_MODEL,
      [
        { role: 'system', content: SYS_SYNTHESIZE_BY_LANGUAGE[language] },
        { role: 'user', content: USR_SHORTEN_BY_LANGUAGE[language](transcript, answer) },
      ],
      { jsonMode: false, timeout: SYNTH_TIMEOUT_MS, maxTokens: 150 },
    );

    if (!pass.ok || !pass.text) {
      console.warn(`[GroqVision] Shorten pass failed (${pass.fallbackReason}); speaking pass-2 answer`);
      return null;
    }

    const candidate = pass.text.trim();
    if (!candidate || candidate.length >= answer.length) {
      console.warn(
        `[GroqVision] Shorten pass did not shorten (${answer.length} → ${candidate.length}); speaking pass-2 answer`,
      );
      return null;
    }
    return candidate;
  }

  // Best-effort spoken fallback if the synthesize pass fails.
  private flattenStructured(jsonText: string): string | null {
    try {
      const o = JSON.parse(jsonText);
      const parts = [
        o.pointers,
        o.environment_summary,
        o.visual_data,
        Array.isArray(o.hazard_data) ? o.hazard_data.join('. ') : o.hazard_data,
      ].filter((v) => typeof v === 'string' && v.trim());
      return parts.length ? parts.join(' ') : null;
    } catch {
      return jsonText && jsonText.length < 600 ? jsonText : null;
    }
  }

  private async post(
    model: string,
    messages: unknown[],
    opts: { jsonMode: boolean; timeout: number; maxTokens: number; noReasoning?: boolean },
  ): Promise<{ ok: boolean; text?: string; fallbackReason?: string }> {
    // The vision model is a reasoning model: left to itself it spends the whole
    // completion budget thinking and returns empty content, which json_object
    // rejects as json_validate_failed. `reasoning_effort: 'none'` is what makes
    // it answer directly — but plain models (the pass-2 synthesizer) 400 on the
    // parameter, and a future vision model may too, so it is requested only
    // where it is needed and dropped if the API objects.
    let sendNoReasoning = opts.noReasoning === true;
    for (let attempt = 0; attempt < Math.min(2, GROQ_API_KEYS.length + 1); attempt += 1) {
      const key = nextKey();
      if (!key) return { ok: false, fallbackReason: 'groq_no_key' };

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), opts.timeout);
      try {
        const res = await fetch(GROQ_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${key}` },
          body: JSON.stringify({
            model,
            temperature: 0.2,
            max_tokens: opts.maxTokens,
            ...(sendNoReasoning ? { reasoning_effort: 'none' } : {}),
            ...(opts.jsonMode ? { response_format: { type: 'json_object' } } : {}),
            messages,
          }),
          signal: controller.signal,
        });
        clearTimeout(timer);
        if (res.status === 429) continue;
        if (!res.ok) {
          // A retired model id, a revoked key and a malformed frame all arrive
          // here and all reach the user as the same "I could not analyze the
          // image". Logging the status is what separates them: a decommissioned
          // vision model went undiagnosed through a whole session because this
          // reason only ever went into a trace nobody printed.
          const body = await res.text().catch(() => '');
          if (sendNoReasoning && body.includes('reasoning_effort')) {
            // Model doesn't take the parameter — drop it and spend one retry
            // rather than failing the request over a capability flag.
            sendNoReasoning = false;
            console.warn(`[GroqVision] ${model} rejected reasoning_effort; retrying without it`);
            continue;
          }
          console.warn(`[GroqVision] ${model} HTTP ${res.status}: ${body.slice(0, 200)}`);
          return { ok: false, fallbackReason: `groq_http_${res.status}` };
        }
        const data = await res.json();
        const content: string | undefined = data?.choices?.[0]?.message?.content;
        const text = typeof content === 'string' ? content.trim() : '';
        if (!text) {
          // Usually a reasoning model that spent the whole completion budget
          // thinking, so the finish reason is the diagnostic worth keeping.
          console.warn(
            `[GroqVision] ${model} returned empty content (finish_reason=${data?.choices?.[0]?.finish_reason})`,
          );
          return { ok: false, fallbackReason: 'groq_empty_content' };
        }
        return { ok: true, text };
      } catch (error: any) {
        clearTimeout(timer);
        const aborted = error?.name === 'AbortError';
        if (attempt >= 1) {
          return { ok: false, fallbackReason: aborted ? 'groq_timeout' : `groq_error:${error?.message || 'unknown'}` };
        }
      }
    }
    return { ok: false, fallbackReason: 'groq_exhausted' };
  }
}

export const groqVisionClient = new GroqVisionClient();