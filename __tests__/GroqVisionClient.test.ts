/* eslint-env jest */
//
// Pass 3 (the shortening pass) is the whole subject here. It mirrors the
// backend "response length" → "If6" → "Synthesize result2" loop, and the thing
// worth testing is not that it can shorten text — it is that it CANNOT make the
// spoken answer worse. The backend's version regressed silently precisely
// because nothing asserted that its output was shorter than its input.

// groq.secrets.ts is gitignored, so mock it virtually: the real file may hold
// live keys locally and is absent in CI.
jest.mock(
  '../src/config/groq.secrets',
  () => ({
    GROQ_API_KEYS: ['test-key'],
    GROQ_VISION_MODEL: 'test-vision',
    GROQ_INTENT_MODEL: 'test-text',
  }),
  { virtual: true },
);

jest.mock('react-native-fs', () => ({
  readFile: jest.fn().mockResolvedValue('BASE64DATA'),
}));

let mockLanguage = 'en';
jest.mock('../src/i18n', () => ({
  getAppLanguage: () => mockLanguage,
}));

const ok = (content: string) => ({
  ok: true,
  status: 200,
  json: async () => ({ choices: [{ message: { content }, finish_reason: 'stop' }] }),
  text: async () => '',
});

// Comfortably over the 300-char budget, so it triggers pass 3. Pre-trimmed:
// the client trims pass-2 output before measuring it, and an untrimmed fixture
// sitting one space over the line measures as under it.
const LONG = `The milk bags are on the shelf directly ahead of you at about waist height, roughly one step away. ${'There is a stack of cardboard boxes on the floor to your left that you should step around carefully. '.repeat(
  3,
)}`.trim();

describe('GroqVisionClient shortening pass', () => {
  let fetchMock: jest.Mock;
  let client: typeof import('../src/services/GroqVisionClient').groqVisionClient;

  const bodyOf = (call: number) => JSON.parse(fetchMock.mock.calls[call][1].body);
  const userMessage = (call: number) => {
    const messages = bodyOf(call).messages;
    return messages[messages.length - 1].content as string;
  };

  beforeEach(() => {
    jest.resetModules();
    mockLanguage = 'en';
    fetchMock = jest.fn();
    (globalThis as any).fetch = fetchMock;
    client = require('../src/services/GroqVisionClient').groqVisionClient;
  });

  it('skips pass 3 when the synthesized answer already fits the spoken budget', async () => {
    fetchMock
      .mockResolvedValueOnce(ok('{"pointers":"raw"}'))
      .mockResolvedValueOnce(ok('Yes, the milk bag is directly ahead at waist height.'));

    const result = await client.answerQuestion('file:///tmp/f.jpg', 'Is this the milk bag?');

    expect(result.ok).toBe(true);
    expect(result.text).toBe('Yes, the milk bag is directly ahead at waist height.');
    expect(fetchMock).toHaveBeenCalledTimes(2);
    // No pass 3 means no shortening metadata at all — the trace should not
    // imply a pass ran when the answer was simply short enough.
    expect(result.lengthBeforeShorten).toBeUndefined();
    expect(result.shortened).toBeUndefined();
  });

  it('runs pass 3 and speaks the compressed answer when pass 2 overruns', async () => {
    expect(LONG.length).toBeGreaterThan(300);
    fetchMock
      .mockResolvedValueOnce(ok('{"pointers":"raw"}'))
      .mockResolvedValueOnce(ok(LONG))
      .mockResolvedValueOnce(ok('Milk bags are one step ahead at waist height. Boxes on your left.'));

    const result = await client.answerQuestion('file:///tmp/f.jpg', 'Where are the milk bags?');

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(result.text).toBe('Milk bags are one step ahead at waist height. Boxes on your left.');
    expect(result.shortened).toBe(true);
    expect(result.lengthBeforeShorten).toBe(LONG.length);
    // The pass must see the question, or it cannot tell which half of a
    // two-part answer was the part actually asked about.
    expect(userMessage(2)).toContain('Where are the milk bags?');
  });

  it('keeps the pass-2 answer when pass 3 comes back no shorter', async () => {
    const notShorter = `${LONG} And a little more besides.`;
    fetchMock
      .mockResolvedValueOnce(ok('{"pointers":"raw"}'))
      .mockResolvedValueOnce(ok(LONG))
      .mockResolvedValueOnce(ok(notShorter));

    const result = await client.answerQuestion('file:///tmp/f.jpg', 'Where are the milk bags?');

    expect(result.ok).toBe(true);
    expect(result.text).toBe(LONG);
    expect(result.shortened).toBe(false);
    // Still reported, so a pass that never shortens anything is visible in the
    // session log rather than looking like it was never needed.
    expect(result.lengthBeforeShorten).toBe(LONG.length);
  });

  it('keeps the pass-2 answer when pass 3 fails outright', async () => {
    fetchMock
      .mockResolvedValueOnce(ok('{"pointers":"raw"}'))
      .mockResolvedValueOnce(ok(LONG))
      .mockResolvedValue({ ok: false, status: 500, text: async () => 'boom', json: async () => ({}) });

    const result = await client.answerQuestion('file:///tmp/f.jpg', 'Where are the milk bags?');

    expect(result.ok).toBe(true);
    expect(result.text).toBe(LONG);
    expect(result.shortened).toBe(false);
  });

  it('never returns an empty utterance if pass 3 returns nothing usable', async () => {
    fetchMock
      .mockResolvedValueOnce(ok('{"pointers":"raw"}'))
      .mockResolvedValueOnce(ok(LONG))
      .mockResolvedValueOnce(ok('   '));

    const result = await client.answerQuestion('file:///tmp/f.jpg', 'Where are the milk bags?');

    expect(result.text).toBe(LONG);
    expect(result.shortened).toBe(false);
  });

  it('shortens in French for a French participant', async () => {
    mockLanguage = 'fr';
    fetchMock
      .mockResolvedValueOnce(ok('{"pointers":"brut"}'))
      .mockResolvedValueOnce(ok(LONG))
      .mockResolvedValueOnce(ok('Les sacs de lait sont à un pas devant, à hauteur de taille.'));

    const result = await client.answerQuestion('file:///tmp/f.jpg', 'Où sont les sacs de lait?');

    expect(result.shortened).toBe(true);
    expect(result.text).toBe('Les sacs de lait sont à un pas devant, à hauteur de taille.');
    // An English pass-3 prompt would hand a Quebec participant an English
    // answer even though passes 1 and 2 were French.
    expect(userMessage(2)).toContain('trop longue');
    expect(userMessage(2)).not.toContain('Hard rules');
  });

  it('applies the same budget to scene descriptions', async () => {
    fetchMock
      .mockResolvedValueOnce(ok('{"environment_summary":"raw"}'))
      .mockResolvedValueOnce(ok(LONG))
      .mockResolvedValueOnce(ok('Shelf one step ahead at waist height. Boxes on your left.'));

    const result = await client.describeScene('file:///tmp/f.jpg');

    expect(fetchMock).toHaveBeenCalledTimes(3);
    expect(result.shortened).toBe(true);
  });
});
