const assert = require('assert');

// Minimal DOM stub for the panel router: querySelector returns stub
// elements keyed by selector, innerHTML is stored verbatim.
function makeElement() {
  return {
    innerHTML: '',
    textContent: '',
    hidden: false,
    style: { display: '' },
    listeners: {},
    addEventListener(type, fn) { this.listeners[type] = fn; },
    click() { if (this.listeners.click) this.listeners.click({ stopPropagation() {} }); }
  };
}

const elements = {
  '.feature-panel': makeElement(),
  '#featureProperties': makeElement(),
  '#featurePanelOwner': makeElement(),
  '#featurePanelBack': makeElement()
};

globalThis.document = {
  querySelector(selector) { return elements[selector] || null; }
};
globalThis.window = globalThis;

require('../frontend/src/ui/panel-router.js');

const router = globalThis.HuaguoshanPanelRouter.createPanelRouter({});
const panel = elements['.feature-panel'];
const content = elements['#featureProperties'];
const owner = elements['#featurePanelOwner'];
const back = elements['#featurePanelBack'];

// First producer renders.
router.show('flight-obstacles', '飞行障碍', '<div>obstacles</div>');
assert.strictEqual(content.innerHTML, '<div>obstacles</div>');
assert.strictEqual(owner.textContent, '飞行障碍');
assert.strictEqual(back.style.display, 'none');
assert.strictEqual(panel.hidden, false);

// Second producer overwrites the view; first owner's content is kept.
router.show('citydb', '建筑属性', '<div>building</div>');
assert.strictEqual(content.innerHTML, '<div>building</div>');
assert.strictEqual(owner.textContent, '建筑属性');
assert.strictEqual(back.style.display, '');
assert.strictEqual(router.depth(), 2);

// Back returns to the previous owner with its content intact.
back.click();
assert.strictEqual(content.innerHTML, '<div>obstacles</div>');
assert.strictEqual(owner.textContent, '飞行障碍');
assert.strictEqual(back.style.display, 'none');

// Same-owner render replaces the entry instead of stacking.
router.show('flight-obstacles', '飞行障碍', '<div>obstacles-2</div>');
assert.strictEqual(router.depth(), 1);
assert.strictEqual(content.innerHTML, '<div>obstacles-2</div>');

// capture() adopts html that a legacy renderer wrote directly.
content.innerHTML = '<div>legacy</div>';
router.capture('citydb', '建筑属性');
assert.strictEqual(router.current(), 'citydb');
back.click();
assert.strictEqual(content.innerHTML, '<div>obstacles-2</div>');

// update() refreshes a background owner without stealing the view.
content.innerHTML = '<div>legacy-2</div>';
router.capture('citydb', '建筑属性');
router.update('flight-obstacles', '<div>obstacles-3</div>');
assert.strictEqual(content.innerHTML, '<div>legacy-2</div>');
back.click();
assert.strictEqual(content.innerHTML, '<div>obstacles-3</div>');

// close() clears the stack and hides the panel.
router.close();
assert.strictEqual(router.depth(), 0);
assert.strictEqual(panel.hidden, true);
assert.strictEqual(owner.textContent, '');

console.log('panel router tests passed');
