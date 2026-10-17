// Night vision on the dev server's cameras, as the bridge answers it: status.nightVision (BridgeWeb/Resources.swift NightVisionResource,
// which leaves `mode` and `lightOn` out while they are unknown) and POST cameras/:id/night-vision {mode?, light?} (WebApp+Routes.swift: 204,
// else 400 invalid, 404, 409 no_night_vision, 422 night_vision_failed with the camera's sentence). A camera's definition offers it with
// `nightVision: { modes, light, refuses }`; `refuses`, or POST /__dev/night-vision {"id", "fail": true or a sentence} (false or null ends it),
// makes every change of that camera fail with 422, to try the page's error. The state lives on the camera's entry, so /__dev/reset puts it back.

import { ApiError } from './http.mjs';

export const NIGHT_VISION_MODES = ['auto', 'on', 'off'];

/** The camera's night vision as the bridge keeps it, made from its definition the first time (null: the camera has none). */
function stateOf(camera) {
  if (camera.nightVision === undefined) {
    const offer = camera.definition.nightVision;
    camera.nightVision = offer
      ? { modes: NIGHT_VISION_MODES.filter((mode) => offer.modes?.includes(mode)), mode: offer.mode ?? 'auto', light: offer.light === true, lightOn: offer.light === true ? false : null, fail: offer.refuses ?? null }
      : null;
  }
  return camera.nightVision;
}

/** status.nightVision of a camera: undefined for one without (the bridge leaves the key out), else the offer and where it is. */
export function nightVisionStatus(camera) {
  const state = stateOf(camera);
  if (!state) return undefined;
  return { modes: [...state.modes], ...(state.mode === null ? {} : { mode: state.mode }), light: state.light, ...(state.lightOn === null ? {} : { lightOn: state.lightOn }) };
}

/**
 * POST cameras/:id/night-vision, in the bridge's order: the body (a mode that is not a string, a light that is not a boolean, an unknown
 * mode, neither), then the camera (`find` throws the 404), then what it can do (409: none, a mode it doesn't offer, a lamp it doesn't have,
 * or turned off) and whether it took the change (422). Changes the camera's state when it did.
 */
export function changeNightVision(body, find) {
  const { mode, light } = body;
  if (mode !== undefined && mode !== null && typeof mode !== 'string') throw ApiError.invalid('“mode” has the wrong kind of value.', 'mode');
  if (light !== undefined && light !== null && typeof light !== 'boolean') throw ApiError.invalid('“light” has the wrong kind of value.', 'light');
  if (typeof mode === 'string' && !NIGHT_VISION_MODES.includes(mode)) throw ApiError.invalid('Night vision is auto, on or off.', 'mode');
  const wantsMode = typeof mode === 'string';
  const wantsLight = typeof light === 'boolean';
  if (!wantsMode && !wantsLight) throw ApiError.invalid('Say the night vision mode or the light.', 'mode');
  const camera = find();
  const state = stateOf(camera);
  if (!state || !camera.configuration.isEnabled || (wantsMode && !state.modes.includes(mode)) || (wantsLight && !state.light)) {
    throw new ApiError(409, 'no_night_vision', 'This camera can’t switch that right now.');
  }
  if (state.fail) {
    const sentence = typeof state.fail === 'string' ? state.fail
      : wantsMode ? `The camera accepted night vision ${mode} but stayed in ${state.mode ?? 'its own mode'}.` : 'The camera refused the lamp command.';
    throw new ApiError(422, 'night_vision_failed', sentence);
  }
  if (wantsMode) state.mode = mode;
  if (wantsLight) state.lightOn = light;
}

/** POST /__dev/night-vision: `fail` true (the bridge's usual sentence) or a sentence makes that camera's changes fail; false or null ends it. */
export function setNightVisionFailure(camera, fail) {
  const state = stateOf(camera);
  if (!state) throw ApiError.invalid('That camera has no night vision.', 'id');
  if (fail !== undefined && fail !== null && typeof fail !== 'boolean' && typeof fail !== 'string') throw ApiError.invalid('fail is true, false or a sentence.', 'fail');
  state.fail = typeof fail === 'string' ? fail.trim().slice(0, 200) || true : fail === true ? true : null;
}
