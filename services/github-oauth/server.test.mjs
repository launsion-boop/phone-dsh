// SPDX-License-Identifier: MIT

import assert from 'node:assert/strict';
import { once } from 'node:events';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { createGitHubOAuthServer } from './server.mjs';

const fixture = JSON.parse(await readFile(new URL(
  '../../spec/v1/golden/github-oauth/github-oauth-cases.json', import.meta.url
), 'utf8'));
const origin = 'https://auth.example.com';
const prefix = '/v1/github/oauth';

async function serve(t, fetchUpstream = () => assert.fail('Unexpected upstream request')) {
  const server = createGitHubOAuthServer({
    origin, clientID: 'Iv1.fixture', clientSecret: 'fixture_secret', fetchUpstream,
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return 'http://127.0.0.1:' + server.address().port + prefix;
}

function post(base, route, body) {
  return fetch(base + route, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
}

test('callback forwards the code and state to the fixed app destination', async (t) => {
  const base = await serve(t);
  const query = new URLSearchParams({
    state: fixture.state, code: fixture.code, redirect_uri: 'https://example.org',
  });
  const result = await fetch(base + '/callback?' + query, { redirect: 'manual' });
  assert.equal(result.status, 302);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.equal(result.headers.get('referrer-policy'), 'no-referrer');
  const destination = new URL(result.headers.get('location'));
  assert.equal(destination.href, 'phonedsh-github://oauth/callback?state=' + fixture.state + '&code=' + fixture.code);
});

test('callback rejects duplicate state and mixed success and cancellation', async (t) => {
  const base = await serve(t);
  for (const tail of ['&state=' + fixture.wrong_state, '&error=access_denied']) {
    const result = await fetch(base + '/callback?state=' + fixture.state + '&code=' + fixture.code + tail);
    assert.equal(result.status, 400);
    assert.deepEqual(await result.json(), { error: 'invalid_request' });
  }
  const denied = await fetch(base + '/callback?state=' + fixture.state
    + '&error=access_denied&error_description=do-not-reflect', { redirect: 'manual' });
  assert.equal(denied.headers.get('location'),
    'phonedsh-github://oauth/callback?state=' + fixture.state + '&error=access_denied');
});

test('exchange uses the verifier and configured callback and returns only an expiring token', async (t) => {
  const base = await serve(t, (url, options) => {
    assert.equal(url, 'https://github.com/login/oauth/access_token');
    assert.equal(options.method, 'POST');
    assert.equal(options.redirect, 'error');
    assert.equal(options.body.get('code'), fixture.code);
    assert.equal(options.body.get('code_verifier'), fixture.code_verifier);
    assert.equal(options.body.get('client_id'), 'Iv1.fixture');
    assert.equal(options.body.get('client_secret'), 'fixture_secret');
    assert.equal(options.body.get('redirect_uri'), origin + prefix + '/callback');
    return Response.json({
      token_type: 'bearer', access_token: fixture.access_token, expires_in: fixture.expires_in,
      refresh_token: 'not-forwarded',
    });
  });
  const result = await post(base, '/exchange', { code: fixture.code, code_verifier: fixture.code_verifier });
  assert.equal(result.status, 200);
  assert.equal(result.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await result.json(), { access_token: fixture.access_token, expires_in: fixture.expires_in });
});

test('exchange rejects invalid verifier, unknown fields, and oversize bodies before calling GitHub', async (t) => {
  const base = await serve(t);
  for (const body of [
    { code: fixture.code, code_verifier: fixture.invalid_verifier },
    { code: fixture.code, code_verifier: fixture.code_verifier, redirect_uri: origin },
    { code: 'A'.repeat(4096), code_verifier: fixture.code_verifier },
  ]) {
    const result = await post(base, '/exchange', body);
    assert.equal(result.status, 400);
    assert.deepEqual(await result.json(), { error: 'invalid_request' });
  }
});

test('exchange does not forward provider errors or an unexpected token', async (t) => {
  let next = { error: 'bad_verification_code', error_description: 'provider-detail' };
  const base = await serve(t, () => Response.json(next));
  const body = { code: fixture.code, code_verifier: fixture.code_verifier };
  const rejected = await post(base, '/exchange', body);
  assert.equal(rejected.status, 401);
  assert.deepEqual(await rejected.json(), { error: 'authorization_failed' });
  next = { token_type: 'bearer', access_token: fixture.invalid_token, expires_in: 28800 };
  const invalid = await post(base, '/exchange', body);
  assert.equal(invalid.status, 502);
  assert.deepEqual(await invalid.json(), { error: 'github_unavailable' });
});

test('revoke rejects a PAT and deletes only the supplied GitHub App token', async (t) => {
  let calls = 0;
  const base = await serve(t, (url, options) => {
    calls += 1;
    assert.equal(url, 'https://api.github.com/applications/Iv1.fixture/token');
    assert.equal(options.method, 'DELETE');
    assert.equal(options.redirect, 'error');
    assert.equal(options.headers.Authorization, 'Basic ' + Buffer.from('Iv1.fixture:fixture_secret').toString('base64'));
    assert.deepEqual(JSON.parse(options.body), { access_token: fixture.access_token });
    return new Response(null, { status: calls === 1 ? 204 : 404 });
  });
  const rejected = await post(base, '/revoke', { access_token: fixture.invalid_token });
  assert.equal(rejected.status, 400);
  assert.equal(calls, 0);
  for (let i = 0; i < 2; i++) {
    const result = await post(base, '/revoke', { access_token: fixture.access_token });
    assert.equal(result.status, 204);
  }
});
