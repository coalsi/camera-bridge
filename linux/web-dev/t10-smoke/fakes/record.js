// Smoke stand-in for T09's js/nvr/record.js.
export async function setRecording(id, on) {
  (window.__recordCalls ||= []).push([id, on]);
  return true;
}
