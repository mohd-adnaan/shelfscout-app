// src/components/MenuIcons.tsx
//
// Icons for the action menu.
//
// Every one is decorative: the menu row that owns it carries the
// accessibilityLabel, and the row is a single accessibility element. An icon
// that announced itself would make VoiceOver read each row twice.
//
// Drawn with stroke weight 2.2 and no fills so they stay legible at the large
// sizes the menu uses and under Increase Contrast / Smart Invert, where
// filled glyphs collapse into solid blocks.

import React from 'react';
import Svg, { Circle, Path, Rect, Line } from 'react-native-svg';

export interface MenuIconProps {
  size?: number;
  color?: string;
}

const STROKE = 2.2;

const base = (size: number) => ({
  width: size,
  height: size,
  viewBox: '0 0 24 24',
  fill: 'none' as const,
});

/** Ask a question — speech bubble with a question mark. */
export const AskIcon: React.FC<MenuIconProps> = ({ size = 34, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Circle cx="12" cy="12" r="9.2" stroke={color} strokeWidth={STROKE} />
    <Path
      d="M9.4 9.3a2.7 2.7 0 1 1 3.4 2.6c-.55.16-.9.66-.9 1.23v.5"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinecap="round"
    />
    <Circle cx="11.9" cy="16.6" r="1.05" fill={color} />
  </Svg>
);

/** Find an object — magnifier. */
export const FindIcon: React.FC<MenuIconProps> = ({ size = 34, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Circle cx="10.6" cy="10.6" r="6.6" stroke={color} strokeWidth={STROKE} />
    <Line
      x1="15.5"
      y1="15.5"
      x2="20.4"
      y2="20.4"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinecap="round"
    />
  </Svg>
);

/** Describe surroundings — eye. */
export const DescribeIcon: React.FC<MenuIconProps> = ({ size = 34, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Path
      d="M1.9 12S5.5 5.4 12 5.4 22.1 12 22.1 12 18.5 18.6 12 18.6 1.9 12 1.9 12Z"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinejoin="round"
    />
    <Circle cx="12" cy="12" r="3.1" stroke={color} strokeWidth={STROKE} />
  </Svg>
);

/** Take me somewhere — route with a destination pin. */
export const RouteIcon: React.FC<MenuIconProps> = ({ size = 34, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Path
      d="M5.2 20.6c0-3.4 4.1-3.4 4.1-6.8S5.2 10.4 5.2 7"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinecap="round"
    />
    <Circle cx="5.2" cy="4.6" r="2.1" stroke={color} strokeWidth={STROKE} />
    <Path
      d="M17.4 3.6c2.5 0 4.5 2 4.5 4.5 0 3.3-4.5 8.1-4.5 8.1s-4.5-4.8-4.5-8.1c0-2.5 2-4.5 4.5-4.5Z"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinejoin="round"
    />
    <Circle cx="17.4" cy="8.1" r="1.7" stroke={color} strokeWidth={STROKE} />
  </Svg>
);

/** Repeat that — counter-clockwise arrow. */
export const RepeatIcon: React.FC<MenuIconProps> = ({ size = 34, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Path
      d="M20.3 12a8.3 8.3 0 1 1-2.43-5.87"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinecap="round"
    />
    <Path
      d="M20.3 3.6v4.6h-4.6"
      stroke={color}
      strokeWidth={STROKE}
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </Svg>
);

/** Stop — filled square inside a ring. The universal "end it now". */
export const StopIcon: React.FC<MenuIconProps> = ({ size = 30, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Circle cx="12" cy="12" r="9.4" stroke={color} strokeWidth={STROKE} />
    <Rect x="8.6" y="8.6" width="6.8" height="6.8" rx="1.4" fill={color} />
  </Svg>
);

/**
 * Settings — gear.
 *
 * Filled, with a punched-out centre, rather than the stroked outline the rest
 * of this file uses. Two reasons: it is rendered at 22pt as a small control
 * where an eight-toothed outline turns into visual noise, and it replaces the
 * U+2699 character, which iOS renders from the emoji font — a fixed-colour
 * picture that ignores the surrounding palette and does not respond to
 * Increase Contrast or Smart Invert.
 *
 * The path is generated rather than hand-drawn so the teeth are exactly
 * symmetric; regenerate it from these constants if the proportions change.
 * 8 teeth, tip radius 11.1, root radius 8.9, tooth half-width 9.5°, root
 * padding 13°, on a 24×24 box centred at (12, 12) with tooth 0 pointing up.
 */
const GEAR_BODY =
  'M10.17 1.05A11.1 11.1 0 0 1 13.83 1.05L14 3.33A8.9 8.9 0 0 1 16.72 4.45' +
  'L18.45 2.96A11.1 11.1 0 0 1 21.04 5.55L19.55 7.28A8.9 8.9 0 0 1 20.67 10' +
  'L22.95 10.17A11.1 11.1 0 0 1 22.95 13.83L20.67 14A8.9 8.9 0 0 1 19.55 16.72' +
  'L21.04 18.45A11.1 11.1 0 0 1 18.45 21.04L16.72 19.55A8.9 8.9 0 0 1 14 20.67' +
  'L13.83 22.95A11.1 11.1 0 0 1 10.17 22.95L10 20.67A8.9 8.9 0 0 1 7.28 19.55' +
  'L5.55 21.04A11.1 11.1 0 0 1 2.96 18.45L4.45 16.72A8.9 8.9 0 0 1 3.33 14' +
  'L1.05 13.83A11.1 11.1 0 0 1 1.05 10.17L3.33 10A8.9 8.9 0 0 1 4.45 7.28' +
  'L2.96 5.55A11.1 11.1 0 0 1 5.55 2.96L7.28 4.45A8.9 8.9 0 0 1 10 3.33Z';

/** Second subpath; `fillRule="evenodd"` turns it into the centre hole. */
const GEAR_HOLE = 'M12 8.1A3.9 3.9 0 1 1 12 15.9A3.9 3.9 0 1 1 12 8.1Z';

export const GearIcon: React.FC<MenuIconProps> = ({ size = 26, color = '#fff' }) => (
  <Svg {...base(size)}>
    <Path d={`${GEAR_BODY} ${GEAR_HOLE}`} fill={color} fillRule="evenodd" />
  </Svg>
);
