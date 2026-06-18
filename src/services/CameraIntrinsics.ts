export interface RawCameraCalibrationData {
  source?: string;
  referenceDimensions?: {
    width?: number;
    height?: number;
  };
  fx?: number;
  fy?: number;
  cx?: number;
  cy?: number;
  K?: number[][];
  K_row_major?: number[];
}

export interface CameraIntrinsicsPayload {
  schema: string;
  source: string;
  orientation: 'same' | 'portrait-right' | 'landscape-right';
  image_width: number;
  image_height: number;
  fx: number;
  fy: number;
  cx: number;
  cy: number;
  K: number[][];
  K_row_major: number[];
  raw_capture: {
    image_width: number;
    image_height: number;
    fx: number;
    fy: number;
    cx: number;
    cy: number;
    K: number[][];
    K_row_major: number[];
  };
}

const finiteNumber = (value: unknown): number | undefined => {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
};

const matrixValue = (matrix: unknown, row: number, col: number): number | undefined => {
  if (!Array.isArray(matrix)) return undefined;
  const rowValue = matrix[row];
  if (!Array.isArray(rowValue)) return undefined;
  return finiteNumber(rowValue[col]);
};

export const cameraIntrinsicsForUploadedImage = (
  calibration: RawCameraCalibrationData | undefined,
  outputImageSize: { width?: number; height?: number },
): CameraIntrinsicsPayload | undefined => {
  if (!calibration) return undefined;

  const refWidth = finiteNumber(calibration.referenceDimensions?.width);
  const refHeight = finiteNumber(calibration.referenceDimensions?.height);
  const outputWidth = finiteNumber(outputImageSize.width);
  const outputHeight = finiteNumber(outputImageSize.height);
  if (!refWidth || !refHeight || !outputWidth || !outputHeight) return undefined;

  const rawFx = finiteNumber(calibration.fx) ?? matrixValue(calibration.K, 0, 0);
  const rawFy = finiteNumber(calibration.fy) ?? matrixValue(calibration.K, 1, 1);
  const rawCx = finiteNumber(calibration.cx) ?? matrixValue(calibration.K, 0, 2);
  const rawCy = finiteNumber(calibration.cy) ?? matrixValue(calibration.K, 1, 2);
  if (!rawFx || !rawFy || rawCx === undefined || rawCy === undefined) return undefined;

  let orientation: CameraIntrinsicsPayload['orientation'] = 'same';
  let fx: number;
  let fy: number;
  let cx: number;
  let cy: number;

  if (refWidth > refHeight && outputWidth < outputHeight) {
    orientation = 'portrait-right';
    const scaleX = outputWidth / refHeight;
    const scaleY = outputHeight / refWidth;
    fx = rawFy * scaleX;
    fy = rawFx * scaleY;
    cx = (refHeight - rawCy) * scaleX;
    cy = rawCx * scaleY;
  } else if (refWidth < refHeight && outputWidth > outputHeight) {
    orientation = 'landscape-right';
    const scaleX = outputWidth / refHeight;
    const scaleY = outputHeight / refWidth;
    fx = rawFy * scaleX;
    fy = rawFx * scaleY;
    cx = rawCy * scaleX;
    cy = (refWidth - rawCx) * scaleY;
  } else {
    const scaleX = outputWidth / refWidth;
    const scaleY = outputHeight / refHeight;
    fx = rawFx * scaleX;
    fy = rawFy * scaleY;
    cx = rawCx * scaleX;
    cy = rawCy * scaleY;
  }

  const K = [
    [fx, 0, cx],
    [0, fy, cy],
    [0, 0, 1],
  ];
  const rawK = [
    [rawFx, 0, rawCx],
    [0, rawFy, rawCy],
    [0, 0, 1],
  ];

  return {
    schema: 'shelfscout.camera_intrinsics.v1',
    source: calibration.source || 'AVCapturePhoto.cameraCalibrationData',
    orientation,
    image_width: outputWidth,
    image_height: outputHeight,
    fx,
    fy,
    cx,
    cy,
    K,
    K_row_major: [fx, 0, cx, 0, fy, cy, 0, 0, 1],
    raw_capture: {
      image_width: refWidth,
      image_height: refHeight,
      fx: rawFx,
      fy: rawFy,
      cx: rawCx,
      cy: rawCy,
      K: rawK,
      K_row_major: [rawFx, 0, rawCx, 0, rawFy, rawCy, 0, 0, 1],
    },
  };
};
