// cf-bestip-smart Worker dashboard v1.3.0
// Defaults point to honghanh691913-glitch/cf-bestip-smart; env vars can override.
const APP_VERSION = '1.3.0';

function cfg(env) {
  return {
    owner: env.GITHUB_OWNER || 'honghanh691913-glitch',
    repo: env.GITHUB_REPO || 'cf-bestip-smart',
    branch: env.GITHUB_BRANCH || 'main',
  };
}
function rawUrl(c, path) {
  return `https://raw.githubusercontent.com/${encodeURIComponent(c.owner)}/${encodeURIComponent(c.repo)}/${encodeURIComponent(c.branch)}/${path}`;
}
function commonHeaders(contentType = 'text/plain; charset=utf-8') {
  return {
    'content-type': contentType,
    'cache-control': 'public,max-age=60',
    'access-control-allow-origin': '*',
  };
}
async function fetchRaw(c, path, contentType) {
  const r = await fetch(rawUrl(c, path), { cf: { cacheTtl: 60, cacheEverything: true } });
  if (!r.ok) return new Response(`upstream ${r.status}`, { status: 502, headers: commonHeaders() });
  return new Response(r.body, { status: 200, headers: commonHeaders(contentType || r.headers.get('content-type') || 'text/plain; charset=utf-8') });
}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function parseCSV(text){
  const lines=text.trim().split(/\r?\n/); if(lines.length<2)return [];
  const h=lines[0].split(',');
  return lines.slice(1).filter(Boolean).map(line=>{
    const a=[]; let cur='', q=false;
    for(let i=0;i<line.length;i++){const ch=line[i]; if(ch==='"'){if(q&&line[i+1]==='"'){cur+='"';i++;}else q=!q;}else if(ch===','&&!q){a.push(cur);cur='';}else cur+=ch;} a.push(cur);
    return Object.fromEntries(h.map((k,i)=>[k,a[i]??'']));
  });
}
async function getText(c,path){const r=await fetch(rawUrl(c,path),{cf:{cacheTtl:60,cacheEverything:true}});if(!r.ok)throw new Error(`${path}: ${r.status}`);return await r.text();}
function statFor(status,pool,fam){
  const x=status?.pools?.[pool]?.[fam]||{};
  return `候选 ${x.candidate_count??'-'} / 活跃段 ${x.active_segments??'-'} / CIDR ${x.cidr_count??'-'}`;
}
async function page(env){
  const c=cfg(env); let status={}; const cards=[];
  try{status=JSON.parse(await getText(c,'status.json'));}catch(e){status={ok:false,error:String(e)}}
  const defs=[['apac','ipv4','亚太 / NRT IPv4'],['apac','ipv6','亚太 / NRT IPv6'],['west','ipv4','美西 IPv4'],['west','ipv6','美西 IPv6']];
  for(const [pool,fam,title] of defs){
    let rows=[]; try{rows=parseCSV(await getText(c,`output/${pool}/${fam}.csv`));}catch(e){}
    const body=rows.map((r,i)=>`<tr><td>${i+1}</td><td class="mono">${esc(r.IP)}</td><td>${esc(r.Colo)}</td><td>${esc(r.City)}</td><td>${esc(r.LatencyMs)} ms</td><td>${esc((Number(r.PacketLoss||0)*100).toFixed(1))}%</td><td>${esc(r.SpeedMBps)} MB/s</td><td class="mono">${esc(r.CIDR)}</td></tr>`).join('')||'<tr><td colspan="8">暂无已发布结果</td></tr>';
    cards.push(`<section class="card"><div class="head"><div><h2>${title}</h2><div class="mini">${esc(statFor(status,pool,fam))}</div></div><div class="actions"><a href="/raw/${pool}/${fam}">TXT</a><a href="/csv/${pool}/${fam}">CSV</a><a href="/pool/${pool}/${fam}">候选池</a></div></div><table><thead><tr><th>#</th><th>IP</th><th>Colo</th><th>城市</th><th>延迟</th><th>丢包</th><th>速度</th><th>来源 CIDR</th></tr></thead><tbody>${body}</tbody></table></section>`);
  }
  const ok=Boolean(status.ok);
  return new Response(`<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>CF BestIP Smart</title><style>
  :root{color-scheme:dark}*{box-sizing:border-box}body{font-family:system-ui,-apple-system,Segoe UI,sans-serif;margin:0;background:#0b1020;color:#e8edf7}.wrap{max-width:1500px;margin:auto;padding:24px}.top{display:flex;justify-content:space-between;gap:20px;align-items:flex-end;flex-wrap:wrap}.muted,.mini{color:#96a3ba}.mini{font-size:12px;margin-top:3px}.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(620px,1fr));gap:18px;margin-top:22px}.card{background:#121a2d;border:1px solid #27324a;border-radius:16px;padding:16px;overflow:auto}.head{display:flex;align-items:center;justify-content:space-between;gap:15px}.actions{display:flex;gap:10px;flex-wrap:wrap}.head a,.links a{color:#8fc7ff;text-decoration:none}h1,h2{margin:0 0 8px}.pill{display:inline-block;padding:4px 9px;border-radius:999px;background:#1f2b46}.ok{color:#80e6a8}.bad{color:#ff9d9d}table{border-collapse:collapse;width:100%;font-size:13px;margin-top:12px}th,td{text-align:left;padding:8px;border-bottom:1px solid #253047;white-space:nowrap}.mono{font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.links{margin-top:18px;display:flex;gap:14px;flex-wrap:wrap}@media(max-width:680px){.grid{grid-template-columns:1fr}.wrap{padding:14px}.head{align-items:flex-start;flex-direction:column}}
  </style></head><body><div class="wrap"><div class="top"><div><h1>CF BestIP Smart</h1><div class="muted">255 合格候选 → 200 完整测速 → 每组 Top 5</div></div><div><span class="pill ${ok?'ok':'bad'}">${ok?'正常':'等待结果'}</span> <span class="muted">${esc(status.updated_at||'尚无更新')}</span></div></div><div class="grid">${cards.join('')}</div><div class="links"><a href="/raw/all/best20">best20.txt</a><a href="/csv/all/best20">best20.csv</a><a href="/api/status">status.json</a><span class="muted">${esc(c.owner)}/${esc(c.repo)} · Worker v${APP_VERSION}</span></div></div></body></html>`,{headers:{'content-type':'text/html; charset=utf-8','cache-control':'no-store'}});
}
export default {
  async fetch(request, env) {
    const url=new URL(request.url); const c=cfg(env);
    if(request.method==='OPTIONS') return new Response(null,{status:204,headers:commonHeaders()});
    if(url.pathname==='/health') return Response.json({ok:true,project:'cf-bestip-smart-worker',version:APP_VERSION,github:`${c.owner}/${c.repo}`,branch:c.branch},{headers:{'access-control-allow-origin':'*'}});
    if(url.pathname==='/api/status') return fetchRaw(c,'status.json','application/json; charset=utf-8');
    if(url.pathname==='/raw/all/best20') return fetchRaw(c,'output/all/best20.txt','text/plain; charset=utf-8');
    if(url.pathname==='/csv/all/best20') return fetchRaw(c,'output/all/best20.csv','text/csv; charset=utf-8');
    let m=url.pathname.match(/^\/raw\/(apac|west)\/(ipv4|ipv6)$/);
    if(m) return fetchRaw(c,`output/${m[1]}/${m[2]}.txt`,'text/plain; charset=utf-8');
    m=url.pathname.match(/^\/csv\/(apac|west)\/(ipv4|ipv6)$/);
    if(m) return fetchRaw(c,`output/${m[1]}/${m[2]}.csv`,'text/csv; charset=utf-8');
    m=url.pathname.match(/^\/pool\/(apac|west)\/(ipv4|ipv6)$/);
    if(m) return fetchRaw(c,`output/${m[1]}/${m[2]}-pool.csv`,'text/csv; charset=utf-8');
    if(url.pathname==='/') return page(env);
    return new Response('Not Found',{status:404,headers:commonHeaders()});
  }
};
