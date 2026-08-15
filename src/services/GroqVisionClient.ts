// src/services/GroqVisionClient.ts
//
// On-device vision orchestration via Groq — the frontend equivalent of the
// backend Scene / Object / Chat vision nodes, now with EXACT two-pass parity:
//
//   Pass 1 (vision):     the multimodal model returns structured JSON, using
//                        the same system/user prompts as the backend Config
//                        nodes plus the user's profile traits.
//   Pass 2 (synthesize): a fast text model turns that JSON into a short spoken
//                        answer, styled by trait_comm_style — mirroring the
//                        backend "Synthesize result" node.
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
  "You are helping a blind shopper understand their immediate surroundings. Describe ONLY what is clearly visible in the image. Hard rules: - AT MOST 3 short sentences. Stop there even if more is visible. - NEAREST FIRST: start with what is within arm's reach or a step away, then anything further. Never open with the far end of the aisle. - Lead with the sentence that would change what the user does next. - State position (left, right, ahead, behind) and distance in metres or steps for anything you name. - Name products and fixtures only when you can identify them. If you cannot tell what something is, leave it out — do not describe it as unclear, vague, or possible. - Never describe floors, lighting, colours, signage style, or general ambience. - No preamble, no summary sentence, no offers of further help. Start with the object.";

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
const USR_CHAT = (transcript: string) =>
  `You are a virtual AI assistant for a blind or low-vision user. Answer in AT MOST 2 short sentences, spoken aloud. Answer the question and nothing else — no preamble, no restating the question, no offer of further help. If the question can be answered yes or no, the FIRST word is "Yes" or "No"; then name what you actually see, and if it is not what they asked about, say what it is instead. Avoid lighting, colours, layout and other detail unless it is what was asked about. If the image cannot answer the question, say so in one sentence.\n\nAnswer this question by the user: "${transcript}".`;

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
- AT MOST 3 short sentences, and stop. This is spoken aloud to someone standing in a store aisle: a minute of speech is a minute they cannot move.
- Nearest first. What is within reach outranks what is at the end of the aisle.
- Drop anything the input hedges about. If the data is unsure what something is, it does not get said at all.
- No preamble ("Here is what I can see…"), no closing offer of help, no restating the question.`;

const USR_SYNTHESIZE = (content: string) => `VISUAL INFORMATION:\n${content}\nNow Begin!`;

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
  'Tu aides une personne aveugle à comprendre ce qui l’entoure immédiatement. Décris UNIQUEMENT ce qui est clairement visible sur l’image. Règles strictes : - AU PLUS 3 phrases courtes. Arrête-toi là, même s’il reste des choses visibles. - LE PLUS PRÈS D’ABORD : commence par ce qui est à portée de main ou à un pas, puis seulement ce qui est plus loin. Ne commence jamais par le fond de l’allée. - Mets en premier la phrase qui change ce que la personne fera ensuite. - Indique la position (à gauche, à droite, devant, derrière) et la distance en mètres ou en pas pour chaque chose que tu nommes. - Ne nomme un produit ou un meuble que si tu peux l’identifier. Si tu n’arrives pas à dire ce que c’est, ne le mentionne pas : n’écris pas que c’est flou, vague ou possible. - Ne décris jamais le plancher, l’éclairage, les couleurs, l’allure des affiches ni l’ambiance générale. - Aucune introduction, aucune phrase de conclusion, aucune offre d’aide supplémentaire. Commence directement par l’objet.';

const SYS_CHAT_FR = `${TRAIT_VISION_PROFILE_FR}

Tu es un assistant visuel précis. Ton objectif est de répondre à la question de l’utilisateur en te fondant strictement sur ce que montre l’image.

Format de sortie :
Retourne un objet JSON avec exactement ces clés. Les NOMS DES CLÉS restent en anglais ; leurs VALEURS sont rédigées en français :
- "visual_reasoning" : une courte réflexion interne qui vérifie si l’image permet de répondre à la question. Sinon, explique pourquoi.
- "pointers" : une réponse brève à la question de l’utilisateur, en t’appuyant sur l’image au besoin.
- "visual_data" : une description objective et détaillée des éléments visuels pertinents pour la question.`;

const USR_CHAT_FR = (transcript: string) =>
  `Tu es un assistant pour une personne aveugle ou malvoyante. Réponds en AU PLUS 2 phrases courtes, lues à voix haute. Réponds à la question et rien d’autre : aucune introduction, aucune reformulation de la question, aucune offre d’aide à la fin. Si la question appelle une réponse par oui ou non, le PREMIER mot est « Oui » ou « Non » ; nomme ensuite ce que tu vois vraiment, et si ce n’est pas ce qu’on te demandait, dis ce que c’est à la place. Évite l’éclairage, les couleurs, l’agencement et les autres détails, sauf si c’est précisément ce qu’on te demande. Si l’image ne permet pas de répondre, dis-le en une phrase.\n\nRéponds à cette question de l’utilisateur : « ${transcript} ».`;

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
- AU PLUS 3 phrases courtes, puis arrête-toi. C’est lu à voix haute à quelqu’un debout dans une allée : une minute de parole, c’est une minute sans bouger.
- Le plus près d’abord. Ce qui est à portée de main passe avant le fond de l’allée.
- Écarte tout ce dont les données ne sont pas sûres. Si l’entrée hésite sur ce qu’est un objet, il ne se dit pas du tout.
- Aucune introduction (« Voici ce que je vois… »), aucune offre d’aide à la fin, aucune reformulation de la question.`;

const USR_SYNTHESIZE_FR = (content: string) =>
  `INFORMATION VISUELLE :\n${content}\nCommence maintenant!`;

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
const USR_CHAT_BY_LANGUAGE: Record<AppLanguage, (transcript: string) => string> = {
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

export interface GroqVisionResult {
  ok: boolean;
  text?: string;
  provider: 'groq_vision' | 'none';
  fallbackReason?: string;
  twoPass?: boolean;
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
    return this.twoPass(SYS_SCENE_BY_LANGUAGE[language], userText, imageUri);
  }

  async answerQuestion(imageUri: string, transcript: string): Promise<GroqVisionResult> {
    const language = getAppLanguage();
    return this.twoPass(
      SYS_CHAT_BY_LANGUAGE[language],
      USR_CHAT_BY_LANGUAGE[language](transcript.trim()),
      imageUri,
    );
  }

  // Pass 1: vision → structured JSON. Pass 2: JSON → spoken text.
  private async twoPass(
    visionSystem: string,
    visionUserText: string,
    imageUri: string,
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

    return { ok: true, provider: 'groq_vision', text: synth.text.trim(), twoPass: true };
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