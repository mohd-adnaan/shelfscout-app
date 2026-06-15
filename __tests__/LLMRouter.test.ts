describe('LLMRouter', () => {
  afterEach(() => {
    jest.resetModules();
    jest.dontMock('react-native');
  });

  const loadRouter = (nativeModules: Record<string, any> = {}, os = 'ios') => {
    jest.resetModules();
    jest.doMock('react-native', () => ({
      Platform: {
        OS: os,
        select: (values: Record<string, any>) => values[os] ?? values.default,
      },
      NativeModules: nativeModules,
    }));
    return require('../src/services/LLMRouter').llmRouter as typeof import('../src/services/LLMRouter').llmRouter;
  };

  it('falls back to local turn-end detection when Apple provider is unavailable', async () => {
    const llmRouter = loadRouter();

    const result = await llmRouter.detectTurnEnd({
      transcript: 'take me to the cereal aisle',
      silenceDurationMs: 1800,
      silenceThresholdMs: 1500,
    });

    expect(result.usedProvider).toBe('heuristic');
    expect(result.needsBackend).toBe(false);
    expect(result.json?.shouldAutoSubmit).toBe(true);
  });

  it('keeps image and reaching requests on the backend path', async () => {
    const llmRouter = loadRouter();

    const result = await llmRouter.classifyIntent({
      text: 'find the red mug',
      hasImage: true,
    });

    expect(result.needsBackend).toBe(true);
    expect(result.fallbackReason).toBe('vision_or_reaching_requires_backend');
  });

  it('discard local guidance rewrites that invent navigation facts', async () => {
    const llmRouter = loadRouter({
      OnDeviceLLMModule: {
        rewriteGuidance: jest.fn().mockResolvedValue({
          available: true,
          usedProvider: 'apple_foundation_models',
          confidence: 0.9,
          needsBackend: false,
          json: JSON.stringify({ text: 'Turn left in 4 meters.', confidence: 0.9 }),
        }),
      },
    });

    const result = await llmRouter.rewriteGuidance({
      instruction: 'Walk 2 meters, toward the cereal aisle.',
      routeStatus: 'Route locked',
      isInstructionSafe: true,
    });

    expect(result.needsBackend).toBe(false);
    expect(result.fallbackReason).toBe('local_guidance_hallucinated_navigation_fact');
    expect(result.json?.text).toBe('Walk 2 meters, toward the cereal aisle.');
  });
});
