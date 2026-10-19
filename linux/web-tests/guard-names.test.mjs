// What a name the Internet guard blocked likely is (js/guard-names.js), in plain Node: each kind of the table and the makers it names,
// the camera's own maker for a name that names none, a name it does not recognize, and the time server's hint about Set up for Camera
// Bridge. Made-up and documentation names only, but for the makers' own words.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { GENERAL_SERVICES, GUARD_MAKERS, GUARD_NAME_KINDS, GUARD_NAME_TEXT, describeGuardName, guardNameKind, makerOfCamera, makerOfName }
  from '../web/js/guard-names.js';

test('the table is data: the kinds in the order they are tried (general services before any kind that names a maker), and the makers', () => {
  assert.deepEqual(GUARD_NAME_KINDS.map((entry) => entry.kind), ['time', 'connectivity', 'general', 'ddns', 'update', 'cloud']);
  assert.ok(GENERAL_SERVICES.includes('apple.com') && GENERAL_SERVICES.includes('cloudfront.net'));
  assert.deepEqual(GUARD_MAKERS.map((entry) => entry.maker), ['Hikvision', 'EZVIZ', 'Reolink', 'TP-Link', 'Wyze', 'Meari', 'Dahua', 'Amcrest']);
});

test('time servers', () => {
  for (const name of ['pool.ntp.org', '3.pool.ntp.org', 'ntp1.example.com', 'time.example.org', 'time-a.example.gov', 'sntp.example.net', 'ntp.reolink.com']) {
    assert.equal(guardNameKind(name), 'time', name);
  }
  assert.equal(describeGuardName('time.example.org').text, 'Likely a time server: the camera asks it for the time.');
  assert.equal(describeGuardName('time.example.org').maker, null, 'a time server is nobody’s cloud');
  for (const name of ['realtime.example.com', 'timer.example.com', 'showtime.example.net', 'ntpd-stats.example.org']) {
    assert.notEqual(guardNameKind(name), 'time', `${name}: “time” and “ntp” only as words of their own`);
  }
  assert.equal(guardNameKind('time.apple.com'), 'time', 'a time server at a general service is still a time server');
});

test('firmware and app update checks, with the maker the name or the camera says', () => {
  for (const name of ['update.example.com', 'fw-update.example.net', 'upgrade.example.org', 'firmware.example.com', 'ota2.example.com', 'fota.example.com']) {
    assert.equal(guardNameKind(name), 'update', name);
  }
  assert.equal(describeGuardName('update.example.com').text, 'Likely a firmware or app update check.');
  assert.equal(describeGuardName('upgrade.reolink.com').text, 'Likely Reolink’s firmware or app update check.');
  assert.equal(describeGuardName('update.example.com', { camera: { vendor: 'hikvision' } }).text, 'Likely a firmware or app update check.',
    'an update name that names no maker is not put down to the camera’s: it may be anybody’s');
  assert.equal(describeGuardName('update.googleapis.com', { camera: { vendor: 'hikvision' } }).kind, 'general');
  assert.equal(guardNameKind('iota.example.com'), 'unknown', '“ota” is a word of its own, not part of one');
});

test('checks that the internet is there', () => {
  for (const name of ['connectivitycheck.gstatic.com', 'captive.example.com', 'www.msftconnecttest.com', 'www.google.com', 'baidu.com', 'nmcheck.example.org']) {
    assert.equal(guardNameKind(name), 'connectivity', name);
  }
  assert.equal(describeGuardName('www.google.com').text, 'Likely a check that the internet can be reached.');
  assert.equal(guardNameKind('*.google.com'), 'general', 'a hidden id is part of the name: “*.google.com” is not www.google.com');
  assert.equal(guardNameKind('*.baidu.com'), 'unknown');
});

test('well-known general services and other third parties are never the camera maker’s cloud', () => {
  const general = ['icloud.com', 'p2p.icloud.com', 'cloudflare.com', 'cloudflare-dns.com', 'd1234.cloudfront.net', 'x.cloudapp.azure.com', 'push.apple.com',
    'gateway.push.apple.com', 'iot.us-east-1.amazonaws.com', 'firebaseinstallations.googleapis.com', 'a1.akamaiedge.net', 'e1.akamaized.net',
    'login.microsoft.com', '*.google.com'];
  for (const name of general) {
    const what = describeGuardName(name, { camera: { vendor: 'reolink', manufacturer: 'Reolink' } });
    assert.deepEqual([what.kind, what.maker, what.text], ['general', null, 'Likely a general internet service (not the camera maker’s).'], name);
  }
  for (const name of ['soundcloud.com', 'api.cloudinary.com', 'pushover.net', 'api.pushbullet.com', 'pushy.me', 'cloudy.example.com', 'pushed.example.org']) {
    const what = describeGuardName(name, { camera: { vendor: 'reolink' } });
    assert.notEqual(what.kind, 'cloud', `${name}: “cloud”, “push” and “relay” only as words of their own`);
    assert.equal(what.maker, null, name);
    assert.ok(!what.text.includes('cloud or phone-app'), name);
  }
});

test('the makers’ clouds and phone-app connections, named by the name, else by the camera', () => {
  const makers = {
    'dev.hik-connect.com': 'Hikvision', 'api.hikvision.example': 'Hikvision', 'eu.ezvizlife.example': 'EZVIZ', 'apis.reolink.example': 'Reolink',
    'n-devs.tplinkcloud.example': 'TP-Link', 'tapo.example.com': 'TP-Link', 'api.wyzecam.example': 'Wyze', 'apis.cloudedge.example': 'Meari',
    'meari.example.com': 'Meari', 'www.easy4ip.example': 'Dahua', 'dahua.example.net': 'Dahua', 'amcrest.example.com': 'Amcrest',
  };
  for (const [name, maker] of Object.entries(makers)) {
    assert.equal(guardNameKind(name), 'cloud', name);
    assert.equal(makerOfName(name), maker, name);
    assert.equal(describeGuardName(name, { camera: { vendor: 'onvif', manufacturer: 'Somebody Else' } }).text, `Likely ${maker}’s cloud or phone-app connection.`,
      `${name}: the name’s maker before the camera’s`);
  }
  for (const name of ['*.p2p.example.com', 'p2p2.example.com', 'cloud.example.net', 'clouds.example.net', 'relay-eu.example.com', 'push.example.org',
    'iot.example.com', 'stun.example.com', 'mqtt.example.net']) {
    assert.equal(guardNameKind(name), 'cloud', name);
    assert.equal(describeGuardName(name).text, 'Likely the camera maker’s cloud or phone-app connection.', `${name}: no maker known`);
  }
  assert.equal(describeGuardName('*.p2p.example.com', { camera: { vendor: 'reolink' } }).text, 'Likely Reolink’s cloud or phone-app connection.');
  assert.equal(describeGuardName('cloud.example.net', { camera: { vendor: 'onvif', manufacturer: 'Jenvista' } }).maker, 'Jenvista', 'the maker the camera gives');
  assert.equal(describeGuardName('cloud.example.net', { camera: { vendor: 'onvif', manufacturer: 'ONVIF' } }).maker, null, 'a manufacturer that names nobody');
  assert.equal(describeGuardName('cloud.example.net', { camera: { vendor: 'onvif', manufacturer: 'IPCAM' } }).maker, null);
  assert.equal(describeGuardName('cloud.example.net', { camera: { vendor: 'amcrest', manufacturer: 'Dahua Technology' } }).maker, 'Dahua');
});

test('a short maker word counts only as a word of its own', () => {
  assert.equal(makerOfName('tapo.example.com'), 'TP-Link');
  assert.equal(makerOfName('tapo-eu.example.com'), 'TP-Link');
  for (const name of ['tapology.com', 'metapod.example.com']) {
    assert.equal(makerOfName(name), null, name);
    assert.equal(guardNameKind(name), 'unknown', name);
  }
  assert.equal(makerOfCamera({ vendor: 'onvif', manufacturer: 'Tapo' }), 'TP-Link');
});

test('dynamic DNS services are said to be that, not the maker’s cloud', () => {
  for (const name of ['ddns.example.com', 'my-camera.dyndns.example', 'x.duckdns.org', '*.ddns.hik-online.example']) {
    const what = describeGuardName(name, { camera: { vendor: 'hikvision' } });
    assert.deepEqual([what.kind, what.maker], ['ddns', null], name);
    assert.equal(what.text, 'Likely a dynamic DNS service, which keeps a name pointing at your home’s internet address.');
  }
});

test('the camera’s maker: its manufacturer when that names one, else its type’s', () => {
  assert.equal(makerOfCamera({ vendor: 'hikvision' }), 'Hikvision');
  assert.equal(makerOfCamera({ vendor: 'onvif', manufacturer: 'TP-LINK' }), 'TP-Link');
  assert.equal(makerOfCamera({ vendor: 'onvif', manufacturer: ' Generic ' }), null);
  assert.equal(makerOfCamera({ vendor: 'rtsp' }), null);
  assert.equal(makerOfCamera({ vendor: 'toString' }), null, 'only the table’s own vendors');
  assert.equal(makerOfCamera(null), null);
});

test('a name it does not recognize says so', () => {
  for (const name of ['a.example.com', 'dev.example.net', '*.devices.example.net', '', null, undefined]) {
    assert.equal(guardNameKind(name), 'unknown', String(name));
    assert.deepEqual(describeGuardName(name), { kind: 'unknown', maker: null, text: GUARD_NAME_TEXT.unknown, hint: null });
  }
  assert.equal(GUARD_NAME_TEXT.unknown, 'Not one Camera Bridge recognizes.');
});

test('a time server gets the setup’s hint only where the setup works and has not taken its clock step', () => {
  const hint = 'Set up for Camera Bridge can point its clock at the bridge instead.';
  assert.equal(describeGuardName('pool.ntp.org', { canSetUp: true, camera: { vendor: 'hikvision' } }).hint, hint);
  assert.equal(describeGuardName('pool.ntp.org', { canSetUp: false, camera: { vendor: 'rtsp' } }).hint, null);
  const steps = (status) => ({ vendor: 'onvif', setupState: { steps: [{ id: 'timeSource', status: 'done' }, { id: 'timeSource', status }] } });
  for (const status of ['notRun', 'restored']) assert.equal(describeGuardName('pool.ntp.org', { canSetUp: true, camera: steps(status) }).hint, hint, status);
  for (const status of ['done', 'alreadyRight', 'notSupported', 'notOffered', 'refused']) {
    assert.equal(describeGuardName('pool.ntp.org', { canSetUp: true, camera: steps(status) }).hint, null, `the last record says ${status}`);
  }
  assert.equal(describeGuardName('cloud.example.net', { canSetUp: true, camera: { vendor: 'hikvision' } }).hint, null, 'only for a time server');
});
