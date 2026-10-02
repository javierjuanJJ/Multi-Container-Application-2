'use strict';

const mongoose = require('mongoose');

const { MONGO_URI } = require('./config');
const { todoSchema } = require('./models/todo.model');

const Todo = mongoose.model('Todo', todoSchema);

async function connectToDatabase(uri = MONGO_URI) {
  mongoose.set('strictQuery', true);

  await mongoose.connect(uri, {
    serverSelectionTimeoutMS: 10000,
  });

  const { host, name } = mongoose.connection;
  console.log(`MongoDB conectado -> ${host}/${name}`);

  return mongoose.connection;
}

module.exports = { connectToDatabase, mongoose, Todo };