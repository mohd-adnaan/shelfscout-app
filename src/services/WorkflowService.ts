import axios from 'axios';
import { Platform } from 'react-native';
import {  WORKFLOW_URL, CONFIG } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse } from '../utils/types';

export const sendToWorkflow = async (
  request: WorkflowRequest
): Promise<WorkflowResponse> => {
  try {
    const formData = new FormData();
    
    //Change 'text' to 'transcript'
    formData.append('transcript', request.text);
    
    // add required fields for n8n
    formData.append('user_id', 'mobile-user');
    formData.append('request_id', `mobile-${Date.now()}`);
    formData.append('session_id', `mobile-session-${Date.now()}`);
    formData.append('continuousMode', 'false');

    let imageUri = request.imageUri;
    if (Platform.OS === 'android' && !imageUri.startsWith('file://')) {
      imageUri = `file://${imageUri}`;
    }

    // add image file
    formData.append('image', {
      uri: imageUri, 
      type: 'image/jpeg',
      name: 'photo.jpg',
    } as any);

    console.log('🚀 Sending to workflow:', WORKFLOW_URL);
    console.log('Transcript:', request.text);  // Changed log text
    console.log('Image URI:', imageUri); 

    const response = await axios.post<WorkflowResponse>(
      WORKFLOW_URL,
      formData,
      {
        headers: {
          'Content-Type': 'multipart/form-data',
          'Accept': 'application/json',
        },
        timeout: CONFIG.REQUEST_TIMEOUT,
      }
    );

    console.log('✅ Workflow response:', response.data);
    return response.data;
  } catch (error) {
    console.error('❌ Workflow request error:', error);
    if (axios.isAxiosError(error)) {
      console.error('Response data:', error.response?.data);
      console.error('Response status:', error.response?.status);
    }
    throw error;
  }
};
