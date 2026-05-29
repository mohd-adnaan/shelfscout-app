import axios from 'axios';
import { Platform } from 'react-native';
import { CONFIG, KASRA_GUIDANCE_URL } from '../utils/constants';

export interface KasraGuidanceRequest {
  objectName: string;
  imageUri: string;
  frameId?: string;
  capturedAtMs?: number;
}

export const sendToKasraGuidance = async (
  payload: KasraGuidanceRequest,
  signal?: AbortSignal
): Promise<void> => {
  const formData = new FormData();
  formData.append('object_name', payload.objectName);

  const capturedAtMs = payload.capturedAtMs ?? Date.now();
  const frameId = payload.frameId ?? `rtab-${capturedAtMs}`;
  formData.append('frame_id', frameId);
  formData.append('captured_at_ms', String(capturedAtMs));

  let imageUri = payload.imageUri;
  if (Platform.OS === 'android' && !imageUri.startsWith('file://')) {
    imageUri = `file://${imageUri}`;
  }

  formData.append('image', {
    uri: imageUri,
    type: 'image/jpeg',
    name: `${frameId.replace(/[^a-zA-Z0-9_-]/g, '_')}.jpg`,
  } as any);

  await axios.post(KASRA_GUIDANCE_URL, formData, {
    headers: {
      'Content-Type': 'multipart/form-data',
      'Accept': 'application/json',
    },
    timeout: CONFIG.REQUEST_TIMEOUT,
    signal,
  });
};
