// Keyboard shortcuts of the watch screen, as a pure mapping from a key event to an action (or null).
//   Space play/pause   Left/Right 1 s   Shift 10 s   Alt 1 min   L go live   + and - zoom   Home oldest recording   Esc close
// Never while focus is in a text field, a select or a dialog, never with ctrl or cmd (those belong to the browser).

const TYPING_TAGS = new Set(['INPUT', 'SELECT', 'TEXTAREA']);
const NATIVE_ACTIVATION_TAGS = new Set(['BUTTON', 'A', 'SUMMARY']);

export function isTypingTarget(target) {
  if (!target) return false;
  if (TYPING_TAGS.has(target.tagName) || target.isContentEditable) return true;
  return typeof target.closest === 'function' && target.closest('dialog[open]') !== null;
}

/** -> { type: 'togglePlay' } | { type: 'seek', deltaMs } | { type: 'live' } | { type: 'zoom', factor } | { type: 'oldest' } | { type: 'close' } | null */
export function keyAction(event) {
  if (event.ctrlKey || event.metaKey || isTypingTarget(event.target)) return null;
  const key = event.key;
  switch (key) {
    case ' ':
    case 'Spacebar':
      // On a button or a link, Space is that control's own click.
      if (event.repeat || NATIVE_ACTIVATION_TAGS.has(event.target?.tagName)) return null;
      return { type: 'togglePlay' };
    case 'ArrowLeft':
    case 'ArrowRight': {
      const step = event.altKey ? 60_000 : event.shiftKey ? 10_000 : 1000;
      return { type: 'seek', deltaMs: key === 'ArrowLeft' ? -step : step };
    }
    case 'l':
    case 'L':
      return event.repeat ? null : { type: 'live' };
    case '+':
    case '=':
      return { type: 'zoom', factor: 0.5 };
    case '-':
    case '_':
      return { type: 'zoom', factor: 2 };
    case 'Home':
      return { type: 'oldest' };
    case 'Escape':
      return event.repeat ? null : { type: 'close' };
    default:
      return null;
  }
}
