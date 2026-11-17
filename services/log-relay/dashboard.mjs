import {getReportThread,nextReportTags,discordTags,supportTags} from './thread-tags.mjs';
import {dashboardHTML} from './dashboard-ui.mjs';
export const dashboardRepos={ios:{repo:'natehuby76/starpilot-galaxy-ios',branch:'ios-companion-dev'},android:{repo:'dirwin31/StarPilotAndroid',branch:'Play-Dev'}};
export function dashboardPage(){
 const nonce=crypto.randomUUID().replaceAll('-','');
 return new Response(dashboardHTML.replaceAll('{{nonce}}',nonce),{headers:{'Content-Type':'text/html;charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff','Content-Security-Policy':"default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'nonce-"+nonce+"'; connect-src 'self' https://api.github.com; img-src 'self' data:; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"}});
}
export async function dashboardAPI(request,env,platform,readJSON,json){
 const body=await readJSON(request,8192),path=new URL(request.url).pathname;
 const index=env.REPORTS.get(env.REPORTS.idFromName('dashboard:'+platform));
 if(path.endsWith('/tags')) {
  if(!/^\d{1,20}$/.test(body.userID||'')||typeof body.reference!=='string')return json({error:'Select a report first.'},400);
  const response=await env.REPORTS.get(env.REPORTS.idFromName(body.userID)).fetch('https://reports/dashboard-record',{method:'POST',body:JSON.stringify({platform,userID:body.userID,reference:body.reference})});
  if(!response.ok)return response;
  const record=await response.json(),id=new URL(record.threadURL).pathname.split('/')[3];
  try{
   let thread=await getReportThread(env,id);
   if(body.save===true){
    if(!Array.isArray(body.expected)||JSON.stringify([...thread.applied_tags].sort())!==JSON.stringify([...body.expected].sort()))return json({error:'Tags changed in Discord. Reload tags before saving.'},409);
    if(thread.thread_metadata?.archived)return json({error:'Unarchive this thread in Discord before changing tags.'},409);
    const tags=nextReportTags(thread.applied_tags,platform,body.status,body.topics);
    thread=await discordTags(env,'/channels/'+id,{applied_tags:tags});
    if(JSON.stringify([...(thread.applied_tags||[])].sort())!==JSON.stringify([...tags].sort()))throw Error('Tag update was not confirmed. Reload tags.');
   }
   return json({tags:thread.applied_tags,status:['Closed','In Progress','Open'].find(n=>thread.applied_tags.includes(supportTags[n]))||'Open',topics:['Navigation','CarPlay','Galaxy'].filter(n=>thread.applied_tags.includes(supportTags[n])),archived:!!thread.thread_metadata?.archived,saved:body.save===true});
  }catch(e){return json({error:e.message},503);}
 }
 if(path.endsWith('/reports')) return index.fetch('https://reports/dashboard-list',{method:'POST',body:JSON.stringify({platform,cursor:body.cursor})});
 if(path.endsWith('/import')) {
  if(body.syncHistory===true && /^\d{1,20}$/.test(body.userID||'')) {
   const owner=env.REPORTS.get(env.REPORTS.idFromName(body.userID));
   const historyResponse=await owner.fetch('https://reports/dashboard-history',{method:'POST',body:JSON.stringify({platform,cursor:body.cursor})});
   if(!historyResponse.ok)return historyResponse;
   const history=await historyResponse.json();let imported=0;
   for(const reference of history.references){
    const response=await owner.fetch('https://reports/dashboard-record',{method:'POST',body:JSON.stringify({platform,userID:body.userID,reference})});
    if(!response.ok)continue;
    const record=await response.json();
    if(record.reporter.startsWith('Discord user ')&&typeof body.reporter==='string'&&body.reporter.trim())record.reporter=body.reporter.trim().slice(0,80);
    const saved=await index.fetch('https://reports/dashboard-put',{method:'POST',body:JSON.stringify({platform,record})});
    if(!saved.ok)return json({error:'Index update interrupted; retry the same page'},503);
    imported++;
   }
   return json({imported,cursor:history.cursor});
  }
  if(!/^\d{1,20}$/.test(body.userID||'')||typeof body.reference!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(body.reference)) return json({error:'Invalid report reference'},400);
  const recordResponse=await env.REPORTS.get(env.REPORTS.idFromName(body.userID)).fetch('https://reports/dashboard-record',{method:'POST',body:JSON.stringify({platform,userID:body.userID,reference:body.reference})});
  if(!recordResponse.ok) return recordResponse;
  const record=await recordResponse.json();
  const saved=await index.fetch('https://reports/dashboard-put',{method:'POST',body:JSON.stringify({platform,record})});
  if(!saved.ok) return json({error:'Could not index report'},503);
  return json({report:record});
 }
 if(path.endsWith('/commits')) {
  const source=dashboardRepos[platform];
  const headers={'Accept':'application/vnd.github+json','User-Agent':'StarPilot-support-dashboard','X-GitHub-Api-Version':'2022-11-28'};
  // Optional server credential for GitHub rate limits; never sent to the browser.
  if(env.GITHUB_READ_TOKEN) headers.Authorization='Bearer '+env.GITHUB_READ_TOKEN;
  let response;try{response=await fetch('https://api.github.com/repos/'+source.repo+'/commits?sha='+encodeURIComponent(source.branch)+'&per_page=30',{headers,redirect:'manual',signal:AbortSignal.timeout(15000)});}catch(error){return json({error:'GitHub connection failed ('+String(error.name)+'). You can still draft manually.'},503);}
  if(!response.ok) return json({error:'GitHub is unavailable (HTTP '+response.status+'). You can still write and send an update manually.'},503);
  const commits=await response.json();
  if(!Array.isArray(commits)) return json({error:'Invalid GitHub response'},503);
  return json({source,commits:commits.filter(c=>/^[a-f0-9]{40}$/.test(c.sha||'')).map(c=>({sha:c.sha,title:String(c.commit?.message||'').split('\n')[0].slice(0,300),date:c.commit?.committer?.date,url:'https://github.com/'+source.repo+'/commit/'+c.sha}))});
 }
 return json({error:'Not found'},404);
}
