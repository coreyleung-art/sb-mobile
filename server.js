#!/usr/bin/env node
/**
 * 星台对话桥 v0.1（StarBridge Mobile Bridge）
 * 手机 App 对话入口：鉴权 → 写黑板 inbox → 星桥收到处理 → 回复写 reply → App 读
 * 零依赖 Node http。2026-09-03 星桥 P0 Step1
 */
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const os = require('node:os');

const PORT = process.env.SB_PORT || 8820;
const BB = process.env.SB_BB || 'http://127.0.0.1:8792';
// v9.10.1: .env 全量加载(KEY=VAL 每行, 已存在的环境变量优先)——key 与窄开关均从 .env 读
(function loadDotEnv() {
  try {
    const raw = fs.readFileSync(path.join(__dirname, '.env'), 'utf8');
    for (const line of raw.split('\n')) {
      const m = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+?)\s*$/);
      if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].trim();
    }
  } catch (e) { /* .env 缺失 */ }
})();
const TOKEN = (fs.existsSync(path.join(__dirname, '.token')) 
  ? fs.readFileSync(path.join(__dirname, '.token'), 'utf8').trim() 
  : 'sb-mobile-20260903'); // 0600 文件优先
const INBOX_PREFIX = 'notes/mac-mini/mobile-inbox';
const REPLY_PREFIX = 'notes/mac-mini/mobile-reply';
let deepseekCache = null;  // v9.9 余额缓存(60s)
// 记录已读 reply（防重复）——内存 Map，重启清零（可接受：回复持久在黑板书可查）

function bbWrite(key, value) {
  return new Promise((resolve) => {
    const body = JSON.stringify(value);
    const req = http.request(BB + '/' + key, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Authorization': 'Bearer bb-token-20260829-macmini' }
    }, (res) => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve({code:res.statusCode, body:d})); });
    req.on('error', (e) => resolve({code:0, body:String(e)}));
    req.write(body); req.end();
  });
}

function bbRead(key) {
  return new Promise((resolve) => {
    http.get(BB + '/' + key, { headers: { 'Authorization': 'Bearer bb-token-20260829-macmini' } }, (res) => {
      let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve({code:res.statusCode, body:d}));
    }).on('error', (e) => resolve({code:0, body:String(e)}));
  });
}

function sendJson(res, code, obj) { const b = JSON.stringify(obj); res.writeHead(code, {'Content-Type':'application/json','Content-Length':Buffer.byteLength(b)}); res.end(b); }

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  if (req.method === 'GET' && p === '/health') return sendJson(res, 200, {ok:true, name:'sb-mobile-bridge', port:PORT});

  // 推演工作台代理: /wargame* → 127.0.0.1:8812 (bench/board/layers/tree/playback + d3)
  if (req.method === 'GET' && (p === '/wargame' || p.startsWith('/wargame/') || p === '/wargame/')) {
    let sub = p.replace(/^\/wargame\/?/, '');
    if (!sub) sub = 'bench';   // /wargame 默认 = 推演工作台
    // 转发时带上原始 query(?k=v), 供 /api/md 等读参数
    const qIdx = req.url.indexOf('?');
    const qs = qIdx >= 0 ? req.url.slice(qIdx) : '';
    const target = 'http://127.0.0.1:8812/' + sub + qs;
    const httpMod = require('node:http');
    return httpMod.get(target, (r2) => {
      let body = '';
      r2.on('data', c => body += c);
      r2.on('end', () => {
        const ct = r2.headers['content-type'] || 'text/html; charset=utf-8';
        res.writeHead(200, { 'Content-Type': ct });
        res.end(body);
      });
    }).on('error', () => sendJson(res, 502, { ok:false, error:'wargame engine 未起(127.0.0.1:8812)' }));
  }
  // d3.min.js 也给推演页用
  if (req.method === 'GET' && p === '/wargame/d3.min.js') {
    const httpMod = require('node:http');
    return httpMod.get('http://127.0.0.1:8812/d3.min.js', (r2) => {
      let b = ''; r2.on('data', c => b += c);
      r2.on('end', () => { res.writeHead(200, {'Content-Type':'application/javascript'}); res.end(b); });
    }).on('error', () => sendJson(res, 502, {ok:false, error:'d3 not proxied'}));
  }

  // v9.9 DeepSeek 账户余额: 服务端带 key 查官方 GET /user/balance(key 不落 App)
  if (req.method === 'GET' && p === '/api/deepseek/balance') {
    try {
      const httpsMod = require('node:https');
      let key = process.env.DEEPSEEK_API_KEY || '';
      if (!key) {  // 兜底读 ~/sb-mobile/.env
        try {
          const env = fs.readFileSync(path.join(__dirname, '.env'), 'utf8');
          const m = env.match(/^\s*DEEPSEEK_API_KEY\s*=\s*(.+)\s*$/m);
          if (m) key = m[1].trim();
        } catch (e) { /* .env 缺失 */ }
      }
      if (!key) return sendJson(res, 200, {ok:false, error:'key-not-configured', hint:'server 需 DEEPSEEK_API_KEY(env 或 ~/sb-mobile/.env)'});
      const now = Date.now();
      if (deepseekCache && (now - deepseekCache.ts) < 60000) return sendJson(res, 200, deepseekCache.data);
      // 本机网络 TLS 拦截(自签链) → SB_DS_ALLOW_SELF_SIGNED=1 时仅对本官方端点放行(窄开关, 默认关)
      const dsOpts = { headers: { 'Authorization': 'Bearer ' + key, 'Accept': 'application/json' },
                       rejectUnauthorized: process.env.SB_DS_ALLOW_SELF_SIGNED === '1' ? false : undefined };
      httpsMod.get('https://api.deepseek.com/user/balance', dsOpts, (r) => {
        let d = ''; r.on('data', c => d += c); r.on('end', () => {
          try {
            const j = JSON.parse(d);
            const bi = (j.balance_infos && j.balance_infos[0]) || {};
            const out = { ok:true, ts: now, currency: bi.currency || 'CNY',
              total_balance: bi.total_balance, granted_balance: bi.granted_balance, topped_up_balance: bi.topped_up_balance,
              http_status: r.statusCode };
            deepseekCache = { ts: now, data: out };
            sendJson(res, 200, out);
          } catch (e) { sendJson(res, 200, {ok:false, error:'parse', http_status:r.statusCode, raw:String(d).slice(0,200)}); }
        });
      }).on('error', (e) => sendJson(res, 200, {ok:false, error:'network:' + String(e).slice(0,80)}));
      return;
    } catch (e) { return sendJson(res, 200, {ok:false, error:String(e).slice(0,100)}); }
  }

  // R1 待你决定收件箱: 聚合需用户拍板事项(审批/会签/求救/低余额)
  function decisionsAggregator() {
    const out = [];
    try {
      const bus = JSON.parse(fs.readFileSync(os.homedir() + '/.dsh/agent-bus.json', 'utf8'));
      for (const a of (bus.approvals || [])) {
        if (String(a.status || '').toLowerCase() !== 'pending') continue;
        out.push({ id: a.id, kind: a.kind || 'approval', title: a.title || '审批',
                   detail: String(a.detail || '').slice(0, 300), ts: a.ts || a.created_at || '',
                   decisionable: true });
      }
    } catch (e) { /* agent-bus 不可读 */ }
    try {
      const dir = os.homedir() + '/dsh-collab/data/registry/convention-proposals';
      if (fs.existsSync(dir)) {
        for (const f of fs.readdirSync(dir)) {
          if (!f.endsWith('.json')) continue;
          try {
            const pr = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
            if (String(pr.status) === 'pending') {
              out.push({ id: pr.pr_id, kind: 'signoff', title: '会签待办: ' + (pr.title || f),
                         detail: (pr.suggest || '').slice(0, 200), ts: pr.ts || '', decisionable: false });
            }
          } catch (e2) {}
        }
      }
    } catch (e) {}
    if (deepseekCache && deepseekCache.data && typeof deepseekCache.data.total_balance === 'number' &&
        deepseekCache.data.total_balance < 20) {
      out.push({ id: 'ds-low-balance', kind: 'balance', title: 'DeepSeek 余额低(¥' + deepseekCache.data.total_balance.toFixed(2) + ')',
                 detail: '低于 ¥20 阈值, 建议充值(星台钱包可跳转)', ts: new Date().toISOString(), decisionable: false });
    }
    return out;
  }
  if (req.method === 'GET' && p === '/api/pending-decisions') {
    return sendJson(res, 200, { ok: true, ts: Date.now(), count: decisionsAggregator().length, items: decisionsAggregator() });
  }
  // R1 决定回写: 黑板 data/ops/decision-<id>(coordinator 桥接执行)
  if (req.method === 'POST' && p === '/api/decision') {
    try {
      let bodyStr = '';
      for await (const c of req) bodyStr += c;
      const { id, verdict, note } = JSON.parse(bodyStr || '{}');
      if (!id || !verdict) return sendJson(res, 400, { error: 'id+verdict 必填' });
      const key = 'data/ops/decision-' + String(id).replace(/[^A-Za-z0-9\-_]/g, '') + '-' + Date.now();
      const r = await bbWrite(key, { from: 'sb-mobile', id, verdict, note: note || '', ts: Date.now(),
                                     type: 'decision', note_hint: 'coordinator 订阅桥接执行' });
      if (r.code === 200) return sendJson(res, 200, { ok: true, key });
      return sendJson(res, 500, { error: 'bb write failed', detail: r.body });
    } catch (e) { return sendJson(res, 500, { error: String(e).slice(0, 100) }); }
  }
  // R2 晨报: 黑板/注册表可得项聚合(外卖业务块待 8787 契约, 标注)
  if (req.method === 'GET' && p === '/api/morning-brief') {
    try {
      const out = { ok: true, ts: Date.now(), generated: new Date().toISOString(),
                    sections: { pending: { title: '待你决定', count: decisionsAggregator().length,
                                           note: decisionsAggregator().length ? '' : '无待办' } } };
      // 健康: 最新 cld-monitor 告警卡名(黑板 notes/mac-mini/cld-monitor-alert-*)
      try {
        const req2 = http.get(BB + '/notes/', { headers: { 'Authorization': 'Bearer bb-token-20260829-macmini' } }, (r2) => {
          let d2 = ''; r2.on('data', c => d2 += c); r2.on('end', () => {
            try {
              const j = JSON.parse(d2);
              const list = j.list;
              const keys = Array.isArray(list) ? list : (list ? Object.keys(list) : Object.keys(j));
              const alertKeys = keys.filter(k => /cld-monitor-alert-/.test(String(k)));
              const last = alertKeys.sort().pop() || '';
              out.sections.health = { title: '系统健康', last_alert: last, alerts_24h: alertKeys.filter(k => /20260909/.test(String(k))).length };
            } catch (e3) { out.sections.health = { title: '系统健康', note: '黑板读失败' }; }
            sendJson(res, 200, out);
          });
        });
        req2.on('error', () => { out.sections.health = { title: '系统健康', note: '不可达' }; sendJson(res, 200, out); });
        return;
      } catch (e2) { out.sections.health = { title: '系统健康', note: '不可达' }; }
      out.sections.voice_engine = { title: '语音引擎', note: 'cld-voice L1 已部署(mbp 侧全栈验证中)' };
      return sendJson(res, 200, out);
    } catch (e) { return sendJson(res, 500, { error: String(e).slice(0, 120) }); }
  }

  if (req.method === 'GET' && p === '/api/devices') {
    // 列在线设备（nodes/* 心跳 <90s）——可切换对话目标 + 各端会话清单（v9.7）
    const devices = [];
    const cutoff = Date.now() - 90 * 1000;
    const nodes = ['mac-mini','mbp','i9'];

    // v9.7：mac-mini 会话清单 → v9.8.2 改为「主角色白名单」（星桥维护 main-roles.json）
    // 只列 20 个常驻主角色（中文名+状态），不再 dump agent-bus 53 个杂会话(worker/工具类)
    let macAgents = [];
    try {
      const rolesFile = path.join(__dirname, 'main-roles.json');
      const roles = JSON.parse(fs.readFileSync(rolesFile, 'utf8'));
      const bus = JSON.parse(fs.readFileSync(os.homedir() + '/.dsh/agent-bus.json', 'utf8'));
      const profiles = bus.profiles || [];
      // 活跃度：agent-bus threads 最近消息时间 → 在线近似（绿=10min 内活跃，灰=静默可唤醒）
      const nowMs = Date.now();
      let lastAct = {};  // agentId前缀 -> 最近消息 ts
      for (const t of (bus.threads || [])) {
        for (const m of (t.messages || [])) {
          const f = String(m.from || ''); const ts = m.time || m.ts || 0;
          if (f && ts) { const k = f.split('-').slice(0,2).join('-'); lastAct[k] = Math.max(lastAct[k]||0, ts); }
        }
      }
      const seen = {};
      for (const r of roles) {
        // 在 profiles 中找该前缀的真实会话
        const match = profiles.find(p => String(p.agentId || '').startsWith(r.prefix));
        if (!match) continue;
        const aid = String(match.agentId);
        const key = aid.split('-').slice(0, 2).join('-');
        if (seen[key]) continue;
        seen[key] = true;
        const act = lastAct[key] || 0;
        macAgents.push({ id: key, sessionId: aid, role: r.name + ' · ' + r.desc,
                         online: (nowMs - act) < 30 * 60 * 1000 });
      }
      // 星桥(协调者)恒排最前
      macAgents.sort((x, y) => {
        const xc = x.id.includes('fa1f9150') ? 0 : 1;
        const yc = y.id.includes('fa1f9150') ? 0 : 1;
        if (xc !== yc) return xc - yc;
        return x.role.localeCompare(y.role);
      });
    } catch(e) { console.error('[sb-mobile] macRoles parse error:', String(e).slice(0,120)); }

    for (const n of nodes) {
      try {
        const r = await bbRead('nodes/' + n + '/heartbeat');
        if (r.code === 200 && r.body) {
          const bb = JSON.parse(r.body);
          const d = bb.value || {};
          const tsRaw = bb.ts || d.ts || 0;
          let ts = 0;
          if (typeof tsRaw === 'number') ts = tsRaw;
          else if (/^\d{10,13}$/.test(String(tsRaw))) ts = parseInt(String(tsRaw), 10) * (String(tsRaw).length === 10 ? 1000 : 1);
          else ts = new Date(String(tsRaw)).getTime() || 0;
          if (ts > cutoff) {
            let agents = macAgents;
            if (n !== 'mac-mini') {
              // v9.8: MBP/i9 会话清单从 E2 发现层拉取 (中枢 data/discovery/agents/<node>, R-ERR4)
              agents = [{ id:'bus', role: n==='mbp'?'MBP总线':'i9协调', note:'E2 拉取中' }];
              try {
                const e2 = await new Promise((res) => {
                  http.get('http://xingqiao.meetfunbp.com:8792/data/discovery/agents/' + n, (r2) => {
                    let d=''; r2.on('data',c=>d+=c); r2.on('end',()=>{ try { res(JSON.parse(d)); } catch(e){ res({}); } });
                  }).on('error',()=>res({}));
                });
                const sess = (e2.value||{}).sessions || [];
                if (sess.length > 0) {
                  agents = sess.map(s => ({ id: (s.session_id||'bus').split('-').slice(0,2).join('-'), sessionId: s.session_id||'', role: (s.role||'').slice(0,40), online: (e2.value||{}).status === 'online' }));
                }
              } catch(e) {}
            }
            devices.push({node:n, online:true, role: n==='mac-mini'?'星桥(本机)':n==='mbp'?'MBP总线':'i9协调', ts, agents});
          }
        }
      } catch(e) {}
    }
    // 本机兜底：心跳未读到才补
    if (!devices.some(x => x.node === 'mac-mini')) devices.push({node:'mac-mini', online:true, role:'星桥(本机)', current:true, agents: macAgents});
    return sendJson(res, 200, {ok:true, devices});
  }

  if (req.method === 'GET' && p === '/api/queue') {
    // 读 agent-bus：统计排给 coordinator(fa1f9150) 的 queued 消息
    // v9.7.1 根治：dead-letter 自动清理——超过 10 分钟未送达的 queued 自动标记 delivered（视为死信归档）
    let queued = 0, total = 0, stale = 0, cleaned = 0;
    const cutoff = Date.now() - 10 * 60 * 1000;  // 10 分钟真实排队窗口（此前 30min 太长会"永远1条"）
    try {
      const p = os.homedir() + '/.dsh/agent-bus.json';
      const bus = JSON.parse(fs.readFileSync(p, 'utf8'));
      let dirty = false;
      for (const t of (bus.threads || [])) {
        for (const m of (t.messages || [])) {
          const toStr = String(m.to || '');
          if (!toStr.includes('fa1f9150')) continue;
          total++;
          if (m.status !== 'queued') continue;
          const mt = Number(m.time) || 0;
          if (mt >= cutoff) { queued++; continue; }
          // 死信：超 10 分钟仍未送达（多为 to 短 id / 目标离线静默 queued）→ 自动清理为 delivered
          if (mt > 0) { m.status = 'delivered'; m.deadLetter = true; m.deadAt = Date.now(); dirty = true; cleaned++; }
          else stale++;
        }
      }
      if (dirty) { try { fs.writeFileSync(p, JSON.stringify(bus)); } catch(e2) {} }
    } catch(e) {}
    return sendJson(res, 200, {ok:true, queued, total, stale, cleaned,
      note:'queued=近10分钟真实排队; 超10分钟未送达自动转死信(delivered)不再显示——根治badge假象'});
  }

  // v9.6：静态图片服务（App 展示收到的图 / 星桥回图）——置于鉴权前，图片 URL 可直接访问
  if (req.method === 'GET' && p.startsWith('/uploads/')) {
    const fname = path.basename(p);  // 防路径穿越
    const fpath = path.join(__dirname, 'uploads', fname);
    if (!fs.existsSync(fpath)) return sendJson(res, 404, {error:'not found'});
    const ext = path.extname(fname).toLowerCase();
    const ct = ext === '.png' ? 'image/png' : ext === '.webp' ? 'image/webp' : ext === '.gif' ? 'image/gif' : 'image/jpeg';
    const data = fs.readFileSync(fpath);
    res.writeHead(200, {'Content-Type':ct, 'Content-Length':data.length, 'Cache-Control':'max-age=3600'});
    return res.end(data);
  }

  // 鉴权（除 health）
  const auth = req.headers['authorization'] || '';
  if (auth !== 'Bearer ' + TOKEN) return sendJson(res, 401, {error:'unauthorized'});

  // 读 body
  let raw = '';
  for await (const c of req) raw += c;

  if (req.method === 'POST' && p === '/api/correct') {
    // 语音识别文字智能纠错（后端 LLM：ollama qwen2.5:3b，实测 3.2s 质量好）
    try {
      const { text } = JSON.parse(raw || '{}');
      if (!text || !text.trim()) return sendJson(res, 400, {error:'text required'});
      // v9.8.1: 领域词 = 内置(星桥/星台等) + 共享纠错库 (data/entity-fix/shared-library-v1, 10条 user confirmed)
      let libDomain = '';
      try {
        const lib = await new Promise((res) => {
          http.get('http://127.0.0.1:8792/data/entity-fix/shared-library-v1', (r2) => {
            let d=''; r2.on('data',c=>d+=c); r2.on('end',()=>{ try { res(JSON.parse(d)); } catch(e){ res({}); } });
          }).on('error',()=>res({}));
        });
        const entries = (lib.value||{}).entries || [];
        libDomain = entries.map(e => { const v=(e.variants||[]).filter(x=>x!==e.canonical).join('/'); return v ? v+'→'+e.canonical : ''; }).filter(Boolean).join('；');
      } catch(e) {}
      const sys = '你是中文语音识别纠错助手。识别文本常有同音/近音错别字，请结合语义改正为最可能的原话。领域专名必须纠正：新桥/心桥/兴桥→星桥（智能体名）；新台→星台（本App名）；老灯/烙灯→老登；驿史/义史→驿使。' + (libDomain ? '商务实体：' + libDomain + '。' : '') + '其他同音词按上下文判断。只输出改正后的句子，不要解释、不要引号、不要改句意。';
      const body = JSON.stringify({ model:'qwen2.5:3b', stream:false, messages:[
        {role:'system', content:sys},
        {role:'user', content:text.trim()}
      ], options:{ temperature:0.1, num_predict:200 }});
      const r = await new Promise((resolve) => {
        const req = http.request('http://127.0.0.1:11434/api/chat', { method:'POST', timeout:20000,
          headers:{ 'Content-Type':'application/json', 'Content-Length':Buffer.byteLength(body) } }, (res) => {
          let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve({code:res.statusCode, body:d}));
        });
        req.on('timeout', () => { req.destroy(); resolve({code:0, body:'ollama timeout'}); });
        req.on('error', (e) => resolve({code:0, body:String(e)}));
        req.write(body); req.end();
      });
      if (r.code === 200) {
        const d = JSON.parse(r.body);
        const corrected = (d.message && d.message.content || '').trim();
        if (corrected) return sendJson(res, 200, {ok:true, original:text.trim(), corrected});
      }
      return sendJson(res, 502, {ok:false, error:'correct failed', detail:r.body.slice(0,200)});
    } catch(e) { return sendJson(res, 500, {error:String(e)}); }
  }

  if (req.method === 'POST' && p === '/api/upload') {
    // v9.6 图片：接收 base64 图 → 存 uploads/ → 写 inbox 卡（image 字段）→ 星桥视觉读图
    try {
      const { text, session, target, image } = JSON.parse(raw || '{}');   // image={mime, b64}
      if (!image || !image.b64) return sendJson(res, 400, {error:'image.b64 required'});
      const mime = String(image.mime || 'image/jpeg');
      const ext = mime.includes('png') ? 'png' : mime.includes('webp') ? 'webp' : 'jpg';
      const ts = Date.now();
      const fname = ts + '.' + ext;
      const fpath = path.join(__dirname, 'uploads', fname);
      const buf = Buffer.from(image.b64, 'base64');
      if (buf.length > 15 * 1024 * 1024) return sendJson(res, 413, {error:'image too large (>15MB)'});
      fs.writeFileSync(fpath, buf);
      const url = '/uploads/' + fname;
      // 跨设备目标与星桥一致：都写 inbox（星桥协调读图；target 仅记录会话归属）
      const key = `${INBOX_PREFIX}/${ts}`;
      const r = await bbWrite(key, { from:'sb-mobile', to:'coordinator', text:(text || '').trim(), ts, session:session||'main',
        image:{ file:url, mime, size:buf.length } });
      if (r.code === 200) return sendJson(res, 200, {ok:true, ts, url, size:buf.length});
      return sendJson(res, 500, {error:'bb write failed', detail:r.body});
    } catch(e) { return sendJson(res, 500, {error:String(e)}); }
  }

  if (req.method === 'POST' && p === '/api/chat') {
    try {
      const { text, session, target } = JSON.parse(raw || '{}');
      if (!text || !text.trim()) return sendJson(res, 400, {error:'text required'});
      const ts = Date.now();
      // v9.9 角色直聊: target=20 主角色中文名(非星桥/main) → bus-envelope 直达其会话
      // (central-inbox 按 to=角色 role-map 注入目标会话, 2026-09-09 实测 [direct] delivered)
      const ROLES = (function(){ try { return JSON.parse(fs.readFileSync(path.join(__dirname,'main-roles.json'),'utf8')); } catch(e){ return []; } })();
      const roleNames = new Set(ROLES.map(r => String(r.name)));
      if (target && roleNames.has(target) && target !== '星桥' && target !== 'main') {
        const key = 'notes/mac-mini/bus-mrole-' + ts;
        const txt = (text || '').trim();
        const val = { content:'[星台直聊→' + target + '] ' + txt, from:'bus:sb-mobile', key, to: target, ts,
          type:'bus-envelope', task_id:'sb-role-' + ts,
          _bus:{ task_id:'sb-role-' + ts, from:'sb-mobile', action:'mobile-role-msg', domain:'mac-mini' } };
        const r = await bbWrite(key, val);
        if (r.code === 200) return sendJson(res, 200, {ok:true, ts, routedTo:target, mode:'role-direct'});
        return sendJson(res, 500, {error:'bb write failed', detail:r.body});
      }
      if (target && target !== 'mac-mini' && target !== '星桥' && target !== 'main') {
        // 跨设备路由（协议对齐）：
        //  MBP → notes/mbp/sb-dialog-<ts>-task（mbp-bus 只消费 -task 后缀任务卡）
        //  i9  → notes/i9/sb-dialog-<ts>-task（i9 总线读 notes/i9/ 域）
        const safe = String(target).replace(/[^a-z0-9-]/gi, '');
        if (!safe || (safe !== 'mbp' && safe !== 'i9')) return sendJson(res, 400, {error:'unsupported target: ' + safe});
        const key = 'notes/' + safe + '/sb-dialog-' + ts + '-task';
        const payload = { from:'sb-mobile', via:'starbridge', ts, session: session || 'main',
          text: text.trim(), target: safe,
          request: '星台跨设备对话消息。请目标总线处理并回报：MBP 回复写 notes/mac-mini/mobile-reply/latest-mbp；i9 回复写 notes/i9/starbridge-reply-latest（星台桥轮询读取）' };
        const r = await bbWrite(key, payload);
        if (r.code === 200) return sendJson(res, 200, {ok:true, ts, routedTo:safe});
        return sendJson(res, 500, {error:'bb write failed', detail:r.body});
      }
      const key = `${INBOX_PREFIX}/${ts}`;
      const r = await bbWrite(key, { from:'sb-mobile', to:'coordinator', text:text.trim(), ts, session:session||'main' });
      if (r.code === 200) return sendJson(res, 200, {ok:true, ts});
      return sendJson(res, 500, {error:'bb write failed', detail:r.body});
    } catch(e) { return sendJson(res, 500, {error:String(e)}); }
  }

    if (req.method === 'GET' && p === '/api/reply') {
    const session = url.searchParams.get('session') || 'main';
    // v9.7.2：i9 无 mac-mini 写权(401) → 改读 notes/i9/starbridge-reply-latest（i9 可写）
    const replyKey = session === 'i9'
      ? 'notes/i9/starbridge-reply-latest'
      : 'notes/mac-mini/mobile-reply/latest-' + session;
    const r = await bbRead(replyKey);
    if (r.code === 200 && r.body) {
      try { const d = JSON.parse(r.body); if (d.value) return sendJson(res, 200, {ok:true, replies:[{ts:d.value.ts||0, reply:d.value}]}); } catch(e){}
    }
    return sendJson(res, 200, {ok:true, replies:[]});
  }

  return sendJson(res, 404, {error:'not found'});
});

server.listen(PORT, '0.0.0.0', () => console.log(`[sb-mobile] bridge on :${PORT}`));
