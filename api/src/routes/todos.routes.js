'use strict';

const express = require('express');
const mongoose = require('mongoose');

const { Todo } = require('../db');
const { NODE_ENV } = require('../config');

const router = express.Router();

// El id se valida antes de tocar la base de datos para responder 400 en lugar de 500.
function validateObjectId(req, res, next) {
  if (!mongoose.isObjectIdOrHexString(req.params.id)) {
    return res.status(400).json({
      error: 'Invalid todo id',
      details: `"${req.params.id}" is not a valid MongoDB ObjectId`,
    });
  }
  return next();
}

// Devuelve 400 con el detalle de los campos que fallan la validacion del schema.
function validationError(res, err) {
  const details = Object.fromEntries(
    Object.entries(err.errors || {}).map(([field, fieldErr]) => [
      field,
      fieldErr.message,
    ])
  );

  return res.status(400).json({ error: 'Validation error', details });
}

// GET /todos
router.get('/', async (req, res) => {
  const todos = await Todo.find().sort({ createdAt: -1 });
  res.status(200).json(todos);
});

// POST /todos
router.post('/', async (req, res) => {
  try {
    const todo = await Todo.create({
      task: req.body?.task,
      completed: req.body?.completed ?? false,
    });

    res.status(201).json(todo);
  } catch (err) {
    if (err instanceof mongoose.Error.ValidationError) {
      return validationError(res, err);
    }
    throw err;
  }
});

// GET /todos/:id
router.get('/:id', validateObjectId, async (req, res) => {
  const todo = await Todo.findById(req.params.id);

  if (!todo) {
    return res.status(404).json({ error: `Todo ${req.params.id} not found` });
  }

  return res.status(200).json(todo);
});

// PUT /todos/:id
router.put('/:id', validateObjectId, async (req, res) => {
  try {
    const todo = await Todo.findByIdAndUpdate(
      req.params.id,
      {
        $set: {
          ...(req.body?.task !== undefined ? { task: req.body.task } : {}),
          ...(req.body?.completed !== undefined
            ? { completed: req.body.completed }
            : {}),
        },
      },
      { new: true, runValidators: true }
    );

    if (!todo) {
      return res
        .status(404)
        .json({ error: `Todo ${req.params.id} not found` });
    }

    return res.status(200).json(todo);
  } catch (err) {
    if (err instanceof mongoose.Error.ValidationError) {
      return validationError(res, err);
    }
    throw err;
  }
});

// DELETE /todos/:id
router.delete('/:id', validateObjectId, async (req, res) => {
  const todo = await Todo.findByIdAndDelete(req.params.id);

  if (!todo) {
    return res
      .status(404)
      .json({ error: `Todo ${req.params.id} not found` });
  }

  return res.status(200).json(todo);
});

router.use((req, res) => {
  res.status(404).json({ error: `Route ${req.method} ${req.originalUrl} not found` });
});

router.use((err, req, res, next) => {
  if (NODE_ENV !== 'production') {
    console.error(err);
  }
  res.status(500).json({ error: 'Internal server error' });
});

module.exports = router;