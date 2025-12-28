import axios from 'axios';
import RNFS from 'react-native-fs';
import { WORKFLOW_URL } from '../utils/constants';
import { WorkflowRequest, WorkflowResponse } from '../utils/types';

export const sendToWorkflow = async (request: WorkflowRequest): Promise<WorkflowResponse> => {
  try {
    console.log('🚀 Sending to workflow:', WORKFLOW_URL);
    console.log('Text:', request.text);
    console.log('Image URI:', request.imageUri);

    // Read image as base64
    const imageUri = request.imageUri.replace('file://', '');
    const base64Image = await RNFS.readFile(imageUri, 'base64');
    console.log('✅ Image read, size:', base64Image.length);

    // Send as JSON 
    const response = await axios.post(
      WORKFLOW_URL,
      {
        transcript: request.text,  // Field name from n8n
        image: base64Image,        // Base64 string
        continuousMode: false
      },
      {
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
        timeout: 30000,
      }
    );

    console.log('✅ SUCCESS! Response:', response.data);
    
    return {
      text: response.data.text || response.data.transcript || '',
    };
    
  } catch (error) {
    console.error('❌ Request failed:', error);
    if (axios.isAxiosError(error)) {
      console.error('Status:', error.response?.status);
      console.error('Data:', error.response?.data);
    }
    throw error;
  }
};