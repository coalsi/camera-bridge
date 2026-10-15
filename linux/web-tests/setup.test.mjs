// setup.js: the words for a signal and which network the setup page shows first.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { preferred, signalWords } from '../web/js/setup.js';

describe('the setup page', () => {
  it('says how strong a network is in words', () => {
    assert.equal(signalWords(90), 'strong');
    assert.equal(signalWords(50), 'good');
    assert.equal(signalWords(30), 'weak');
    assert.equal(signalWords(5), 'very weak');
  });

  it('shows first a network the box knows, else the strongest, else nothing', () => {
    const networks = [{ ssid: 'Neighbour', signal: 90 }, { ssid: 'Home', signal: 60 }];
    assert.equal(preferred(networks, ['Home']), 'Home');
    assert.equal(preferred(networks, []), 'Neighbour');
    assert.equal(preferred([], []), '');
  });
});
