// Add a camera: the Mac app's wizard, page for page. Camera type, find it, connect, check it, name it, motion, sensors and audio,
// review, then add it to Apple Home. Everything typed stays in `w`, so Back never loses it.
import { get, post } from '../api.js';
import { h, replace, spinner, toast } from '../dom.js';
import { icon } from '../icons.js';
import { backLink, field, inlineError, switchRow } from './common.js';
import { pairingPanel } from './pairing.js';

const SENSITIVITY_LABELS = ['Low', 'Medium', 'High'];

export function renderAdd({ navigate }) {
  const w = {
    step: 'type', typeId: null, catalog: null,
    host: '', httpPort: null, rtspPort: null, onvifPort: null, useHTTPS: false,
    username: '', password: '', apiKey: '', mainStreamURL: '', subStreamURL: '', source: '',
    unifiCameras: [], unifiCameraID: null, unifiCameraName: '', unifiBusy: false, unifiError: null,
    nest: { projectID: '', clientID: '', clientSecret: '', code: '', session: null, cameras: [], deviceID: null, busy: false, error: null, linkURL: null },
    discovered: null, discovering: false, discoverRun: 0,
    probe: null, probeError: null, probeRun: 0,
    name: '', nameTouched: false, kind: 'camera', motionSource: 'softMotion', motionSensitivity: 0.5, motionHoldSeconds: 20,
    sensors: {}, audioEnabled: true, twoWayAudio: false,
    adding: false, addError: null, addedId: null, errors: {}, connectError: null,
  };
  let gone = false;
  const root = h('div', { class: 'wizard' });
  const body = h('div');
  const progress = h('div', { class: 'progress' });
  let pairing = null;

  const spec = () => w.catalog?.types.find((t) => t.id === w.typeId) || null;
  const steps = () => {
    const t = spec();
    if (!t) return ['type'];
    const list = ['type'];
    if (t.usesDiscovery) list.push('discover');
    if (t.fields.length) list.push('connect');
    list.push('check', 'name', 'motion', 'extras', 'review');
    return list;
  };

  function show(step = w.step) {
    if (gone) return;
    w.step = step;
    pairing?.destroy();
    pairing = null;
    const list = steps();
    const index = list.indexOf(step);
    if (step === 'pair') {
      replace(progress);
    } else {
      replace(progress, h('span', null, `Step ${index + 1} of ${list.length}`),
        h('div', { class: 'bar', 'aria-hidden': 'true' }, h('i')), h('span', { class: 'sr-only' }, STEP_TITLES[step]));
      progress.querySelector('i').style.width = `${Math.round(((index + 1) / list.length) * 100)}%`;
    }
    replace(body, STEP_VIEWS[step]());
    const heading = body.querySelector('h1, h2');
    if (heading) { heading.setAttribute('tabindex', '-1'); heading.focus({ preventScroll: true }); }
    window.scrollTo(0, 0);
  }

  function go(offset) {
    const list = steps();
    const next = list[list.indexOf(w.step) + offset];
    if (next) show(next);
  }

  function nav({ back = true, next = 'Continue', onNext, nextDisabled = false, nextBusy = false, extra = null }) {
    return h('div', { class: 'wizard-actions' },
      back ? h('button', { class: 'btn', type: 'button', onclick: () => (w.step === 'type' ? navigate('/') : go(-1)) }, w.step === 'type' ? 'Cancel' : 'Back') : h('span'),
      h('div', { class: 'row' }, extra,
        h('button', { class: 'btn primary', type: 'submit', disabled: nextDisabled || nextBusy, onclick: onNext ? (e) => { e.preventDefault(); onNext(); } : null },
          nextBusy ? spinner() : null, next)));
  }

  function form(children, onSubmit) {
    return h('form', { novalidate: true, onsubmit: (e) => { e.preventDefault(); onSubmit?.(); } }, children);
  }

  // Request body for /probe and /cameras.
  function request(forAdd = false) {
    const t = spec();
    const body = { type: t.id };
    for (const key of ['host', 'username', 'password', 'apiKey', 'mainStreamURL', 'subStreamURL', 'source']) if (w[key]) body[key] = w[key];
    if (t.fields.includes('host') || t.advancedFields.length) {
      if (w.httpPort) body.httpPort = Number(w.httpPort);
      if (w.rtspPort) body.rtspPort = Number(w.rtspPort);
      if (w.onvifPort) body.onvifPort = Number(w.onvifPort);
      body.useHTTPS = w.useHTTPS;
    }
    if (t.id === 'unifiProtect') { body.unifiCameraID = w.unifiCameraID; body.unifiCameraName = w.unifiCameraName; }
    if (t.id === 'googleNest') { body.nestSession = w.nest.session; body.nestDeviceID = w.nest.deviceID; }
    if (forAdd) {
      Object.assign(body, { name: w.name, kind: w.kind, motionSource: w.motionSource, motionSensitivity: w.motionSensitivity, motionHoldSeconds: w.motionHoldSeconds,
        sensors: w.sensors, audioEnabled: w.audioEnabled, twoWayAudio: w.twoWayAudio });
    }
    return body;
  }

  // MARK: Step 1, camera type

  function typeStep() {
    const t = spec();
    const groups = w.catalog.groups.map((group) => {
      const types = w.catalog.types.filter((x) => x.group === group.id);
      return h('fieldset', { class: 'type-group' },
        h('legend', { class: 'sr-only' }, group.title), h('h3', { 'aria-hidden': 'true' }, group.title),
        types.map((type) => {
          const radio = h('input', { type: 'radio', name: 'camera-type', value: type.id, checked: type.id === w.typeId,
            onchange: () => { w.typeId = type.id; applyDefaults(type); show('type'); } });
          return h('label', { class: 'choice' }, radio, h('span', { class: 'text' }, h('span', { class: 'title' }, type.title), h('span', { class: 'desc' }, type.summary)));
        }),
        group.footer ? h('p', { class: 'footer-note' }, group.footer) : null);
    });
    const details = t ? typeDetails(t) : h('div', { class: 'card' }, h('p', { class: 'muted' }, 'Choose the kind of camera you have. The details appear here.'));
    return form([
      h('h1', null, 'What kind of camera is it?'),
      h('p', { class: 'lede' }, 'If you are not sure, choose the first one. Camera Bridge tries Hikvision, Reolink and then ONVIF.'),
      h('div', { class: 'layout-2' }, h('div', null, groups), h('div', null, details)),
      nav({ nextDisabled: !t }),
    ], () => t && go(1));
  }

  function applyDefaults(type) {
    w.httpPort = type.defaultHTTPPort === 80 ? null : type.defaultHTTPPort;
    w.rtspPort = type.defaultRTSPPort === 554 ? null : type.defaultRTSPPort;
    w.useHTTPS = type.defaultUseHTTPS;
    w.probe = null;
    w.errors = {};
  }

  function typeDetails(type) {
    const support = (label, s, detail) => h('li', { class: s.level === 'yes' ? '' : 'partly' }, icon(s.level === 'yes' ? 'check' : 'info'),
      h('span', null, h('strong', null, label), s.note ? ` — ${s.note}` : '', detail ? ` — ${detail}` : ''));
    return h('div', { class: 'card' },
      h('h2', null, type.title),
      h('p', { class: 'muted' }, type.summary),
      h('h3', { class: 'section-title' }, 'What you get'),
      h('ul', { class: 'support-list' }, support('Live view', type.live), support('HomeKit Secure Video recording', type.recording), support('Motion and detections', type.events, type.eventsDetail)),
      h('h3', { class: 'section-title' }, 'Before you start'),
      h('ol', { class: 'steps' }, type.setupSteps.map((s) => h('li', null, s))),
      type.notes.length ? [h('h3', { class: 'section-title' }, 'Good to know'), type.notes.map((n) => h('p', { class: 'small muted' }, n))] : null,
      type.needsStreamingHelper && !w.catalog.streamingHelperInstalled
        ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, 'This copy of Camera Bridge doesn’t include the streaming helper (go2rtc), which this camera type needs.')) : null);
  }

  // MARK: Step 2, find the camera

  async function runDiscovery() {
    const run = ++w.discoverRun;
    w.discovering = true;
    w.discovered = null;
    if (w.step === 'discover') show('discover');
    try {
      const { cameras } = await post('discover');
      if (run !== w.discoverRun || gone) return;
      w.discovered = cameras;
    } catch (error) {
      if (run !== w.discoverRun || gone) return;
      w.discovered = [];
      toast(error.message, 'error');
    }
    w.discovering = false;
    if (w.step === 'discover') show('discover');
  }

  function discoverStep() {
    if (w.discovered === null && !w.discovering) queueMicrotask(runDiscovery);
    const list = w.discovering || w.discovered === null
      ? h('div', { class: 'checking' }, spinner(), h('div', null, h('strong', null, 'Looking for cameras on your network…'), h('div', { class: 'muted small' }, 'This takes a few seconds.')))
      : w.discovered.length
        ? h('div', { class: 'found', role: 'radiogroup', 'aria-label': 'Cameras found' }, w.discovered.map((camera) => {
          const radio = h('input', { type: 'radio', name: 'found', checked: w.selectedHost === camera.host,
            disabled: camera.alreadyAdded, onchange: () => { w.selectedHost = camera.host; w.host = camera.host; w.onvifPort = camera.onvifPort && camera.onvifPort !== 80 ? camera.onvifPort : null; if (!w.nameTouched && camera.name) w.name = camera.name; w.discoveredName = camera.name; show('discover'); } });
          return h('label', { class: 'choice' }, radio, h('span', { class: 'text' },
            h('span', { class: 'title' }, camera.name || camera.hardware || camera.host, camera.alreadyAdded ? h('span', { class: 'pill plain' }, ' Already added') : null),
            h('span', { class: 'desc' }, [camera.host, camera.hardware && camera.name ? camera.hardware : null].filter(Boolean).join(' · '))));
        }))
        : h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, h('span', { class: 'title' }, 'No cameras answered'),
          'Not every camera announces itself. You can type its address instead. Make sure the camera is on and on the same network as this bridge.'));
    const manual = field('Or type the camera’s address', h('input', { type: 'text', value: w.host, placeholder: '192.0.2.20 or camera.local', autocomplete: 'off', spellcheck: 'false',
      oninput: (e) => { w.host = e.target.value; if (w.selectedHost && w.selectedHost !== w.host.trim()) w.selectedHost = null; update(); } }),
    { hint: 'An IP address or a name, like 192.0.2.20 or camera.local.' });
    const next = nav({ nextDisabled: !w.host.trim() });
    function update() { next.querySelector('[type=submit]').disabled = !w.host.trim(); }
    return form([
      h('h1', null, 'Find your camera'),
      h('p', { class: 'lede' }, 'Camera Bridge looks for ONVIF cameras on your network. Pick yours, or type its address.'),
      list, h('div', { class: 'row' }, h('button', { class: 'btn small', type: 'button', disabled: w.discovering, onclick: runDiscovery }, icon('refresh'), 'Search again')),
      h('hr'), manual, next,
    ], () => w.host.trim() && go(1));
  }

  // MARK: Step 3, connect

  function connectStep() {
    const t = spec();
    const e = w.errors;
    const controls = [];
    const input = (key, props = {}) => h('input', { type: 'text', value: w[key] ?? '', autocomplete: 'off', spellcheck: 'false', 'aria-invalid': e[key] ? 'true' : null,
      oninput: (ev) => { w[key] = ev.target.value; delete e[key]; }, ...props });
    if (t.fields.includes('host')) {
      controls.push(field(t.id === 'unifiProtect' ? 'Console address' : t.id === 'wyzeRTSP' ? 'Camera’s IP address' : 'Camera address', input('host', { placeholder: '192.0.2.20' }),
        { error: e.host, hint: t.id === 'unifiProtect' ? 'The console’s address, like 192.0.2.1.' : 'You can paste the address from a browser, user name and port included.' }));
    }
    if (t.fields.includes('mainStreamURL')) {
      controls.push(field('Main stream URL', input('mainStreamURL', { placeholder: 'rtsp://192.0.2.20:554/stream1' }), { error: e.mainStreamURL, hint: 'A user name and password typed into the address are moved to the fields below.' }),
        field('Sub stream URL (optional)', input('subStreamURL', { placeholder: 'rtsp://192.0.2.20:554/stream2' }), { error: e.subStreamURL, hint: 'A smaller picture, used for built-in motion detection and small live views.' }));
    }
    if (t.fields.includes('username')) {
      controls.push(field(t.id === 'wyzeRTSP' ? 'RTSP user name' : 'User name', input('username', { autocomplete: 'off' }), { error: e.username }));
    }
    if (t.fields.includes('password')) {
      controls.push(field(t.id === 'wyzeRTSP' ? 'RTSP password' : 'Password', input('password', { type: 'password', autocomplete: 'new-password' }),
        { error: e.password, hint: 'Camera Bridge keeps it encrypted on this bridge.' }));
    }
    if (t.fields.includes('apiKey')) {
      controls.push(field('API key', input('apiKey', { type: 'password', autocomplete: 'off' }), { error: e.apiKey, hint: 'Create it in UniFi Protect under Settings › Control Plane › Integrations.' }),
        unifiPicker());
    }
    if (t.fields.includes('source')) {
      const area = h('textarea', { rows: 3, spellcheck: 'false', autocomplete: 'off', placeholder: 'ring:?refresh_token=…', 'aria-invalid': e.source ? 'true' : null,
        oninput: (ev) => { w.source = ev.target.value; delete e.source; } }, w.source);
      controls.push(field('Source address', area, { error: e.source, hint: 'Camera Bridge keeps it encrypted on this bridge. It is never shown again.' }));
    }
    if (t.fields.includes('nest')) controls.push(nestPanel());
    if (t.advancedFields.length) {
      const more = [];
      if (t.advancedFields.includes('httpPort')) {
        more.push(field(w.useHTTPS ? 'HTTPS port' : 'HTTP port', h('input', { type: 'number', min: 1, max: 65535, value: w.httpPort ?? t.defaultHTTPPort,
          oninput: (ev) => { w.httpPort = ev.target.value; } }), { error: e.httpPort }));
      }
      if (t.advancedFields.includes('rtspPort')) {
        more.push(field('RTSP port', h('input', { type: 'number', min: 1, max: 65535, value: w.rtspPort ?? t.defaultRTSPPort, oninput: (ev) => { w.rtspPort = ev.target.value; } }), { error: e.rtspPort }));
      }
      if (t.advancedFields.includes('onvifPort')) {
        more.push(field('ONVIF port', h('input', { type: 'number', min: 1, max: 65535, value: w.onvifPort ?? '', placeholder: 'Found automatically', oninput: (ev) => { w.onvifPort = ev.target.value; } }),
          { error: e.onvifPort, hint: 'Only if the camera’s ONVIF service is on a port other than the HTTP port. Tapo uses 2020.' }));
      }
      if (t.advancedFields.includes('useHTTPS')) {
        more.push(switchRow({ title: 'Use HTTPS', desc: 'Turn on if the camera only answers HTTPS.', checked: w.useHTTPS, onchange: (v) => {
          w.useHTTPS = v;
          if (v && Number(w.httpPort || 80) === 80) w.httpPort = 443;
          else if (!v && Number(w.httpPort) === 443) w.httpPort = null;
          show('connect');
        } }));
      }
      controls.push(h('details', { class: 'card', open: Object.keys(e).some((k) => k.endsWith('Port')) || null }, h('summary', null, 'More options'), h('div', { class: 'stack' }, more)));
    }
    const ready = t.id === 'unifiProtect' ? !!w.unifiCameraID : t.id === 'googleNest' ? !!w.nest.deviceID : true;
    return form([
      h('h1', null, `Connect to ${t.id === 'rtspURL' ? 'the camera' : t.title}`),
      h('p', { class: 'lede' }, t.usesDiscovery ? 'Enter the user you created for Camera Bridge on the camera.' : 'Enter the details Camera Bridge needs to reach it.'),
      w.connectError ? inlineError(w.connectError) : null,
      controls,
      nav({ nextDisabled: !ready, next: 'Check the camera' }),
    ], () => ready && go(1));
  }

  function unifiPicker() {
    const t = spec();
    const list = w.unifiCameras.length
      ? h('div', { class: 'found', role: 'radiogroup', 'aria-label': 'Cameras on the console' }, w.unifiCameras.map((camera) => h('label', { class: 'choice' },
        h('input', { type: 'radio', name: 'protect', checked: w.unifiCameraID === camera.id, onchange: () => { w.unifiCameraID = camera.id; w.unifiCameraName = camera.name; if (!w.nameTouched) w.name = camera.name; show('connect'); } }),
        h('span', { class: 'text' }, h('span', { class: 'title' }, camera.name), h('span', { class: 'desc' }, `${camera.model}${camera.doorbell ? ' · doorbell' : ''}${camera.connected ? '' : ' · offline'}`)))))
      : null;
    return h('div', { class: 'field' },
      h('button', { class: 'btn', type: 'button', disabled: w.unifiBusy || !w.host.trim() || !w.apiKey.trim(), onclick: async () => {
        w.unifiBusy = true; w.unifiError = null; show('connect');
        try {
          const useHTTPS = w.useHTTPS;
          const { cameras } = await post('integrations/unifi/cameras', { host: w.host, apiKey: w.apiKey, useHTTPS, httpPort: w.httpPort ? Number(w.httpPort) : undefined });
          w.unifiCameras = cameras;
          if (cameras.length === 1) { w.unifiCameraID = cameras[0].id; w.unifiCameraName = cameras[0].name; }
          if (!cameras.length) w.unifiError = 'The console has no cameras.';
        } catch (error) { w.unifiError = error.message; w.unifiCameras = []; }
        w.unifiBusy = false;
        if (w.step === 'connect') show('connect');
      } }, w.unifiBusy ? spinner() : icon('search'), 'Find cameras'),
      w.unifiError ? h('span', { class: 'error', role: 'alert' }, w.unifiError) : null, list, t ? null : null);
  }

  function nestPanel() {
    const n = w.nest;
    const text = (key, label, type = 'text') => field(label, h('input', { type, value: n[key], autocomplete: 'off', spellcheck: 'false', oninput: (e) => { n[key] = e.target.value; n.linkURL = null; } }));
    const link = h('button', { class: 'btn', type: 'button', disabled: !n.projectID.trim() || !n.clientID.trim(), onclick: async () => {
      try {
        const { url } = await post('integrations/nest/authorize', { projectID: n.projectID, clientID: n.clientID });
        n.linkURL = url;
        n.error = null;
        window.open(url, '_blank', 'noopener,noreferrer');
      } catch (error) { n.error = error.message; }
      show('connect');
    } }, icon('lock'), 'Open Google’s sign-in page');
    const connect = h('button', { class: 'btn', type: 'button', disabled: n.busy || !n.code.trim() || !n.clientSecret.trim(), onclick: async () => {
      n.busy = true; n.error = null; show('connect');
      try {
        const result = await post('integrations/nest/connect', { projectID: n.projectID, clientID: n.clientID, clientSecret: n.clientSecret, code: n.code });
        n.session = result.session; n.cameras = result.cameras; n.code = '';
        if (result.cameras.length === 1) { n.deviceID = result.cameras[0].id; if (!w.nameTouched) w.name = result.cameras[0].name; }
      } catch (error) { n.error = error.message; }
      n.busy = false;
      if (w.step === 'connect') show('connect');
    } }, n.busy ? spinner() : null, 'Connect');
    return h('div', { class: 'stack' },
      text('projectID', 'Device Access project ID'), text('clientID', 'OAuth client ID'), text('clientSecret', 'OAuth client secret', 'password'),
      h('div', { class: 'row' }, link),
      field('Code from Google', h('input', { type: 'text', value: n.code, autocomplete: 'off', spellcheck: 'false', oninput: (e) => { n.code = e.target.value; } }),
        { hint: 'After you allow access, Google sends you to a page. Paste that page’s address, or just the code in it.' }),
      h('div', { class: 'row' }, connect),
      n.error ? h('span', { class: 'error', role: 'alert' }, n.error) : null,
      n.cameras.length ? h('div', { class: 'found', role: 'radiogroup', 'aria-label': 'Cameras in your Google home' }, n.cameras.map((camera) => h('label', { class: 'choice' },
        h('input', { type: 'radio', name: 'nest', checked: n.deviceID === camera.id, onchange: () => { n.deviceID = camera.id; if (!w.nameTouched) w.name = camera.name; show('connect'); } }),
        h('span', { class: 'text' }, h('span', { class: 'title' }, camera.name), h('span', { class: 'desc' }, `${camera.doorbell ? 'Doorbell' : 'Camera'} · ${camera.transport}`)))) ) : null);
  }

  // MARK: Step 4, check the camera

  async function runProbe() {
    const run = ++w.probeRun;
    w.probe = null; w.probeError = null; w.probing = true;
    if (w.step === 'check') show('check');
    try {
      const result = await post('probe', request());
      if (run !== w.probeRun || gone) return;
      w.probing = false;
      if (result.ok) {
        w.probe = result;
        if (!w.nameTouched && !w.name) w.name = result.suggestedName;
        w.kind = result.suggestedKind;
        w.motionSource = result.suggestedMotionSource;
        w.audioEnabled = result.hasCameraAudio;
        w.twoWayAudio = result.canUseTwoWayAudio;
        w.sensors = {};
      } else {
        w.probeError = result.error;
      }
    } catch (error) {
      if (run !== w.probeRun || gone) return;
      w.probing = false;
      if (error.status === 400) {
        // Something to fix on the Connect page.
        w.errors = error.field ? { [error.field]: error.message } : {};
        w.connectError = error.field ? null : error.message;
        w.probing = false;
        const t = spec();
        show(t.fields.length ? 'connect' : 'type');
        return;
      }
      w.probeError = error.message;
    }
    if (w.step === 'check') show('check');
  }

  function checkStep() {
    if (!w.probe && !w.probeError && !w.probing) { w.connectError = null; queueMicrotask(runProbe); }
    const t = spec();
    if (w.probing || (!w.probe && !w.probeError)) {
      return h('div', null, h('h1', null, 'Checking the camera…'),
        h('div', { class: 'checking card' }, spinner(), h('div', null, t.id === 'demo' ? 'Starting the test pattern…' : 'Camera Bridge is signing in and reading the camera’s streams. This can take up to 20 seconds.')));
    }
    if (w.probeError) {
      return form([h('h1', null, 'Couldn’t check the camera'), inlineError(w.probeError),
        h('p', { class: 'muted' }, 'Check the address, the user name and the password, then try again.'),
        nav({ next: 'Try again', onNext: runProbe })], runProbe);
    }
    const p = w.probe;
    const row = (k, v) => v ? [h('dt', null, k), h('dd', null, v)] : null;
    return form([
      h('h1', null, 'The camera answered'),
      h('div', { class: 'card' },
        h('dl', { class: 'kv' },
          row('Type', p.vendorName),
          row('Make', [p.manufacturer, p.model].filter(Boolean).join(' ')),
          row('Firmware', p.firmware),
          row('Main stream', p.mainStream?.summary),
          row('Sub stream', p.subStream?.summary),
          row('Events', p.capabilities.events.length ? p.capabilities.events.map((x) => x.replace(/([A-Z])/g, ' $1').toLowerCase()).join(', ') : 'None reported — built-in motion detection will be used'))),
      p.alreadyAdded ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, h('span', { class: 'title' }, `Already added as “${p.alreadyAdded.name}”`),
        'Adding it again makes a second accessory in the Home app, with its own connections to the camera.')) : null,
      nav({}),
    ], () => go(1));
  }

  // MARK: Step 5, name and kind

  function nameStep() {
    const name = h('input', { type: 'text', value: w.name, maxlength: 60, autocomplete: 'off', required: true, 'aria-invalid': w.errors.name ? 'true' : null,
      oninput: (e) => { w.name = e.target.value; w.nameTouched = true; submit.disabled = !w.name.trim(); } });
    const submitRow = nav({ nextDisabled: !w.name.trim() });
    const submit = submitRow.querySelector('[type=submit]');
    const kinds = [['camera', 'Camera', 'Shows in the Home app as a camera.'], ['doorbell', 'Video doorbell', 'Shows as a video doorbell and rings your devices when pressed.']];
    return form([
      h('h1', null, 'Name it'),
      h('p', { class: 'lede' }, 'This is the name Apple Home shows. You can change it later.'),
      field('Camera name', name, { error: w.errors.name }),
      h('div', { class: 'field', role: 'radiogroup', 'aria-labelledby': 'kind-label' }, h('span', { class: 'label', id: 'kind-label' }, 'Camera or doorbell?'),
        kinds.map(([value, title, desc]) => h('label', { class: 'choice' }, h('input', { type: 'radio', name: 'kind', value, checked: w.kind === value, onchange: () => { w.kind = value; show('name'); } }),
          h('span', { class: 'text' }, h('span', { class: 'title' }, title), h('span', { class: 'desc' }, desc)))),
        h('span', { class: 'hint' }, 'Choose carefully: changing between Camera and Video Doorbell later means removing the accessory from the Home app and re-adding it.')),
      w.kind === 'doorbell' && w.probe?.ringsThroughWebhook
        ? h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, 'This camera reports no doorbell button of its own. Doorbell presses can come from another system through the webhook (turn it on in Settings).')) : null,
      submitRow,
    ], () => w.name.trim() && go(1));
  }

  // MARK: Step 6, motion

  function motionStep() {
    const p = w.probe;
    const sens = h('input', { type: 'range', min: 0, max: 1, step: 0.05, value: w.motionSensitivity, 'aria-label': 'Sensitivity', oninput: (e) => { w.motionSensitivity = Number(e.target.value); out.textContent = label(); } });
    const label = () => SENSITIVITY_LABELS[Math.min(2, Math.floor(w.motionSensitivity * 3))] + ` (${Math.round(w.motionSensitivity * 100)}%)`;
    const out = h('output', { class: 'muted' }, label());
    return form([
      h('h1', null, 'How should motion be found?'),
      h('p', { class: 'lede' }, 'Motion tells Apple Home when to record a clip and send notifications.'),
      h('div', { role: 'radiogroup', 'aria-label': 'Motion source' }, p.motionSources.map((source) => h('label', { class: 'choice' },
        h('input', { type: 'radio', name: 'motion', checked: w.motionSource === source.id, onchange: () => { w.motionSource = source.id; w.sensors = {}; show('motion'); } }),
        h('span', { class: 'text' }, h('span', { class: 'title' }, source.title), h('span', { class: 'desc' }, source.detail))))),
      w.motionSource === 'softMotion' ? h('div', { class: 'field' }, h('div', { class: 'row spread' }, h('label', { for: 'sens' }, 'Sensitivity'), out), (sens.id = 'sens', sens),
        h('span', { class: 'hint' }, 'Higher finds smaller movements and also more false alarms.')) : null,
      field('Motion stays on for (seconds)', h('input', { type: 'number', min: 1, max: 3600, value: w.motionHoldSeconds, oninput: (e) => { w.motionHoldSeconds = Number(e.target.value) || 20; } }),
        { hint: 'How long after the last movement the camera still counts as having motion.' }),
      nav({}),
    ], () => go(1));
  }

  // MARK: Step 7, sensors and audio

  function extrasStep() {
    const p = w.probe;
    const sensors = p.sensorsByMotionSource[w.motionSource] || [];
    return form([
      h('h1', null, 'Sensors and audio'),
      h('p', { class: 'lede' }, 'Extras that appear in the Home app next to the camera.'),
      h('div', { class: 'card' }, h('h2', null, 'Sensors'),
        h('p', { class: 'desc' }, 'Each one is a sensor in Home you can use in automations.'),
        sensors.length ? sensors.map((s) => switchRow({ title: s.title, desc: `${s.homeAccessory}${s.fromWebhook ? ' · reported through the webhook' : ''}`, checked: !!w.sensors[s.id], onchange: (v) => { w.sensors[s.id] = v; } }))
          : h('p', { class: 'muted' }, 'This camera doesn’t report any extra detections.')),
      h('div', { class: 'card' }, h('h2', null, 'Audio'),
        switchRow({ title: 'Camera audio', desc: p.hasCameraAudio ? 'Hear the camera’s microphone in live view and recordings.' : 'This camera has no audio.', checked: w.audioEnabled && p.hasCameraAudio,
          disabled: !p.hasCameraAudio, onchange: (v) => { w.audioEnabled = v; } }),
        p.canUseTwoWayAudio ? switchRow({ title: 'Two-way audio', desc: 'Talk through the camera’s speaker from the Home app.', checked: w.twoWayAudio, onchange: (v) => { w.twoWayAudio = v; } }) : null),
      nav({}),
    ], () => go(1));
  }

  // MARK: Step 8, review and add

  function reviewStep() {
    const p = w.probe;
    const t = spec();
    const sensors = (p.sensorsByMotionSource[w.motionSource] || []).filter((s) => w.sensors[s.id]).map((s) => s.title);
    const audio = w.audioEnabled && p.hasCameraAudio ? (w.twoWayAudio ? 'Camera audio and two-way audio' : 'Camera audio') : (w.twoWayAudio ? 'Two-way audio only' : 'Off');
    const source = p.motionSources.find((s) => s.id === w.motionSource)?.title;
    const row = (k, v) => [h('dt', null, k), h('dd', null, v)];
    return form([
      h('h1', null, 'Ready to add'),
      w.addError ? inlineError(w.addError) : null,
      h('div', { class: 'card' }, h('dl', { class: 'kv review' },
        row('Name', w.name.trim()), row('Type', t.title), row('Camera or doorbell', w.kind === 'doorbell' ? 'Video doorbell' : 'Camera'),
        w.host && t.fields.includes('host') ? row('Address', w.host.trim()) : null,
        row('Motion', `${source}${w.motionSource === 'softMotion' ? `, sensitivity ${Math.round(w.motionSensitivity * 100)}%` : ''}`),
        row('Sensors', sensors.length ? sensors.join(', ') : 'None'), row('Audio', audio))),
      p.alreadyAdded ? h('div', { class: 'banner warning' }, icon('alert'), h('div', { class: 'text' }, h('span', { class: 'title' }, `This camera is already added as “${p.alreadyAdded.name}”`),
        'Adding it again makes a second accessory with its own connections to the camera.',
        h('div', { class: 'actions' }, h('a', { class: 'btn small', href: `#/camera/${p.alreadyAdded.id}` }, 'Open it')))) : null,
      nav({ next: 'Add camera', nextBusy: w.adding, onNext: add }),
    ], add);
  }

  async function add() {
    if (w.adding) return;
    w.adding = true; w.addError = null;
    show('review');
    try {
      const camera = await post('cameras', request(true));
      w.addedId = camera.id;
      w.adding = false;
      show('pair');
    } catch (error) {
      w.adding = false;
      if (error.field === 'name') { w.errors = { name: error.message }; show('name'); return; }
      w.addError = error.message;
      show('review');
    }
  }

  // MARK: Step 9, add to Apple Home

  function pairStep() {
    pairing = pairingPanel({ cameraId: w.addedId, cameraName: w.name.trim(), intro: true });
    return h('div', null,
      h('h1', null, `${w.name.trim() || 'Your camera'} is added`),
      h('p', { class: 'lede' }, 'One more step: add it to Apple Home on your iPhone or iPad.'),
      pairing.el,
      w.kind === 'doorbell' && w.probe?.ringsThroughWebhook
        ? h('div', { class: 'banner info' }, icon('info'), h('div', { class: 'text' }, 'Rings from this camera come through the webhook. Turn it on in Settings and send it a doorbell event from your other system.')) : null,
      h('div', { class: 'wizard-actions' }, h('a', { class: 'btn', href: '#/add' }, 'Add another camera'), h('a', { class: 'btn primary', href: '#/' }, 'Done')));
  }

  const STEP_TITLES = {
    type: 'Camera type', discover: 'Find your camera', connect: 'Connect', check: 'Check the camera', name: 'Name it',
    motion: 'Motion', extras: 'Sensors and audio', review: 'Review', pair: 'Add to Apple Home',
  };
  const STEP_VIEWS = { type: typeStep, discover: discoverStep, connect: connectStep, check: checkStep, name: nameStep, motion: motionStep, extras: extrasStep, review: reviewStep, pair: pairStep };

  replace(root, backLink('#/', 'Cameras'), progress, body);
  replace(body, h('div', { class: 'checking' }, spinner()));
  get('camera-types').then((catalog) => { w.catalog = catalog; show('type'); }).catch((error) => replace(body, inlineError(error.message)));

  return { el: root, destroy() { gone = true; pairing?.destroy(); } };
}
