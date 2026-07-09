(function (global) {
  'use strict';

  function formatNumber(value, digits) {
    return Number.isFinite(value) ? value.toFixed(digits) : '--';
  }

  function text(selector, value) {
    var el = document.querySelector(selector);
    if (el) el.textContent = value;
  }

  function createStatusLogger(selector) {
    return function log(message) {
      text(selector || '#status', message);
      console.info('[Tianditu3D]', message);
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
      if (statusEl) { statusEl.textContent = '已登录'; statusEl.className = 'auth-status logged-in'; }
      if (userInput) userInput.value = '';
      if (passInput) passInput.value = '';
    } else {
      if (loginBtn) loginBtn.style.display = '';
      if (logoutBtn) logoutBtn.style.display = 'none';
      if (statusEl) { statusEl.textContent = '未登录'; statusEl.className = 'auth-status anon'; }
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
          if (statusEl) { statusEl.textContent = '登录失败'; statusEl.className = 'auth-status error'; }
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

  global.HuaguoshanHud = {
    formatNumber: formatNumber,
    createStatusLogger: createStatusLogger,
    updateCameraReadout: updateCameraReadout,
    updateAuthUI: updateAuthUI,
    authenticate: authenticate,
    logout: logout,
    checkAuthStatus: checkAuthStatus,
    initAuth: initAuth
  };
})(window);
