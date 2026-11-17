/* shared/poll.js — 两套界面共用的轮询构件：/api/status 获取 + 变更键。
   经典脚本：顶层只新增 LiruPoll 一个名字，不碰页面其它全局声明。
   为什么共用：两版曾各自实现一份（变更键一个排除 time 一个没排除、fetch 一个有
   超时中止一个没有），行为已经实际漂移过；同一件事只留这一份。 */
(function () {
  'use strict';

  /* 变更键：time 每秒都变但不影响界面，排除它，避免每次轮询都被判"有变化"而全量重绘。 */
  function statusKey(j) {
    return JSON.stringify(j, function (k, v) { return k === 'time' ? undefined : v; });
  }

  /* 获取 /api/status：10 秒中止；HTTP 非 2xx、负载缺 state 字段都按失败处理。 */
  async function fetchStatus(url) {
    const ctrl = new AbortController();
    const timer = setTimeout(function () { ctrl.abort(); }, 10000);
    try {
      const r = await fetch(url, { cache: 'no-store', signal: ctrl.signal });
      if (!r.ok) throw new Error('HTTP ' + r.status);
      const j = await r.json();
      if (!j || typeof j !== 'object' || !j.state) throw new Error('bad status');
      return j;
    } finally {
      clearTimeout(timer);
    }
  }

  /* 完成一轮才安排下一轮；前台操作后短间隔观察，静止时降低请求频率。 */
  function pollDelay(j, pending) {
    if (pending || (j && (j.scan_proc || /^(starting|edge|scanning)$/.test(j.state)))) return 450;
    return document.hidden ? 3000 : 1000;
  }
  function createLoop(task, delay) {
    let timer = 0, stopped = false, running = false, again = false;
    async function tick() {
      clearTimeout(timer);
      if (stopped) return;
      if (running){ again = true; return; }
      running = true;
      try { await task(); }
      finally {
        running = false;
        if (!stopped) timer = setTimeout(tick, again ? 0 : delay());
        again = false;
      }
    }
    function wake() {
      clearTimeout(timer);
      if (running) again = true;
      else timer = setTimeout(tick, 0);
    }
    document.addEventListener('visibilitychange', () => { if (!document.hidden && !stopped) wake(); });
    wake();
    return {wake, stop: function () { stopped = true; clearTimeout(timer); }};
  }

  /* 只描绘请求意图；alive/PID 等运行证据仍来自原始响应。 */
  function presentation(j, action) {
    if (!j || !action) return j;
    const state = action === 'scan' ? 'scanning' : action === 'edge' ? 'edge'
      : action === 'start' ? 'starting' : j.state;
    return Object.assign({}, j, {state, scan_proc: action === 'scan' || j.scan_proc});
  }
  function readWaitText(j) {
    const seconds = Number(j && j.read_wait_seconds);
    return Number.isFinite(seconds) && seconds > 0 ? '再次识别还需等 ' + Math.ceil(seconds) + ' 秒' : '';
  }
  function scanResult(j, before, seen) {
    if (j.alive || j.scan_proc || /^(scanning|starting)$/.test(j.state)) return '';
    const finished = j.scan_only && j.run_ended && j.run_ended !== before.run_ended;
    const saved = j.scan_at && j.scan_at !== before.scan_at;
    if (j.scanned && (seen || saved || finished)) return 'success';
    if (!j.scanned && (seen || finished)) return 'error';
    return '';
  }

  window.LiruPoll = { readWaitText, scanResult, statusKey, fetchStatus, pollDelay, createLoop, presentation };
})();
