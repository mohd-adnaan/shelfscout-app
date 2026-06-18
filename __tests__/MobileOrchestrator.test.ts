const createAsyncStorageMock = () => {
  const store = new Map<string, string>();
  return {
    getItem: jest.fn((key: string) => Promise.resolve(store.get(key) ?? null)),
    setItem: jest.fn((key: string, value: string) => {
      store.set(key, value);
      return Promise.resolve();
    }),
    removeItem: jest.fn((key: string) => {
      store.delete(key);
      return Promise.resolve();
    }),
    clear: jest.fn(() => {
      store.clear();
      return Promise.resolve();
    }),
  };
};

describe('MobileOrchestrator', () => {
  afterEach(() => {
    jest.resetModules();
    jest.dontMock('react-native');
    jest.dontMock('@react-native-async-storage/async-storage');
  });

  const loadOrchestrator = (
    nativeModules: Record<string, any> = {},
    os = 'ios',
  ) => {
    jest.resetModules();
    const asyncStorage = createAsyncStorageMock();
    jest.doMock('@react-native-async-storage/async-storage', () => asyncStorage);
    jest.doMock('react-native', () => ({
      Platform: {
        OS: os,
        select: (values: Record<string, any>) => values[os] ?? values.default,
      },
      NativeModules: nativeModules,
    }));
    return {
      asyncStorage,
      mobileOrchestrator: require('../src/services/MobileOrchestrator').mobileOrchestrator as typeof import('../src/services/MobileOrchestrator').mobileOrchestrator,
    };
  };

  const backendWorkflowProvider = jest.fn().mockResolvedValue({
    text: 'Remote answer.',
    navigation: false,
    reaching_flag: false,
    reaching_ios: false,
    loopDelay: 2500,
  });

  beforeEach(() => {
    backendWorkflowProvider.mockClear();
  });

  it('starts text-only iOS navigation locally without using a local LLM when only heuristics are available', async () => {
    const { mobileOrchestrator } = loadOrchestrator();

    const result = await mobileOrchestrator.process(
      {
        text: 'take me to the cereal aisle',
        imageUri: '',
      },
      undefined,
      {
        backendWorkflowProvider,
        getSessionId: () => 'session-1',
      },
    );

    expect(backendWorkflowProvider).not.toHaveBeenCalled();
    expect(result.navigation).toBe(true);
    expect(result.navigation_pipeline).toBe('arkit');
    expect(result.navigation_target).toBe('the cereal aisle');
    expect(result.local_orchestrator_used).toBe(true);
    expect(result.local_llm_used).toBe(false);
    expect(result.intent_provider).toBe('heuristic');
    expect(result.apple_fm_available).toBe(false);
    expect(result.provider_trace?.some((entry) => entry.provider === 'local_navigation' && entry.ok)).toBe(true);
  });

  it('keeps image scene requests on the backend vision path while preserving local orchestration diagnostics', async () => {
    const { mobileOrchestrator } = loadOrchestrator();

    const result = await mobileOrchestrator.process(
      {
        text: "what's in front",
        imageUri: 'file:///tmp/frame.jpg',
        imageWidth: 1280,
        imageHeight: 720,
      },
      undefined,
      {
        backendWorkflowProvider,
        getSessionId: () => 'session-2',
      },
    );

    expect(backendWorkflowProvider).toHaveBeenCalledTimes(1);
    const delegatedRequest = backendWorkflowProvider.mock.calls[0][0];
    expect(delegatedRequest.local_orchestrator_used).toBe(true);
    expect(delegatedRequest.local_llm_used).toBe(false);
    expect(delegatedRequest.provider_trace.some((entry: any) => entry.provider === 'vision_object_backend')).toBe(true);
    expect(result.text).toBe('Remote answer.');
    expect(result.local_orchestrator_used).toBe(true);
    expect(result.local_llm_used).toBe(false);
    expect(result.intent_provider).toBe('heuristic');
  });

  it('falls back to backend for text-only requests when local intent is not actionable', async () => {
    const { mobileOrchestrator } = loadOrchestrator();

    const result = await mobileOrchestrator.process(
      {
        text: 'hello there',
        imageUri: '',
      },
      undefined,
      {
        backendWorkflowProvider,
        getSessionId: () => 'session-vague',
      },
    );

    expect(backendWorkflowProvider).toHaveBeenCalledTimes(1);
    const delegatedRequest = backendWorkflowProvider.mock.calls[0][0];
    expect(delegatedRequest.local_orchestrator_used).toBe(true);
    expect(delegatedRequest.local_llm_used).toBe(false);
    expect(delegatedRequest.apple_fm_available).toBe(false);
    expect(delegatedRequest.apple_fm_unavailable_reason).toBe('on_device_llm_not_linked');
    expect(delegatedRequest.llm_fallback_reason).toBe('low_confidence_intent');
    expect(delegatedRequest.provider_trace.some((entry: any) =>
      entry.provider === 'backend_workflow' &&
      entry.diagnostics?.delegatedTo === 'backend_workflow',
    )).toBe(true);
    expect(result.text).toBe('Remote answer.');
    expect(result.local_orchestrator_used).toBe(true);
    expect(result.local_llm_used).toBe(false);
    expect(result.apple_fm_unavailable_reason).toBe('on_device_llm_not_linked');
  });

  it('surfaces exact Apple Foundation Models unavailable reasons', async () => {
    const { mobileOrchestrator } = loadOrchestrator({
      OnDeviceLLMModule: {
        isAvailable: jest.fn().mockResolvedValue({
          available: false,
          usedProvider: 'none',
          confidence: 0,
          needsBackend: true,
          fallbackReason: 'foundation_models_model_not_ready',
          appleFmAvailable: false,
          appleFmUnavailableReason: 'foundation_models_model_not_ready',
        }),
        classifyIntent: jest.fn().mockResolvedValue({
          available: false,
          usedProvider: 'none',
          confidence: 0,
          needsBackend: true,
          fallbackReason: 'foundation_models_model_not_ready',
        }),
      },
    });

    const result = await mobileOrchestrator.process(
      {
        text: 'take me to pasta',
        imageUri: '',
      },
      undefined,
      {
        backendWorkflowProvider,
        getSessionId: () => 'session-3',
      },
    );

    expect(result.navigation).toBe(true);
    expect(result.local_llm_used).toBe(false);
    expect(result.apple_fm_available).toBe(false);
    expect(result.apple_fm_unavailable_reason).toBe('foundation_models_model_not_ready');
    expect(result.intent_provider).toBe('heuristic');
  });

  it('marks local_llm_used only when Apple Foundation Models actually classify the intent', async () => {
    const { mobileOrchestrator } = loadOrchestrator({
      OnDeviceLLMModule: {
        isAvailable: jest.fn().mockResolvedValue({
          available: true,
          usedProvider: 'apple_foundation_models',
          confidence: 1,
          needsBackend: false,
          appleFmAvailable: true,
        }),
        classifyIntent: jest.fn().mockResolvedValue({
          available: true,
          usedProvider: 'apple_foundation_models',
          confidence: 0.88,
          needsBackend: false,
          json: JSON.stringify({
            intent: 'navigation',
            target: 'milk',
            needsImage: false,
            confidence: 0.88,
          }),
        }),
      },
    });

    const result = await mobileOrchestrator.process(
      {
        text: 'guide me to milk',
        imageUri: '',
      },
      undefined,
      {
        backendWorkflowProvider,
        getSessionId: () => 'session-4',
      },
    );

    expect(backendWorkflowProvider).not.toHaveBeenCalled();
    expect(result.navigation_target).toBe('milk');
    expect(result.local_llm_used).toBe(true);
    expect(result.intent_provider).toBe('apple_foundation_models');
    expect(result.apple_fm_available).toBe(true);
  });
});
