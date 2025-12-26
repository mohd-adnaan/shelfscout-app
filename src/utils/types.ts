export interface WorkflowRequest {
  text: string;
  imageUri: string;
}

export interface WorkflowResponse {
  text: string;
  continuousMode?: boolean;
  loopDelay?: number;
}

export interface CameraPhoto {
  path: string;
  width: number;
  height: number;
}