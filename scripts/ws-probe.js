// ws-probe.js — 检查 ttyd 是否真的能拉起会话
// 用法: node ws-probe.js [port]
// 输出: {"ok":true,"msgs":N} 或 {"ok":false,"reason":"..."}
const port = process.argv[2] || 7683;
const url = `ws://127.0.0.1:${port}/ws`;
const timeoutMs = 5000;

let msgs = 0;
let done = false;
const finish = (obj) => {
  if (done) return;
  done = true;
  console.log(JSON.stringify(obj));
  try { ws.close(); } catch (e) {}
  setTimeout(() => process.exit(0), 50);
};

const ws = new WebSocket(url, 'tty');
ws.binaryType = 'arraybuffer';
const timer = setTimeout(() => finish({ ok: false, reason: 'no_frame', msgs }), timeoutMs);
ws.onopen = () => {};
ws.onmessage = () => { msgs++; if (msgs >= 1) { clearTimeout(timer); finish({ ok: true, msgs }); } };
ws.onerror = () => { clearTimeout(timer); finish({ ok: false, reason: 'error', msgs }); };
ws.onclose = (e) => { if (!done) { clearTimeout(timer); finish({ ok: false, reason: 'closed:' + e.code, msgs }); } };
