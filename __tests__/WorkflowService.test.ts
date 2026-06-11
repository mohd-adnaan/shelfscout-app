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
});
