const assert = require('assert');

globalThis.window = globalThis;
require('../frontend/src/app/app-events.js');

const bus = globalThis.HuaguoshanAppEvents.createEventBus();

const seen = [];
const offA = bus.on('auth:changed', (event) => seen.push(['a', event.loggedIn]));
bus.on('auth:changed', (event) => seen.push(['b', event.loggedIn]));

bus.emit('auth:changed', { loggedIn: true });
assert.deepStrictEqual(seen, [['a', true], ['b', true]]);

// Unsubscribe via returned function.
offA();
bus.emit('auth:changed', { loggedIn: false });
assert.deepStrictEqual(seen, [['a', true], ['b', true], ['b', false]]);

// Emit without listeners is a no-op.
bus.emit('layer:visibility-changed', { layer: 'image', visible: false });

// A throwing handler does not break other handlers or emit().
bus.on('boom', () => { throw new Error('handler failed'); });
const afterBoom = [];
bus.on('boom', () => afterBoom.push(1));
bus.emit('boom');
assert.deepStrictEqual(afterBoom, [1]);

// clear() removes everything.
bus.clear();
bus.emit('auth:changed', { loggedIn: true });
assert.deepStrictEqual(seen, [['a', true], ['b', true], ['b', false]]);

// on() rejects non-functions.
assert.throws(() => bus.on('x', null), TypeError);

console.log('app events tests passed');
