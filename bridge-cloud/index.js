const https = require('https');
const http = require('http');

const RELAY_SECRET = process.env.HASS_RELAY_SECRET;
const ORIGIN_BASE = process.env.HA_ORIGIN_BASE || null;
const HTTP_PASS = ['true','1'].includes((process.env.HA_HTTP_PASSTHROUGH||'').toLowerCase());

const httpsAgent = new https.Agent({ keepAlive: true });
const httpAgent = new http.Agent({ keepAlive: true });

function originUrl(suffix) {
  const u = new URL(ORIGIN_BASE);
  u.pathname = u.pathname.replace(/\/+$/, '') + '/' + suffix;
  return u.toString();
}

let upstreamConnId = null;
let _initPromise = null;

function getHeader(h, n) {
  if (!h) return '';
  if (h[n]) return h[n];
  const lower = n.toLowerCase();
  for (const k of Object.keys(h)) {
    if (k.toLowerCase() === lower) return h[k];
  }
  return '';
}

function httpPost(url, headers, body) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const agent = url.startsWith('https') ? httpsAgent : httpAgent;
    const p = new URL(url);
    const req = mod.request({
      hostname: p.hostname, port: p.port || (p.protocol === 'https:' ? 443 : 80),
      path: p.pathname + p.search, method: 'POST', agent,
      headers: { ...headers, 'Content-Length': Buffer.byteLength(body) },
    }, res => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve({status:res.statusCode,body:d})); });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

function httpGet(url, headers) {
  return new Promise((resolve, reject) => {
    const mod = url.startsWith('https') ? https : http;
    const agent = url.startsWith('https') ? httpsAgent : httpAgent;
    const p = new URL(url);
    const req = mod.request({
      hostname: p.hostname, port: p.port || (p.protocol === 'https:' ? 443 : 80),
      path: p.pathname + p.search, method: 'GET', agent,
      headers: headers || {},
    }, res => { let d=''; res.on('data',c=>d+=c); res.on('end',()=>resolve({status:res.statusCode,body:d})); });
    req.on('error', reject);
    req.end();
  });
}

async function refreshConnId() {
  if (!ORIGIN_BASE) return;
  try {
    const r = await httpGet(originUrl('status'), { 'Authorization': 'Bearer ' + RELAY_SECRET });
    if (r.status === 200 && r.body) {
      upstreamConnId = r.body;
    }
  } catch(e) { console.error('init err:', e.message || e); }
}

_initPromise = refreshConnId();

async function wsSend(connId, data, type, token) {
  const b64 = Buffer.from(data).toString('base64');
  const body = JSON.stringify({ data: b64, type: type });
  try {
    const r = await httpPost(
      `https://apigateway-connections.api.cloud.yandex.net/apigateways/websocket/v1/connections/${encodeURIComponent(connId)}:send`,
      { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token }, body
    );
    if (r.status >= 300) console.error('push err:', r.status);
    return r.status;
  } catch(e) { console.error('push exc:', e.message); return 500; }
}

async function wsDisconnect(connId, token) {
  try {
    const r = await httpPost(
      `https://apigateway-connections.api.cloud.yandex.net/apigateways/websocket/v1/connections/${encodeURIComponent(connId)}:disconnect`,
      { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token }, '{}'
    );
    if (r.status >= 300) console.error('reset err:', r.status);
    return r.status;
  } catch(e) { console.error('reset exc:', e.message); return 500; }
}

function encode(clientId, type, flags, seqId, payload) {
  const cid = Buffer.from(clientId, 'utf-8');
  const seq = Buffer.from(seqId || '', 'utf-8');
  const h = Buffer.alloc(2 + cid.length + 2 + 2 + seq.length);
  h.writeUInt16BE(cid.length, 0);
  cid.copy(h, 2);
  h[2 + cid.length] = type;
  h[2 + cid.length + 1] = flags;
  h.writeUInt16BE(seq.length, 2 + cid.length + 2);
  seq.copy(h, 2 + cid.length + 4);
  return payload ? Buffer.concat([h, payload]) : h;
}

function decode(buf) {
  const cidLen = buf.readUInt16BE(0);
  const off = 2 + cidLen;
  const seqLen = buf.readUInt16BE(off + 2);
  return { clientId: buf.subarray(2, 2+cidLen).toString('utf-8'), type: buf[off], flags: buf[off+1], seqId: buf.subarray(off+4, off+4+seqLen).toString('utf-8'), payload: buf.subarray(off+4+seqLen) };
}

function encodeClientConnected(path, subprotocols, iamToken) {
  const p = Buffer.from(path, 'utf-8');
  const s = Buffer.from(subprotocols, 'utf-8');
  const t = Buffer.from(iamToken, 'utf-8');
  const buf = Buffer.alloc(2 + p.length + 2 + s.length + 2 + t.length);
  let off = 0;
  buf.writeUInt16BE(p.length, off); off += 2; p.copy(buf, off); off += p.length;
  buf.writeUInt16BE(s.length, off); off += 2; s.copy(buf, off); off += s.length;
  buf.writeUInt16BE(t.length, off); off += 2; t.copy(buf, off);
  return buf;
}

const T_HELLO=0x01, T_HELLO_OK=0x02, T_HELLO_ERR=0x03;
const T_CONN=0x10, T_DISC=0x11;
const T_DATA=0x20, T_PING=0xF0, T_PONG=0xF1;
const F_TEXT=0x01;

async function forwardToOrigin(frame, iamToken) {
  if (upstreamConnId) {
    const st = await wsSend(upstreamConnId, frame, 'BINARY', iamToken);
    if (st >= 200 && st < 300) return true;
    console.error('push failed:', st);
    upstreamConnId = null;
  }
  if (!ORIGIN_BASE) return false;
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      const r = await httpPost(ORIGIN_BASE, {
        'Content-Type': 'application/octet-stream',
        'Authorization': 'Bearer ' + RELAY_SECRET,
      }, Buffer.from(frame));
      if (r.status === 200) {
        if (r.body) upstreamConnId = r.body;
        return true;
      }
      console.error('origin POST err:', r.status);
    } catch(e) {
      console.error('origin exc:', e.message || e);
    }
  }
  return false;
}

async function forwardHTTP(event) {
  if (!ORIGIN_BASE) return { statusCode: 502, body: 'unavailable' };
  const actualPath = (event.params && event.params.path)
    ? '/' + event.params.path
    : event.url || event.path || '/';
  const proxyReq = {
    method: event.httpMethod || 'GET',
    path: actualPath,
    queryString: event.queryStringParameters || {},
    headers: event.headers || {},
    body: event.body || '',
    isBase64Encoded: event.isBase64Encoded || false,
  };
  try {
    const r = await httpPost(originUrl('relay'), {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ' + RELAY_SECRET,
    }, JSON.stringify(proxyReq));
    return JSON.parse(r.body);
  } catch(e) {
    console.error('http fwd err:', e.message || e);
    return { statusCode: 502, body: 'error' };
  }
}

module.exports.handler = async function(event, context) {
  try { return await handle(event, context); }
  catch(e) { console.error('exc:', e.stack||e); return {statusCode:200}; }
};

async function handle(event, context) {
  const rc = event.requestContext || {};
  const connId = rc.connectionId;
  const ev = rc.eventType;
  const token = context.token?.access_token || '';
  const route = rc.apiGateway?.operationContext?.route || 'channel';

  if (!ev && HTTP_PASS) {
    return await forwardHTTP(event);
  }

  if (route === 'origin') {
    if (ev === 'CONNECT') {
      upstreamConnId = connId;
      return { statusCode: 200 };
    }
    if (ev === 'MESSAGE') {
      if (!upstreamConnId) { upstreamConnId = connId; }
      const buf = event.isBase64Encoded ? Buffer.from(event.body,'base64') : Buffer.from(event.body||'');
      const f = decode(buf);
      if (f.type === T_HELLO) {
        const ver = f.payload[0];
        const tok = f.payload.subarray(1).toString('utf-8');
        if (ver !== 1 || tok !== RELAY_SECRET) {
          return binaryResp(encode('', T_HELLO_ERR, 0, '', Buffer.from('unauthorized')));
        }
        return binaryResp(encode('', T_HELLO_OK, 0, '', Buffer.from(upstreamConnId || '')));
      }
      if (f.type === T_PING) return binaryResp(encode('', T_PONG, 0, ''));
      return { statusCode: 200 };
    }
    if (ev === 'DISCONNECT') {
      if (upstreamConnId === connId) upstreamConnId = null;
      return { statusCode: 200 };
    }
    return { statusCode: 200 };
  }

  if (ev === 'CONNECT') {
    const path = event.path || '/';
    const sub = getHeader(event.headers, 'Sec-WebSocket-Protocol');
    const payload = encodeClientConnected(path, sub, token);
    const ok = await forwardToOrigin(encode(connId, T_CONN, 0, '', payload), token);
    if (!ok) {
      console.error('session open failed:', connId);
      return { statusCode: 502 };
    }
    const headers = {};
    if (sub) headers['Sec-WebSocket-Protocol'] = sub;
    return { statusCode: 200, headers };
  }

  if (ev === 'MESSAGE') {
    const buf = event.isBase64Encoded ? Buffer.from(event.body,'base64') : Buffer.from(event.body||'');
    const ct = getHeader(event.headers, 'Content-Type');
    const isText = ct.startsWith('application/json') || ct.startsWith('text/');
    const rawMsgId = rc.messageId || '';
    const ok = await forwardToOrigin(encode(connId, T_DATA, isText ? F_TEXT : 0, rawMsgId, buf), token);
    if (!ok) {
      console.error('stream reset:', connId);
      await wsDisconnect(connId, token);
    }
    return { statusCode: 200 };
  }

  if (ev === 'DISCONNECT') {
    await forwardToOrigin(encode(connId, T_DISC, 0, ''), token);
    return { statusCode: 200 };
  }

  return { statusCode: 200 };
}

function binaryResp(buf) {
  return { statusCode:200, headers:{'Content-Type':'application/octet-stream'}, body:buf.toString('base64'), isBase64Encoded:true };
}
