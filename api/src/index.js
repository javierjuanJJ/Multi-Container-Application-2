'use strict';

const app = require('./app');
const { connectToDatabase, mongoose } = require('./db');
const { PORT, NODE_ENV, SHUTDOWN_TIMEOUT_MS } = require('./config');

async function main() {
  await connectToDatabase();

  const server = app.listen(PORT, '0.0.0.0', () => {
    console.log(`todos-api listening on http://0.0.0.0:${PORT} (${NODE_ENV})`);
  });

  let shuttingDown = false;

  async function shutdown(signal) {
    if (shuttingDown) return;
    shuttingDown = true;
    console.log(`${signal} received, shutting down...`);

    const forceExit = setTimeout(() => {
      console.error('Graceful shutdown timed out, forcing exit');
      process.exit(1);
    }, SHUTDOWN_TIMEOUT_MS);
    forceExit.unref();

    server.close(async () => {
      await mongoose.connection.close().catch((err) => {
        console.error('Error closing MongoDB connection', err);
      });
      clearTimeout(forceExit);
      process.exit(0);
    });
  }

  for (const signal of ['SIGTERM', 'SIGINT']) {
    process.on(signal, () => shutdown(signal));
  }

  process.on('unhandledRejection', (reason) => {
    console.error('Unhandled promise rejection:', reason);
    shutdown('unhandledRejection');
  });
}

main().catch((err) => {
  // `err.cause` de Mongoose trae un volcado enorme de TopologyDescription:
  // para los logs del contenedor solo interesa la causa.
  console.error(`Fatal error starting the API: ${err.cause?.message || err.message}`);
  process.exit(1);
});