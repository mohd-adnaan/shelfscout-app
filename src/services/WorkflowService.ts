import axios from 'axios';
import RNFS from 'react-native-fs';
import { WEBHOOK_URL, CONFIG } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse } from '../utils/types';

export const sendToWorkflow = async (
  request: WorkflowRequest
): Promise<WorkflowResponse> => {
  try {
    const formData = new FormData();
    
    // Add text field
    formData.append('text', request.text);

    // Add image file
    formData.append('image', {
      uri: request.imageUri,
      type: 'image/jpeg',
      name: 'photo.jpg',
    } as any);

    console.log('Sending to workflow:', WEBHOOK_URL);
    console.log('Text:', request.text);
    console.log('Image URI:', request.imageUri);

    const response = await axios.post<WorkflowResponse>(
      WEBHOOK_URL,
      formData,
      {
        headers: {
          'Content-Type': 'multipart/form-data',
          'Accept': 'application/json',
        },
        timeout: CONFIG.REQUEST_TIMEOUT,
      }
    );

    console.log('Workflow response:', response.data);
    return response.data;
  } catch (error) {
    console.error('Workflow request error:', error);
    if (axios.isAxiosError(error)) {
      console.error('Response data:', error.response?.data);
      console.error('Response status:', error.response?.status);
    }
    throw error;
  }
};