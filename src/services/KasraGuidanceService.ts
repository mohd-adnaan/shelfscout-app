import axios from 'axios';
import { Platform } from 'react-native';
import { CONFIG, KASRA_GUIDANCE_URL } from '../utils/constants';

export interface KasraGuidanceRequest {
  objectName: string;
  imageUri: string;
}

export const sendToKasraGuidance = async (
  payload: KasraGuidanceRequest,
  signal?: AbortSignal
): Promise<void> => {
  const formData = new FormData();
  formData.append('object_name', payload.objectName);

  let imageUri = payload.imageUri;
  if (Platform.OS === 'android' && !imageUri.startsWith('file://')) {
    imageUri = `file://${imageUri}`;
  }

  formData.append('image', {
    uri: imageUri,
    type: 'image/jpeg',
    name: 'frame.jpg',
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
