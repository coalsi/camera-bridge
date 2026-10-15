// The nine synthetic cameras of the dev server: who they are, which fixture each records, and what its history looks like.
// Addresses are RFC 5737 documentation addresses; ids are fixed so a link to a camera survives a restart.

export const HOUR = 3_600_000;
export const DAY = 86_400_000;

/**
 * fixture: the clip a file is made of, or `{ by(startMs) }` choosing it per file (the "two sizes" camera alternates every two hours).
 * boundary: how one file meets the next: 'abut' (exactly), 'gap300' (300 ms of nothing), 'overlap' (the next file starts 0.4 ms early).
 * history: 'days3' records for three days (with `gap`, a daily gap in UTC), 'stopped' ended `stoppedHoursAgo` ago, 'fresh' began `freshMinutes` ago.
 */
const RAW_DEFINITIONS = [
  { index: 1, name: 'Front Door', kind: 'doorbell', fixture: 'gop2', boundary: 'abut', history: 'days3', gap: null, enabled: true, host: '192.0.2.11', model: 'Doorbell 5MP' },
  { index: 2, name: 'Driveway', kind: 'camera', fixture: 'hd', boundary: 'gap300', history: 'days3', gap: { hour: 3, minute: 40, minutes: 20 }, enabled: true, host: '192.0.2.12', model: 'Bullet 4MP' },
  { index: 3, name: 'Garage', kind: 'camera', fixture: 'longgop', boundary: 'abut', history: 'days3', gap: null, enabled: true, host: '192.0.2.13', model: 'Turret 4MP (smart codec)' },
  { index: 4, name: 'Back Yard', kind: 'camera', fixture: 'ntsc', boundary: 'overlap', history: 'days3', gap: { hour: 4, minute: 5, minutes: 7 }, enabled: true, host: '192.0.2.14', model: 'Dome 4MP' },
  { index: 5, name: 'Side Gate', kind: 'camera', fixture: 'hevc', boundary: 'abut', history: 'days3', gap: null, enabled: true, host: '192.0.2.15', model: 'Bullet 4K (H.265)' },
  { index: 6, name: 'Living Room', kind: 'camera', fixture: { by: (startMs) => (Math.floor(startMs / (2 * HOUR)) % 2 === 0 ? 'gop2' : 'res-b') }, boundary: 'abut', history: 'days3', gap: { hour: 2, minute: 15, minutes: 45 }, enabled: true, host: '192.0.2.16', model: 'Indoor 3MP' },
  { index: 7, name: 'Porch', kind: 'camera', fixture: 'gop2', boundary: 'abut', history: 'days3', gap: null, enabled: true, recordSound: true, audioEnabled: true, host: '192.0.2.17', model: 'Bullet 4MP' },
  { index: 8, name: 'Shed', kind: 'camera', fixture: 'quiet', boundary: 'abut', history: 'stopped', stoppedHoursAgo: 6, gap: null, enabled: false, host: '192.0.2.18', model: 'Mini 2MP' },
  { index: 9, name: 'New Gate', kind: 'camera', fixture: 'gop2', boundary: 'abut', history: 'fresh', freshMinutes: 25, gap: null, enabled: true, host: '192.0.2.19', model: 'Bullet 4MP' },
];

/** The camera's id: fixed, upper case, a valid UUID. */
export const cameraId = (index) => `0A1B2C3D-0000-4000-8000-${String(index).padStart(12, '0')}`;

export const CAMERA_DEFINITIONS = RAW_DEFINITIONS.map((definition) => ({ ...definition, id: cameraId(definition.index) }));

/** What the file starting at `startMs` is made of: the name of a fixture. */
export const fixtureNameAt = (definition, startMs) => (typeof definition.fixture === 'string' ? definition.fixture : definition.fixture.by(startMs));

/** The boundary between two files in ms: 0 abut, +300 a gap, -0.4 an overlap. */
export const boundaryAdjust = (definition) => ({ abut: 0, gap300: 300, overlap: -0.4 })[definition.boundary];

/** The configuration the page shows for the camera (the engine's `CameraConfiguration` without a password; the NVR fields are added by the state). */
export function cameraConfiguration(definition) {
  return {
    id: cameraId(definition.index),
    name: definition.name,
    kind: definition.kind,
    vendor: 'onvif',
    endpoint: { host: definition.host, httpPort: 80, rtspPort: 554, onvifPort: 80, useHTTPS: false },
    username: 'viewer',
    mainStreamURL: null,
    subStreamURL: null,
    motionSource: 'cameraEvents',
    motionSensitivity: 0.5,
    motionHoldSeconds: 20,
    sensors: { person: false, vehicle: false, animal: false, package: false, dayNight: false, digitalInputs: false, temperature: false, humidity: false },
    audioEnabled: definition.audioEnabled ?? false,
    twoWayAudio: false,
    hapPort: 38100 + definition.index,
    isEnabled: true,
    manufacturer: 'Example Optics',
    model: definition.model,
    serialNumber: `SN-DEV-${String(definition.index).padStart(4, '0')}`,
    firmware: '1.0.0',
    capabilities: null,
    liveStreamMode: 'automatic',
    liveQualityMode: 'matchHomeKitRequest',
    liveMaxBitrateOverride: 'auto',
    recordingStreamMode: 'automatic',
    recordingQualityMode: 'matchHubRequest',
    preferredConfigMethod: null,
    timestampOverlay: { enabled: false, position: 'topRight', showCameraName: false, showDate: true, showSeconds: true, use24Hour: true, size: 'medium' },
    hiddenCameraClock: null,
    integration: null,
    nvrEnabled: definition.enabled,
    nvrRecordSound: definition.recordSound ?? false,
  };
}
