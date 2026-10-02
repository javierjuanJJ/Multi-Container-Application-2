'use strict';

const PORT = Number(process.env.PORT) || 3000;
const MONGO_URI =
  process.env.MONGO_URI || 'mongodb://localhost:27017/todos';
const NODE_ENV = process.env.NODE_ENV || 'development';
const SHUTDOWN_TIMEOUT_MS = Number(process.env.SHUTDOWN_TIMEOUT_MS) || 10000;

// Detras del reverse proxy de nginx hay exactamente un proxy delante. `1` hace que
// Express lea X-Forwarded-For para resolver req.ip y req.protocol.
// `false` (por defecto) no se fia de cabeceras que puede enviar el cliente.
const TRUST_PROXY = process.env.TRUST_PROXY === 'true';

module.exports = {
  PORT,
  MONGO_URI,
  NODE_ENV,
  SHUTDOWN_TIMEOUT_MS,
  TRUST_PROXY,
};