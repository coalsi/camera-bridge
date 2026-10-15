// The page's appearance on this browser: Dark (the default), Light, or Auto (follows the device's light or dark setting). Kept in localStorage,
// so it is this browser's choice, not the bridge's; /theme-boot.js applies it before the first paint, applyTheme() whenever it changes.
const KEY = 'cb-theme';
export const THEMES = ['dark', 'light', 'auto'];
export const THEME_INFO = {
  auto: { label: 'Auto', icon: 'contrast', desc: 'Follows this device’s light or dark setting.' },
  light: { label: 'Light', icon: 'sun', desc: 'Always light.' },
  dark: { label: 'Dark', icon: 'moon', desc: 'Always dark.' },
};
const BACKGROUND = { light: '#f6f4ef', dark: '#151517' };
export const THEME_EVENT = 'cb-themechange';

/** 'dark', 'light' or 'auto' (Dark when nothing is stored or storage is blocked). */
export function currentTheme() {
  try {
    const theme = localStorage.getItem(KEY);
    return theme === 'light' || theme === 'auto' ? theme : 'dark';
  } catch {
    return 'dark';
  }
}

/** The one after `theme` in Dark → Light → Auto → Dark. */
export function nextTheme(theme) {
  return THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
}

/** Keeps `theme` for this browser and shows it (still shown, for this visit, when storage is blocked). */
export function setTheme(theme) {
  const value = THEMES.includes(theme) ? theme : 'dark';
  try {
    if (value === 'dark') localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, value);
  } catch {
    // Not kept: the choice lasts until the page is reloaded.
  }
  applyTheme(value);
}

/** Shows `theme`: the data-theme attribute the colours follow, the browser bar colour, and THEME_EVENT for code that draws (the timeline). */
export function applyTheme(theme) {
  const root = document.documentElement;
  if (theme === 'light' || theme === 'dark') root.setAttribute('data-theme', theme);
  else root.removeAttribute('data-theme');
  for (const meta of document.querySelectorAll('meta[name="theme-color"]')) {
    const own = (meta.getAttribute('media') || '').includes('light') ? BACKGROUND.light : BACKGROUND.dark;
    meta.setAttribute('content', BACKGROUND[theme] || own);
  }
  document.dispatchEvent(new CustomEvent(THEME_EVENT, { detail: { theme } }));
}
