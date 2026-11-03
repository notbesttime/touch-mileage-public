#!/usr/bin/env node
// 触控里程 · 无障碍能力自证工具
// 不解包成工程、不信任任何说明文字，直接从你手上的 APK 里读出它到底申请了什么能力。
// 零依赖：只用 Node 内置模块（fs / zlib / crypto），不需要 Android SDK。
//
// 用法：
//   node verify_a11y.mjs <app-release.apk>            人类可读报告
//   node verify_a11y.mjs <app-release.apk> --json     机器可读
//   node verify_a11y.mjs <app-release.apk> --selftest 自检：证明这个工具不是永远说 PASS
//
// 退出码：0 = 通过，1 = 需人工核对，2 = 用法错误，3 = 文件读不了

import fs from 'node:fs';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

// ---------- zip ----------
function readZip(buf) {
  let eocd = -1;
  for (let i = buf.length - 22; i >= 0 && i > buf.length - 66000; i--) {
    if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('不是有效的 zip/apk 文件');
  const count = buf.readUInt16LE(eocd + 10);
  let off = buf.readUInt32LE(eocd + 16);
  const entries = new Map();
  for (let k = 0; k < count; k++) {
    if (buf.readUInt32LE(off) !== 0x02014b50) break;
    const method = buf.readUInt16LE(off + 10);
    const csize = buf.readUInt32LE(off + 20);
    const nlen = buf.readUInt16LE(off + 28);
    const elen = buf.readUInt16LE(off + 30);
    const clen = buf.readUInt16LE(off + 32);
    const lho = buf.readUInt32LE(off + 42);
    const name = buf.toString('utf8', off + 46, off + 46 + nlen);
    entries.set(name, { method, csize, lho });
    off += 46 + nlen + elen + clen;
  }
  return entries;
}

function extract(buf, e) {
  const nlen = buf.readUInt16LE(e.lho + 26);
  const elen = buf.readUInt16LE(e.lho + 28);
  const start = e.lho + 30 + nlen + elen;
  const data = buf.subarray(start, start + e.csize);
  if (e.method === 0) return Buffer.from(data);
  if (e.method === 8) return zlib.inflateRawSync(data);
  throw new Error('不支持的压缩方式: ' + e.method);
}

// ---------- Android 二进制 XML ----------
function parseAxml(b) {
  if (b.length < 8 || b.readUInt16LE(0) !== 0x0003) throw new Error('不是 Android 二进制 XML');
  let p = b.readUInt16LE(2);
  const strings = [];
  const resMap = [];
  const elements = [];
  while (p + 8 <= b.length) {
    const type = b.readUInt16LE(p);
    const hsize = b.readUInt16LE(p + 2);
    const size = b.readUInt32LE(p + 4);
    if (size <= 0 || p + size > b.length) break;

    if (type === 0x0001) {                       // string pool
      const scount = b.readUInt32LE(p + 8);
      const flags = b.readUInt32LE(p + 16);
      const sstart = b.readUInt32LE(p + 20);
      const utf8 = (flags & 0x100) !== 0;
      for (let i = 0; i < scount; i++) {
        const o = b.readUInt32LE(p + hsize + i * 4);
        let q = p + sstart + o;
        if (utf8) {
          let l1 = b[q++]; if (l1 & 0x80) l1 = ((l1 & 0x7f) << 8) | b[q++];
          let l2 = b[q++]; if (l2 & 0x80) l2 = ((l2 & 0x7f) << 8) | b[q++];
          strings.push(b.toString('utf8', q, q + l2));
        } else {
          let l = b.readUInt16LE(q); q += 2;
          if (l & 0x8000) { l = ((l & 0x7fff) << 16) | b.readUInt16LE(q); q += 2; }
          strings.push(b.toString('utf16le', q, q + l * 2));
        }
      }
    } else if (type === 0x0180) {                 // resource map
      const n = Math.floor((size - hsize) / 4);
      for (let i = 0; i < n; i++) resMap.push(b.readUInt32LE(p + hsize + i * 4));
    } else if (type === 0x0102) {                 // start element
      const nameIdx = b.readInt32LE(p + hsize + 4);
      const attrStart = b.readUInt16LE(p + hsize + 8);
      const attrSize = b.readUInt16LE(p + hsize + 10);
      const attrCount = b.readUInt16LE(p + hsize + 12);
      const attrs = [];
      for (let i = 0; i < attrCount; i++) {
        const a = p + hsize + attrStart + i * attrSize;
        const aname = b.readInt32LE(a + 4);
        const araw = b.readInt32LE(a + 8);
        const dtype = b.readUInt8(a + 15);
        const data = b.readInt32LE(a + 16);
        attrs.push({
          name: aname >= 0 ? strings[aname] : null,
          resId: (aname >= 0 && aname < resMap.length) ? resMap[aname] : 0,
          raw: araw >= 0 ? strings[araw] : null,
          dtype, data,
          dataOffset: a + 16,
        });
      }
      elements.push({ name: strings[nameIdx] || ('#element' + nameIdx), attrs });
    }
    p += size;
  }
  return elements;
}

// ---------- 事件类型 ----------
const EVENTS = [
  [0x00000001, 'TYPE_VIEW_CLICKED', '点击'],
  [0x00000002, 'TYPE_VIEW_LONG_CLICKED', '长按'],
  [0x00000004, 'TYPE_VIEW_SELECTED', '选中'],
  [0x00000008, 'TYPE_VIEW_FOCUSED', '获得焦点'],
  [0x00000010, 'TYPE_VIEW_TEXT_CHANGED', '文字变化'],
  [0x00000020, 'TYPE_WINDOW_STATE_CHANGED', '窗口状态变化（前台应用切换）'],
  [0x00000040, 'TYPE_NOTIFICATION_STATE_CHANGED', '通知变化'],
  [0x00000080, 'TYPE_VIEW_HOVER_ENTER', '悬停进入'],
  [0x00000100, 'TYPE_VIEW_HOVER_EXIT', '悬停离开'],
  [0x00000200, 'TYPE_TOUCH_EXPLORATION_GESTURE_START', '触摸探索开始'],
  [0x00000400, 'TYPE_TOUCH_EXPLORATION_GESTURE_END', '触摸探索结束'],
  [0x00000800, 'TYPE_WINDOW_CONTENT_CHANGED', '窗口内容变化'],
  [0x00001000, 'TYPE_VIEW_SCROLLED', '滚动'],
  [0x00002000, 'TYPE_VIEW_TEXT_SELECTION_CHANGED', '文字选区变化'],
  [0x00004000, 'TYPE_ANNOUNCEMENT', '无障碍播报'],
  [0x00008000, 'TYPE_VIEW_ACCESSIBILITY_FOCUSED', '无障碍焦点'],
  [0x00010000, 'TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED', '无障碍焦点清除'],
  [0x00020000, 'TYPE_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY', '文字逐字遍历'],
  [0x00040000, 'TYPE_GESTURE_DETECTION_START', '手势检测开始'],
  [0x00080000, 'TYPE_GESTURE_DETECTION_END', '手势检测结束'],
  [0x00100000, 'TYPE_TOUCH_INTERACTION_START', '手指按下'],
  [0x00200000, 'TYPE_TOUCH_INTERACTION_END', '手指抬起'],
  [0x00400000, 'TYPE_WINDOWS_CHANGED', '窗口列表变化'],
  [0x00800000, 'TYPE_VIEW_CONTEXT_CLICKED', '上下文点击'],
  [0x01000000, 'TYPE_ASSIST_READING_CONTEXT', '读屏辅助'],
];
const ALL_BITS = EVENTS.reduce((s, [b]) => s | b, 0);

// 会碰到「内容」或「代替操作」的能力，出现即报警
const DANGEROUS = {
  0x01010385: ['canRetrieveWindowContent', '读取窗口内容（能拿到屏幕上的文字与控件树）'],
  0x01010514: ['canPerformGestures', '代替用户执行手势（能自己点屏幕）'],
  0x0101054e: ['canRequestFilterKeyEvents', '拦截按键（能拿到你输入的每一个键）'],
  0x0101054f: ['canRequestTouchExplorationMode', '触摸探索模式'],
  0x01010551: ['canControlMagnification', '控制屏幕放大'],
};

function attrVal(a) {
  if (!a) return null;
  if (a.dtype === 0x03) return a.raw != null ? a.raw : a.data;
  if (a.dtype === 0x12) return a.data !== 0;
  if (a.dtype === 0x11) return a.data >>> 0;
  if (a.dtype === 0x10) return a.data;
  if (a.dtype === 0x01) return '@ref:0x' + (a.data >>> 0).toString(16);
  return a.raw != null ? a.raw : a.data;
}
const byResId = (el, id) => el.attrs.find(a => a.resId === id) || null;
const byName = (el, n) => el.attrs.find(a => a.name === n) || null;

// ---------- 从元素得出能力摘要 ----------
function summarize(el) {
  const crwc = byResId(el, 0x01010385) || byName(el, 'canRetrieveWindowContent');
  const evts = byResId(el, 0x01010380) || byName(el, 'accessibilityEventTypes');
  const fb = byResId(el, 0x01010382) || byName(el, 'accessibilityFeedbackType');
  const to = byResId(el, 0x01010383) || byName(el, 'notificationTimeout');
  const evMask = evts ? (Number(attrVal(evts)) >>> 0) : 0;
  return {
    canRetrieveWindowContent: crwc ? attrVal(crwc) : null,
    eventMask: evMask,
    eventMaskHex: '0x' + evMask.toString(16).padStart(8, '0'),
    events: EVENTS.filter(([bit]) => (evMask & bit) !== 0)
                  .map(([bit, n, cn]) => ({ bit: '0x' + bit.toString(16).padStart(8, '0'), name: n, cn })),
    unknownBits: (evMask & ~ALL_BITS) >>> 0,
    feedbackType: fb ? '0x' + (Number(attrVal(fb)) >>> 0).toString(16).padStart(8, '0') : null,
    notificationTimeout: to ? attrVal(to) : null,
    otherAttrs: el.attrs
      .filter(a => ![0x01010385, 0x01010380, 0x01010382, 0x01010383].includes(a.resId))
      .map(a => ({ name: a.name || '0x' + a.resId.toString(16), value: String(attrVal(a)) })),
  };
}

// ---------- 判定 ----------
function judge(el, s) {
  const problems = [];
  if (s.canRetrieveWindowContent !== false) {
    problems.push('canRetrieveWindowContent 不是 false —— 该服务有能力读取屏幕内容');
  }
  for (const a of el.attrs) {
    const d = DANGEROUS[a.resId];
    if (d) {
      const v = attrVal(a);
      if (v !== false && v !== 0) problems.push(d[0] + ' = ' + v + ' —— ' + d[1]);
    }
  }
  if (s.unknownBits !== 0) {
    problems.push('存在未识别的事件位 0x' + s.unknownBits.toString(16) + '，需人工核对');
  }
  return problems;
}

// ---------- 主流程 ----------
const args = process.argv.slice(2);
const apkPath = args.find(a => !a.startsWith('--'));
const asJson = args.includes('--json');
const selfTest = args.includes('--selftest');

if (!apkPath) {
  console.error('用法: node verify_a11y.mjs <app-release.apk> [--json] [--selftest]');
  process.exit(2);
}

const raw = fs.readFileSync(apkPath);
const zip = readZip(raw);
const result = {
  apk: apkPath,
  bytes: raw.length,
  sha256: crypto.createHash('sha256').update(raw).digest('hex'),
  package: null, versionName: null, versionCode: null,
  permissions: [],
  a11y: null,
  verdict: null,
  problems: [],
};

if (zip.has('AndroidManifest.xml')) {
  const els = parseAxml(extract(raw, zip.get('AndroidManifest.xml')));
  const man = els.find(e => e.name === 'manifest');
  if (man) {
    const pk = byName(man, 'package');
    const vn = byName(man, 'versionName');
    const vc = byName(man, 'versionCode') || byResId(man, 0x0101021b);
    result.package = pk ? attrVal(pk) : null;
    result.versionName = vn ? attrVal(vn) : null;
    result.versionCode = vc ? attrVal(vc) : null;
  }
  for (const e of els.filter(x => x.name === 'uses-permission')) {
    const n = byName(e, 'name') || byResId(e, 0x01010003);
    const v = n ? attrVal(n) : null;
    if (v) result.permissions.push(String(v).replace('android.permission.', ''));
  }
}

let found = null;
for (const [name, e] of zip) {
  if (!name.endsWith('.xml')) continue;
  let els;
  try { els = parseAxml(extract(raw, e)); } catch { continue; }
  const svc = els.find(x => x.name === 'accessibility-service');
  if (svc) { found = { file: name, el: svc }; break; }
}

if (!found) {
  result.verdict = 'NO_A11Y_SERVICE';
  result.problems.push('APK 里没有无障碍服务声明');
} else {
  const s = summarize(found.el);
  result.a11y = { file: found.file, ...s };
  result.problems = judge(found.el, s);
  result.verdict = result.problems.length === 0 ? 'PASS' : 'REVIEW';
}

// ---------- 自检：证明这个工具会红 ----------
if (selfTest) {
  if (!found) {
    console.log('自检失败：这个 APK 里没有无障碍服务，无法自检');
    process.exit(1);
  }
  const buf = Buffer.from(extract(raw, zip.get(found.file)));
  const els0 = parseAxml(buf);
  const el0 = els0.find(x => x.name === 'accessibility-service');
  const target = el0.attrs.find(a => a.resId === 0x01010385);
  if (!target) {
    console.log('自检失败：没找到 canRetrieveWindowContent 属性');
    process.exit(1);
  }
  const before = attrVal(target);
  buf.writeInt32LE(1, target.dataOffset);          // 把 false 改成 true
  const els1 = parseAxml(buf);
  const el1 = els1.find(x => x.name === 'accessibility-service');
  const after = attrVal(el1.attrs.find(a => a.resId === 0x01010385));
  const probs = judge(el1, summarize(el1));

  console.log('自检 · 把一个 canRetrieveWindowContent=false 的 APK 改成 true，看工具会不会报警');
  console.log('  改之前 : ' + String(before));
  console.log('  改之后 : ' + String(after));
  console.log('  判定   : ' + (probs.length ? '⚠ 已报警 → ' + probs[0] : '✅ 没报警'));
  const ok = before === false && after === true && probs.length > 0;
  console.log('  结果   : ' + (ok ? '通过 —— 这个工具确实会红，不是摆设' : '失败 —— 检测逻辑有问题'));
  process.exit(ok ? 0 : 1);
}

// ---------- 输出 ----------
if (asJson) {
  console.log(JSON.stringify(result, null, 2));
} else {
  const L = [];
  L.push('触控里程 · 无障碍能力自证');
  L.push('='.repeat(58));
  L.push('APK      : ' + result.apk);
  L.push('大小     : ' + (result.bytes / 1024 / 1024).toFixed(2) + ' MB');
  L.push('SHA-256  : ' + result.sha256);
  L.push('包名     : ' + result.package);
  L.push('版本     : ' + result.versionName + ' (' + result.versionCode + ')');
  L.push('');
  L.push('申请的系统权限：');
  if (result.permissions.length === 0) L.push('  （无）');
  for (const p of result.permissions) L.push('  · ' + p);
  L.push('');
  if (result.a11y) {
    L.push('无障碍服务声明（APK 内 ' + result.a11y.file + '）：');
    L.push('  canRetrieveWindowContent = ' + String(result.a11y.canRetrieveWindowContent) +
           (result.a11y.canRetrieveWindowContent === false ? '   ← 不读取窗口内容' : '   ← ⚠ 危险'));
    L.push('  accessibilityEventTypes  = ' + result.a11y.eventMaskHex +
           '，共 ' + result.a11y.events.length + ' 种：');
    for (const e of result.a11y.events) {
      L.push('      ' + e.bit + '  ' + e.name.padEnd(42) + ' ' + e.cn);
    }
    if (result.a11y.notificationTimeout != null) {
      L.push('  notificationTimeout      = ' + result.a11y.notificationTimeout);
    }
    for (const o of result.a11y.otherAttrs) {
      L.push('  ' + String(o.name).padEnd(24) + ' = ' + o.value);
    }
    L.push('');
  }
  L.push('结论：' + (result.verdict === 'PASS'
    ? '✅ 该 APK 的无障碍服务没有声明读取屏幕内容的能力，事件类型仅为上述 ' +
      (result.a11y ? result.a11y.events.length : 0) + ' 种。'
    : '⚠ 需要人工核对，见下方问题。'));
  if (result.problems.length) {
    L.push('');
    L.push('问题：');
    for (const p of result.problems) L.push('  · ' + p);
  }
  L.push('');
  L.push('本结论只针对你手上这个 APK 文件的二进制内容，不依赖任何文字说明。');
  console.log(L.join('\n'));
}

process.exit(result.verdict === 'PASS' ? 0 : 1);
