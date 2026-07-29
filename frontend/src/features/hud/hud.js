(function (global) {
  'use strict';

  function formatNumber(value, digits) {
    return Number.isFinite(value) ? value.toFixed(digits) : '--';
  }

  function text(selector, value) {
    var el = document.querySelector(selector);
    if (el) el.textContent = value;
  }

  function setAuthStatusClass(statusEl, stateClass) {
    statusEl.classList.remove('anon', 'logged-in', 'error');
    statusEl.classList.add('auth-status', stateClass);
  }

  function createStatusLogger(selector) {
    return function log(message) {
      text(selector || '#status', message);
      console.info('[Tianditu3D]', message);
    };
  }

  function detectStatusLevel(message) {
    var textValue = String(message || '');
    if (/失败|错误|异常|无法|拒绝|过期/.test(textValue)) return 'error';
    if (/已|成功|完成|就绪/.test(textValue)) return 'success';
    return 'info';
  }

  function formatStatusTime(date) {
    var pad = function (value) { return String(value).padStart(2, '0'); };
    return pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
  }

  // 状态中心：当前消息 + 最近历史，避免多模块共用单行状态互相覆盖。
  // log(message[, level]) — level 为 'info' | 'success' | 'error'，缺省按文本推断。
  function createStatusCenter(options) {
    var target = options || {};
    var currentEl = document.querySelector(target.currentSelector || '#status');
    var historyEl = document.querySelector(target.historySelector || '#statusHistory');
    var maxItems = target.maxItems || 5;
    var entries = [];

    function render() {
      if (historyEl) {
        historyEl.innerHTML = entries.map(function (entry) {
          return '<li class="status-entry" data-level="' + entry.level + '">' +
            '<time>' + entry.time + '</time>' +
            '<span>' + escapeStatusHtml(entry.message) + '</span>' +
          '</li>';
        }).join('');
      }
    }

    function escapeStatusHtml(value) {
      return String(value).replace(/[&<>"']/g, function (ch) {
        return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch];
      });
    }

    function log(message, level) {
      var resolvedLevel = level || detectStatusLevel(message);
      if (currentEl) {
        currentEl.textContent = message;
        currentEl.setAttribute('data-level', resolvedLevel);
      }
      entries.unshift({ message: String(message), level: resolvedLevel, time: formatStatusTime(new Date()) });
      if (entries.length > maxItems) entries.length = maxItems;
      render();
      if (resolvedLevel === 'error') console.warn('[Tianditu3D]', message);
      else console.info('[Tianditu3D]', message);
    }

    return {
      log: log,
      entries: function () { return entries.slice(); },
      destroy: function () {
        entries = [];
        if (historyEl) historyEl.innerHTML = '';
        if (currentEl) currentEl.textContent = '';
      }
    };
  }

  function updateCameraReadout(CesiumRuntime, viewer, selectors) {
    var cartographic;
    var target = selectors || {};
    if (!viewer) return;
    cartographic = viewer.camera.positionCartographic;
    text(target.lon || '#lon', formatNumber(CesiumRuntime.Math.toDegrees(cartographic.longitude), 4));
    text(target.lat || '#lat', formatNumber(CesiumRuntime.Math.toDegrees(cartographic.latitude), 4));
    text(target.alt || '#alt', formatNumber(cartographic.height / 1000, 1) + 'km');
  }

  function updateAuthUI(authClient, selectors) {
    var target = selectors || {};
    var jwt = authClient.token();
    var loginBtn = document.querySelector(target.loginButton || '#authLoginBtn');
    var logoutBtn = document.querySelector(target.logoutButton || '#authLogoutBtn');
    var statusEl = document.querySelector(target.status || '#authStatus');
    var userInput = document.querySelector(target.username || '#authUsername');
    var passInput = document.querySelector(target.password || '#authPassword');

    if (jwt) {
      if (loginBtn) loginBtn.style.display = 'none';
      if (logoutBtn) logoutBtn.style.display = '';
      if (statusEl) { statusEl.textContent = '已登录'; setAuthStatusClass(statusEl, 'logged-in'); }
      if (userInput) { userInput.value = ''; userInput.style.display = 'none'; }
      if (passInput) { passInput.value = ''; passInput.style.display = 'none'; }
    } else {
      if (loginBtn) loginBtn.style.display = '';
      if (logoutBtn) logoutBtn.style.display = 'none';
      if (statusEl) { statusEl.textContent = '未登录'; setAuthStatusClass(statusEl, 'anon'); }
      if (userInput) userInput.style.display = '';
      if (passInput) passInput.style.display = '';
    }
  }

  function authenticate(authClient, log, selectors, username, password) {
    return authClient.login(username, password).then(function (payload) {
      updateAuthUI(authClient, selectors);
      log('认证成功 — 已登录为 ' + payload.user.username + ' (role=' + payload.user.role + ')');
      return payload;
    });
  }

  function logout(authClient, log, selectors) {
    authClient.logout();
    updateAuthUI(authClient, selectors);
    log('已登出');
  }

  function checkAuthStatus(authClient, log, selectors) {
    var jwt = authClient.token();
    if (!jwt) {
      updateAuthUI(authClient, selectors);
      return Promise.resolve(null);
    }
    return authClient.check().then(function (user) {
      updateAuthUI(authClient, selectors);
      if (!user && jwt) log('令牌已过期，请重新登录');
      return user;
    }).catch(function () {
      updateAuthUI(authClient, selectors);
      return null;
    });
  }

  function initAuth(options) {
    var authClient = options.authClient;
    var log = options.log;
    var selectors = options.selectors || {};
    var loginBtn = document.querySelector(selectors.loginButton || '#authLoginBtn');
    var logoutBtn = document.querySelector(selectors.logoutButton || '#authLogoutBtn');
    var usernameInput = document.querySelector(selectors.username || '#authUsername');
    var passwordInput = document.querySelector(selectors.password || '#authPassword');
    var statusSelector = selectors.status || '#authStatus';

    if (loginBtn) {
      loginBtn.addEventListener('click', function () {
        var username = usernameInput ? usernameInput.value.trim() : '';
        var password = passwordInput ? passwordInput.value : '';
        if (!username || !password) {
          log('请输入用户名和密码');
          return;
        }
        authenticate(authClient, log, selectors, username, password).catch(function (error) {
          var statusEl;
          log('登录失败：' + error.message);
          statusEl = document.querySelector(statusSelector);
          if (statusEl) { statusEl.textContent = '登录失败'; setAuthStatusClass(statusEl, 'error'); }
        });
      });
    }

    if (logoutBtn) {
      logoutBtn.addEventListener('click', function () {
        logout(authClient, log, selectors);
      });
    }

    if (passwordInput) {
      passwordInput.addEventListener('keydown', function (event) {
        if (event.key === 'Enter' && loginBtn) {
          loginBtn.click();
        }
      });
    }

    return checkAuthStatus(authClient, log, selectors);
  }

  function initHudSections(options) {
    var target = options || {};
    var storageKey = target.storageKey || 'hud.sections.open';
    var sections = Array.prototype.slice.call(document.querySelectorAll('details.hud-section[id]'));
    if (!sections.length) return;
    function readStored() {
      try {
        var raw = window.localStorage.getItem(storageKey);
        var parsed = raw ? JSON.parse(raw) : null;
        return Array.isArray(parsed) ? parsed : null;
      } catch (error) {
        return null;
      }
    }
    var stored = readStored();
    if (stored) {
      sections.forEach(function (section) {
        section.open = stored.indexOf(section.id) !== -1;
      });
    }
    function persist() {
      var openIds = sections.filter(function (section) { return section.open; }).map(function (section) { return section.id; });
      try {
        window.localStorage.setItem(storageKey, JSON.stringify(openIds));
      } catch (error) { /* 忽略隐私模式下的存储失败 */ }
    }
    sections.forEach(function (section) {
      section.addEventListener('toggle', persist);
    });
  }

  global.HuaguoshanHud = {
    formatNumber: formatNumber,
    createStatusLogger: createStatusLogger,
    updateCameraReadout: updateCameraReadout,
    updateAuthUI: updateAuthUI,
    authenticate: authenticate,
    logout: logout,
    checkAuthStatus: checkAuthStatus,
    initAuth: initAuth,
    initHudSections: initHudSections,
    createStatusCenter: createStatusCenter
  };
})(window);
