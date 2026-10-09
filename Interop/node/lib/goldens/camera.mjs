// Camera configuration TLV goldens: the Supported* characteristic values a HAP-NodeJS CameraController /
// DoorbellController serves for CameraBridge's v1 options (RTPStreamManagement, RecordingManagement and
// DataStreamManagement build them), plus SelectedCameraRecordingConfiguration parses by HAP-NodeJS.
// Option fields use the raw values of the HAPCamera contract enums (H264Profile, H264Level, StreamingAudioCodec,
// StreamingSampleRate, SRTPCryptoSuite, RecordingAudioCodec, RecordingSampleRate).
import { hn } from "../hap-nodejs.mjs";
import { check, generatorNote, hex } from "./util.mjs";

const HN_STREAMING_AUDIO = { 0: "PCMU", 1: "PCMA", 2: "AAC-eld", 3: "OPUS", 4: "mSBC", 5: "AMR", 6: "AMR-WB" };
const HN_STREAMING_RATE_KHZ = { 0: 8, 1: 16, 2: 24 };

const OPUS_16_24 = { codec: 3, sampleRates: [1, 2], channels: 1, bitrateMode: 0 };
const V1_STREAMING_RESOLUTIONS = [[3840, 2160, 30], [2560, 1440, 30], [1920, 1080, 30], [1280, 720, 30], [960, 540, 30], [640, 360, 30], [320, 240, 15]];
const V1_RECORDING_RESOLUTIONS = [[1280, 720, 30], [1920, 1080, 30]];
const V1_RECORDING_RESOLUTIONS_4_3 = [...V1_RECORDING_RESOLUTIONS, [1280, 960, 30], [1600, 1200, 30]];

/** CameraBridge v1 options (research brief integration §5.1), in the goldens' option form. */
export const V1_OPTIONS = {
    streaming: { resolutions: V1_STREAMING_RESOLUTIONS, profiles: [1], levels: [0, 1, 2], audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: false, cryptoSuites: [0] },
    recording: { prebufferLengthMs: 4000, fragmentLengthMs: 4000, resolutions: V1_RECORDING_RESOLUTIONS, profiles: [0, 1, 2], levels: [0, 1, 2], audioCodec: 0, audioSampleRates: [3], audioChannels: 1, audioBitrateMode: 0 },
};

const STREAMING_CASES = [
    ["brief §3.5 reference: 1080p30 + 720p30, all profiles and levels", {
        resolutions: [[1920, 1080, 30], [1280, 720, 30]], profiles: [0, 1, 2], levels: [0, 1, 2],
        audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: false, cryptoSuites: [0],
    }],
    ["v1 default", {
        resolutions: V1_STREAMING_RESOLUTIONS, profiles: [1], levels: [0, 1, 2],
        audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: false, cryptoSuites: [0],
    }],
    ["v1 default with two-way audio", {
        resolutions: V1_STREAMING_RESOLUTIONS, profiles: [1], levels: [0, 1, 2],
        audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: true, cryptoSuites: [0],
    }],
    ["v1 4:3 source", {
        resolutions: [[1600, 1200, 30], [1280, 960, 30], [640, 480, 30], [320, 240, 15]], profiles: [1], levels: [0, 1, 2],
        audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: false, cryptoSuites: [0],
    }],
    ["single 720p30 resolution", {
        resolutions: [[1280, 720, 30]], profiles: [1], levels: [2],
        audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: false, cryptoSuites: [0],
    }],
    // comfortNoise true cannot be expressed with CameraStreamingOptions (no such field): parser tests only.
    ["list delimiters: two audio codecs, two crypto suites, comfort noise", {
        resolutions: [[1920, 1080, 30], [1280, 720, 30]], profiles: [0, 1], levels: [2],
        audioCodecs: [OPUS_16_24, { codec: 2, sampleRates: [1], channels: 1, bitrateMode: 0 }], comfortNoise: true, twoWayAudio: false, cryptoSuites: [0, 1],
    }, { decodeOnly: true }],
];

const RECORDING_CASES = [
    ["brief §3.7 reference: High 4.0 1080p30, AAC-LC 32/44.1/48 kHz, motion", {
        isDoorbell: false, prebufferLengthMs: 4000, fragmentLengthMs: 4000,
        resolutions: [[1920, 1080, 30]], profiles: [2], levels: [2],
        audioCodec: 0, audioSampleRates: [3, 4, 5], audioChannels: 1, audioBitrateMode: 0,
    }],
    ["v1 camera", {
        isDoorbell: false, prebufferLengthMs: 4000, fragmentLengthMs: 4000,
        resolutions: V1_RECORDING_RESOLUTIONS, profiles: [0, 1, 2], levels: [0, 1, 2],
        audioCodec: 0, audioSampleRates: [3], audioChannels: 1, audioBitrateMode: 0,
    }],
    ["v1 doorbell", {
        isDoorbell: true, prebufferLengthMs: 4000, fragmentLengthMs: 4000,
        resolutions: V1_RECORDING_RESOLUTIONS, profiles: [0, 1, 2], levels: [0, 1, 2],
        audioCodec: 0, audioSampleRates: [3], audioChannels: 1, audioBitrateMode: 0,
    }],
    ["v1 camera, 4:3 source", {
        isDoorbell: false, prebufferLengthMs: 4000, fragmentLengthMs: 4000,
        resolutions: V1_RECORDING_RESOLUTIONS_4_3, profiles: [0, 1, 2], levels: [0, 1, 2],
        audioCodec: 0, audioSampleRates: [3], audioChannels: 1, audioBitrateMode: 0,
    }],
];

const streamingDelegate = {
    handleSnapshotRequest(_request, callback) { callback(new Error("golden generator: no snapshots")); },
    prepareStream(_request, callback) { callback(new Error("golden generator: no streams")); },
    handleStreamRequest(_request, callback) { callback(new Error("golden generator: no streams")); },
};
const recordingDelegate = {
    updateRecordingActive() {},
    updateRecordingConfiguration() {},
    async *handleRecordingStreamRequest() {},
    acknowledgeStream() {},
    closeRecordingStream() {},
};

const DEFAULT_STREAMING = {
    resolutions: [[1280, 720, 30]], profiles: [1], levels: [2], audioCodecs: [OPUS_16_24], comfortNoise: false, twoWayAudio: false, cryptoSuites: [0],
};

export function hapNodeJSStreamingOptions(o) {
    return {
        supportedCryptoSuites: [...o.cryptoSuites],
        video: { codec: { profiles: [...o.profiles], levels: [...o.levels] }, resolutions: o.resolutions.map(r => [...r]) },
        audio: {
            twoWayAudio: o.twoWayAudio,
            comfort_noise: o.comfortNoise,
            codecs: o.audioCodecs.map(c => ({
                type: HN_STREAMING_AUDIO[c.codec], audioChannels: c.channels, bitrate: c.bitrateMode,
                samplerate: c.sampleRates.map(r => HN_STREAMING_RATE_KHZ[r]),
            })),
        },
    };
}

export function hapNodeJSRecordingOptions(o) {
    return {
        prebufferLength: o.prebufferLengthMs,
        mediaContainerConfiguration: [{ type: 0, fragmentLength: o.fragmentLengthMs }],
        video: { type: 0, parameters: { profiles: [...o.profiles], levels: [...o.levels] }, resolutions: o.resolutions.map(r => [...r]) },
        audio: { codecs: [{ type: o.audioCodec, audioChannels: o.audioChannels, bitrateMode: o.audioBitrateMode, samplerate: [...o.audioSampleRates] }] },
    };
}

/** A HAP-NodeJS camera or doorbell accessory configured like a CameraBridge camera (2 RTP streams, motion sensor). */
function hapNodeJSCamera({ streaming = DEFAULT_STREAMING, recording, isDoorbell = false }) {
    const { hap } = hn();
    const accessory = new hap.Accessory("CameraBridge golden", hap.uuid.generate("camerabridge.golden.camera"));
    const Controller = isDoorbell ? hap.DoorbellController : hap.CameraController;
    const controller = new Controller({
        cameraStreamCount: 2,
        delegate: streamingDelegate,
        streamingOptions: hapNodeJSStreamingOptions(streaming),
        recording: recording ? { options: hapNodeJSRecordingOptions(recording), delegate: recordingDelegate } : undefined,
        sensors: { motion: true },
    });
    accessory.configureController(controller);
    const value = (serviceType, characteristicType) => {
        const values = accessory.services
            .filter(s => s.UUID === serviceType.UUID)
            .map(s => Buffer.from(s.getCharacteristic(characteristicType).value, "base64").toString("hex"));
        check(values.length > 0, `service ${serviceType.name ?? serviceType.UUID} present`);
        check(values.every(v => v === values[0]), "every stream service serves the same value");
        return values[0];
    };
    return { hap, accessory, controller, value, streamServiceCount: accessory.services.filter(s => s.UUID === hap.Service.CameraRTPStreamManagement.UUID).length };
}

/** Can CameraStreamingOptions express these options? It has audioCodecs [(codec, sampleRates)] and no comfort noise. */
const contractBuildsStreaming = o => !o.comfortNoise && o.audioCodecs.every(a => a.channels === 1 && a.bitrateMode === 0);

function streamingCase([name, options, { decodeOnly = false } = {}]) {
    const { hap, value, streamServiceCount } = hapNodeJSCamera({ streaming: options });
    const C = hap.Characteristic, S = hap.Service;
    check(streamServiceCount === 2, "two RTP stream services");
    check(decodeOnly === !contractBuildsStreaming(options), `${name}: decodeOnly exactly when CameraStreamingOptions cannot express the options`);
    return {
        name,
        ...(decodeOnly ? { decodeOnly: true } : {}),
        options,
        supportedVideoStreamConfiguration: value(S.CameraRTPStreamManagement, C.SupportedVideoStreamConfiguration),
        supportedAudioStreamConfiguration: value(S.CameraRTPStreamManagement, C.SupportedAudioStreamConfiguration),
        supportedRTPConfiguration: value(S.CameraRTPStreamManagement, C.SupportedRTPConfiguration),
    };
}

function recordingCase([name, options]) {
    const { hap, controller, value } = hapNodeJSCamera({ recording: options, isDoorbell: options.isDoorbell });
    const C = hap.Characteristic, S = hap.Service;
    check(options.audioBitrateMode === 0, `${name}: CameraRecordingOptions has no bitrate mode, so only 0 (variable) is reachable`);
    const eventTriggers = controller.recordingManagement.eventTriggerOptions;
    check(eventTriggers === (options.isDoorbell ? 3 : 1), `${name}: motion (+ doorbell) triggers`);
    return {
        name,
        options: { ...options, eventTriggers },
        supportedCameraRecordingConfiguration: value(S.CameraRecordingManagement, C.SupportedCameraRecordingConfiguration),
        supportedVideoRecordingConfiguration: value(S.CameraRecordingManagement, C.SupportedVideoRecordingConfiguration),
        supportedAudioRecordingConfiguration: value(S.CameraRecordingManagement, C.SupportedAudioRecordingConfiguration),
    };
}

/** SelectedCameraRecordingConfiguration bytes in the brief §3.7 layout, assembled with HAP-NodeJS tlv.encode. */
function selectedRecordingTLV(s) {
    const { tlv } = hn();
    const i32 = v => { const b = Buffer.alloc(4); b.writeInt32LE(v); return b; };
    const u16 = v => { const b = Buffer.alloc(2); b.writeUInt16LE(v); return b; };
    const u32 = v => { const b = Buffer.alloc(4); b.writeUInt32LE(v); return b; };
    const triggers = Buffer.alloc(8);
    triggers.writeUInt32LE(s.eventTriggers);
    const recording = tlv.encode(1, i32(s.prebufferLengthMs), 2, triggers, 3, tlv.encode(1, 0, 2, tlv.encode(1, i32(s.fragmentLengthMs))));
    const video = tlv.encode(1, 0,
        2, tlv.encode(1, s.videoProfile, 2, s.videoLevel, 3, i32(s.videoBitrateKbps), 4, i32(s.iFrameIntervalMs)),
        3, tlv.encode(1, u16(s.resolution.width), 2, u16(s.resolution.height), 3, s.resolution.fps));
    const audio = tlv.encode(1, s.audioCodec, 2, tlv.encode(1, s.audioChannels, 2, s.audioBitrateMode, 3, s.audioSampleRate, 4, u32(s.audioMaxBitrateKbps)));
    return tlv.encode(1, recording, 2, video, 3, audio);
}

const SELECTED_CASES = [
    ["hub-selected example (brief §3.7): 4000/4000, Main 4.0, 2000 kbps, IDR 4000 ms, 1080p30, AAC-LC mono 32 kHz", {
        prebufferLengthMs: 4000, eventTriggers: 1, fragmentLengthMs: 4000,
        videoProfile: 1, videoLevel: 2, videoBitrateKbps: 2000, iFrameIntervalMs: 4000, resolution: { width: 1920, height: 1080, fps: 30 },
        audioCodec: 0, audioChannels: 1, audioBitrateMode: 0, audioSampleRate: 3, audioMaxBitrateKbps: 64,
    }],
    ["doorbell selection: motion + doorbell, High 3.2, 800 kbps, IDR 2000 ms, 720p30", {
        prebufferLengthMs: 4000, eventTriggers: 3, fragmentLengthMs: 4000,
        videoProfile: 2, videoLevel: 1, videoBitrateKbps: 800, iFrameIntervalMs: 2000, resolution: { width: 1280, height: 720, fps: 30 },
        audioCodec: 0, audioChannels: 1, audioBitrateMode: 0, audioSampleRate: 3, audioMaxBitrateKbps: 32,
    }],
];

function selectedCase([name, s]) {
    const { controller } = hapNodeJSCamera({ recording: RECORDING_CASES[1][1] });
    const encoded = selectedRecordingTLV(s);
    const parsed = controller.recordingManagement.parseSelectedConfiguration(encoded.toString("base64"));
    const eventTriggers = parsed.eventTriggerTypes.reduce((a, b) => a | b, 0);
    const configuration = {
        prebufferLengthMs: parsed.prebufferLength,
        eventTriggers,
        fragmentLengthMs: parsed.mediaContainerConfiguration.fragmentLength,
        videoProfile: parsed.videoCodec.parameters.profile,
        videoLevel: parsed.videoCodec.parameters.level,
        videoBitrateKbps: parsed.videoCodec.parameters.bitRate,
        iFrameIntervalMs: parsed.videoCodec.parameters.iFrameInterval,
        resolution: { width: parsed.videoCodec.resolution[0], height: parsed.videoCodec.resolution[1], fps: parsed.videoCodec.resolution[2] },
        audioCodec: parsed.audioCodec.type,
        audioChannels: parsed.audioCodec.audioChannels,
        audioSampleRate: parsed.audioCodec.samplerate,
        audioMaxBitrateKbps: parsed.audioCodec.bitrate,
    };
    const { audioBitrateMode, ...expected } = s;
    check(JSON.stringify(configuration) === JSON.stringify(expected), `${name}: HAP-NodeJS parses what was encoded`);
    check(parsed.mediaContainerConfiguration.type === 0 && parsed.videoCodec.type === 0 && parsed.audioCodec.bitrateMode === audioBitrateMode, `${name}: fixed fields`);
    return { name, encoded: hex(encoded), configuration };
}

export function generateCamera() {
    const { hap, version } = hn();
    const probe = hapNodeJSCamera({ recording: RECORDING_CASES[1][1] });
    const C = hap.Characteristic, S = hap.Service;
    return {
        generator: generatorNote("camera"),
        source: `HAP-NodeJS ${version} (Apache-2.0) CameraController / DoorbellController (cameraStreamCount 2, sensors.motion) → lib/camera/RTPStreamManagement.ts, RecordingManagement.ts, lib/datastream/DataStreamManagement.ts; research brief §3.5, §3.7`,
        notes: [
            "All TLV values are hex, exactly as HAP-NodeJS serves them (its characteristic values are base64 of these bytes).",
            "List elements (resolutions, profiles, levels, sample rates, audio codec configurations, crypto suites, media containers) are separated by a `00 00` item; a single-element list has no separator.",
            "Option fields are raw values of the HAPCamera contract enums: profiles H264Profile, levels H264Level, audio codec StreamingAudioCodec / RecordingAudioCodec, sample rates StreamingSampleRate / RecordingSampleRate, cryptoSuites SRTPCryptoSuite. resolutions are [width, height, fps]. channels / bitrateMode are the TLV values (bitrate mode 0 = variable).",
            "`streaming`: the three Supported* values of each CameraRTPStreamManagement service. Every case without `decodeOnly` is an encoder target: CameraStreamingOptions(resolutions:profiles:levels:audioCodecs:twoWayAudio:cryptoSuites:) built from `options` (audioCodecs as (codec, sampleRates)) must produce these bytes. `channels` 1, `bitrateMode` 0 (variable) and `comfortNoise` false are what the contract implies; CameraStreamingOptions has no fields for them. twoWayAudio does not change these TLVs (it adds Speaker/Microphone services).",
            "`decodeOnly: true` (only the list-delimiter case, which turns comfort noise on and so writes `020101` in the audio TLV) cannot be built through CameraStreamingOptions: use it for TLV parser / list-delimiter tests only, and do not add a comfort-noise option to the contract for it. CameraBridge v1 always offers comfort noise off.",
            "`recording`: the Supported* values of CameraRecordingManagement. CameraRecordingOptions(prebufferLengthMs:fragmentLengthMs:resolutions:profiles:levels:audioCodec:audioSampleRates:audioChannels:) built from `options` must produce these bytes; `audioBitrateMode` 0 (variable) is implied (not a contract field). `isDoorbell` is CameraControllerConfiguration.isDoorbell, not part of CameraRecordingOptions, and `eventTriggers` is the result that follows from it (1 = motion on a camera, 3 = motion | doorbell on a doorbell). The container is fragmented MP4 (type 0) with fragmentLengthMs.",
            "`selectedRecordingConfiguration`: a SelectedCameraRecordingConfiguration write (bytes assembled in the brief §3.7 layout with HAP-NodeJS tlv.encode, not a hub capture) and the CameraRecordingConfiguration HAP-NodeJS parses from it.",
        ],
        streaming: STREAMING_CASES.map(streamingCase),
        recording: RECORDING_CASES.map(recordingCase),
        selectedRecordingConfiguration: SELECTED_CASES.map(selectedCase),
        dataStreamTransport: {
            supportedDataStreamTransportConfiguration: probe.value(S.DataStreamTransportManagement, C.SupportedDataStreamTransportConfiguration),
        },
        streamingStatus: {
            available: probe.value(S.CameraRTPStreamManagement, C.StreamingStatus),
            inUse: hex(hn().tlv.encode(1, 1)),
            unavailable: hex(hn().tlv.encode(1, 2)),
        },
        setupEndpointsDefault: probe.value(S.CameraRTPStreamManagement, C.SetupEndpoints),
    };
}
