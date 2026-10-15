// Smoke stand-in for T08's js/nvr/fetcher.js: the watch screen only creates and destroys it.
export function createFetcher() {
  return { destroy() {}, stats: () => ({ bytesInFlight: 0, jsonInFlight: 0, queued: 0 }) };
}
