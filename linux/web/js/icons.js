// A small set of stroke icons (24x24), drawn as SVG elements.
import { svg } from './dom.js';

const PATHS = {
  camera: ['M4 7h3l2-2h6l2 2h3a1 1 0 0 1 1 1v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1z', 'circle:12,13,3.5'],
  doorbell: ['M6 16v-5a6 6 0 0 1 12 0v5l2 2H4z', 'M10 20a2 2 0 0 0 4 0'],
  plus: ['M12 5v14', 'M5 12h14'],
  sliders: ['M4 7h9', 'M17 7h3', 'M4 17h3', 'M11 17h9', 'circle:15,7,2', 'circle:9,17,2'],
  list: ['M9 6h11', 'M9 12h11', 'M9 18h11', 'M4.5 6h.01', 'M4.5 12h.01', 'M4.5 18h.01'],
  server: ['M4 5h16v6H4z', 'M4 13h16v6H4z', 'M8 8h.01', 'M8 16h.01'],
  check: ['M5 13l4 4L19 7'],
  alert: ['M12 3l10 18H2z', 'M12 10v5', 'M12 18h.01'],
  info: ['circle:12,12,9', 'M12 11v5', 'M12 8h.01'],
  refresh: ['M20 11a8 8 0 1 0-2.3 5.7', 'M20 4v7h-7'],
  trash: ['M4 7h16', 'M9 7V4h6v3', 'M6 7l1 13h10l1-13'],
  play: ['M8 5l11 7-11 7z'],
  pause: ['M8 5v14', 'M16 5v14'],
  copy: ['M9 9h11v11H9z', 'M5 15V5h10'],
  lock: ['M6 11h12v9H6z', 'M8 11V8a4 4 0 0 1 8 0v3'],
  home: ['M3 11l9-8 9 8', 'M5 10v10h14V10'],
  download: ['M12 4v11', 'M7 11l5 5 5-5', 'M5 20h14'],
  power: ['M12 3v9', 'M6.3 6.3a8 8 0 1 0 11.4 0'],
  monitor: ['M3 5h18v11H3z', 'M8 20h8', 'M12 16v4'],
  maximize: ['M4 9V4h5', 'M20 9V4h-5', 'M4 15v5h5', 'M20 15v5h-5'],
  minimize: ['M9 4v5H4', 'M15 4v5h5', 'M9 20v-5H4', 'M15 20v-5h5'],
  clock: ['circle:12,12,9', 'M12 7v5l3 2'],
  bell: ['M6 16v-5a6 6 0 0 1 12 0v5l2 2H4z', 'M10 20a2 2 0 0 0 4 0'],
  plugin: ['M9 3v4M15 3v4', 'M6 7h12v4a6 6 0 0 1-12 0z', 'M12 17v4'],
  volume: ['M4 9h4l5-4v14l-5-4H4z', 'M16.5 8.5a5 5 0 0 1 0 7', 'M19 6a8.5 8.5 0 0 1 0 12'],
  volumeOff: ['M4 9h4l5-4v14l-5-4H4z', 'M17 9.5l5 5', 'M22 9.5l-5 5'],
  bellOff: ['M6 16v-5a6 6 0 0 1 .8-3', 'M18 11a6 6 0 0 0-8.5-5.4', 'M4 18h14', 'M10 20a2 2 0 0 0 4 0', 'M3 3l18 18'],
  sun: ['circle:12,12,4', 'M12 2.5v2', 'M12 19.5v2', 'M4.6 4.6l1.4 1.4', 'M18 18l1.4 1.4', 'M2.5 12h2', 'M19.5 12h2', 'M4.6 19.4L6 18', 'M18 6l1.4-1.4'],
  moon: ['M20 14.5A8.5 8.5 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5z'],
  bulb: ['M9 18h6', 'M10 21h4', 'M12 3a6 6 0 0 0-3.6 10.8c.7.6 1.1 1.3 1.1 2.2h5c0-.9.4-1.6 1.1-2.2A6 6 0 0 0 12 3z'],
  contrast: ['circle:12,12,9', 'M12 3v18', 'M12 7h4.5', 'M12 11h6.8', 'M12 15h6.3', 'M12 19h3'],
  chevron: ['M9 6l6 6-6 6'],
  back: ['M15 6l-6 6 6 6'],
  x: ['M6 6l12 12', 'M18 6L6 18'],
  search: ['circle:11,11,7', 'M20 20l-4-4'],
  eye: ['M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z', 'circle:12,12,3'],
  shield: ['M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z'],
  bolt: ['M13 3L5 14h6l-1 7 8-11h-6z'],
  scissors: ['circle:6,6,3', 'circle:6,18,3', 'M8.5 7.5L20 18', 'M8.5 16.5L20 6'],
  network: ['circle:12,5,2', 'circle:5,19,2', 'circle:19,19,2', 'M12 7v5', 'M12 12l-6 5', 'M12 12l6 5'],
  qr: ['M4 4h6v6H4z', 'M14 4h6v6h-6z', 'M4 14h6v6H4z', 'M14 14h2v2h-2z', 'M18 14h2', 'M14 18h2v2', 'M18 18h2v2'],
  film: ['M4 5h16v14H4z', 'M8 5v14', 'M16 5v14', 'M4 9h4', 'M4 15h4', 'M16 9h4', 'M16 15h4'],
  battery: ['M4 7h13a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1z', 'M21 10.5v3', 'M6.5 10.5v3', 'M9.5 10.5v3', 'M12.5 10.5v3'],
  batteryLow: ['M4 7h13a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1z', 'M21 10.5v3', 'M6.5 10.5v3'],
  batteryCharging: ['M4 7h13a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1z', 'M21 10.5v3', 'M11.5 9l-2.5 3.5h3L9.5 15'],
};

/** icon('camera') -> an <svg> that takes the surrounding text colour. */
export function icon(name, { size, label } = {}) {
  const el = svg('svg', {
    viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.8', 'stroke-linecap': 'round', 'stroke-linejoin': 'round',
    ...(label ? { role: 'img', 'aria-label': label } : { 'aria-hidden': 'true', focusable: 'false' }),
  });
  for (const part of PATHS[name] || []) {
    if (part.startsWith('circle:')) {
      const [cx, cy, r] = part.slice(7).split(',');
      el.append(svg('circle', { cx, cy, r }));
    } else {
      el.append(svg('path', { d: part }));
    }
  }
  if (size) { el.setAttribute('width', size); el.setAttribute('height', size); }
  return el;
}
