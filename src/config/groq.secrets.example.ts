// src/config/groq.secrets.example.ts
// Copy this file to src/config/groq.secrets.ts and set your real key(s).
// groq.secrets.ts is gitignored — never commit real keys.
//
// You may provide several keys; the client round-robins on rate-limit (429)
// to spread load across the team's Groq accounts.

export const GROQ_API_KEYS: string[] = [
  'gsk_your_groq_key_here',
];

// Text model used for on-device intent extraction (mirrors the backend
// "Extract Intent" node). llama-3.3-70b-versatile is fast + accurate.
export const GROQ_INTENT_MODEL = 'llama-3.3-70b-versatile';

// Multimodal model for on-device scene/object/general vision queries.
// Groq retires models without notice and a retired id 404s at request time,
// which reaches a blind user as "I could not analyze the image" — check this
// id against GET /openai/v1/models when vision starts failing.
export const GROQ_VISION_MODEL = 'qwen/qwen3.6-27b';