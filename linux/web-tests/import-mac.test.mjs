// screens/import-mac.js: which passwords are sent, and the one line about how an import went.
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { importSummary, passwordsFor } from '../web/js/screens/import-mac.js';

describe('importing from the Mac app', () => {
  const cameras = [{ id: 'a' }, { id: 'b' }, { id: 'c', alreadySetUp: true }];

  it('sends one password for every new camera, or each camera its own, never empty ones', () => {
    assert.deepEqual(passwordsFor(cameras, { shared: 'same', each: {} }), { a: 'same', b: 'same' });
    assert.deepEqual(passwordsFor(cameras, { shared: null, each: { a: 'one', b: '', c: 'x' } }), { a: 'one' });
    assert.deepEqual(passwordsFor(cameras, { shared: '', each: {} }), {});
  });

  it('says what happened in one line', () => {
    assert.equal(importSummary({ added: ['A', 'B'], addedOff: ['C'], alreadySetUp: [], failed: [] }), '2 cameras added; C added turned off (no password).');
    assert.equal(importSummary({ added: [], addedOff: [], alreadySetUp: ['A'], failed: [{ name: 'B', message: 'Port in use' }] }), 'A already here; not added: B (Port in use).');
    assert.equal(importSummary({ added: [], addedOff: [], alreadySetUp: [], failed: [] }), 'Nothing to import.');
  });
});
