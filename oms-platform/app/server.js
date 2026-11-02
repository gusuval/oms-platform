// Stub del OMS: SOLO sirve para validar la plataforma de punta a punta
// (build → firma → deploy → healthcheck). La aplicación real (seis bounded
// contexts) se implementa en bloques posteriores y sustituye a este fichero.
'use strict';

const http = require('node:http');

const port = Number(process.env.PORT || 8080);

function handler(req, res) {
  if (req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify({ status: 'ok', env: process.env.ENV || 'local' }));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/plain', 'cache-control': 'no-store' });
  res.end('AcmeOMS\n');
}

const server = http.createServer(handler);

if (require.main === module) {
  server.listen(port, () => console.log(`oms listening on :${port}`));
  process.on('SIGTERM', () => server.close(() => process.exit(0)));
}

module.exports = { handler };
