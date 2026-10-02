'use strict';

const express = require('express');
const mongoose = require('mongoose');

const todosRouter = require('./routes/todos.routes');
const { TRUST_PROXY } = require('./config');

const app = express();

app.disable('x-powered-by');
// Detras de nginx hay un unico proxy: hay que confiar en el para leer
// X-Forwarded-For y X-Forwarded-Proto. Fuera de produccion no se confia en nada.
app.set('trust proxy', TRUST_PROXY);
app.use(express.json({ limit: '16kb' }));

// Sonda usada por los healthchecks de Docker (compose y GitHub Actions).
app.get('/health', (req, res) => {
  const states = ['disconnected', 'connected', 'connecting', 'disconnecting'];
  const dbState = mongoose.connection.readyState;
  const healthy = mongoose.connection.readyState === 1;

  res.status(healthy ? 200 : 503).json({
    status: healthy ? 'ok' : 'degraded',
    uptime: Math.round(process.uptime()),
    database: {
      status: states[dbState] ?? 'unknown',
      name: mongoose.connection.name || null,
    },
  });
});

app.get('/', (req, res) => {
  res.status(200).json({
    name: 'todos-api',
    endpoints: {
      'GET /todos': 'get all todos',
      'POST /todos': 'create a todo { "task": "...", "completed": false }',
      'GET /todos/:id': 'get a todo by id',
      'PUT /todos/:id': 'update a todo by id',
      'DELETE /todos/:id': 'delete a todo by id',
      'GET /health': 'healthcheck',
    },
  });
});

app.use('/todos', todosRouter);

app.use((req, res) => {
  res.status(404).json({ error: `Route ${req.method} ${req.originalUrl} not found` });
});

// Express 5 propaga automaticamente los rechazos de handlers async a este middleware.
app.use((err, req, res, next) => {
  if (err instanceof SyntaxError && err.status === 400 && 'body' in err) {
    return res.status(400).json({ error: 'Invalid JSON body' });
  }

  console.error(err);
  return res.status(500).json({ error: 'Internal server error' });
});

module.exports = app;