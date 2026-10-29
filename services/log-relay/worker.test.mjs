import test from 'node:test';
import assert from 'node:assert/strict';
import worker, {Reports, reportTitle} from './worker.mjs';
const env = {REPORT_MAINTAINER_ID:'524762496373096459',DISCORD_CLIENT_ID:'123', DISCORD_CLIENT_SECRET:'test', DISCORD_WEBHOOK_URL:'https://discord.com/api/webhooks/123/fake'};
const request = (path, body, token) => new Request('https://relay'+path, {method:'POST',headers:{'Content-Type':'application/json', ...(token ? {Authorization:token}: {})},body:JSON.stringify(body)});
test('OAuth uses fixed callback and PKCE, rejects invalid state', async () => {
  assert.equal((await worker.fetch(new Request('https://relay/auth/discord/start'),env)).status,400);
  const response=await worker.fetch(new Request('https://relay/auth/discord/start?state='+ 'a'.repeat(43)+'&code_challenge='+'b'.repeat(43)),env);
  const target=new URL(response.headers.get('location'));
  assert.equal(target.searchParams.get('code_challenge_method'),'S256');
  assert.equal(target.searchParams.get('scope'),'identify');
  assert.equal(target.searchParams.get('redirect_uri'),'https://starpilot-log-relay.nathan-g-hubbard.workers.dev/auth/discord/callback');
});
test('rejects invalid JSON and missing authentication',async()=>{
  assert.equal((await worker.fetch(request('/auth/discord/exchange',null),env)).status,400);
  assert.equal((await worker.fetch(request('/v1/logs',{}),env)).status,401);
});
test('rejects tokens issued to other applications',async()=>{
  const old=globalThis.fetch;
  globalThis.fetch=async()=>Response.json({application:{id:'456'},scopes:['identify'],user:{id:'789'}});
  try {assert.equal((await worker.fetch(request('/v1/logs',{},'Bearer test'),env)).status,403);} finally {globalThis.fetch=old;}
});
function storage(){const values=new Map();return {transaction:async function(f){return f(this)},get:async k=>values.get(k),put:async(k,v)=>values.set(k,v),setAlarm:async()=>{},list:async()=>values,delete:async k=>values.delete(k)};}
const body={reference:'12345678-1234-1234-1234-123456789abc',description:'Bluetooth failed @everyone',logs:'synthetic diagnostics',user:{id:'789',username:'tester'}};
test('confirmed report retry returns same thread without another post',async()=>{
 const old=globalThis.fetch;let posts=0;
 globalThis.fetch=async(url,options)=>{
  assert.equal(options.redirect,'manual');
  if(options.method==='POST') {posts++;const payload=JSON.parse(options.body.get('payload_json'));assert.deepEqual(payload.allowed_mentions,{parse:[],users:['789','524762496373096459']});assert.ok(payload.content.includes('<@524762496373096459>'));return Response.json({id:'111',channel_id:'222'});}
  return Response.json({guild_id:'333'});
 };
 const reports=new Reports({storage:storage(),blockConcurrencyWhile:f=>f()},env);
 try {
  const first=await (await reports.fetch(request('/submit',body))).json();
  const retry=await (await reports.fetch(request('/submit',body))).json();
  assert.deepEqual(first,retry);assert.equal(posts,1);assert.equal(first.threadURL,'https://discord.com/channels/333/222/111');
 }finally{globalThis.fetch=old;}
});
test('uncertain delivery is not automatically sent twice',async()=>{
 const old=globalThis.fetch;let posts=0;
 globalThis.fetch=async(url,options)=>{if(options.method==='POST'){posts++;throw new Error('network lost');}return Response.json({guild_id:'333'});};
 const reports=new Reports({storage:storage(),blockConcurrencyWhile:f=>f()},env);
 try {assert.equal((await reports.fetch(request('/submit',body))).status,409);assert.equal((await reports.fetch(request('/submit',body))).status,409);assert.equal(posts,1);}finally{globalThis.fetch=old;}
});

test('AI titles use only the description and fall back safely', async () => {
 let received;
 const ai = {run: async (model, input) => { received = {model, input}; return {response: 'Bluetooth reconnect fails'}; }};
 assert.equal(await reportTitle(ai, 'Bluetooth failed'), 'iOS — Bluetooth reconnect fails');
 assert.equal(received.model, '@cf/meta/llama-3.2-1b-instruct');
 assert.equal(received.input.messages[1].content, 'Bluetooth failed');
 assert.equal(await reportTitle({run: async () => {throw Error('unavailable')}}, 'Bluetooth failed'), 'iOS — Bluetooth failed');
 assert.equal(await reportTitle({run: async () => ({response: ''})}, 'Bluetooth failed'), 'iOS — Bluetooth failed');
});
