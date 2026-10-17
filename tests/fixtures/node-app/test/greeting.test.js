import assert from 'node:assert/strict';
import net from 'node:net';
import { test } from 'node:test';
import { greeting } from '../src/greeting.js';

test('greets by name', () => {
  assert.equal(greeting('CI'), 'Hello, CI!');
});

test('build-env and build-secrets are exported', () => {
  assert.equal(process.env.GREETING, 'hello from build-env');
  assert.ok(process.env.SELF_TEST_SECRET, 'SELF_TEST_SECRET should be set');
});

test('the PostgreSQL service accepts connections', async () => {
  assert.ok(process.env.DATABASE_URL, 'DATABASE_URL should point at the service');
  assert.equal(process.env.TEST_DATABASE_URL, process.env.DATABASE_URL);
  const { hostname, port } = new URL(process.env.DATABASE_URL);
  await new Promise((resolve, reject) => {
    const socket = net.connect(Number(port), hostname, () => {
      socket.end();
      resolve();
    });
    socket.on('error', reject);
  });
});
