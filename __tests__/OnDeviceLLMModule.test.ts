describe('OnDeviceLLMModule bridge', () => {
  afterEach(() => {
    jest.resetModules();
    jest.dontMock('react-native');
  });

  const loadBridge = (nativeModules: Record<string, any> = {}, os = 'ios') => {
    jest.resetModules();
    jest.doMock('react-native', () => ({
      Platform: {
        OS: os,
        select: (values: Record<string, any>) => values[os] ?? values.default,
      },
      NativeModules: nativeModules,
    }));
    return require('../src/native/OnDeviceLLMModule').OnDeviceLLMBridge as typeof import('../src/native/OnDeviceLLMModule').OnDeviceLLMBridge;
  };

  it('reports a precise iOS unavailable reason when the native module is not linked', async () => {
    const bridge = loadBridge();

    await expect(bridge.isAvailable()).resolves.toMatchObject({
      available: false,
      usedProvider: 'none',
      needsBackend: true,
      fallbackReason: 'on_device_llm_not_linked',
      appleFmAvailable: false,
      appleFmUnavailableReason: 'on_device_llm_not_linked',
    });

    await expect(bridge.classifyIntent({ text: 'take me to cereal' })).resolves.toMatchObject({
      available: false,
      fallbackReason: 'on_device_llm_not_linked',
      appleFmUnavailableReason: 'on_device_llm_not_linked',
    });
  });

  it('uses the linked native module on iOS when present', async () => {
    const native = {
      isAvailable: jest.fn().mockResolvedValue({
        available: true,
        usedProvider: 'apple_foundation_models',
        confidence: 1,
        needsBackend: false,
        appleFmAvailable: true,
      }),
      classifyIntent: jest.fn(),
      detectTurnEnd: jest.fn(),
      rewriteGuidance: jest.fn(),
    };
    const bridge = loadBridge({ OnDeviceLLMModule: native });

    await expect(bridge.isAvailable()).resolves.toMatchObject({
      available: true,
      usedProvider: 'apple_foundation_models',
    });
    expect(native.isAvailable).toHaveBeenCalledTimes(1);
  });
});
