
export interface WorkflowRequest {
  text: string;
  imageUri: string;
  navigation?: boolean;
  reaching_flag?: boolean;
}

export interface WorkflowResponse {
  text: string;
  
  // Continuous mode flags (THREE-FLAG SYSTEM)
  navigation: boolean;
  reaching_flag: boolean;
  
  // iOS ARKit Reaching (HIGHEST PRIORITY)
  reaching_ios: boolean;
  bbox?: [number, number, number, number];  // [xmin, ymin, xmax, ymax] from Qwen detection
  object?: string;                           // Name of detected object
  
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
}

export interface IOSReachingResult {
  success: boolean;
  reached: boolean;
  error?: string;
}






