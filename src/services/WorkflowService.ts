import axios from 'axios';
import RNFS from 'react-native-fs';
import { WORKFLOW_URL } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse } from '../utils/types';

export const sendToWorkflow = async (request: WorkflowRequest): Promise<WorkflowResponse> => {
  try {
    console.log('🚀 Sending to workflow:', WORKFLOW_URL);
    console.log('Text:', request.text);
    console.log('Image URI:', request.imageUri);

    const imageUri = request.imageUri.replace('file://', '');
    
    // Create FormData matching n8n's expected format
    const formData = new FormData();
    
    // n8n expects 'transcript', not 'text'!
    formData.append('transcript', request.text);
    
    // add other fields that n8n expects
    formData.append('user_id', 'mobile-user');
    formData.append('request_id', `mobile-${Date.now()}`);
    formData.append('session_id', `mobile-session-${Date.now()}`);
    formData.append('continuousMode', 'false');
    
    // image stays the same
    formData.append('image', {
      uri: imageUri,
      type: 'image/jpeg',
      name: 'photo.jpg',
    } as any);

    console.log('📤 Sending FormData to server...');

    const response = await axios.post(WORKFLOW_URL, formData, {
      headers: {
        'Content-Type': 'multipart/form-data',
        'Accept': 'application/json',
      },
      timeout: 30000,
    });

    console.log('✅✅ SUCCESS! Full response:', JSON.stringify(response.data));
    
    const responseText = response.data.text || 
                        response.data.message || 
                        response.data.response ||
                        (typeof response.data === 'string' ? response.data : null);
    
    console.log('Parsed text:', responseText);
    
    return {
      text: responseText || 'No response from server',
    };
    
  } catch (error) {
    console.error('❌❌ Request failed:', error);
    if (axios.isAxiosError(error)) {
      console.error('Status:', error.response?.status);
      console.error('Data:', error.response?.data);
    }
    throw error;
  }
};
