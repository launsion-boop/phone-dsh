// SPDX-License-Identifier: MIT

import { createServer } from 'node:http';
import { pathToFileURL } from 'node:url';

const prefix = '/v1/github/oauth';
const statePattern = /^[A-Za-z0-9_-]{43}$/;
const codePattern = /^[A-Za-z0-9_-]{1,512}$/;
const verifierPattern = /^[A-Za-z0-9._~-]{43,128}$/;
const tokenPattern = /^ghu_[A-Za-z0-9_]{1,251}$/;
const maxBody = 4096;

const problems = {
  400: 'invalid_request',
  401: 'authorization_failed',
  502: 'github_unavailable',
};

function matches(pattern, value) {
  return typeof value === 'string' && pattern.test(value);
}

function problem(response, status) {
  response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8' });
  response.end(JSON.stringify({ error: problems[status] }));
}

function getSingle(params, key) {
  const values = params.getAll(key);
  return values.length === 1 ? values[0] : null;
}

function callback(url, response) {
  const state = getSingle(url.searchParams, 'state');
  const codes = url.searchParams.getAll('code');
  const errors = url.searchParams.getAll('error');
  const code = getSingle(url.searchParams, 'code');
  const denied = codes.length === 0 && errors.length === 1
    && matches(codePattern, errors[0]);
  const approved = errors.length === 0 && matches(codePattern, code);
  if (!matches(statePattern, state) || (!approved && !denied)) return problem(response, 400);

  const destination = new URL('phonedsh-github://oauth/callback');
  destination.searchParams.set('state', state);
  if (approved) {
    destination.searchParams.set('code', code);
  } else {
    destination.searchParams.set('error', 'access_denied');
  }
  response.writeHead(302, { Location: destination.href });
  response.end();
}

async function readObject(request, keys) {
  const media = request.headers['content-type']?.split(';', 1)[0].trim().toLowerCase();
  if (media !== 'application/json' || Number(request.headers['content-length']) > maxBody) {
    request.resume();
    return null;
  }

  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of request.iterator({ destroyOnReturn: false })) {
      size += chunk.length;
      if (size > maxBody) {
        request.resume();
        return null;
      }
      chunks.push(chunk);
    }
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (value === null || typeof value !== 'object' || Array.isArray(value)
      || Object.keys(value).length !== keys.length
      || !keys.every((key) => Object.hasOwn(value, key))) return null;
    return value;
  } catch {
    return null;
  }
}

export function createGitHubOAuthServer({ origin, clientID, clientSecret, fetchUpstream = fetch }) {
  const base = new URL(origin);
  if (base.protocol !== 'https:' || base.username || base.password
    || base.pathname !== '/' || base.search || base.hash
    || !matches(/^[A-Za-z0-9._-]{1,128}$/, clientID)
    || !matches(/^[A-Za-z0-9_]{1,256}$/, clientSecret)) {
    throw new Error('Configure an HTTPS broker origin and the GitHub App credentials.');
  }
  const redirectURI = new URL(prefix + '/callback', base).href;
  const basicAuth = 'Basic ' + Buffer.from(clientID + ':' + clientSecret).toString('base64');

  function upstream(url, options) {
    return fetchUpstream(url, {
      ...options,
      redirect: 'error',
      signal: AbortSignal.timeout(10_000),
    });
  }

  async function exchange(request, response) {
    const body = await readObject(request, ['code', 'code_verifier']);
    if (!body || !matches(codePattern, body.code)
      || !matches(verifierPattern, body.code_verifier)) return problem(response, 400);

    const result = await upstream('https://github.com/login/oauth/access_token', {
      method: 'POST',
      headers: { Accept: 'application/json' },
      body: new URLSearchParams({
        client_id: clientID,
        client_secret: clientSecret,
        redirect_uri: redirectURI,
        code: body.code,
        code_verifier: body.code_verifier,
      }),
    });
    if (result.status === 401) return problem(response, 401);
    if (!result.ok) return problem(response, 502);
    const grant = await result.json();
    if (grant?.error === 'bad_verification_code' || grant?.error === 'access_denied') {
      return problem(response, 401);
    }
    if (!matches(tokenPattern, grant?.access_token)
      || !Number.isSafeInteger(grant.expires_in) || grant.expires_in <= 0
      || grant.token_type?.toLowerCase() !== 'bearer') return problem(response, 502);

    response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    response.end(JSON.stringify({ access_token: grant.access_token, expires_in: grant.expires_in }));
  }

  async function revoke(request, response) {
    const body = await readObject(request, ['access_token']);
    if (!body || !matches(tokenPattern, body.access_token)) return problem(response, 400);
    const result = await upstream('https://api.github.com/applications/' + clientID + '/token', {
      method: 'DELETE',
      headers: {
        Accept: 'application/vnd.github+json',
        Authorization: basicAuth,
        'Content-Type': 'application/json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
      body: JSON.stringify({ access_token: body.access_token }),
    });
    if (result.status !== 204 && result.status !== 404) return problem(response, 502);
    response.writeHead(204);
    response.end();
  }

  return createServer({ requestTimeout: 15_000, headersTimeout: 8_000 }, async (request, response) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    try {
      if (!request.url?.startsWith('/') || request.url.startsWith('//')) return problem(response, 400);
      const url = new URL(request.url, base);
      if (request.method === 'GET' && url.pathname === prefix + '/callback') return callback(url, response);
      if (request.method === 'POST' && url.search === '') {
        if (url.pathname === prefix + '/exchange') return await exchange(request, response);
        if (url.pathname === prefix + '/revoke') return await revoke(request, response);
      }
      response.writeHead(404);
      response.end();
    } catch {
      problem(response, 502);
    }
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { GITHUB_OAUTH_ORIGIN, GITHUB_CLIENT_ID, GITHUB_CLIENT_SECRET, PORT = '8080' } = process.env;
  try {
    const server = createGitHubOAuthServer({
      origin: GITHUB_OAUTH_ORIGIN,
      clientID: GITHUB_CLIENT_ID,
      clientSecret: GITHUB_CLIENT_SECRET,
    });
    server.listen(Number(PORT));
  } catch {
    process.stderr.write('Invalid GitHub OAuth broker configuration.\n');
    process.exitCode = 1;
  }
}
