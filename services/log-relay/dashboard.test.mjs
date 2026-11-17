import test from 'node:test';import assert from 'node:assert/strict';
import vm from 'node:vm';
import worker,{Reports} from './worker.mjs';import {dashboardHTML} from './dashboard-ui.mjs';
const ref='12345678-1234-1234-1234-123456789ABC';
function storage(){const data=new Map();let pending=Promise.resolve();return {get:async k=>data.get(k),put:async(k,v)=>data.set(k,structuredClone(v)),delete:async k=>data.delete(k),setAlarm:async()=>{},list:async({prefix='',limit=Infinity,startAfter}={})=>new Map([...data].filter(([k])=>k.startsWith(prefix)&&(!startAfter||k>startAfter)).sort(([a],[b])=>a.localeCompare(b)).slice(0,limit)),transaction(f){const p=pending.then(()=>f(this));pending=p.catch(()=>{});return p;}};}
function environment(){const objects=new Map();const env={IOS_RELEASE_KEY:'i'.repeat(43),ANDROID_RELEASE_KEY:'a'.repeat(43),REPORT_MAINTAINER_ID:'999',DISCORD_WEBHOOK_URL:'https://discord.com/api/webhooks/123/fake',DISCORD_PRIVATE_WEBHOOK_URL:'https://discord.com/api/webhooks/456/privatefake'};env.REPORTS={idFromName:n=>n,get:n=>({fetch:(url,options)=>get(n).fetch(new Request(url,options))})};const get=n=>{if(!objects.has(n))objects.set(n,new Reports({storage:storage()},env));return objects.get(n);};return {env,get};}
const req=(path,body={},key='i'.repeat(43))=>new Request('https://relay/v1/'+path,{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Bearer '+key},body:JSON.stringify(body)});
const internal=(object,path,body)=>object.fetch(new Request('https://reports/'+path,{method:'POST',body:JSON.stringify(body)}));
const authReq=(platform,action,body={})=>new Request('https://relay/v1/'+platform+'/dashboard/auth/'+action,{method:'POST',headers:{'Content-Type':'application/json','CF-Connecting-IP':'192.0.2.1'},body:JSON.stringify(body)});
const sessionReq=(platform,token)=>new Request('https://relay/v1/'+platform+'/dashboard/reports',{method:'POST',headers:{'Content-Type':'application/json',Authorization:'Session '+token},body:'{}'});

test('platform setup survives reload, handles old fragment links and confirms password creation',async()=>{
 const elements=new Map(),events={};
 const element=id=>{if(!elements.has(id))elements.set(id,{value:id==='platform'?'ios':'',textContent:'',hidden:false,replaceChildren(){},removeAttribute(){},querySelectorAll:()=>[],children:[]});return elements.get(id);};
 const location={pathname:'/dashboard/android',hash:'',search:'?invite=example'};
 const paths=[];
 const context=vm.createContext({URLSearchParams,AbortSignal,TypeError,Error,Date,JSON,Set,location,
  document:{getElementById:element,querySelectorAll:()=>[]},window:{addEventListener:(name,handler)=>events[name]=handler},
  history:{replaceState:(_,__,url)=>{location.pathname=url;location.hash='';}},
  fetch:async(path)=>{paths.push(path);return {ok:true,json:async()=>path.endsWith('/state')?{configured:false}:path.endsWith('/setup')?{token:'x'}:path.endsWith('/reports')?{reports:[],cursor:null}:{source:{repo:'android',branch:'Play-Dev'},commits:[]}};}});
 // No rows are rendered in this fixture, but the empty state creates one paragraph.
 context.document.createElement=()=>({append(){},classList:{remove(){},add(){}}});element('reportList').append=()=>{};
 vm.runInContext(dashboardHTML.match(/<script nonce="\{\{nonce\}\}">([\s\S]*?)<\/script>/)[1],context);
 await new Promise(resolve=>setImmediate(resolve));
 assert.equal(element('platform').value,'android');assert.equal(element('unlock').textContent,'Set Android password');assert.equal(location.pathname,'/dashboard/android');
 element('key').value='test password';element('login').onsubmit({preventDefault(){}});await new Promise(resolve=>setImmediate(resolve));
 assert.ok(paths.includes('/v1/android/dashboard/auth/setup'));assert.match(element('status').textContent,/Android password created successfully/);
 location.hash='#platform=ios&invite=legacy';events.hashchange();await new Promise(resolve=>setImmediate(resolve));
 assert.equal(element('platform').value,'ios');assert.equal(element('unlock').textContent,'Set iOS password');assert.equal(location.pathname,'/dashboard/ios');
});

test('both platform-specific dashboard addresses serve the password page',async()=>{
 for(const platform of ['ios','android'])assert.equal((await worker.fetch(new Request('https://relay/dashboard/'+platform),{})).status,200);
});

test('first-time password setup, sign-in, platform isolation and logout',async()=>{
 const {env,get}=environment();
 assert.equal((await (await worker.fetch(authReq('ios','state'),env)).json()).configured,false);
 assert.equal((await worker.fetch(authReq('ios','setup',{password:'my new password'}),env)).status,403);
 const link=await (await worker.fetch(req('ios/dashboard/setup-link',{platform:'ios'}),env)).json();
 const invite=new URL(link.url).searchParams.get('invite');
 const response=await worker.fetch(authReq('ios','setup',{password:'my new password',invite}),env);assert.equal(response.status,200);
 const {token}=await response.json();assert.equal((await worker.fetch(sessionReq('ios',token),env)).status,200);
 assert.equal((await worker.fetch(sessionReq('android',token),env)).status,401);
 assert.equal((await (await worker.fetch(authReq('ios','state'),env)).json()).configured,true);
 assert.equal((await worker.fetch(req('ios/dashboard/setup-link',{platform:'ios'}),env)).status,409);
 assert.equal((await worker.fetch(authReq('ios','setup',{password:'replacement password',invite}),env)).status,403);
 assert.equal((await worker.fetch(authReq('ios','login',{password:'wrong password'}),env)).status,401);
 assert.equal((await worker.fetch(authReq('ios','login',{password:'my new password'}),env)).status,200);
 const stored=await get('dashboard:ios').ctx.storage.get('auth:password');assert.ok(stored.hash);assert.ok(!JSON.stringify(stored).includes('my new password'));
 await worker.fetch(authReq('ios','logout',{token}),env);assert.equal((await worker.fetch(sessionReq('ios',token),env)).status,401);
});

test('setup invites are owner-only, single-use and atomic',async()=>{
 const {env}=environment();
 assert.equal((await worker.fetch(req('android/dashboard/setup-link',{platform:'android'},'a'.repeat(43)),env)).status,403);
 const result=await (await worker.fetch(req('ios/dashboard/setup-link',{platform:'android'}),env)).json();
 const invite=new URL(result.url).searchParams.get('invite');
 const results=await Promise.all(['first password','second password'].map(password=>worker.fetch(authReq('android','setup',{password,invite}),env)));
 assert.equal(results.filter(r=>r.status===200).length,1);assert.equal(results.filter(r=>r.status!==200).length,1);
});

test('password attempts are rate limited and expired sessions fail closed',async()=>{
 const {env,get}=environment();
 for(let i=0;i<10;i++)assert.equal((await worker.fetch(authReq('ios','login',{password:'wrong password'}),env)).status,401);
 assert.equal((await worker.fetch(authReq('ios','login',{password:'wrong password'}),env)).status,429);
 const index=get('dashboard:ios');await index.ctx.storage.put('auth:session:expired',{expires:0});await index.alarm();
 assert.equal(await index.ctx.storage.get('auth:session:expired'),undefined);
 assert.equal((await worker.fetch(sessionReq('ios','f'.repeat(64)),env)).status,401);
});
test('dashboard metadata requires platform key and never crosses namespaces',async()=>{
 const {env,get}=environment();const record={platform:'ios',userID:'123',reference:ref,title:'Tunnel issue',reporter:'Test person',created:100,threadURL:'https://discord.com/channels/1/2/3'};
 await internal(get('dashboard:ios'),'dashboard-put',{platform:'ios',record});
 assert.equal((await worker.fetch(req('ios/dashboard/reports',{},'a'.repeat(43)),env)).status,401);
 assert.equal((await worker.fetch(req('android/dashboard/reports'),env)).status,401);
 assert.equal((await (await worker.fetch(req('android/dashboard/reports',{},'a'.repeat(43)),env)).json()).reports.length,0);
 const result=await (await worker.fetch(req('ios/dashboard/reports'),env)).json();assert.equal(result.reports[0].reference,ref);assert.ok(!JSON.stringify(result).includes('RELEASE_KEY'));
});
test('index upserts and paginates without duplicate entries',async()=>{
 const {get}=environment(),index=get('dashboard:ios');
 for(let i=0;i<102;i++)await internal(index,'dashboard-put',{platform:'ios',record:{platform:'ios',userID:String(i+1),reference:ref,created:i,title:'Report'}});
 await internal(index,'dashboard-put',{platform:'ios',record:{platform:'ios',userID:'1',reference:ref,created:999,title:'Updated'}});
 const first=await (await internal(index,'dashboard-list',{platform:'ios'})).json();assert.equal(first.reports.length,100);assert.ok(first.cursor);
 const second=await (await internal(index,'dashboard-list',{platform:'ios',cursor:first.cursor})).json();assert.equal(second.reports.length,2);assert.equal(second.cursor,null);
 assert.equal([...first.reports,...second.reports].filter(r=>r.userID==='1').length,1);
});
test('legacy backfill validates actual stored reference and platform',async()=>{
 const {env,get}=environment(),owner=get('123');
 await owner.ctx.storage.put('reference:'+ref,{threadURL:'https://discord.com/channels/1/2/3'});await owner.ctx.storage.put('thread:2',{id:'2',title:'Stored title',created:100});
 const response=await worker.fetch(req('ios/dashboard/import',{userID:'123',reference:ref,title:'Forged',threadURL:'https://evil.test'}),env);
 assert.equal(response.status,200);const record=(await response.json()).report;assert.equal(record.title,'Stored title');assert.equal(record.threadURL,'https://discord.com/channels/1/2/3');
 assert.equal((await worker.fetch(req('android/dashboard/import',{userID:'123',reference:ref},'a'.repeat(43)),env)).status,404);
 assert.equal((await worker.fetch(req('ios/dashboard/import',{userID:'456',reference:ref}),env)).status,404);
 await owner.ctx.storage.put('reference:android:'+ref,{threadURL:'https://discord.com/channels/1/8/9'});
 await owner.ctx.storage.put('thread:8',{id:'8',platform:'android',title:'Android title',created:101});
 const history=await (await worker.fetch(req('ios/dashboard/import',{userID:'123',syncHistory:true,reporter:'Known tester'}),env)).json();
 assert.equal(history.imported,1);
 const indexed=await (await worker.fetch(req('ios/dashboard/reports'),env)).json();assert.equal(indexed.reports.length,1);assert.equal(indexed.reports[0].reporter,'Known tester');
});
test('successful reports enqueue metadata only, retry index failure without resending Discord',async()=>{
 const {env,get}=environment(),old=globalThis.fetch;let posts=0,fail=true;
 const original=env.REPORTS.get;env.REPORTS.get=n=>n.startsWith('dashboard:')&&fail?{fetch:async()=>{throw Error('offline')}}:original(n);
 globalThis.fetch=async(url,options)=>{if(options.method==='POST'){posts++;return Response.json({id:'3',channel_id:String(url).includes('/456/')?'6':'2'});}return Response.json({guild_id:'1',channel_id:String(url).includes('/456/')?'6':'7'});};
 const owner=get('123'),body={platform:'ios',reference:ref,description:'Tunnel issue',logs:'PRIVATE DIAGNOSTICS',user:{id:'123',username:'Tester'}};
 try {
  assert.equal((await internal(owner,'submit',body)).status,200);assert.equal(posts,2);
  const pending=await owner.ctx.storage.list({prefix:'dashboard-pending:'});assert.equal(pending.size,1);assert.ok(!JSON.stringify([...pending.values()]).includes('PRIVATE DIAGNOSTICS'));
  fail=false;await owner.alarm();assert.equal((await owner.ctx.storage.list({prefix:'dashboard-pending:'})).size,0);
  const rows=await (await worker.fetch(req('ios/dashboard/reports'),env)).json();assert.equal(rows.reports[0].reporter,'Tester');
  await internal(owner,'submit',body);assert.equal(posts,2);
 }finally{globalThis.fetch=old;}
});
test('GitHub uses only configured platform branches and sanitizes output fields',async()=>{
 const {env}=environment(),old=globalThis.fetch,urls=[];
 globalThis.fetch=async (url,options)=>{assert.equal(options.redirect,'manual');urls.push(String(url));return Response.json([{sha:'a'.repeat(40),html_url:'https://evil.test',commit:{message:'Fix tunnel\nprivate trailing text',committer:{date:'2026-11-05T00:00:00Z'}}}]);};
 try {for(const p of ['ios','android']){const result=await (await worker.fetch(req(p+'/dashboard/commits',{repo:'evil/repo'},p==='ios'?env.IOS_RELEASE_KEY:env.ANDROID_RELEASE_KEY),env)).json();assert.ok(result.commits[0].url.startsWith('https://github.com/'));assert.equal(result.commits[0].title,'Fix tunnel');}
 assert.ok(urls[0].includes('natehuby76/starpilot-galaxy-ios/commits?sha=ios-companion-dev'));assert.ok(urls[1].includes('dirwin31/StarPilotAndroid/commits?sha=Play-Dev'));
 }finally{globalThis.fetch=old;}
});
test('dashboard shell has no embedded secrets, no persistent browser key storage, and valid JS',async()=>{
 const response=await worker.fetch(new Request('https://relay/dashboard'),{});assert.equal(response.status,200);assert.ok(response.headers.get('Content-Security-Policy').includes("frame-ancestors 'none'"));
 const html=await response.text();assert.ok(!html.includes('{{nonce}}'));assert.ok(!/localStorage|sessionStorage|innerHTML/.test(html));
 new Function(dashboardHTML.match(/<script nonce="\{\{nonce\}\}">([\s\S]*?)<\/script>/)[1]);
});

test('GitHub connection errors return JSON rather than escaping Worker handler',async()=>{const {env}=environment(),old=globalThis.fetch;globalThis.fetch=async()=>{throw new TypeError('network unavailable');};try{const r=await worker.fetch(req('ios/dashboard/commits'),env);assert.equal(r.status,503);assert.match((await r.json()).error,/GitHub connection failed/);}finally{globalThis.fetch=old;}});

test('dashboard tag editing verifies ownership, platform, current tags and Discord confirmation',async()=>{
 const {env,get}=environment();env.DISCORD_BOT_TOKEN='fake-test-token';
 await get('123').ctx.storage.put('reference:'+ref,{threadURL:'https://discord.com/channels/1/456/789'});
 await get('123').ctx.storage.put('thread:456',{id:'456',platform:'ios',title:'Report',created:1});
 const old=globalThis.fetch;let patches=0;let tags=['1565236988913913887','1567744790856990730'];
 globalThis.fetch=async(url,options)=>{assert.equal(options.headers.Authorization,'Bot fake-test-token');if(options.method==='PATCH'){patches++;tags=JSON.parse(options.body).applied_tags;}return Response.json({id:'456',parent_id:'1565235002734809168',type:11,applied_tags:tags,thread_metadata:{archived:false}});};
 try{
  const body={userID:'123',reference:ref};
  assert.equal((await worker.fetch(req('ios/dashboard/tags',body),env)).status,200);
  assert.equal((await worker.fetch(req('android/dashboard/tags',body,'a'.repeat(43)),env)).status,404);
  assert.equal((await worker.fetch(req('ios/dashboard/tags',{...body,userID:'999'}),env)).status,404);
  const save={...body,save:true,expected:[...tags],status:'Closed',topics:['Galaxy']};
  const result=await worker.fetch(req('ios/dashboard/tags',save),env);assert.equal(result.status,200);assert.equal((await result.json()).saved,true);assert.equal(patches,1);
  assert.ok(tags.includes('1565237052524466207'));assert.ok(tags.includes('1567744790856990730'));
  assert.equal((await worker.fetch(req('ios/dashboard/tags',save),env)).status,409);assert.equal(patches,1);
  globalThis.fetch=async()=>new Response('',{status:403});
  assert.equal((await worker.fetch(req('ios/dashboard/tags',body),env)).status,503);
 }finally{globalThis.fetch=old;}
});
