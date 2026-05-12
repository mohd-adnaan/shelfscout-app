export interface WorkflowRequest {
  text: string;
  imageUri: string;
  imageWidth?: number;   
  imageHeight?: number;
  navigation?: boolean;
  reaching_flag?: boolean;
  reaching_ios?: boolean;
  // Sent once per fresh client session (app open OR resetSessionId).
  // Backend uses this to reinitialize Melody's tracker container so it
  // doesn't stay locked on a stale target from the previous session.
  session_start?: boolean;
}

export interface WorkflowResponse {
  text: string;
  
  // Continuous mode flags (THREE-FLAG SYSTEM)
  navigation: boolean;
  reaching_flag: boolean;
  reaching_completed?: boolean;
  
  // iOS ARKit Reaching (HIGHEST PRIORITY)
  reaching_ios: boolean;
  
  bbox?: [number, number, number, number];  // [xmin, ymin, xmax, ymax] from Qwen detection
  object?: string;                           // Name of detected object
  depth?: string;
  hand_direction?: string;
  annotated_image?: string;

  // Melody's tracker is locked on the target → backend has stopped
  // querying Qwen for this iteration. Informational for now (logged);
  // backend gates the Qwen call internally based on this flag.
  tracking_active?: boolean;

  // RTAB navigation completion signal (Kasra). When `reached === true`
  // and the loop is currently in navigation mode, the app force-switches
  // to reaching mode so the next iteration requests reaching processing.
  reached?: boolean;
  
  // Loop control
  loopDelay: number;
  session_id?: string;
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