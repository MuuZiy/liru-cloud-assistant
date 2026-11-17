"""控制台纯计算核心。无磁盘、进程、网络或 Windows API 依赖。"""
import copy
import re
import time
from webui_log import (LINE_RE, short_chapter, to_pct, hhmm, humanize, matches, RESOLVED_BY)

LEC_NO_RE = re.compile(r"第\s*(\d+)\s*讲")


def lecture_no(name):
    m = LEC_NO_RE.search(name or "")
    return int(m.group(1)) if m else None


class LogState:
    """按完整日志行归约；状态跨轮询保留，新一轮启动自动重置。"""

    def __init__(self):
        self.planned, self.planned_set = None, False
        self.items, self.events, self.warns, self.feed = [], [], [], []
        self.cur, self.progress, self.run_started, self.run_ended, self.chapter = None, None, None, None, ""
        self.progress_unattached = None      # 没有讲次表头时仍保留的进度（见 PROG_RE 处注释）
        self.edge_only, self.saw_attach = False, False
        self.scan_done = False               # 本轮是否跑完过「重新识别」（四步引导的第 3 步用）
        self.scan_only = False               # 「重新识别」那一轮：只核对不播放（引擎会写明）
        self.scan_at = ""                    # 本次重新识别完成时间
        self.scan_for = ""                   # 本次重新识别的起始讲（页面标题）
        self.scan_anchor_title = ""          # 扫描开始时附着的页面标题
        self.scan_scope = ""                  # 本次扫描实际范围（all/current/forward/chapter）

    def _current_row(self, row):
        """标题可重复：活动 ID 优先，其次使用本轮计划序号。"""
        if not self.cur:
            return False
        if row.get('id') and self.cur.get('id'):
            return row['id'] == self.cur['id']
        return row.get('index') == self.cur.get('index') and row['name'] == self.cur['name']

    def consume(self, lines, *, historical=False):
        for raw in lines:
            m = LINE_RE.match(raw)
            if not m:
                continue
            ts, level, text = m.group(1), m.group(2), m.group(3)
            found = matches(text)
            self.warns[:] = [w for w in self.warns if not any(
                key in w['text'] and any(f in text for f in fixes)
                for key, fixes in RESOLVED_BY)]
            if 'start' in found:
                # 进入新的一轮运行: 清单/动态/告警全部清零, 否则上一轮的告警会被当成"当前问题"
                self.run_started = ts
                self.run_ended = None
                self.items, self.planned, self.planned_set, self.cur, self.progress = [], None, False, None, None
                self.progress_unattached = None
                self.feed, self.events, self.warns = [], [], []
                self.edge_only, self.saw_attach = False, False
                self.scan_done = False                  # 本轮是否跑完过「重新识别」（四步引导第 3 步用）
                self.scan_only = False
                self.scan_at = ""
                self.scan_for = ""
                self.scan_anchor_title = ""
                self.scan_scope = ""
                self.chapter = ""
            if 'scan_mode' in found:
                self.scan_only = True
                self.scan_at = ""
                self.scan_for = ""
                self.scan_anchor_title = ""
                self.scan_scope = ""
            if 'end' in found:
                self.run_ended = ts
            if 'edge_mode' in found:
                self.edge_only = True            # 引擎一进入 OpenEdgeOnly 就写这一行，早于「启动 Edge」
            if 'attach' in found:
                self.saw_attach = True
                if self.scan_only:
                    anchor = text.split("：", 1)[-1].split("|", 1)[0].strip()
                    if anchor:
                        self.scan_anchor_title = anchor
            if 'edge_start' in found:
                self.edge_only = True
            if 'scope_all' in found:
                self.scan_scope = "all"
            elif 'scope_current' in found:
                self.scan_scope = "current"
            elif 'scope_forward' in found:
                self.scan_scope = "forward"
            elif 'scope_chapter' in found:
                self.scan_scope = "chapter"
            if 'scan_done' in found:
                self.scan_done = True        # 「重新识别」跑完了（四步引导第 3 步打勾）
                self.scan_at = ts
                self.scan_for = self.scan_anchor_title or ((self.cur or {}).get("name") or "")
            mm = found.get('chapter')
            if mm:
                self.chapter = mm.group(1).strip()
                ch_short = short_chapter(self.chapter)
                if self.cur:
                    self.cur["chapter"] = self.chapter
                    self.cur["chapter_short"] = ch_short
                # 只给“当前这一讲”贴章节。一轮计划可能横跨多章，
                # 把第一个章节名套给所有未标签的讲，会把整轮都标成同一章
                # （32 讲全进“第五周”，圆盘的章节分段和范围菜单都会跟着错）。
                # 其它讲次的章节由 build_status 用 课程结构.json 的标题反查补齐。
                if self.cur:
                    for it in self.items:
                        if self._current_row(it):
                            it["chapter"] = self.chapter
                            it["chapter_short"] = ch_short
                continue
    
            # 本轮计划明细（引擎开刷时逐条写日志）→ 清单立刻列出全部讲次
            mm = found.get('plan_item')
            if mm:
                idx, nm = int(mm.group(1)), mm.group(2).strip()
                nm = re.sub(r"（活动\s*\d+）\s*$", "", nm)
                aid = re.search(r"（活动\s*(\d+)）\s*$", text)
                aid = aid.group(1) if aid else ''
                if not any((x.get('id') == aid if aid else x.get('index') == idx) for x in self.items):
                    new_it = {"index": idx, "name": nm, "status": "等待中", "pct": 0, "id": aid}
                    lno = lecture_no(nm)
                    if lno:
                        new_it["lec_no"] = lno
                    if self.chapter:
                        new_it["chapter"] = self.chapter
                        new_it["chapter_short"] = short_chapter(self.chapter)
                    self.items.append(new_it)
                    self.items.sort(key=lambda x: x.get("index") or 999)
                self.planned_set = True
                continue
    
            # 识别时的逐讲结果（引擎对整门课每一讲写一行）→ 每次重新识别都重建清单。
            # 这些行不再进“最近动态”，但必须进清单，否则用户看不到 32 讲到底是哪些。
            mm = found.get('scan_item')
            if mm:
                nm = re.sub(r"（活动\s*\d+）\s*$", "", mm.group(1).strip())
                done = "已完成" in mm.group(2)
                if not any(x["name"] == nm for x in self.items):
                    lno = lecture_no(nm)
                    new_it = {
                        "index": lno or (len(self.items) + 1),
                        "name": nm,
                        "status": "已完成" if done else "等待中",
                        "pct": 100 if done else 0,
                    }
                    if lno:
                        new_it["lec_no"] = lno
                    self.items.append(new_it)
                    self.items.sort(key=lambda x: x.get("index") or 999)
                continue
    
            tone, sentence = humanize(ts, level, text, found)
            if tone is None:            # 操作细节不进动态, 但仍计入告警判断
                if not historical and level in ("警告", "错误"):
                    self.warns.append({"time": hhmm(ts), "level": level, "text": text, "_ts": ts})
                continue
            if level == "错误":
                tone = "err"            # 错误级在"最近动态"里显示红色
            # 压缩重复动态：连续多条「正在播放」只保留最新一条；连续完全相同的提示
            # （如"正在等你打开视频页"每 30 秒刷一次）也只保留一条，避免"最近动态"刷屏
            compressed = bool(self.feed and sentence == self.feed[-1]["text"])
            if compressed or (self.feed and sentence.startswith("正在播放：")
                              and self.feed[-1]["text"].startswith("正在播放：")):
                self.feed[-1] = {"time": hhmm(ts), "tone": tone, "text": sentence}
            else:
                self.feed.append({"time": hhmm(ts), "tone": tone, "text": sentence})
                del self.feed[:-10]
            if level in ("警告", "错误", "提醒"):
                self.events.append({"time": hhmm(ts), "level": level, "text": sentence, "_ts": ts})
                del self.events[:-8]
                if not historical and level in ("警告", "错误"):
                    self.warns.append({"time": hhmm(ts), "level": level, "text": sentence, "_ts": ts})
    
            mm = found.get('plan')
            if mm:
                self.planned, self.planned_set = int(mm.group(1)), True
                # 扫描结果不是本轮播放计划；计划随后逐行按活动 ID 重建。
                self.items = []
    
            mm = found.get('lecture')
            if mm:
                name = re.sub(r"（活动\s*\d+）\s*$", "", mm.group(3).strip())
                aid = re.search(r"（活动\s*(\d+)）\s*$", mm.group(3).strip())
                aid = aid.group(1) if aid else ''
                next_cur = {"index": int(mm.group(1)), "total": int(mm.group(2)), "name": name, "id": aid}
                # 进入新的一讲：上一讲的进度不能继续挂在新讲上。
                # 日志里若没有上一讲的汇总行（失败/停止/跳过），把它的“播放中”收尾为“中断”，
                # 否则清单会同时有两行显示播放中（用户实报过）。
                self.cur = next_cur
                for it in self.items:
                    if not self._current_row(it) and it.get("status") in ("播放中", "进行中"):
                        it["status"] = "中断"
                self.progress = None
                self.progress_unattached = None      # 表头一到手，挂靠不明的进度就可以丢了
                lno = lecture_no(name)
                if lno:
                    self.cur["lec_no"] = lno
                if not self.planned_set:
                    self.planned = self.cur["total"]
                hit = [it for it in self.items if self._current_row(it)]
                if hit:
                    hit[0].update(status="进行中", id=aid)
                    if lno:
                        hit[0]["lec_no"] = lno
                else:
                    new_it = {"index": self.cur["index"], "name": self.cur["name"],
                              "status": "等待中", "pct": 0, "id": aid}
                    if lno:
                        new_it["lec_no"] = lno
                    if self.chapter:                # 本轮已知的章节直接补上（同一轮同一章节）
                        new_it["chapter"] = self.chapter
                        new_it["chapter_short"] = short_chapter(self.chapter)
                    self.items.append(new_it)
                self.items.sort(key=lambda x: x.get("index") or 999)
    
            mm = found.get('progress')
            if mm:
                pct = to_pct(mm.group(1))
                self.progress = {"pct": pct, "cur": int(mm.group(2).replace(",", "")),
                            "dur": int(mm.group(3).replace(",", ""))}
                if self.cur:
                    for it in self.items:
                        if self._current_row(it) and it["status"] != "已完成":
                            it.update(pct=pct, dur=self.progress["dur"], cur=self.progress["cur"],
                                      status="播放中" if pct < 100 else "已完成")
                else:
                    # ⚠ 进度条在"当前讲"未知时**不能丢**。
                    # 引擎有一类路径（接管你已打开的视频页）不写 `--- 第 N/M 讲 ---` 表头，
                    # 于是 cur 一直是 None；以前写成 `if mm and cur` 就把整轮进度全部丢弃，
                    # 表现为"明明在刷课，进度面板/清单/胶囊却全空"（2026-09-16 实测）。
                    # 这里先存下来，交给 build_status 用 CDP 标题 / 课程结构.json 补出讲次名。
                    self.progress_unattached = self.progress
    
            if 'lecture_done' in found and self.cur:
                for it in self.items:
                    if self._current_row(it):
                        it.update(status="已完成", pct=100)
    
            mm = found.get('summary')
            if mm:
                name, detail, pct = mm.group(2).strip(), mm.group(3).strip(), to_pct(mm.group(4))
                hit = [it for it in self.items if it.get('index') == int(mm.group(1))
                       and (it["name"] == name or name.endswith(it["name"]))]
                if hit:
                    hit[0].update(status="已完成" if "已完成" in detail else detail, pct=pct)
                else:
                    new_it = {"index": len(self.items) + 1, "name": name,
                              "status": detail, "pct": pct}
                    lno = lecture_no(name)
                    if lno:
                        new_it["lec_no"] = lno
                    self.items.append(new_it)

    def snapshot(self):
        value = {"planned": self.planned, "current": self.cur, "progress": self.progress, "items": self.items,
                    "events": self.events[-8:], "warns": self.warns[-4:], "run_started": self.run_started,
                    "run_ended": self.run_ended,
                    "chapter": self.chapter, "feed": self.feed[-10:],
                    "progress_unattached": self.progress_unattached,
                    "scan_only": bool(self.scan_only),
                    "edge_only": bool(self.edge_only and not self.saw_attach),
                    "saw_attach": bool(self.saw_attach),
                    "scan_done": bool(self.scan_done),
                    "scan_at": self.scan_at,
                    "scan_for": self.scan_for,
                    "scan_scope": self.scan_scope}
        value = copy.deepcopy(value)
        for row in value['events'] + value['warns']:
            row.pop('_ts', None)
        return value


def parse_lines(lines):
    state = LogState()
    state.consume(lines)
    return state.snapshot()


def map_course(sections, current=""):
    """课程结构.json → (按活动 id 查, 按讲次名查, 当前讲 id)。

    这是引擎写下的**全课程权威结构**（27 个章节、每讲的标题/完成状态/是否被
    平台跟踪），比日志可靠得多：日志只有"本轮处理了哪几讲"，这里能给出完整上下文。
    """
    by_id, by_name, ambiguous = {}, {}, set()
    for sec in sections:
        for it in (sec.get("items") or []):
            title = (it.get("title") or "").strip()
            entry = {"title": title, "section": sec.get("name") or "", "id": str(it.get('id') or ''),
                     "done": it.get("done"), "tracked": it.get("tracked", True)}
            if it.get("id"):
                by_id[str(it["id"])] = entry
            if title:
                if title in by_name:
                    ambiguous.add(title)
                else:
                    by_name[title] = entry
    for title in ambiguous:
        by_name.pop(title, None)
    return by_id, by_name, current


def normalize_course(d):
    if not isinstance(d, dict) or not isinstance(d.get('sections'), list):
        raise ValueError('invalid course structure')
    secs, seen = [], set()
    for s in d.get("sections") or []:
        if not isinstance(s, dict) or not isinstance(s.get('items'), list):
            continue
        items = []
        for it in (s.get("items") or []):
            if not isinstance(it, dict):
                continue
            title = str(it.get("title") or "")
            if not title:
                continue
            aid = str(it.get('id') or '')
            if aid and aid in seen:
                continue
            if aid:
                seen.add(aid)
            done = it.get("done")
            tracked = it.get("tracked")
            vid = it.get("video")
            items.append({"title": title,
                          "id": aid,
                          "done": done if isinstance(done, bool) else None,
                          "tracked": tracked if isinstance(tracked, bool) else True,
                          "type": str(it.get("mod") or it.get("type") or ""),
                          # video 是**引擎的最终结论**（识别规则.ps1 判的）：
                          #   True=要刷的视频 / False=文档课件等 / None=老快照没这个字段
                          "video": vid if isinstance(vid, bool) else None,
                          "kind": str(it.get("kind") or ""),
                          "videoBy": str(it.get("videoBy") or ""),
                          "icon": str(it.get("icon") or "")})
        if items:
            secs.append({"id": str(s.get('id') or ''), "name": str(s.get("name") or ""), "items": items})
    return secs


def _looks_video(it):
    """这条活动是不是视频。**只认引擎的结论**（课程结构.json 的 video 字段）。

    None（老版本快照没这个字段）按"可能是"处理：保留它、计入章节总数，
    等下一次识别由引擎给出确定结论；不会把它直接排除掉。
    """
    if it.get('kind') == 'unknown':
        return False
    v = it.get("video")
    if v is True:
        return True
    if v is False:
        return False
    return True                      # 未知 → 保守保留（不排除真视频）


def _video_sections(secs):
    """只保留含"可能是视频"活动的章节；若这样会一章不剩，就原样返回（避免误杀）"""
    kept = [s for s in secs if any(_looks_video(it) for it in s["items"])]
    return kept or secs

def _is_counted(it):
    """这条活动算不算"要刷的讲"。
    排除两类：① 平台不跟踪完成的（论坛/资源等，刷了也没有进度意义）；
              ② 引擎判定不是视频的（教学大纲/课件/实验）。
    判定只读引擎结论，见 _looks_video。"""
    if it.get("tracked") is False:
        return False
    if not _looks_video(it):
        return False
    return True

def map_chapters(secs, cur_name="", cur_id=""):
    """每章的完成度视图：[{name,total,done,remain,known,current}]。

    完成状态**只认引擎的实时识别结果**（逐个打开讲、按页面真实状态判断），
    不使用任何本地记录 —— 换台电脑解压即用、记录丢了也不影响。
    一章里只要还有没被识别过的讲，known 就是 False（此时不显示"剩几讲"，避免瞎猜）。
    """
    if not secs:
        return []
    secs = _video_sections(secs)
    any_tracked = any(_is_counted(it) for s in secs for it in s['items'])
    cur_id = str(cur_id or '')
    matches_by_name = sum(i.get('title') == cur_name for s in secs for i in s['items']) if cur_name else 0
    out = []
    for s in secs:
        # 只数真正的视频讲：平台不跟踪的、以及引擎判定为非视频的，都不算"要刷的讲"
        items = [it for it in s["items"] if _is_counted(it) or (not any_tracked and _looks_video(it))]
        if not items:
            continue
        known = all(it["done"] is not None for it in items)
        done = sum(1 for it in items if it["done"] is True)
        out.append({"name": s["name"], "total": len(items),
                    "done": done,
                    "remain": (len(items) - done) if known else None,
                    "known": known,
                    "current": (any(str(i.get('id') or '') == cur_id for i in items) if cur_id else
                                bool(matches_by_name == 1 and any(i['title'] == cur_name for i in items)))})
    return out


def estimate_times(info, running, done, now):
    def _epoch(s):
        try:
            return time.mktime(time.strptime(s, "%Y-%m-%d %H:%M:%S"))
        except Exception:  # noqa: BLE001
            return None

    t0 = _epoch(info.get("run_started") or "")
    t1 = _epoch(info.get("run_ended") or "") if info.get("run_ended") else None
    elapsed = None
    # 只对“真的干了活”的轮次报用时：开登录窗口那一轮只有十几秒，
    # 报成“本轮用时 0:16”只会干扰阅读。
    if (info["items"] or info.get("scan_done")) \
            and not info.get("scan_only") and not info.get("edge_only"):
        if t0 and running:
            elapsed = max(0, int(now - t0))
        elif t0 and t1:
            elapsed = max(0, int(t1 - t0))

    durs = [it["dur"] for it in info["items"] if it.get("dur")]
    avg_dur = (sum(durs) / len(durs)) if durs else 0
    pending_states = ("等待中", "未开始", "播放中", "进行中", "中断")
    pending = [it for it in info["items"] if it.get("status") in pending_states]
    planned_n = info["planned"] or 0
    eta = None
    if planned_n and done >= planned_n:
        eta = 0                       # 本轮已刷完，剩余就是 0
    elif running and not info.get("scan_only") and not info.get("edge_only") and avg_dur > 0:
        total = 0.0
        for it in pending:
            d = it.get("dur") or avg_dur
            frac = 1 - min(100.0, max(0.0, float(it.get("pct") or 0))) / 100.0
            # 平台百分比是累计记账，本遍剩余时间使用 current/duration。
            if it.get('cur') is not None and it.get('dur'):
                total += max(0.0, d - float(it['cur']))
            else:
                total += d * frac
        # 计划里有、但 items 还没列出的讲（清单不完整时）按整段均值补
        unlisted = max(0, planned_n - len(info["items"]))
        total += unlisted * avg_dur
        eta = int(total)

    return elapsed, eta


def select_state(info, running, scanning, cdp, page, cur, p, warn, boot_wait, strays, clock):
    state, state_text, note, hint = "stopped", "已停止", "", ""
    if scanning:
        state, state_text = "scanning", "正在重新识别"
        note = "正在重新核对每一讲的完成情况…"
    elif running:
        if info.get("edge_only"):
            # 只是"登录 Edge"那一次运行, 不是在刷课
            state, state_text, note = "edge", "正在接管 Edge", ""
        elif info.get("scan_only"):
            # 「重新识别」那一轮：只核对完成情况，不播放。不能报成"正在刷课" ——
            # 那会让用户以为视频已经在放了（引擎同样会附着浏览器、也要跑几十秒）。
            state, state_text = "scanning", "正在重新识别"
            note = "正在重新核对每一讲的完成情况…"
        elif warn and any(k in warn["text"] for k in ("考勤校验没自动通过", "还没播起来", "等太久了")):
            state, state_text, note = "attention", "需要留意", warn["text"]
        elif boot_wait:
            state, state_text = "starting", "正在连接浏览器"
            note = "正在核对每一讲的完成情况…"
        else:
            state, state_text = "running", "正在正常运行"
            # 讲次名通常自带"第N讲"前缀（如"第11讲-表单元素"），所以这里不要再包一层
            note = ("%s 播放中（%d%%）" % (cur.get("name", "?"), p.get("pct", 0))
                    if cur and p else "正在连接浏览器…")
    elif page == "login":
        state, state_text = "login", "等待登录"
        note, hint = "Edge 已连接", "在日常 Edge 中登录课堂，打开课程页或一讲视频"
    elif cdp and page == "activity":
        state, state_text = "setup", "等待选讲"
        note = "当前打开的不是视频页"
        hint = "回到课程页，点开带播放器的视频讲；资料/讨论区不能用来开始刷课"
    elif cdp and page == "unverified":
        state, state_text = "setup", "等待选讲"
        note = "还不能确认这一页是视频"
        hint = "先点「重新识别」核对这一讲；确认是视频后再开始"
    elif cdp and page == "course":
        state, state_text = "setup", "等待选讲"
        note = "课程页已打开"
        hint = "点开一讲视频；选整门课/指定章时也可以直接开始"
    elif cdp and page == "moodle":
        state, state_text = "setup", "等待选讲"
        note, hint = "已登录", "先打开课程页或一讲视频"
    elif cdp and page == "other":
        state, state_text = "setup", "等待选讲"
        note, hint = "Edge 已连接", "在窗口里打开砺儒云课堂课程页，再点开一讲视频"
    elif cdp and page == "none":
        # 端口还在、但浏览器窗口已经关了：不能报「Edge 已连接」，
        # 否则用户点「登录 Edge」也拿不到窗口，看起来像按钮失灵。
        state, state_text = "stopped", "未找到课堂标签"
        note = "未找到课堂标签"
        hint = "请在已连接的 Edge 中打开课堂页"
    elif page == "video":
        state, state_text = "ready", "可以开始"
        note, hint = "已就绪", "条件齐了，点上面的「开始刷课」即可"
    else:
        note = "Edge 已连接" if cdp else "尚未接管 Edge"
        if cdp:
            hint = "在已连接的 Edge 中点开你要看的那一讲视频，然后点上面的「开始刷课」"
        else:
            hint = "先打开日常 Edge、允许调试连接，再点「接管 Edge」"

    # 有"残留脚本"（不受本控制台管理）时优先提示：它占着浏览器，而且以前点「停止」根本没反应
    if not running and not scanning and strays:
        state, state_text = "attention", "需要留意"
        note = "发现残留脚本，正在确认并自动清理"
        hint = "连续确认约 15 秒后自动结束；也可点「停止」手动处理"
        warn = {"time": clock, "level": "警告",
                "text": "正在确认并自动清理残留脚本（进程 %s）"
                        % "/".join(str(e["pid"]) for e in strays[:3])}
    return state, state_text, note, hint, warn
