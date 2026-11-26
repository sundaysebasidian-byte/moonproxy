#!/usr/bin/env node
// Loads compiled plugins into a small proxy-wasm host written in JS and
// drives them through the raw ABI, to check the parts that only exist in
// the wasm build: the import signatures, the memory protocol
// (proxy_on_memory_allocate, out-parameters, header map serialisation,
// buffers handed over by the host) and reference counting (memory must stay
// flat over many requests). The emulator tests cover behaviour; this covers
// the bytes crossing the boundary.
// Usage: node scripts/ffi_test.cjs <dir with minimal.wasm, pii_mask.wasm, rate_limit.wasm>
'use strict';
const fs = require('fs');
const path = require('path');

const dir = process.argv[2] || 'plugins';
const OK = 0, NOT_FOUND = 1, BAD_ARGUMENT = 2, CAS_MISMATCH = 8, UNIMPLEMENTED = 12;
const enc = new TextEncoder(), dec = new TextDecoder();
let failures = 0, checks = 0;

function check(name, cond, detail) {
  checks++;
  if (cond) {
    console.log('PASS ' + name);
  } else {
    failures++;
    console.log('FAIL ' + name + (detail === undefined ? '' : '  [' + JSON.stringify(detail) + ']'));
  }
}

function serializePairs(pairs) {
  const parts = pairs.map(([k, v]) => [enc.encode(k), enc.encode(v)]);
  let size = 4 + parts.length * 8;
  for (const [k, v] of parts) size += k.length + v.length + 2;
  const out = new Uint8Array(size);
  const dv = new DataView(out.buffer);
  dv.setUint32(0, parts.length, true);
  let p = 4 + parts.length * 8;
  parts.forEach(([k, v], i) => {
    dv.setUint32(4 + i * 8, k.length, true);
    dv.setUint32(8 + i * 8, v.length, true);
    out.set(k, p); p += k.length + 1;
    out.set(v, p); p += v.length + 1;
  });
  return out;
}

function parsePairs(bytes) {
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const n = dv.getUint32(0, true);
  let p = 4 + n * 8;
  const out = [];
  for (let i = 0; i < n; i++) {
    const kl = dv.getUint32(4 + i * 8, true), vl = dv.getUint32(8 + i * 8, true);
    const k = dec.decode(bytes.subarray(p, p + kl)); p += kl + 1;
    const v = dec.decode(bytes.subarray(p, p + vl)); p += vl + 1;
    out.push([k, v]);
  }
  return out;
}

class Host {
  constructor(file, config) {
    this.config = enc.encode(JSON.stringify(config || {}));
    this.maps = {};        // map type -> [[k, v]]
    this.buffers = {};     // buffer type -> Uint8Array
    this.shared = new Map(); // key -> {value, cas}
    this.cas = 0;
    this.metrics = [];
    this.logs = [];
    this.local = null;
    this.properties = {};
    this.hostAllocations = 0;
    this.calls = [];
    this.lastToken = 0;
    this.effective = [];
    this.continued = [];
    const module = new WebAssembly.Module(fs.readFileSync(file));
    const env = {};
    for (const imp of WebAssembly.Module.imports(module)) {
      if (imp.kind !== 'function') continue;
      const impl = this[imp.name];
      env[imp.name] = impl ? impl.bind(this) : () => UNIMPLEMENTED;
    }
    this.instance = new WebAssembly.Instance(module, { env });
    this.x = this.instance.exports;
    if (this.x._start) this.x._start();
  }
  get mem() { return new Uint8Array(this.x.memory.buffer); }
  get dv() { return new DataView(this.x.memory.buffer); }
  read(ptr, len) { return this.mem.slice(ptr, ptr + len); }
  str(ptr, len) { return dec.decode(this.read(ptr, len)); }
  // Hand bytes to the plugin the way Envoy does: in memory it allocates.
  // Like proxy-wasm-cpp-host's copyToPointerSize: nothing is allocated for
  // empty data, the plugin gets pointer 0 and size 0.
  give(bytes, retPtr, retLen) {
    let p = 0;
    if (bytes.length > 0) {
      p = this.x.proxy_on_memory_allocate(bytes.length);
      this.hostAllocations++;
      if (p === 0) throw new Error('proxy_on_memory_allocate returned 0');
      this.mem.set(bytes, p);
    }
    this.dv.setUint32(retPtr, p, true);
    this.dv.setUint32(retLen, bytes.length, true);
    return OK;
  }

  // ---- env imports (only those the test plugins use) ----
  proxy_log(level, ptr, len) { this.logs.push(this.str(ptr, len)); return OK; }
  proxy_get_log_level(ret) { this.dv.setUint32(ret, 0, true); return OK; }
  proxy_get_current_time_nanoseconds(ret) {
    this.dv.setBigUint64(ret, BigInt(Date.now()) * 1000000n, true);
    return OK;
  }
  proxy_get_buffer_bytes(kind, start, max, retPtr, retLen) {
    // Envoy serves the plugin configuration only during proxy_on_configure.
    const buf = kind === 7 ? (this.configuring ? this.config : null) : this.buffers[kind];
    if (!buf) return NOT_FOUND;
    // sizes are u32 on the wire; the SDK asks for 0x7fffffff ("all")
    return this.give(buf.subarray(start >>> 0, (start >>> 0) + (max >>> 0)), retPtr, retLen);
  }
  proxy_set_buffer_bytes(kind, start, size, ptr, len) {
    const old = this.buffers[kind] || new Uint8Array();
    const data = this.read(ptr, len);
    if (start === 0 && (size >>> 0) >= old.length) this.buffers[kind] = data;
    else return BAD_ARGUMENT;
    return OK;
  }
  proxy_get_header_map_pairs(kind, retPtr, retLen) {
    return this.give(serializePairs(this.maps[kind] || []), retPtr, retLen);
  }
  proxy_set_header_map_pairs(kind, ptr, len) {
    this.maps[kind] = parsePairs(this.read(ptr, len));
    return OK;
  }
  proxy_get_header_map_value(kind, kp, kl, retPtr, retLen) {
    const k = this.str(kp, kl);
    const hit = (this.maps[kind] || []).find((e) => e[0] === k);
    if (!hit) return NOT_FOUND;
    return this.give(enc.encode(hit[1]), retPtr, retLen);
  }
  proxy_add_header_map_value(kind, kp, kl, vp, vl) {
    (this.maps[kind] = this.maps[kind] || []).push([this.str(kp, kl), this.str(vp, vl)]);
    return OK;
  }
  proxy_replace_header_map_value(kind, kp, kl, vp, vl) {
    const k = this.str(kp, kl);
    const m = (this.maps[kind] || []).filter((e) => e[0] !== k);
    m.push([k, this.str(vp, vl)]);
    this.maps[kind] = m;
    return OK;
  }
  proxy_remove_header_map_value(kind, kp, kl) {
    const k = this.str(kp, kl);
    this.maps[kind] = (this.maps[kind] || []).filter((e) => e[0] !== k);
    return OK;
  }
  proxy_get_property(pp, pl, retPtr, retLen) {
    const key = this.str(pp, pl).split('\0').filter((s) => s).join('.');
    if (!(key in this.properties)) return NOT_FOUND;
    return this.give(enc.encode(this.properties[key]), retPtr, retLen);
  }
  proxy_get_shared_data(kp, kl, retPtr, retLen, retCas) {
    const e = this.shared.get(this.str(kp, kl));
    if (!e) return NOT_FOUND;
    this.dv.setUint32(retCas, e.cas, true);
    return this.give(e.value, retPtr, retLen);
  }
  proxy_set_shared_data(kp, kl, vp, vl, cas) {
    const k = this.str(kp, kl);
    const e = this.shared.get(k);
    if (cas !== 0 && e && e.cas !== cas) return CAS_MISMATCH;
    this.shared.set(k, { value: this.read(vp, vl), cas: ++this.cas });
    return OK;
  }
  proxy_define_metric(type, np, nl, retId) {
    this.metrics.push({ name: this.str(np, nl), value: 0n });
    this.dv.setUint32(retId, this.metrics.length - 1, true);
    return OK;
  }
  proxy_increment_metric(id, delta) {
    if (typeof delta !== 'bigint') return BAD_ARGUMENT; // i64 must arrive as i64
    this.metrics[id].value += delta;
    return OK;
  }
  proxy_record_metric(id, value) { this.metrics[id].value = BigInt.asUintN(64, value); return OK; }
  proxy_send_local_response(code, dp, dl, bp, bl, hp, hl, grpc) {
    this.local = {
      code,
      details: this.str(dp, dl),
      body: this.str(bp, bl),
      headers: parsePairs(this.read(hp, hl)),
    };
    return OK;
  }
  proxy_http_call(up, ul, hp, hl, bp, bl, tp, tl, timeout, retToken) {
    const token = ++this.lastToken;
    this.calls.push({
      token,
      upstream: this.str(up, ul),
      headers: parsePairs(this.read(hp, hl)),
      body: this.str(bp, bl),
      timeout,
    });
    this.dv.setUint32(retToken, token, true);
    return OK;
  }
  proxy_set_effective_context(id) { this.effective.push(id); return OK; }
  proxy_continue_stream(kind) { this.continued.push(kind); return OK; }

  metric(name) {
    const m = this.metrics.find((e) => e.name === name);
    return m ? Number(m.value) : undefined;
  }
  start() {
    this.x.proxy_on_context_create(1, 0);
    if (this.x.proxy_on_vm_start(1, 0) !== 1) return false;
    this.configuring = true;
    try {
      return this.x.proxy_on_configure(1, this.config.length) === 1;
    } finally {
      this.configuring = false;
    }
  }
  // Envoy's order for an HTTP stream: log, then done, then delete.
  finish(id) {
    this.x.proxy_on_log(id);
    this.x.proxy_on_done(id);
    this.x.proxy_on_delete(id);
  }
}

function load(name, config) {
  const file = path.join(dir, name + '.wasm');
  const h = new Host(file, config);
  check(`${name}: starts`, h.start(), h.logs);
  return h;
}

// Memory must stop growing once the allocator has warmed up: a leaked
// header string or a missing decref would add up over the requests.
function flat(name, h, run) {
  for (let i = 0; i < 2000; i++) run(i);
  const before = h.x.memory.buffer.byteLength;
  for (let i = 2000; i < 22000; i++) run(i);
  const after = h.x.memory.buffer.byteLength;
  check(`${name}: memory flat over 20000 requests`, after - before <= 65536, { before, after });
}

function testMinimal() {
  const h = load('minimal');
  let id = 2;
  const request = (headers) => {
    const ctx = id++;
    h.local = null;
    h.maps = { 0: headers };
    h.x.proxy_on_context_create(ctx, 1);
    const action = h.x.proxy_on_request_headers(ctx, headers.length, 0);
    h.finish(ctx);
    return action;
  };
  check('minimal: allowed request continues', request([[':path', '/'], ['x-api-key', 'k']]) === 0);
  check('minimal: header added through add_header_map_value',
    JSON.stringify(h.maps[0]) === JSON.stringify([[':path', '/'], ['x-api-key', 'k'], ['x-checked-by', 'moonbit']]),
    h.maps[0]);
  check('minimal: missing key pauses', request([[':path', '/']]) === 1);
  check('minimal: local response carries status and body',
    h.local && h.local.code === 401 && h.local.body === 'missing key', h.local);
  flat('minimal', h, (i) => request(i % 2 ? [[':path', '/' + i], ['x-api-key', 'k' + i]] : [[':path', '/']]));
}

function testPiiMask() {
  const h = load('pii_mask');
  let id = 2;
  const respond = (body) => {
    const ctx = id++;
    h.maps = { 0: [['accept-encoding', 'gzip']], 2: [['content-type', 'application/json']] };
    h.buffers = { 1: enc.encode(body) };
    h.x.proxy_on_context_create(ctx, 1);
    h.x.proxy_on_request_headers(ctx, 1, 0);
    h.x.proxy_on_response_headers(ctx, 1, 0);
    const action = h.x.proxy_on_response_body(ctx, h.buffers[1].length, 1);
    h.finish(ctx);
    return [action, dec.decode(h.buffers[1])];
  };
  const [action, out] = respond('{"tel":"13812345678","mail":"alice@example.com"}');
  check('pii_mask: request lost accept-encoding', (h.maps[0] || []).length === 0, h.maps[0]);
  check('pii_mask: body read from host memory and written back masked',
    action === 0 && out === '{"tel":"138****5678","mail":"a****@example.com"}', out);
  check('pii_mask: metric incremented with an i64', h.metric('pii_mask.masked_responses') === 1, h.metrics);
  const big = 'x'.repeat(100000) + ' 13812345678';
  check('pii_mask: 100 KB body survives the round trip', respond(big)[1] === 'x'.repeat(100000) + ' 138****5678');
  flat('pii_mask', h, (i) => respond(`{"n":${i},"tel":"13812345678"}`));
}

function testRateLimit() {
  const h = load('rate_limit', { rate_per_second: 1, burst: 3 });
  h.properties['source.address'] = '10.1.2.3:4567';
  let id = 2;
  const request = () => {
    const ctx = id++;
    h.local = null;
    h.maps = { 0: [[':path', '/']] };
    h.x.proxy_on_context_create(ctx, 1);
    const action = h.x.proxy_on_request_headers(ctx, 1, 0);
    h.finish(ctx);
    return action;
  };
  const got = [request(), request(), request(), request()];
  check('rate_limit: burst then 429 through shared data and CAS', JSON.stringify(got) === '[0,0,0,1]', got);
  check('rate_limit: 429 has retry-after',
    h.local && h.local.code === 429 && h.local.headers.some(([k]) => k === 'retry-after'), h.local);
  check('rate_limit: one bucket written', h.shared.size === 1, [...h.shared.keys()]);
  flat('rate_limit', h, () => request());
}

function testExtAuthz() {
  const h = load('ext_authz', {
    cluster: 'authz', authority: 'authz', path: '/check', timeout_ms: 700,
    forward: ['authorization'], copy_back: ['x-user-id'],
  });
  let id = 2;
  // One request through the whole callout path: proxy_http_call, the
  // response read from header map 6 and buffer 4, the switch back to the
  // stream, then resume or local reply.
  const request = (status, extra) => {
    const ctx = id++;
    h.local = null;
    h.calls = []; h.effective = []; h.continued = [];
    h.maps = { 0: [[':method', 'GET'], [':path', '/orders'], ['authorization', 'Bearer t'], ['x-user-id', 'forged']] };
    h.x.proxy_on_context_create(ctx, 1);
    const action = h.x.proxy_on_request_headers(ctx, 4, 0);
    const call = h.calls[0];
    if (call) {
      h.maps[6] = [[':status', String(status)], ...(extra || [])];
      h.buffers[4] = enc.encode(status === 403 ? 'denied' : '');
      h.x.proxy_on_http_call_response(1, call.token, h.maps[6].length, h.buffers[4].length, 0);
      delete h.maps[6]; delete h.buffers[4];
    }
    h.finish(ctx);
    return { ctx, action, call };
  };
  const ok = request(200, [['x-user-id', 'u-1']]);
  check('ext_authz: headers pause while the callout runs', ok.action === 1, ok.action);
  check('ext_authz: callout goes to the cluster with forwarded headers and timeout',
    ok.call && ok.call.upstream === 'authz' && ok.call.timeout === 700 &&
    ok.call.headers.some(([k, v]) => k === 'authorization' && v === 'Bearer t') &&
    ok.call.headers.some(([k, v]) => k === ':path' && v === '/check'), ok.call);
  check('ext_authz: answer handled in the context that made the call',
    h.effective.includes(ok.ctx), h.effective);
  check('ext_authz: allowed request resumed', JSON.stringify(h.continued) === '[0]', h.continued);
  check('ext_authz: identity copied back, forged copy gone',
    JSON.stringify(h.maps[0].filter(([k]) => k === 'x-user-id')) === '[["x-user-id","u-1"]]', h.maps[0]);
  const no = request(403);
  check('ext_authz: denial replied locally with the service body',
    h.local && h.local.code === 403 && h.local.body === 'denied' && h.continued.length === 0, h.local);
  flat('ext_authz', h, (i) => request(i % 3 ? 200 : 403, [['x-user-id', 'u' + i]]));
}

function testAiGuard() {
  const h = load('ai_guard', { allowed_models: ['m'], max_tokens: 64 });
  let id = 2;
  const post = (body) => {
    const ctx = id++;
    h.local = null;
    h.maps = { 0: [[':method', 'POST'], [':path', '/v1/chat/completions'], ['content-length', '9']] };
    h.buffers = { 0: enc.encode(body) };
    h.x.proxy_on_context_create(ctx, 1);
    const head = h.x.proxy_on_request_headers(ctx, 3, 0);
    const action = h.x.proxy_on_request_body(ctx, h.buffers[0].length, 1);
    h.finish(ctx);
    return { head, action, out: dec.decode(h.buffers[0]) };
  };
  const ok = post('{"model":"m","max_tokens":1000,"messages":[]}');
  check('ai_guard: headers continue, content-length removed',
    ok.head === 0 && !h.maps[0].some(([k]) => k === 'content-length'), h.maps[0]);
  check('ai_guard: body rewritten in host memory',
    ok.action === 0 && ok.out === '{"model":"m","max_tokens":64,"messages":[]}', ok.out);
  const bad = post('{"model":"x","messages":[]}');
  check('ai_guard: disallowed model is a 400', bad.action === 1 && h.local && h.local.code === 400, h.local);
  flat('ai_guard', h, (i) => post(`{"model":"${i % 2 ? 'm' : 'x'}","max_tokens":${i},"messages":[]}`));
}

// Every example module must instantiate against this host's import list
// and start with its documented configuration.
function testAllLoad() {
  const configs = {
    http_headers: {}, api_key_auth: { keys: { k: 'a' } }, tcp_quota: { max_bytes: 1024 },
  };
  for (const [name, config] of Object.entries(configs)) {
    if (fs.existsSync(path.join(dir, name + '.wasm'))) load(name, config);
    else check(`${name}: module built`, false);
  }
}

for (const t of [testMinimal, testPiiMask, testRateLimit, testExtAuthz, testAiGuard, testAllLoad]) {
  try {
    t();
  } catch (e) {
    failures++;
    console.log('FAIL ' + t.name + ' threw: ' + (e && e.stack || e));
  }
}
console.log(`\n${checks - failures}/${checks} checks passed`);
process.exit(failures ? 1 : 0);
