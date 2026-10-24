// The order of the cameras on every page: the order the person gave (saved on the box as `cameraOrder`), else by name. No DOM: Node tests run it.

const byName = (a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' });

/** `cameras` in the saved `order` (camera ids): the listed ones first, then the others by name. Unknown and repeated ids are ignored. */
export function orderCameras(cameras, order) {
  const byId = new Map(cameras.map((camera) => [camera.id, camera]));
  const listed = [];
  for (const id of Array.isArray(order) ? order : []) {
    const camera = byId.get(id);
    if (camera) { listed.push(camera); byId.delete(id); }
  }
  return [...listed, ...[...byId.values()].sort(byName)];
}

/** `ids` with `id` taking the place of `targetId` (the ones between shift by one). The same list when either is not in it. */
export function placeAt(ids, id, targetId) {
  const from = ids.indexOf(id);
  const to = ids.indexOf(targetId);
  if (from < 0 || to < 0 || from === to) return ids;
  const next = [...ids];
  next.splice(from, 1);
  next.splice(to, 0, id);
  return next;
}
