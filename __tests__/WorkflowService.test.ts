jest.mock('@react-native-async-storage/async-storage', () => ({
  getItem: jest.fn().mockResolvedValue(null),
  setItem: jest.fn().mockResolvedValue(undefined),
  removeItem: jest.fn().mockResolvedValue(undefined),
}));

import { parseWorkflowResponse } from '../src/services/WorkflowService';

describe('parseWorkflowResponse', () => {
  it('preserves ARKit navigation pipeline when response text is null', () => {
    const parsed = parseWorkflowResponse({
      response: null,
      navigation_pipeline: 'arkit',
      navigation_target: 'coffee',
      route_map_id: 'map-1',
    });

    expect(parsed.text).toBe('');
    expect(parsed.navigation_pipeline).toBe('arkit');
    expect(parsed.navigation_target).toBe('coffee');
    expect(parsed.route_map_id).toBe('map-1');
  });

  it('accepts backend string variants for navigation_pipeline', () => {
    const parsed = parseWorkflowResponse({
      json: JSON.stringify({
        response: null,
        navigationPipeline: 'navigation_pipeline:arkit',
        target_name: 'pasta',
      }),
    });

    expect(parsed.text).toBe('');
    expect(parsed.navigation_pipeline).toBe('arkit');
    expect(parsed.navigation_target).toBe('pasta');
  });

  it('handles the n8n ARKit response body when text is null', () => {
    const parsed = parseWorkflowResponse({
      text: null,
      reached: null,
      navigation: 'false',
      reaching_flag: 'false',
      reaching_ios: 'false',
      navigation_pipeline: 'arkit',
      object: 'crave cereal',
      loopDelay: 2500,
    });

    expect(parsed.text).toBe('');
    expect(parsed.navigation).toBe(false);
    expect(parsed.reaching_ios).toBe(false);
    expect(parsed.navigation_pipeline).toBe('arkit');
    expect(parsed.object).toBe('crave cereal');
    expect(parsed.loopDelay).toBe(2500);
  });

  it('preserves local LLM observability fields', () => {
    const parsed = parseWorkflowResponse({
      response: null,
      navigation_pipeline: 'arkit',
      local_orchestrator_used: 'true',
      local_llm_used: 'true',
      llm_provider: 'apple_foundation_models',
      intent_provider: 'apple_foundation_models',
      llm_fallback_reason: 'foundation_models_unavailable',
      apple_fm_available: 'false',
      apple_fm_unavailable_reason: 'foundation_models_model_not_ready',
      provider_trace: JSON.stringify([
        {
          provider: 'apple_foundation_models',
          ok: false,
          fallbackReason: 'foundation_models_model_not_ready',
        },
      ]),
    });

    expect(parsed.local_orchestrator_used).toBe(true);
    expect(parsed.local_llm_used).toBe(true);
    expect(parsed.llm_provider).toBe('apple_foundation_models');
    expect(parsed.intent_provider).toBe('apple_foundation_models');
    expect(parsed.llm_fallback_reason).toBe('foundation_models_unavailable');
    expect(parsed.apple_fm_available).toBe(false);
    expect(parsed.apple_fm_unavailable_reason).toBe('foundation_models_model_not_ready');
    expect(parsed.provider_trace?.[0]?.provider).toBe('apple_foundation_models');
  });
});
