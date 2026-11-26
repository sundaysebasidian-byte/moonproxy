#!/usr/bin/env node
// Checks that a compiled plugin is a module Envoy will load:
// - every proxy-wasm v0.2.1 entry point is exported with the exact ABI
//   signature (i32 parameters, one i32 result or none);
// - linear memory is exported as "memory";
// - every import comes from module "env" and is a proxy-wasm host call
//   (no WASI, no spectest printing).
// Usage: node scripts/check_wasm.cjs plugin.wasm [--allow-wasi]
'use strict';
const fs = require('fs');

// name -> [number of i32 params, returns i32]
const EXPORTS = {
  proxy_abi_version_0_2_1: [0, false],
  proxy_on_memory_allocate: [1, true],
  proxy_on_context_create: [2, false],
  proxy_on_vm_start: [2, true],
  proxy_on_configure: [2, true],
  proxy_on_tick: [1, false],
  proxy_on_queue_ready: [2, false],
  proxy_on_done: [1, true],
  proxy_on_log: [1, false],
  proxy_on_delete: [1, false],
  proxy_on_request_headers: [3, true],
  proxy_on_request_body: [3, true],
  proxy_on_request_trailers: [2, true],
  proxy_on_response_headers: [3, true],
  proxy_on_response_body: [3, true],
  proxy_on_response_trailers: [2, true],
  proxy_on_new_connection: [1, true],
  proxy_on_downstream_data: [3, true],
  proxy_on_downstream_connection_close: [2, false],
  proxy_on_upstream_data: [3, true],
  proxy_on_upstream_connection_close: [2, false],
  proxy_on_http_call_response: [5, false],
};

function reader(buf) {
  let p = 0;
  const r = {
    get pos() { return p; },
    set pos(v) { p = v; },
    byte: () => buf[p++],
    u32() {
      let result = 0, shift = 0, b;
      do { b = buf[p++]; result |= (b & 0x7f) << shift; shift += 7; } while (b & 0x80);
      return result >>> 0;
    },
    name() { const n = r.u32(); const s = buf.toString('utf8', p, p + n); p += n; return s; },
    limits() { const flag = r.u32(); r.u32(); if (flag & 1) r.u32(); },
  };
  return r;
}

function parse(buf) {
  if (buf.readUInt32LE(0) !== 0x6d736100) throw new Error('not a wasm module');
  const r = reader(buf);
  r.pos = 8;
  const types = [], funcs = [], imports = [], exports = [];
  let importedFuncs = 0;
  while (r.pos < buf.length) {
    const id = r.byte(), size = r.u32(), end = r.pos + size;
    if (id === 1) {
      for (let n = r.u32(); n > 0; n--) {
        if (r.byte() !== 0x60) throw new Error('unsupported type form');
        const params = []; for (let k = r.u32(); k > 0; k--) params.push(r.byte());
        const results = []; for (let k = r.u32(); k > 0; k--) results.push(r.byte());
        types.push({ params, results });
      }
    } else if (id === 2) {
      for (let n = r.u32(); n > 0; n--) {
        const module = r.name(), name = r.name(), kind = r.byte();
        let type = null;
        if (kind === 0) { type = r.u32(); funcs.push(type); importedFuncs++; }
        else if (kind === 1) { r.byte(); r.limits(); }
        else if (kind === 2) r.limits();
        else if (kind === 3) { r.byte(); r.byte(); }
        else throw new Error('unknown import kind ' + kind);
        imports.push({ module, name, kind, type });
      }
    } else if (id === 3) {
      for (let n = r.u32(); n > 0; n--) funcs.push(r.u32());
    } else if (id === 7) {
      for (let n = r.u32(); n > 0; n--) exports.push({ name: r.name(), kind: r.byte(), index: r.u32() });
    }
    r.pos = end;
  }
  return { types, funcs, imports, exports, importedFuncs };
}

function main() {
  const file = process.argv[2];
  const allowWasi = process.argv.includes('--allow-wasi');
  const m = parse(fs.readFileSync(file));
  const errors = [];
  const I32 = 0x7f;
  const byName = new Map(m.exports.map(e => [e.name, e]));
  for (const [name, [nparams, ret]] of Object.entries(EXPORTS)) {
    const e = byName.get(name);
    if (!e || e.kind !== 0) { errors.push(`missing export ${name}`); continue; }
    const t = m.types[m.funcs[e.index]];
    const ok = t.params.length === nparams && t.params.every(x => x === I32) &&
      (ret ? t.results.length === 1 && t.results[0] === I32 : t.results.length === 0);
    if (!ok) errors.push(`${name}: signature (${t.params}) -> (${t.results}), want ${nparams} x i32 -> ${ret ? 'i32' : 'nothing'}`);
  }
  const mem = byName.get('memory');
  if (!mem || mem.kind !== 2) errors.push('linear memory is not exported as "memory"');
  for (const i of m.imports) {
    const fromEnv = i.module === 'env' && i.name.startsWith('proxy_');
    const wasi = allowWasi && i.module.startsWith('wasi_snapshot_preview1');
    if (!fromEnv && !wasi) errors.push(`unexpected import ${i.module}.${i.name}`);
  }
  const hostcalls = m.imports.filter(i => i.module === 'env').map(i => i.name);
  console.log(`${file}: ${fs.statSync(file).size} bytes, ${m.exports.length} exports, ` +
    `${hostcalls.length} host calls imported`);
  if (errors.length) {
    for (const e of errors) console.error('  ' + e);
    process.exit(1);
  }
}

main();
