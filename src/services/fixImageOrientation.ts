/**
 * fixImageOrientation.ts
 * 
 * Calls the native ImageOrientationFixer module to apply EXIF rotation
 * to actual pixel data BEFORE sending the image to the backend.
 * 
 * WHY: iPhone camera stores all photos as landscape pixels + EXIF tag.
 *      Qwen/backend reads raw pixels, ignores EXIF → sees sideways image.
 *      This module bakes the rotation into the pixels so the backend
 *      always receives an upright image regardless of phone orientation.
 * 
 * USAGE:
 *   import { fixImageOrientation } from './fixImageOrientation';
 *   
 *   const photo = await cameraRef.current.takePhoto({ ... });
 *   const fixed = await fixImageOrientation(photo.path);
 *   // fixed.uri is the corrected image path → send to backend
 */

import { NativeModules, Platform } from 'react-native';

const { ImageOrientationFixer } = NativeModules;

interface FixedImage {
  uri: string;
  path: string;
  width: number;
  height: number;
  size: number;
}

/**
 * Fix image orientation by applying EXIF rotation to pixel data.
 * 
 * @param imagePath - Path to the original photo (from takePhoto())
 * @param maxDimension - Max width/height in pixels (default 2048, saves bandwidth)
 * @param quality - JPEG quality 0-1 (default 0.85)
 * @returns FixedImage with uri to the corrected file
 */
export async function fixImageOrientation(
  imagePath: string,
  maxDimension: number = 2048,
  quality: number = 0.85
): Promise<FixedImage> {
  if (Platform.OS !== 'ios') {
    // Android handles orientation differently; pass through for now
    console.log('📐 [OrientationFix] Android — skipping (not needed)');
    return {
      uri: imagePath.startsWith('file://') ? imagePath : `file://${imagePath}`,
      path: imagePath.replace('file://', ''),
      width: 0,
      height: 0,
      size: 0,
    };
  }

  if (!ImageOrientationFixer) {
    console.warn('⚠️ [OrientationFix] Native module not available, using original');
    return {
      uri: imagePath.startsWith('file://') ? imagePath : `file://${imagePath}`,
      path: imagePath.replace('file://', ''),
      width: 0,
      height: 0,
      size: 0,
    };
  }

  try {
    console.log('📐 [OrientationFix] Fixing orientation for:', imagePath);
    
    const result = await ImageOrientationFixer.fixOrientation(
      imagePath,
      maxDimension,
      quality
    );

    console.log(`✅ [OrientationFix] Fixed: ${result.width}×${result.height}, ${(result.size / 1024).toFixed(0)}KB`);
    
    return result as FixedImage;
  } catch (error) {
    console.error('❌ [OrientationFix] Failed:', error);
    // Fall back to original image
    return {
      uri: imagePath.startsWith('file://') ? imagePath : `file://${imagePath}`,
      path: imagePath.replace('file://', ''),
      width: 0,
      height: 0,
      size: 0,
    };
  }
}