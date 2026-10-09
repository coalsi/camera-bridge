#!/usr/bin/env node
// Dev-only generator for the HAP module's CharacteristicType / ServiceType constants (plan task W1-1).
//
// Reads HAP-NodeJS (Apache-2.0) `lib/CharacteristicDefinitions.ts` and `lib/ServiceDefinitions.ts` and writes
// `Packages/CameraBridgeKit/Sources/HAP/Definitions/{CharacteristicType,ServiceType}+Definitions.swift` for the subset
// listed in research brief §3.4. The output is committed; rerun after changing the subset:
//
//   node Tools/hap-definitions/generate.mjs [path/to/hap-nodejs]
//
// Default HAP-NodeJS path: Reference/hap-nodejs next to the repository (gitignored, local only). Never shipped.

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const hapNodeJS = path.resolve(process.argv[2] ?? findReference());
const outDir = path.join(repo, "Packages/CameraBridgeKit/Sources/HAP/Definitions");

function findReference() {
  // Worktrees live under <main repo>/.claude/worktrees/<name>; Reference/ exists only in the main checkout.
  for (let dir = repo; dir !== path.dirname(dir); dir = path.dirname(dir)) {
    const candidate = path.join(dir, "Reference/hap-nodejs");
    if (fs.existsSync(path.join(candidate, "lib/CharacteristicDefinitions.ts"))) return candidate;
  }
  throw new Error("Reference/hap-nodejs not found; pass its path as the first argument");
}

// Research brief §3.4 subset, in output order (HAP-NodeJS class names).
const characteristicGroups = [
  ["Identity", ["Identify", "Manufacturer", "Model", "Name", "SerialNumber", "FirmwareRevision", "HardwareRevision",
    "ConfiguredName", "Version"]],
  ["RTP stream management", ["SupportedVideoStreamConfiguration", "SupportedAudioStreamConfiguration",
    "SupportedRTPConfiguration", "SelectedRTPStreamConfiguration", "SetupEndpoints", "StreamingStatus", "Active"]],
  ["Recording management", ["SupportedCameraRecordingConfiguration", "SupportedVideoRecordingConfiguration",
    "SupportedAudioRecordingConfiguration", "SelectedCameraRecordingConfiguration", "RecordingAudioActive"]],
  ["Operating mode", ["EventSnapshotsActive", "HomeKitCameraActive", "CameraOperatingModeIndicator", "ManuallyDisabled",
    "NightVision", "PeriodicSnapshotsActive", "ThirdPartyCameraActive", "DiagonalFieldOfView", "VideoAnalysisActive"]],
  ["Data stream", ["SupportedDataStreamTransportConfiguration", "SetupDataStreamTransport"]],
  ["Audio", ["Mute", "Volume"]],
  ["Doorbell / switch", ["ProgrammableSwitchEvent"]],
  ["Sensors", ["MotionDetected", "OccupancyDetected", "CurrentAmbientLightLevel", "CurrentTemperature",
    "CurrentRelativeHumidity", "ContactSensorState", "On"]],
  ["Status / battery", ["StatusActive", "StatusFault", "StatusTampered", "StatusLowBattery", "BatteryLevel", "ChargingState"]],
];

const services = ["AccessoryInformation", "ProtocolInformation", "CameraRTPStreamManagement", "CameraRecordingManagement",
  "CameraOperatingMode", "DataStreamTransportManagement", "Microphone", "Speaker", "Doorbell",
  "StatelessProgrammableSwitch", "MotionSensor", "OccupancySensor", "LightSensor", "TemperatureSensor", "HumiditySensor",
  "ContactSensor", "Battery", "Switch"];

const formats = { BOOL: "bool", UINT8: "uint8", UINT16: "uint16", UINT32: "uint32", UINT64: "uint64", INT: "int",
  FLOAT: "float", STRING: "string", TLV8: "tlv8", DATA: "data" };
const perms = { PAIRED_READ: ".pairedRead", PAIRED_WRITE: ".pairedWrite", NOTIFY: ".events",
  ADDITIONAL_AUTHORIZATION: ".additionalAuthorization", TIMED_WRITE: ".timedWrite", HIDDEN: ".hidden",
  WRITE_RESPONSE: ".writeResponse" };
const permOrder = Object.values(perms);
const units = { CELSIUS: "celsius", PERCENTAGE: "percentage", ARC_DEGREE: "arcdegrees", LUX: "lux", SECONDS: "seconds" };

function classBody(source, name, base) {
  const start = source.indexOf(`export class ${name} extends ${base} {`);
  if (start < 0) throw new Error(`${base} ${name} not found`);
  const end = source.indexOf(`\n${base}.${name} = ${name};`, start);
  if (end < 0) throw new Error(`end of ${name} not found`);
  return source.slice(start, end);
}

function shortUUID(full) {
  const match = /^([0-9A-F]{8})-0000-1000-8000-0026BB765291$/i.exec(full);
  return match ? match[1].replace(/^0+/, "").toUpperCase() : full.toUpperCase();
}

function lowerCamel(name) {
  const m = /^([A-Z]+)(?=[A-Z][a-z]|$)|^[A-Z]/.exec(name);
  const lowered = m[0].length > 1 && m[0].length < name.length ? m[0].slice(0, -1).toLowerCase() + m[0].slice(-1) : m[0].toLowerCase();
  const result = lowered + name.slice(m[0].length);
  return ["switch", "default", "repeat"].includes(result) ? "`" + result + "`" : result;
}

function swiftNumber(text) {
  const n = Number(text);
  if (!Number.isFinite(n)) throw new Error(`bad number ${text}`);
  return Number.isInteger(n) && Math.abs(n) >= 10000 ? n.toLocaleString("en-US").replaceAll(",", "_") : String(n);
}

function parseCharacteristic(source, name) {
  const body = classBody(source, name, "Characteristic");
  const uuid = /UUID: string = "([^"]+)"/.exec(body)[1];
  const displayName = new RegExp(`super\\("([^"]+)", ${name}\\.UUID`).exec(body)[1];
  const format = formats[/format: Formats\.(\w+)/.exec(body)[1]];
  const permList = /perms: \[([^\]]*)\]/.exec(body)[1].split(",").map(s => s.trim()).filter(Boolean)
    .map(p => { const key = p.replace("Perms.", ""); if (!perms[key]) throw new Error(`perm ${p}`); return perms[key]; });
  permList.sort((a, b) => permOrder.indexOf(a) - permOrder.indexOf(b));
  const value = key => { const m = new RegExp(`\\b${key}: (-?[0-9.e]+),`).exec(body); return m ? swiftNumber(m[1]) : undefined; };
  const unitMatch = /unit: Units\.(\w+)/.exec(body);
  const validMatch = /validValues: \[([^\]]*)\]/.exec(body);
  const admin = /adminOnlyAccess: \[([^\]]*)\]/.exec(body);
  if (admin) throw new Error(`${name} has adminOnlyAccess (${admin[1]}); CharacteristicType cannot express it`);
  const args = [`uuid: "${shortUUID(uuid)}"`, `name: "${displayName}"`, `format: .${format}`, `permissions: [${permList.join(", ")}]`];
  if (unitMatch) args.push(`unit: .${units[unitMatch[1]]}`);
  for (const [key, label] of [["minValue", "minValue"], ["maxValue", "maxValue"], ["minStep", "minStep"]]) {
    const v = value(key);
    if (v !== undefined) args.push(`${label}: ${v}`);
  }
  if (validMatch) args.push(`validValues: [${validMatch[1].split(",").map(s => s.trim()).filter(Boolean).join(", ")}]`);
  const maxLen = value("maxLen");
  if (maxLen !== undefined) args.push(`maxLength: ${maxLen}`);
  const maxDataLen = value("maxDataLen");
  if (maxDataLen !== undefined) args.push(`maxLength: ${maxDataLen}`);
  return { swiftName: lowerCamel(name), args };
}

function parseService(source, name) {
  const body = classBody(source, name, "Service");
  const uuid = /UUID: string = "([^"]+)"/.exec(body)[1];
  // The display name is only in the doc comment above the class: /** * Service "Motion Sensor" ... */
  const before = source.slice(0, source.indexOf(`export class ${name} extends Service {`));
  const comments = [...before.matchAll(/\* Service "([^"]+)"/g)];
  const displayName = comments.length ? comments[comments.length - 1][1] : name;
  const required = [...body.matchAll(/this\.addCharacteristic\(Characteristic\.(\w+)\)/g)].map(m => lowerCamel(m[1]));
  const optional = [...body.matchAll(/this\.addOptionalCharacteristic\(Characteristic\.(\w+)\)/g)].map(m => lowerCamel(m[1]));
  return { swiftName: lowerCamel(name), uuid: shortUUID(uuid), displayName, required, optional };
}

const characteristicSource = fs.readFileSync(path.join(hapNodeJS, "lib/CharacteristicDefinitions.ts"), "utf8");
const serviceSource = fs.readFileSync(path.join(hapNodeJS, "lib/ServiceDefinitions.ts"), "utf8");

const header = (source) => `// Portions derived from HAP-NodeJS (https://github.com/homebridge/HAP-NodeJS), Apache License 2.0. Modified for CameraBridge.
// GENERATED by Tools/hap-definitions/generate.mjs from HAP-NodeJS lib/${source} (research brief §3.4 subset).
// Do not edit by hand: change the generator's subset and rerun it.
`;

const known = new Set();
let characteristics = header("CharacteristicDefinitions.ts") + "\nimport Foundation\n\nextension CharacteristicType {\n";
characteristicGroups.forEach(([group, names], index) => {
  characteristics += `${index ? "\n" : ""}    // MARK: ${group}\n\n`;
  for (const name of names) {
    const c = parseCharacteristic(characteristicSource, name);
    known.add(c.swiftName);
    characteristics += `    public static let ${c.swiftName} = CharacteristicType(\n        ${c.args.join(", ")})\n`;
  }
});
characteristics += "}\n";

let serviceText = header("ServiceDefinitions.ts") + "\nimport Foundation\n\nextension ServiceType {\n";
for (const name of services) {
  const s = parseService(serviceSource, name);
  const list = xs => "[" + xs.map((x, i) => (i === 0 ? "CharacteristicType." : ".") + x).join(", ") + "]";
  for (const c of s.required) {
    if (!known.has(c)) throw new Error(`service ${name} requires ${c}, which is outside the §3.4 subset; add it to the generator`);
  }
  // Optional characteristics outside the subset are left out (they have no CharacteristicType constant).
  const dropped = s.optional.filter(c => !known.has(c));
  const optional = s.optional.filter(c => known.has(c));
  if (dropped.length) serviceText += `    /// Optional characteristics not in the subset: ${dropped.map(c => c.replaceAll("`", "")).join(", ")}.\n`;
  serviceText += `    public static let ${s.swiftName} = ServiceType(\n        uuid: "${s.uuid}", name: "${s.displayName}",\n` +
    `        required: ${list(s.required)},\n        optional: ${optional.length ? list(optional) : "[]"})\n`;
}
serviceText += "}\n";

fs.writeFileSync(path.join(outDir, "CharacteristicType+Definitions.swift"), characteristics);
fs.writeFileSync(path.join(outDir, "ServiceType+Definitions.swift"), serviceText);
process.stdout.write(`wrote ${known.size} characteristic and ${services.length} service definitions to ${path.relative(repo, outDir)}\n`);
