/*
 * Lightweight typed event bus for cross-feature communication.
 *
 * Features emit domain events (auth:changed, layer:visibility-changed,
 * status:log, ...) instead of holding references to each other; the app
 * assembly owns the bus instance. Handlers are plain functions; on()
 * returns an unsubscribe function so modules can implement destroy().
 */
(function (global) {
  'use strict';

  function createEventBus() {
    var handlers = Object.create(null);

    function on(type, handler) {
      if (typeof handler !== 'function') throw new TypeError('handler must be a function');
      (handlers[type] || (handlers[type] = [])).push(handler);
      return function unsubscribe() {
        off(type, handler);
      };
    }

    function off(type, handler) {
      var list = handlers[type];
      if (!list) return;
      var index = list.indexOf(handler);
      if (index !== -1) list.splice(index, 1);
      if (!list.length) delete handlers[type];
    }

    function emit(type, payload) {
      var list = handlers[type];
      if (!list) return;
      // Copy so handlers can unsubscribe during emit.
      list.slice().forEach(function (handler) {
        try {
          handler(payload);
        } catch (error) {
          console.error('[AppEvents] handler failed for ' + type + ':', error);
        }
      });
    }

    function clear() {
      handlers = Object.create(null);
    }

    return { on: on, off: off, emit: emit, clear: clear };
  }

  global.HuaguoshanAppEvents = { createEventBus: createEventBus };
})(window);
