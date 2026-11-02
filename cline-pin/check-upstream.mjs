#!/usr/bin/env node
/**
 * check-upstream: 验证请求到底落在哪个上游。
 *
 * 这个脚本故意不带 providerOptions，用来证明"注入是代理做的"而不是脚本做的。
 *
 * 用法：
 *   CLINE_KEY=sk-xxx node check-upstream.mjs
 *   CLINE_KEY=sk-xxx CLINE_BASE=http://127.0.0.1:8788/api/v1 node check-upstream.mjs
 *   CLINE_KEY=sk-xxx node check-upstream.mjs --count 5 --stream
 *
 * 环境变量：
 *   CLINE_KEY   必填，Cline Pass 的 API key
 *   CLINE_BASE  默认 https://api.cline.bot/api/v1，指向代理即可验证代理是否生效
 *   CLINE_MODEL 默认 cline-pass/deepseek-v4.1-flash-1017
 *
 * 退出码：全部命中期望上游 → 0，否则 1。
 */

const KEY = process.env.CLINE_KEY;
const BASE = (process.env.CLINE_BASE || 'https://api.cline.bot/api/v1').replace(/\/+$/, '');
const MODEL = process.env.CLINE_MODEL || 'cline-pass/deepseek-v4.1-flash-1017';
const EXPECT = process.env.CLINE_EXPECT || null;

const args = process.argv.slice(2);
const count = Number(argValue('--count') ?? 3);
const stream = args.includes('--stream');

function argValue(flag) {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : undefined;
}

if (!KEY) {
  console.error('缺少 CLINE_KEY 环境变量');
  process.exit(2);
}

const URL_ = `${BASE}/chat/completions`;

function extract(text) {
  const provider = /"finalProvider":"([^"]+)"/.exec(text)?.[1] ?? null;
  const resolved = /"resolvedProvider":"([^"]+)"/.exec(text)?.[1] ?? null;
  const planning = /"planningReasoning":"((?:[^"\\]|\\.)*)"/.exec(text)?.[1] ?? null;
  const cost = /"gatewayCost":"([^"]+)"/.exec(text)?.[1] ?? null;
  const err = /"message":"((?:[^"\\]|\\.){0,300})"/.exec(text)?.[1] ?? null;
  return { provider, resolved, planning, cost, err };
}

async function once(i) {
  const started = Date.now();
  const res = await fetch(URL_, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${KEY}` },
    body: JSON.stringify({
      model: MODEL,
      messages: [{ role: 'user', content: '只回复 OK' }],
      stream,
      max_tokens: 64,
    }),
    signal: AbortSignal.timeout(90000),
  });
  const text = await res.text();
  const info = extract(text);
  const ms = Date.now() - started;
  const ok = info.provider !== null && (!EXPECT || info.provider === EXPECT);
  console.log(
    `#${i} HTTP ${res.status} ${ms}ms final=${info.provider ?? '-'} resolved=${info.resolved ?? '-'} cost=${
      info.cost ?? '-'
    } ${ok ? 'OK' : 'UNEXPECTED'}`
  );
  if (!info.provider && info.err) console.log(`    error: ${info.err}`);
  if (info.planning) console.log(`    planning: ${info.planning.slice(0, 220)}`);
  return { ok, provider: info.provider };
}

const results = [];
for (let i = 1; i <= count; i++) results.push(await once(i));

const hits = results.filter((r) => r.ok).length;
const tally = results.reduce((m, r) => m.set(r.provider ?? 'none', (m.get(r.provider ?? 'none') ?? 0) + 1), new Map());
console.log(`\n${hits}/${results.length} 命中${EXPECT ? ` ${EXPECT}` : ''} · 分布: ${[...tally].map(([k, v]) => `${k}=${v}`).join(', ')}`);
process.exit(hits === results.length ? 0 : 1);
