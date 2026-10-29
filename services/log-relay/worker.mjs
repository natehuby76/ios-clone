const BASE = 'https://starpilot-log-relay.nathan-g-hubbard.workers.dev';
const CALLBACK = BASE + '/auth/discord/callback';
const APP_CALLBACK = 'starpilot-discord://callback';
const API = 'https://discord.com/api/v10';
const MAX = 1024 * 1024;
const json = (data, status = 200) => Response.json(data, {status, headers: {'Cache-Control': 'no-store'}});
class InputError extends Error {}
const validNonce = value => typeof value === 'string' && /^[A-Za-z0-9_-]{43,128}$/.test(value);
export async function readJSON(request) {
  if (!request.headers.get('content-type')?.startsWith('application/json')) throw new InputError('Expected JSON');
  const reader = request.body?.getReader();
  if (!reader) throw new InputError('Missing body');
  const chunks = []; let length = 0;
  while (true) {
    const {done, value} = await reader.read(); if (done) break;
    length += value.length;
    if (length > MAX) { await reader.cancel(); throw new InputError('Report is too large'); }
    chunks.push(value);
  }
  const bytes = new Uint8Array(length); let offset = 0;
  for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
  let value;
  try { value = JSON.parse(new TextDecoder().decode(bytes)); } catch { throw new InputError('Invalid JSON'); }
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new InputError('Expected an object');
  return value;
}
async function discord(path, options = {}) {
  return fetch(API + path, {...options, redirect: 'manual', signal: AbortSignal.timeout(15000)});
}
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === 'GET' && url.pathname === '/') return json({service: 'StarPilot log relay', version: 7});
      if (request.method === 'GET' && url.pathname === '/auth/discord/start') {
        const state = url.searchParams.get('state'), challenge = url.searchParams.get('code_challenge');
        if (!validNonce(state) || !validNonce(challenge)) return json({error: 'Invalid sign-in request'}, 400);
        if (!env.DISCORD_CLIENT_ID || !env.DISCORD_CLIENT_SECRET) return json({error: 'Discord sign-in is not configured yet'}, 503);
        const target = new URL('https://discord.com/oauth2/authorize');
        target.search = new URLSearchParams({client_id: env.DISCORD_CLIENT_ID, redirect_uri: CALLBACK,
          response_type: 'code', scope: 'identify', state, code_challenge: challenge, code_challenge_method: 'S256'}).toString();
        return new Response(null, {status: 302, headers: {Location: target.href, 'Cache-Control': 'no-store'}});
      }
      if (request.method === 'GET' && url.pathname === '/auth/discord/callback') {
        const state = url.searchParams.get('state');
        if (!validNonce(state) || url.searchParams.get('iss') !== 'https://discord.com') return json({error: 'Invalid sign-in callback'}, 400);
        const target = new URL(APP_CALLBACK);
        for (const key of ['code', 'state', 'error', 'iss']) if (url.searchParams.has(key)) target.searchParams.set(key, url.searchParams.get(key));
        return new Response(null, {status: 302, headers: {Location: target.href, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer'}});
      }
      if (request.method === 'POST' && ['/auth/discord/exchange', '/auth/discord/refresh', '/auth/discord/revoke'].includes(url.pathname)) {
        if (!env.DISCORD_CLIENT_ID || !env.DISCORD_CLIENT_SECRET) return json({error: 'Discord sign-in is not configured yet'}, 503);
        const body = await readJSON(request);
        const params = new URLSearchParams({client_id: env.DISCORD_CLIENT_ID, client_secret: env.DISCORD_CLIENT_SECRET});
        let path = '/oauth2/token';
        if (url.pathname.endsWith('/exchange')) {
          if (!validNonce(body.verifier) || typeof body.code !== 'string' || body.code.length > 2048) return json({error: 'Invalid sign-in request'}, 400);
          Object.entries({grant_type: 'authorization_code', code: body.code, code_verifier: body.verifier, redirect_uri: CALLBACK}).forEach(([k,v]) => params.set(k,v));
        } else if (url.pathname.endsWith('/refresh')) {
          if (typeof body.refresh_token !== 'string' || body.refresh_token.length > 2048) return json({error: 'Invalid refresh request'}, 400);
          params.set('grant_type', 'refresh_token'); params.set('refresh_token', body.refresh_token);
        } else {
          if (typeof body.token !== 'string' || body.token.length > 2048) return json({error: 'Invalid token'}, 400);
          path += '/revoke'; params.set('token', body.token);
        }
        const result = await discord(path, {method: 'POST', body: params});
        if (!result.ok) return json({error: 'Discord sign-in expired or was declined. Connect again.'}, 401);
        if (path.endsWith('/revoke')) return json({disconnected: true});
        const token = await result.json();
        const identity = await discord('/oauth2/@me', {headers: {Authorization: 'Bearer ' + token.access_token}});
        if (!identity.ok) return json({error: 'Could not verify Discord sign-in. Connect again.'}, 401);
        const auth = await identity.json();
        if (auth.application?.id !== env.DISCORD_CLIENT_ID || !auth.scopes?.includes('identify') || !/^\d+$/.test(auth.user?.id || '')) return json({error: 'Invalid Discord authorization'}, 403);
        return json({access_token: token.access_token, refresh_token: token.refresh_token, expires_in: token.expires_in, user_id: auth.user.id});
      }
      if (request.method === 'POST' && url.pathname === '/v1/logs') {
        const token = request.headers.get('Authorization');
        if (!token?.startsWith('Bearer ') || token.length > 2100) return json({error: 'Connect with Discord first'}, 401);
        const identity = await discord('/oauth2/@me', {headers: {Authorization: token}});
        if (!identity.ok) return json({error: 'Please reconnect Discord'}, 401);
        const auth = await identity.json();
        if (auth.application?.id !== env.DISCORD_CLIENT_ID || !auth.scopes?.includes('identify') || !/^\d+$/.test(auth.user?.id || '')) return json({error: 'Invalid Discord authorization'}, 403);
        const body = await readJSON(request);
        if (!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(body.reference || '') || typeof body.description !== 'string' || !body.description.trim() || body.description.length > 1000 || typeof body.logs !== 'string' || !body.logs.trim()) return json({error: 'Add a short description and diagnostics'}, 400);
        const id = env.REPORTS.idFromName(auth.user.id);
        return env.REPORTS.get(id).fetch('https://reports/submit', {method: 'POST', body: JSON.stringify({...body, user: auth.user})});
      }
      return json({error: 'Not found'}, 404);
    } catch (error) {
      if (error instanceof InputError) return json({error: error.message}, 400);
      return json({error: 'Could not complete the request. Your report has not been confirmed.'}, 503);
    }
  }
};

// One object per verified Discord user serializes submissions across retries/devices.
export class Reports {
  constructor(ctx, env) { this.ctx = ctx; this.env = env; }
  async fetch(request) {
    {
      const body = await request.json();
      const key = 'report:' + body.reference;
      const previous = await this.ctx.storage.get(key);
      if (previous) return json(previous.result, previous.status);
      const now = Date.now();
      let webhook;
      try {
        webhook = new URL(this.env.DISCORD_WEBHOOK_URL);
        if (webhook.protocol !== 'https:' || webhook.hostname !== 'discord.com' || !/^\/api\/webhooks\/\d+\/[A-Za-z0-9_-]+$/.test(webhook.pathname)) throw new Error();
      } catch { return json({error: 'Report destination is not configured'}, 503); }
      webhook.search = ''; webhook.hash = '';
      // Fetch only webhook metadata, never expose its URL/token in a response or log.
      const metadata = await fetch(webhook, {redirect: 'manual', signal: AbortSignal.timeout(10000)});
      if (!metadata.ok) return json({error: 'Report destination is unavailable'}, 503);
      const hook = await metadata.json();
      if (!/^\d+$/.test(hook.guild_id || '')) return json({error: 'Forum server is not configured'}, 503);
      const uncertain = {status: 409, result: {error: 'Delivery is unconfirmed. Check the forum before sending a new report.', reference: body.reference}, at: now};
      const reservation = await this.ctx.storage.transaction(async storage => {
        const existing = await storage.get(key);
        if (existing) return existing;
        const times = (await storage.get('times') || []).filter(t => now - t < 3600000);
        if (times.length >= 5) return {status: 429, result: {error: 'Please wait before sending another report.'}};
        await storage.put(key, uncertain);
        await storage.put('times', [...times, now]);
        return null;
      });
      if (reservation) return json(reservation.result, reservation.status);
      await this.ctx.storage.setAlarm(now + 86400000);
      const name = (body.user.global_name || body.user.username).replace(/[\r\n]/g, ' ').slice(0, 80);
      const title = ('iOS — ' + body.description.trim().split('\n')[0]).slice(0, 100);
      const maintainer = this.env.REPORT_MAINTAINER_ID || '';
      const recipients = [...new Set([body.user.id, ...(/^\d+$/.test(maintainer) ? [maintainer] : [])])];
      const notify = maintainer && maintainer !== body.user.id && /^\d+$/.test(maintainer) ? `\nFor <@${maintainer}>` : '';
      const payload = {thread_name: title,
        content: `Report from <@${body.user.id}> (${name})${notify}\nReference: ${body.reference}\n\n${body.description}`,
        allowed_mentions: {parse: [], users: recipients},
        applied_tags: (this.env.FORUM_TAG_IDS || '').split(',').map(s => s.trim()).filter(s => /^\d+$/.test(s)).slice(0, 5)};
      const form = new FormData();
      form.append('payload_json', JSON.stringify(payload));
      form.append('files[0]', new Blob([body.logs], {type: 'text/plain;charset=utf-8'}), `StarPilot-${body.reference}.txt`);
      webhook.searchParams.set('wait', 'true');
      try {
        const result = await fetch(webhook, {method: 'POST', body: form, redirect: 'manual', signal: AbortSignal.timeout(15000)});
        if (!result.ok) return json(uncertain.result, 409);
        const message = await result.json();
        if (!/^\d+$/.test(message.id || '') || !/^\d+$/.test(message.channel_id || '')) return json(uncertain.result, 409);
        const response = {sent: true, reference: body.reference, threadURL: `https://discord.com/channels/${hook.guild_id}/${message.channel_id}/${message.id}`};
        await this.ctx.storage.put(key, {status: 200, result: response, at: now});
        return json(response);
      } catch { return json(uncertain.result, 409); }
    }
  }
  async alarm() {
    const records = await this.ctx.storage.list({prefix: 'report:'});
    for (const [key, value] of records) if (Date.now() - value.at > 7 * 86400000) await this.ctx.storage.delete(key);
    if ((await this.ctx.storage.list({prefix: 'report:', limit: 1})).size) await this.ctx.storage.setAlarm(Date.now() + 86400000);
  }
}
