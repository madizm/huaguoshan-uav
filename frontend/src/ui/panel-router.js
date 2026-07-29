/*
 * Feature panel ownership router.
 *
 * Multiple features (CityDB inspector, flight obstacles, airspace tiles)
 * share the single detail panel. Without routing, whichever feature
 * renders last silently overwrites the previous content. The router
 * keeps a small owner stack: each render registers its owner, the header
 * shows the current source, and a back button returns to the previous
 * owner without losing its content.
 */
(function (global) {
  'use strict';

  function escapeHtml(value) {
    return String(value).replace(/[&<>"']/g, function (ch) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
    });
  }

  function createPanelRouter(options) {
    var target = options || {};
    var panel = document.querySelector(target.panelSelector || '.feature-panel');
    var content = document.querySelector(target.contentSelector || '#featureProperties');
    var ownerEl = document.querySelector(target.ownerSelector || '#featurePanelOwner');
    var backButton = document.querySelector(target.backSelector || '#featurePanelBack');
    var stack = [];

    function top() {
      return stack.length ? stack[stack.length - 1] : null;
    }

    function indexOf(ownerId) {
      for (var i = 0; i < stack.length; i += 1) {
        if (stack[i].ownerId === ownerId) return i;
      }
      return -1;
    }

    function updateChrome() {
      var current = top();
      if (ownerEl) {
        ownerEl.textContent = current ? current.label : '';
        ownerEl.style.display = current ? '' : 'none';
      }
      if (backButton) {
        backButton.style.display = stack.length > 1 ? '' : 'none';
      }
    }

    function renderCurrent() {
      var current = top();
      if (content && current) content.innerHTML = current.html;
      updateChrome();
    }

    function push(ownerId, label, html) {
      var existing = indexOf(ownerId);
      if (existing !== -1) stack.splice(existing, 1);
      stack.push({ ownerId: ownerId, label: label, html: html });
    }

    function showPanel() {
      if (panel) panel.hidden = false;
    }

    // Render feature-owned html and make the owner current.
    function show(ownerId, label, html) {
      push(ownerId, label, html);
      renderCurrent();
      showPanel();
    }

    // Adopt html that a feature already wrote into the content element
    // directly (legacy renderers) and make the owner current.
    function capture(ownerId, label) {
      push(ownerId, label, content ? content.innerHTML : '');
      updateChrome();
      showPanel();
    }

    // Refresh the stored html for an owner without changing the visible
    // entry unless it is current.
    function update(ownerId, html) {
      var idx = indexOf(ownerId);
      if (idx === -1) return;
      stack[idx].html = html;
      if (idx === stack.length - 1 && content) content.innerHTML = html;
    }

    function back() {
      if (stack.length <= 1) return;
      stack.pop();
      renderCurrent();
    }

    function close() {
      stack = [];
      updateChrome();
      if (panel) panel.hidden = true;
    }

    function current() {
      var entry = top();
      return entry ? entry.ownerId : null;
    }

    if (backButton) {
      backButton.addEventListener('click', function (event) {
        event.stopPropagation();
        back();
      });
    }

    return {
      show: show,
      capture: capture,
      update: update,
      back: back,
      close: close,
      current: current,
      depth: function () { return stack.length; },
      escapeHtml: escapeHtml
    };
  }

  global.HuaguoshanPanelRouter = { createPanelRouter: createPanelRouter };
})(window);
