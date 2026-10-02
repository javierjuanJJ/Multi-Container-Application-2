'use strict';

const mongoose = require('mongoose');

const todoSchema = new mongoose.Schema(
  {
    task: {
      type: String,
      required: [true, 'The "task" field is required'],
      trim: true,
      maxlength: [200, 'The "task" field must be at most 200 characters'],
    },
    completed: {
      type: Boolean,
      default: false,
    },
  },
  {
    timestamps: true,
    versionKey: false,
  }
);

module.exports = { todoSchema };