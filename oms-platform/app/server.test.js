'use strict';

const test = require('node:test');
const assert = require('node:assert');
const http = require('node:http');
const { handler } = require('./server');

test('/healthz responde 200 con status ok', async () => {
  const server = http.createServer(handler).listen(0);
  const { port } = server.address();
  const res = await fetch(`http://127.0.0.1:${port}/healthz`);
  assert.strictEqual(res.status, 200);
  assert.deepStrictEqual((await res.json()).status, 'ok');
  server.close();
});
