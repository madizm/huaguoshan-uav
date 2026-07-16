(function (global) {
  'use strict';

  function parseJsonText(text) {
    return text ? JSON.parse(text) : null;
  }

  function storageGet(storageKey) {
    return global.localStorage ? global.localStorage.getItem(storageKey) : null;
  }

  function storageSet(storageKey, value) {
    if (global.localStorage) global.localStorage.setItem(storageKey, value);
  }

  function storageRemove(storageKey) {
    if (global.localStorage) global.localStorage.removeItem(storageKey);
  }

  function authHeaders(storageKey) {
    var jwt = storageGet(storageKey);
    return jwt ? { 'Authorization': 'Bearer ' + jwt } : {};
  }

  function createPostgrestClient(options) {
    var baseUrl = (options && options.baseUrl) || '../postgrest';
    var storageKey = (options && options.storageKey) || 'postgrest.jwt';

    function request(path, requestOptions) {
      var opts = Object.assign({}, requestOptions || {});
      var errorLabel = opts.errorLabel || 'PostgREST request';
      var profile = opts.profile;
      var headers = Object.assign({ 'Accept': 'application/json' }, authHeaders(storageKey), opts.headers || {});
      delete opts.errorLabel;
      delete opts.profile;
      if (profile) {
        headers['Accept-Profile'] = profile;
        headers['Content-Profile'] = profile;
      }
      opts.headers = headers;
      return fetch(baseUrl + path, opts).then(function (response) {
        if (!response.ok) {
          return response.text().then(function (text) {
            throw new Error(errorLabel + ' HTTP ' + response.status + (text ? ': ' + text : ''));
          });
        }
        return response.text();
      }).then(parseJsonText);
    }

    function rpc(name, payload, requestOptions) {
      var opts = Object.assign({}, requestOptions || {}, {
        method: 'POST',
        headers: Object.assign({ 'Content-Type': 'application/json' }, (requestOptions && requestOptions.headers) || {}),
        body: JSON.stringify(payload || {}),
        errorLabel: (requestOptions && requestOptions.errorLabel) || ('PostgREST RPC ' + name)
      });
      return request('/rpc/' + name, opts);
    }

    return {
      request: request,
      rpc: rpc,
      authHeaders: function () { return authHeaders(storageKey); }
    };
  }

  function createAuthClient(options) {
    var loginUrl = (options && options.loginUrl) || '../auth/login';
    var meUrl = (options && options.meUrl) || '../auth/me';
    var storageKey = (options && options.storageKey) || 'postgrest.jwt';

    return {
      token: function () { return storageGet(storageKey); },
      login: function (username, password) {
        return fetch(loginUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ username: username, password: password })
        }).then(function (response) {
          if (!response.ok) {
            return response.json().then(function (body) {
              throw new Error(body.detail || '登录失败');
            });
          }
          return response.json();
        }).then(function (payload) {
          storageSet(storageKey, payload.access_token);
          return payload;
        });
      },
      logout: function () { storageRemove(storageKey); },
      check: function () {
        var jwt = storageGet(storageKey);
        if (!jwt) return Promise.resolve(null);
        return fetch(meUrl, {
          headers: { 'Authorization': 'Bearer ' + jwt }
        }).then(function (response) {
          if (!response.ok) {
            storageRemove(storageKey);
            return null;
          }
          return response.json().catch(function () { return {}; });
        });
      }
    };
  }

  global.HuaguoshanPostgrest = {
    createPostgrestClient: createPostgrestClient,
    createAuthClient: createAuthClient
  };
})(window);
