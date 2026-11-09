#!/usr/bin/env node
/**
 * cline-pin: 本地反代，把 Cline Pass 的请求钉到指定上游。
 *
 * 背景：cline-pass/* 是一个 VMC（virtual model config），默认会走免费的私有
 * contributor 池（provider: openai-compatible-private, cost 0）。只有请求体里带
 * providerOptions.gateway.has 时，私有池才被排除，此时 only 才会生效。
 * Zed 的 openai_compatible provider 没有 extra_body 能力，所以只能在传输层注入。
 *
 * 用法：
 *   node proxy.mjs
 *   CLINE_PIN_PORT=8789 CLINE_PIN_ONLY=deepseek node proxy.mjs
 *
 * 环境变量：
 *   CLINE_PIN_HOST       监听地址，默认 127.0.0.1
 *   CLINE_PIN_PORT       监听端口，默认 8788
 *   CLINE_PIN_ONLY       逗号分隔的 only 列表，默认 deepseek
 *   CLINE_PIN_HAS        额外追加的 has，逗号分隔（如 vision,tool-use）
 *   CLINE_PIN_FALLBACK   置 1 时，上游 4xx/5xx 会去掉注入重试一次（会退回私有池）
 *   CLINE_PIN_QUIET      置 1 时关闭逐请求日志（连文件也不写）
 *   CLINE_PIN_API_KEY    选填，配置后强制用它替换请求里的 key（没带也会补上）
 */

import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import path from 'node:path';
import { inspect } from 'node:util';
import { fileURLToPath } from 'node:url';

// ---- 上游 ----
// 转发目标，默认 Cline 官方；只有跑 selftest / 调试时才用 CLINE_PIN_UPSTREAM 指到本地 mock。
const UPSTREAM_URL = new URL(process.env.CLINE_PIN_UPSTREAM || 'https://api.cline.bot');
// 上游是 https 就走 TLS 客户端，http（本地 mock）走明文。
const USE_TLS = UPSTREAM_URL.protocol === 'https:';
// 建连用的 host / port；端口没写时按协议取默认值。
const UPSTREAM = {
  hostname: UPSTREAM_URL.hostname,
  port: Number(UPSTREAM_URL.port || (USE_TLS ? 443 : 80)),
};

// ---- 本地监听 ----
// 监听地址。默认只绑回环地址，不对外暴露；确实要给局域网用才改成 0.0.0.0。
const HOST = process.env.CLINE_PIN_HOST || '127.0.0.1';
// 监听端口。改这个值之后，Zed settings.json 里的 api_url 要一起改。
const PORT = Number(process.env.CLINE_PIN_PORT || 8788);

// ---- 注入策略 ----
// 期望落到的上游（providerOptions.gateway.only），逗号分隔；第一个值同时用作「命中」的判定标准。
const ONLY = split(process.env.CLINE_PIN_ONLY || 'deepseek');
// 额外追加的 has，逗号分隔（如 vision,tool-use）；会与从请求体推导出的 has 合并。
const EXTRA_HAS = split(process.env.CLINE_PIN_HAS || '');
// 只对这个子串匹配到的模型注入，避免误伤同一 provider 下的其他模型。
const MODEL_FILTER = (process.env.CLINE_PIN_MODEL_FILTER ?? 'deepseek').trim();
// 置 1：上游 4xx/5xx 时去掉注入重试一次，会退回免费私有池（等于放弃钉住）。
const ALLOW_FALLBACK = process.env.CLINE_PIN_FALLBACK === '1';
// 置 1：逐请求访问日志也不写文件；异常和未钉住仍然输出到控制台。
const QUIET = process.env.CLINE_PIN_QUIET === '1';
// 选填：配置后无条件覆盖请求里的 Authorization，客户端没带也会补上。
// 留空则透传客户端自己的 key。
// 读取顺序：环境变量 CLINE_PIN_API_KEY -> 本目录 cline-pin.key -> 空（透传）。
// 真 key 一律不要写进源码：这个文件是进版本库的，写死等于公开。
const API_KEY = (process.env.CLINE_PIN_API_KEY || readKeyFile()).trim();
// 请求体上限，超过直接回 413，避免一个超大上传把内存吃光。
const MAX_BODY = 64 * 1024 * 1024;

// ---- 日志：同时写控制台和程序目录下的文件 ----
const HERE = path.dirname(fileURLToPath(import.meta.url));

/**
 * 本机 key 文件：与源码同目录的 cline-pin.key（已在 .gitignore 里排除）。
 * 没有这个文件是正常情况——此时 CLINE_PIN_API_KEY 没配就透传客户端的 key。
 */
function readKeyFile() {
  try {
    const file = path.join(path.dirname(fileURLToPath(import.meta.url)), 'cline-pin.key');
    if (!fs.existsSync(file)) return '';
    return fs.readFileSync(file, 'utf8').trim();
  } catch (e) {
    process.stderr.write(`读取 cline-pin.key 失败: ${e.message}\n`);
    return '';
  }
}

const LOG_FILE =
  process.env.CLINE_PIN_LOG === 'off' ? null : process.env.CLINE_PIN_LOG || path.join(HERE, 'cline-pin.log');
const MAX_LOG_BYTES = 5 * 1024 * 1024;

let logStream = null;
if (LOG_FILE) {
  try {
    // 超过 5MB 就把旧文件转成 .1，避免无限增长
    if (fs.existsSync(LOG_FILE) && fs.statSync(LOG_FILE).size > MAX_LOG_BYTES) {
      fs.renameSync(LOG_FILE, `${LOG_FILE}.1`);
    }
    logStream = fs.createWriteStream(LOG_FILE, { flags: 'a' });
    logStream.on('error', (e) => {
      process.stderr.write(`日志文件写入失败: ${e.message}\n`);
      logStream = null;
    });
  } catch (e) {
    process.stderr.write(`无法打开日志文件 ${LOG_FILE}: ${e.message}\n`);
    logStream = null;
  }
}

const consoleLog = console.log.bind(console);
console.log = (...args) => {
  const line = fmt(args);
  consoleLog(line);
  if (logStream) logStream.write(`${line}\n`);
};

// 网关只认这套 kebab-case 取值，写错会直接 400。
const HAS_VALUES = new Set([
  'free',
  'implicit-caching',
  'reasoning',
  'structured-output',
  'tool-use',
  'vision',
]);

const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);

const stats = {
  startedAt: new Date().toISOString(),
  requests: 0,
  injected: 0,
  streamed: 0,
  skipped: 0,
  finalProviders: {},
  unverified: 0,
  lastError: null,
};

function split(v) {
  return v
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/** 值里已经带 scheme（如 "Bearer sk-x"）就原样用，否则补上 Bearer。 */
function authValue(key) {
  return /\s/.test(key) ? key : `Bearer ${key}`;
}

function fmt(args) {
  return args.map((a) => (typeof a === 'string' ? a : inspect(a))).join(' ');
}

function stamp() {
  return new Date().toISOString().slice(11, 23);
}

// 异常、告警、配置问题：控制台 + 文件。不受 CLINE_PIN_QUIET 影响，出错必须看得见。
function log(...args) {
  console.log(stamp(), ...args);
}

/**
 * 逐请求访问日志：只写文件，不刷控制台。
 * 控制台只保留异常和未按预期钉住的情况，日常盯 cline-pin.log 即可。
 */
function access(...args) {
  if (QUIET || !logStream) return;
  logStream.write(`${stamp()} ${fmt(args)}\n`);
}

function collectBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error('request body too large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function hasImagePart(messages) {
  for (const m of messages) {
    if (!Array.isArray(m?.content)) continue;
    for (const part of m.content) {
      if (part?.type === 'image_url' || part?.type === 'input_image' || part?.image_url) return true;
    }
  }
  return false;
}

/**
 * 从请求体推导 has。至少保证有一项——否则私有池不会被排除，only 形同虚设。
 */
function deriveHas(body) {
  const has = new Set(EXTRA_HAS);

  if (Array.isArray(body.tools) && body.tools.length > 0) has.add('tool-use');
  if (body.response_format) has.add('structured-output');
  if (Array.isArray(body.messages) && hasImagePart(body.messages)) has.add('vision');
  if (!has.size) has.add('reasoning');

  for (const h of [...has]) {
    if (HAS_VALUES.has(h)) continue;
    // 允许 quantization:fp8 这类重量格式条件原样透传
    if (/^!?quantization:[a-z0-9]+$/i.test(h)) continue;
    log(`warn: 丢弃非法 has 值 "${h}"`);
    has.delete(h);
  }
  if (!has.size) has.add('reasoning');
  return [...has];
}

function shouldPin(body) {
  if (!MODEL_FILTER) return true;
  return String(body?.model ?? '')
    .toLowerCase()
    .includes(MODEL_FILTER.toLowerCase());
}

function inject(body) {
  const prev = body.providerOptions && typeof body.providerOptions === 'object' ? body.providerOptions : {};
  const prevGw = prev.gateway && typeof prev.gateway === 'object' ? prev.gateway : {};
  const has = new Set(Array.isArray(prevGw.has) ? prevGw.has : []);

  for (const h of deriveHas(body)) has.add(h);

  return {
    ...body,
    providerOptions: {
      ...prev,
      gateway: { ...prevGw, only: ONLY.slice(), has: [...has] },
    },
  };
}

function buildHeaders(req, payloadLength) {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    const key = k.toLowerCase();
    if (HOP_BY_HOP.has(key) || key === 'host' || key === 'content-length' || key === 'accept-encoding') continue;
    headers[key] = v;
  }
  headers.host = UPSTREAM_URL.host;
  if (API_KEY) {
    // 客户端可能用 Authorization / api-key / x-api-key 任一携带凭据，一律换成代理配置的。
    headers.authorization = authValue(API_KEY);
    for (const h of ['api-key', 'x-api-key']) {
      if (headers[h] !== undefined) headers[h] = API_KEY;
    }
  }
  if (payloadLength > 0) headers['content-length'] = String(payloadLength);
  return headers;
}

function recordProvider(label, provider) {
  stats.finalProviders[provider] = (stats.finalProviders[provider] ?? 0) + 1;
  if (provider === ONLY[0]) {
    access(`${label} finalProvider=${provider}`);
    return;
  }
  log(`${label} finalProvider=${provider}  <-- 未按预期钉住!`);
}

/**
 * 转发到上游，透传字节。流式响应边转边扫 finalProvider。
 */
function forward({ method, path, headers, payload, label, attempt, res, parsedBody, rawPayload }) {
  const upstreamReq = (USE_TLS ? https : http).request(
    { ...UPSTREAM, method, path, headers },
    (upstreamRes) => {
      const status = upstreamRes.statusCode || 502;

      if (status >= 400 && ALLOW_FALLBACK && attempt === 0 && parsedBody) {
        // 硬失败：去掉注入重试一次，让请求退回默认（私有池）路径。
        upstreamRes.resume();
        log(`${label} HTTP ${status}，按 CLINE_PIN_FALLBACK=1 去掉注入重试`);
        forward({
          method,
          path,
          headers: { ...headers, 'content-length': String(rawPayload.length) },
          payload: rawPayload,
          label: `${label}[fallback]`,
          attempt: 1,
          res,
          parsedBody: null,
          rawPayload,
        });
        return;
      }

      const outHeaders = {};
      for (const [k, v] of Object.entries(upstreamRes.headers)) {
        if (HOP_BY_HOP.has(k) || k === 'content-length' || k === 'content-encoding') continue;
        outHeaders[k] = v;
      }
      res.writeHead(status, outHeaders);

      const isStream = String(upstreamRes.headers['content-type'] || '').includes('text/event-stream');
      if (isStream) stats.streamed++;

      let tail = '';
      let seen = false;

      upstreamRes.on('data', (chunk) => {
        res.write(chunk);
        // 路由元数据可能被 chunk 边界切开，因此保留一段滚动缓冲。
        tail = (tail + chunk.toString('utf8')).slice(-8192);
        if (!seen) {
          const m = /"finalProvider":"([^"]+)"/.exec(tail);
          if (m) {
            seen = true;
            recordProvider(label, m[1]);
          }
        }
      });

      upstreamRes.on('end', () => {
        res.end();
        if (!seen) {
          // 非流式响应、或者流里没带 provider_metadata
          const m = /"finalProvider":"([^"]+)"/.exec(tail);
          if (m) recordProvider(label, m[1]);
          else {
            stats.unverified++;
            log(`${label} HTTP ${status} 无 provider_metadata（可能是错误响应），length=${tail.length}`);
          }
        }
      });

      upstreamRes.on('error', (e) => {
        stats.lastError = e.message;
        log(`${label} upstream stream error: ${e.message}`);
        res.end();
      });
    }
  );

  upstreamReq.on('error', (e) => {
    stats.lastError = e.message;
    log(`${label} upstream error: ${e.message}`);
    if (!res.headersSent) {
      res.writeHead(502, { 'content-type': 'application/json' });
    }
    res.end(JSON.stringify({ error: { message: `cline-pin upstream error: ${e.message}` } }));
  });

  upstreamReq.end(payload);
}

const server = http.createServer(async (req, res) => {
  const path = req.url || '/';

  if (path === '/_health' || path === '/health') {
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(
      JSON.stringify(
        {
          ok: true,
          upstream: UPSTREAM_URL.origin,
          pin: { only: ONLY, extraHas: EXTRA_HAS, fallback: ALLOW_FALLBACK, modelFilter: MODEL_FILTER, authOverride: Boolean(API_KEY) },
          logFile: LOG_FILE,
          stats,
        },
        null,
        2
      )
    );
    return;
  }

  stats.requests++;

  let raw = Buffer.alloc(0);
  try {
    raw = await collectBody(req);
  } catch (e) {
    stats.lastError = e.message;
    res.writeHead(413, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { message: e.message } }));
    return;
  }

  const label = `${req.method} ${path}`;
  let payload = raw;
  let parsedBody = null;
  let rawPayload = raw;

  if (raw.length > 0 && path.includes('chat/completions')) {
    try {
      parsedBody = JSON.parse(raw.toString('utf8'));
    } catch {
      log(`${label} 请求体不是 JSON，原样透传`);
      parsedBody = null;
    }

    if (parsedBody && parsedBody.providerOptions !== 'skip-pin') {
      if (shouldPin(parsedBody)) {
        const injected = inject(parsedBody);
        payload = Buffer.from(JSON.stringify(injected));
        stats.injected++;
        access(
          `${label} inject model=${injected.model} only=${JSON.stringify(ONLY)} has=${JSON.stringify(
            injected.providerOptions.gateway.has
          )}`
        );
      } else {
        stats.skipped++;
        access(`${label} skip inject model=${parsedBody.model}（不符合 model_filter=${
          MODEL_FILTER || '*'
        }）`);
      }
    }
  }

  forward({
    method: req.method || 'POST',
    path,
    headers: buildHeaders(req, payload.length),
    payload,
    label,
    attempt: 0,
    res,
    parsedBody,
    rawPayload,
  });
});

server.on('clientError', (err, socket) => {
  stats.lastError = err.message;
  if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\n\r\n');
});

server.listen(PORT, HOST, () => {
  console.log(`cline-pin 已启动: http://${HOST}:${PORT}`);
  console.log(`  转发到     : ${UPSTREAM_URL.origin}`);
  console.log(`  注入 only  : ${JSON.stringify(ONLY)}`);
  console.log(`  额外 has   : ${JSON.stringify(EXTRA_HAS)}`);
  console.log(`  模型过滤   : ${MODEL_FILTER || '(不过滤)'}`);
  console.log(`  日志文件   : ${LOG_FILE ?? '(仅控制台)'}`);
  console.log(`  失败回退   : ${ALLOW_FALLBACK ? '开（会退回私有池）' : '关（钉不住就报错，建议保持关闭）'}`);
  console.log(`  强制 key   : ${API_KEY ? '开（覆盖客户端的 Authorization）' : '关（透传客户端 key）'}`);
  console.log(`  健康检查   : http://${HOST}:${PORT}/_health`);
  console.log(`  控制台     : 只报异常和未钉住（逐请求日志只写文件）`);
  console.log('');
  console.log('Zed settings.json 里把 cline provider 的 api_url 改成:');
  console.log(`  "api_url": "http://${HOST}:${PORT}/api/v1"`);
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    access('shutdown', JSON.stringify(stats));
    logStream?.end();
    server.close(() => process.exit(0));
  });
}
