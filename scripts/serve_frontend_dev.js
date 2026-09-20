#!/usr/bin/env node
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');

const projectRoot = path.resolve(__dirname, '..');
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || 18080);
const serviceOrigin = new URL(process.env.DEV_SERVICE_ORIGIN || 'http://10.1.109.151:20000');
const proxyPrefixes = ['/auth/', '/postgrest/'];
const mimeTypes = {
  '.b3dm': 'application/octet-stream',
  '.bin': 'application/octet-stream',
  '.css': 'text/css; charset=utf-8',
  '.glb': 'model/gltf-binary',
  '.gltf': 'model/gltf+json',
  '.html': 'text/html; charset=utf-8',
  '.ico': 'image/x-icon',
  '.jpeg': 'image/jpeg',
  '.jpg': 'image/jpeg',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.svg': 'image/svg+xml',
  '.terrain': 'application/vnd.quantized-mesh',
  '.webp': 'image/webp',
};

function proxyRequest(request, response) {
  const target = new URL(request.url, serviceOrigin);
  const headers = Object.assign({}, request.headers, { host: serviceOrigin.host });
  const upstream = http.request(target, { method: request.method, headers }, (upstreamResponse) => {
    response.writeHead(upstreamResponse.statusCode || 502, upstreamResponse.headers);
    upstreamResponse.pipe(response);
  });
  upstream.on('error', (error) => {
    response.writeHead(502, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ error: 'development service unavailable', detail: error.message }));
  });
  request.pipe(upstream);
}

function staticRequest(request, response) {
  let pathname;
  try {
    pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
  } catch (_error) {
    response.writeHead(400).end('Bad request');
    return;
  }
  if (pathname === '/') pathname = '/frontend/tianditu-3d.html';
  const filePath = path.resolve(projectRoot, '.' + pathname);
  if (filePath !== projectRoot && !filePath.startsWith(projectRoot + path.sep)) {
    response.writeHead(403).end('Forbidden');
    return;
  }
  fs.stat(filePath, (error, stat) => {
    if (error || !stat.isFile()) {
      response.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not found');
      return;
    }
    response.writeHead(200, {
      'Cache-Control': 'no-store',
      'Content-Length': stat.size,
      'Content-Type': mimeTypes[path.extname(filePath).toLowerCase()] || 'application/octet-stream',
    });
    if (request.method === 'HEAD') response.end();
    else fs.createReadStream(filePath).pipe(response);
  });
}

const server = http.createServer((request, response) => {
  if (proxyPrefixes.some((prefix) => request.url.startsWith(prefix))) proxyRequest(request, response);
  else staticRequest(request, response);
});

server.listen(port, host, () => {
  console.log(`Frontend: http://${host}:${port}/frontend/tianditu-3d.html`);
  console.log(`Proxy: ${serviceOrigin.origin} (/auth/, /postgrest/)`);
});
