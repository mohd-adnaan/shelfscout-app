export interface WorkflowRequest {
  text: string;
  imageUri: string;
  imageWidth?: number;   
  imageHeight?: number;
  cameraIntrinsics?: {
    schema?: string;
    source?: string;
    orientation?: string;
    image_width?: number;
    image_height?: number;
    fx?: number;
    fy?: number;
    cx?: number;
    cy?: number;
    K?: number[][];
    K_row_major?: number[];
    raw_capture?: unknown;
  };
  navigation?: boolean;
  navigation_pipeline?: 'rtab' | 'arkit';
  navigation_ios_preferred?: boolean;
  reaching_flag?: boolean;
  reaching_ios?: boolean;
  // Sent once per fresh client session (app open OR resetSessionId).
  // Backend uses this to reinitialize Melody's tracker container so it
  // doesn't stay locked on a stale target from the previous session.
  session_start?: boolean;

  // Local orchestration observability. These are optional because older
  // backend contracts do not require them.
  local_orchestrator_used?: boolean;
  local_llm_used?: boolean;
  llm_provider?: string;
  llm_fallback_reason?: string;
  intent_provider?: string;
  local_intent_json?: unknown;
  apple_fm_available?: boolean;
  apple_fm_unavailable_reason?: string;
  provider_trace?: ProviderTraceEntry[];
}

export interface WorkflowResponse {
  text: string;
  
  // Continuous mode flags (THREE-FLAG SYSTEM)
  navigation: boolean;
  navigation_ios?: boolean;
  navigation_arkit?: boolean;
  navigation_pipeline?: 'rtab' | 'arkit';
  navigation_target?: string;
  route_map_id?: string;
  route_map_name?: string;
  targetWorldPosition?: { x: number; y: number; z: number } | [number, number, number];
  target_world_position?: { x: number; y: number; z: number } | [number, number, number];
  navigation_error?: string;
  local_orchestrator_used?: boolean;
  intent_provider?: string;
  provider_trace?: ProviderTraceEntry[];
  apple_fm_available?: boolean;
  apple_fm_unavailable_reason?: string;
  local_llm_used?: boolean;
  llm_provider?: string;
  llm_fallback_reason?: string;
  reaching_flag: boolean;
  reaching_completed?: boolean;
  
  // iOS ARKit Reaching (HIGHEST PRIORITY)
  reaching_ios: boolean;
  
  bbox?: [number, number, number, number];  // [xmin, ymin, xmax, ymax] from Qwen detection
  object?: string;                           // Name of detected object
  depth?: string;
  hand_direction?: string;
  annotated_image?: string;
  confidence?: number;

  // Melody's tracker is locked on the target → backend has stopped
  // querying Qwen for this iteration. Informational for now (logged);
  // backend gates the Qwen call internally based on this flag.
  tracking_active?: boolean;

  // RTAB navigation completion signal (Rtab). When `reached === true`
  // and the loop is currently in navigation mode, the app force-switches
  // to reaching mode so the next iteration requests reaching processing.
  reached?: boolean;
  
  // Loop control
  loopDelay: number;
  session_id?: string;
}

export interface ProviderTraceEntry {
  provider: string;
  ok: boolean;
  confidence?: number;
  needsRemote?: boolean;
  fallbackReason?: string;
  diagnostics?: Record<string, unknown>;
}

export interface ProviderResult<T = unknown> {
  ok: boolean;
  provider: string;
  confidence: number;
  data?: T;
  needsRemote: boolean;
  fallbackReason?: string;
  diagnostics?: Record<string, unknown>;
}

export interface CameraPhoto {
  path: string;
  width: number;
  height: number;
}

export interface ContinuousModeState {
  isActive: boolean;
  mode: 'navigation' | 'reaching' | null;
  iterationCount: number;
  lastRequestTime: number;
  currentLoopDelay: number;
}

// iOS ARKit types for Nicolas's CybsGuidance module
export interface IOSReachingParams {
  bbox: [number, number, number, number];
  object: string;
  depth?: string;
}

export interface IOSReachingResult {
  success: boolean;
  reached: boolean;
  error?: string;
}
