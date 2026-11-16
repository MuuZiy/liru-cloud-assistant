"""引擎日志契约：正则、翻译与字段捕获集中在这里；无 IO。

修改引擎 Write-Log 后必须同步本表与 ENGINE_TEMPLATES；源码契约测试禁止漏登。
"""
import re
from dataclasses import dataclass

LINE_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\s*\[(.+?)\]\s*(.*)$")
PLAN_RE = re.compile(r"本次将处理\s*(\d+)\s*个视频")
PLAN_ITEM_RE = re.compile(r"计划\s*(\d+)\.\s*(.+?)\s*（活动\s*\d+）\s*$")
LEC_RE = re.compile(r"---\s*第\s*(\d+)/(\d+)\s*讲[:：]\s*(.+?)\s*---")
PROG_RE = re.compile(r"进度\s*([\d.]+)%\s*[（(]\s*([\d,]+)\s*/\s*([\d,]+)\s*秒")
SUM_RE = re.compile(r"汇总[:：]\s*(\d+)\.\s*(.+?)\s*——\s*(.+?)\s*[（(]进度\s*([\d.]+)%")
CHAP_RE = re.compile(r"本讲章节[:：]\s*(.+?)\s*$")


def short_chapter(name):
    """「第一周-教学视频」-> 「第一周」"""
    if not name:
        return ""
    return name.split("-")[0].strip() or name


def to_pct(s):
    try:
        return int(round(float(s)))
    except (TypeError, ValueError):
        return 0


TIME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}):\d{2}")
URL_RE = re.compile(r"https?://\S+")
ACT_RE = re.compile(r"（活动\s*\d+）")
HM_RE = re.compile(r"(\d+)")


def hhmm(ts):
    m = TIME_RE.match(ts)
    return m.group(1)[11:] if m else ts


def mmss(sec):
    sec = int(sec)
    return "%d分%02d秒" % (sec // 60, sec % 60) if sec >= 60 else "%d秒" % sec


@dataclass(frozen=True)
class LogRule:
    key: str
    pattern: object
    render: object = None


def rule(key, pattern, render=None):
    return LogRule(key, re.compile(pattern) if isinstance(pattern, str) else pattern, render)


def _render_progress(m, t):
    pct = to_pct(m.group(1))
    return ('info', '正在播放：已看 %s / 共 %s（%d%%）' % (mmss(m.group(2).replace(',', '')), mmss(m.group(3).replace(',', '')), pct))


def _render_summary(m, t):
    name, detail, pct = (m.group(2).strip(), m.group(3).strip(), to_pct(m.group(4)))
    if '已完成' in detail:
        return ('ok', '「%s」已完成（进度 100%%）' % name)
    if '跳过' in detail and '异常' not in detail:
        return ('ok', '「%s」之前就完成了，跳过' % name)
    return ('warn', '「%s」中断了：%s（进度 %d%%）' % (name, detail, pct))


def _render_lecture(m, t):
    name = re.sub('（活动\\s*\\d+）\\s*$', '', m.group(3).strip())
    return ('info', '开始第 %s/%s 讲：%s' % (m.group(1), m.group(2), name))


def _render_completion_probe(m, t):
    return ('info', '正在逐个核对这 %s 讲的观看进度…' % m.group(1))


def _render_completion_result(m, t):
    return ('info', '%s 讲的观看进度核对完了（用时 %s 秒）' % (m.group(1), m.group(3)))


def _render_identified(m, t):
    return ('ok', '核对完了：还有 %s 讲没看完' % m.group(1))


def _render_excluded(m, t):
    return ('info', '跳过 %s 个不是视频的条目（大纲、课件这些），只看有视频的讲' % m.group(1))


def _render_structure(m, t):
    return ('info', '读到整门课 %s 个章节、%s 个活动' % (m.group(1), m.group(2)))


def _render_need_evidence_legacy(m, t):
    return ('info', '有 %s 个活动要看页面内容才能确定是不是视频…' % m.group(1))


def _render_probe_result_legacy(m, t):
    return ('info', '页面核对完成，%s 个活动已确定' % m.group(1))


def _render_scope_forward_render(m, t):
    return ('info', '从你正在看的这一讲往后排，一共 %s 讲' % m.group(1))


def _render_completion_counts_legacy(m, t):
    return ('info', '核对结果：%s 讲已完成，%s 讲要处理' % (m.group(1), m.group(2)))


RULES = [
    rule('progress', PROG_RE, _render_progress),
    rule('summary', SUM_RE, _render_summary),
    rule('lecture', LEC_RE, _render_lecture),
    rule('completion_probe', '有\\s*(\\d+)\\s*讲读不到平台完成状态，正在实时核对', _render_completion_probe),
    rule('completion_result', '并发核对完成：(\\d+)/(\\d+) 讲已判定（耗时 ([\\d.]+) 秒）', _render_completion_result),
    rule('identified', '识别完成：本轮需要播放\\s*(\\d+)\\s*讲', _render_identified),
    rule('excluded', '已排除\\s*(\\d+)\\s*个非视频活动', _render_excluded),
    rule('structure', '已读取课程结构：(\\d+)\\s*个章节，共\\s*(\\d+)\\s*个活动', _render_structure),
    rule('need_evidence_legacy', '有\\s*(\\d+)\\s*个活动无法从图标/类型判定', _render_need_evidence_legacy),
    rule('probe_result_legacy', '页面核对完成：(\\d+)\\s*个活动已判定', _render_probe_result_legacy),
    rule('scope_forward_render', '已从当前这一讲开始.*?共\\s*(\\d+)\\s*讲', _render_scope_forward_render),
    rule("detail_26", '《(.+?)》还没完成，加入本轮', lambda m, t: (None, None)),
    rule("detail_27", '《(.+?)》已完成，本轮跳过', lambda m, t: (None, None)),
    rule('completion_counts_legacy', '完成情况：(\\d+)\\s*讲已完成、(\\d+)\\s*讲待处理', _render_completion_counts_legacy),
    rule("message_0", re.escape('脚本启动'), lambda m, t: ('info', '开始运行')),
    rule("message_1", re.escape('重新识别模式'), lambda m, t: ('info', '正在重新核对每一讲的完成情况（只识别，不播放）')),
    rule("message_2", re.escape('重新识别完成'), lambda m, t: ('ok', '重新识别完成，还剩几讲已经更新')),
    rule("message_3", re.escape('已附着到浏览器窗口'), lambda m, t: ('ok', '已连接到浏览器，当前页面：%s' % t.split('：', 1)[-1])),
    rule("message_4", re.escape('已识别到视频页面'), lambda m, t: ('info', '已识别到视频页面')),
    rule("message_5", re.escape('本次将处理'), lambda m, t: ('info', t.replace('本次将处理', '本次准备播放').replace('个视频：', '讲'))),
    rule("message_6", re.escape('将按「'), lambda m, t: ('info', '播放顺序：' + t.split('」', 1)[0].split('「', 1)[-1])),
    rule("message_7", re.escape('页面显示已完成，本讲结束'), lambda m, t: ('ok', '这一讲已完成，准备下一讲')),
    rule("message_8", re.escape('该讲此前已完成，跳过播放'), lambda m, t: ('ok', '这一讲之前就完成了，跳过')),
    rule("message_9", re.escape('收到停止指令'), lambda m, t: ('warn', '收到停止指令，已保存进度并退出')),
    rule("message_10", re.escape('登录已完成'), lambda m, t: ('ok', '登录完成，继续刷课')),
    rule("message_11", re.escape('确认已完成，恢复播放监控'), lambda m, t: ('ok', '平台的考勤校验已通过，继续播放')),
    rule("message_12", re.escape('长按校验通过'), lambda m, t: ('ok', '考勤校验已通过，弹窗已关闭')),
    rule("message_13", re.escape('自动长按未通过'), lambda m, t: ('warn', '自动长按没通过，改为人工确认：请按住「按住确认」直到进度条满')),
    rule("message_14", re.escape('自动长按未能通过'), lambda m, t: ('warn', '平台考勤校验没自动通过，需要你在 Edge 窗口里手动按住「按住确认」直到进度条满')),
    rule("message_15", re.escape('无法开始播放，稍后重试'), lambda m, t: ('warn', '视频还没播起来，稍后自动重试')),
    rule("message_16", re.escape('尚未开始播放'), lambda m, t: ('warn', '这一讲还没播起来，正在自动重试')),
    rule("message_17", re.escape('等待超时'), lambda m, t: ('warn', '等太久了，平台一直没标记这讲完成，建议稍后自己核对')),
    rule("message_18", re.escape('弹出【考勤确认】'), lambda m, t: ('warn', '平台弹出考勤校验，正在自动按住确认')),
    rule("message_19", re.escape('调试 Edge 已在运行'), lambda m, t: ('info', '登录 Edge 已在运行')),
    rule("message_20", re.escape('已打开调试 Edge 窗口'), lambda m, t: ('ok', '已打开登录 Edge 窗口')),
    rule("message_21", re.escape('启动 Edge'), lambda m, t: ('info', '正在打开登录 Edge')),
    rule("message_22", re.escape('请在这个 Edge 窗口里打开你要看的那一讲视频页面'), lambda m, t: ('info', '正在等你打开视频页')),
    rule("message_23", re.escape('当前标签页不是视频页面'), lambda m, t: ('info', '正在等你打开视频页')),
    rule("hidden_0", re.escape('已在运行'), lambda m, t: (None, None)),
    rule("hidden_1", re.escape('打开页面'), lambda m, t: (None, None)),
    rule("hidden_2", re.escape('点击播放按钮'), lambda m, t: (None, None)),
    rule("hidden_3", re.escape('点击视频画面'), lambda m, t: (None, None)),
    rule("hidden_4", re.escape('脚本结束'), lambda m, t: (None, None)),
    rule("hidden_5", re.escape('PowerShell 版本'), lambda m, t: (None, None)),
    rule("hidden_6", re.escape('读取页面状态失败'), lambda m, t: (None, None)),
    rule("hidden_7", re.escape('偶尔读不到播放状态'), lambda m, t: (None, None)),
    rule("hidden_8", re.escape('临时浏览器配置目录'), lambda m, t: (None, None)),
    rule('plan', PLAN_RE),
    rule('plan_item', PLAN_ITEM_RE),
    rule('chapter', CHAP_RE),
    rule('scan_item', r"^《(.+?)》(还没完成，加入本轮|已完成，本轮跳过)"),
    rule('start', r"脚本启动"),
    rule('scan_mode', r"重新识别模式"),
    rule('end', r"脚本结束"),
    rule('edge_mode', r"打开登录窗口模式|接管 Edge 模式"),
    rule('attach', r"已附着到浏览器窗口：(.+)"),
    rule('edge_start', r"启动 Edge"),
    rule('scope_all', r"已按全课程章节读取到"),
    rule('scope_current', r"当前章共"),
    rule('scope_forward', r"已从当前这一讲开始"),
    rule('scope_chapter', r"章节「.*」共"),
    rule('scan_done', r"重新识别完成"),
    rule('lecture_done', r"该讲此前已完成|页面显示已完成，本讲结束|平台已记账完成，本讲结束"),
]

# 当前文案优先；保留历史文案的读取兼容。
RULES[:0] = [
    rule('completion_result_current', r"逐项核对完成：(\d+)/(\d+) 讲已判定（耗时 ([\d.]+) 秒）",
         lambda m, t: ('info', '%s/%s 讲已核对（用时 %s 秒）' % m.groups())),
    rule('need_evidence', r"有\s*(\d+)\s*个活动需要页面证据",
         lambda m, t: ('info', '有 %s 个活动要看页面内容才能确定是不是视频…' % m[1])),
    rule('unverified', r"还有\s*(\d+)\s*个活动证据不足",
         lambda m, t: ('info', '另有 %s 项内容需手动查看，不参与自动播放；已确认的视频可正常开始' % m[1])),
    rule('completion_counts', r"完成情况：(\d+)\s*讲已完成、(\d+)\s*讲待处理",
         lambda m, t: ('info', '核对结果：%s 讲已完成，%s 讲要处理' % m.groups())),
    rule('structure_retry', r"读取课程结构失败|改用课程索引方式", lambda m, t: (None, None)),
    rule('structure_save_failed', r"保存课程结构失败，已保留原文件：(.+)",
         lambda m, t: ('warn', '课程记录保存失败，旧记录仍保留：%s' % m[1])),
    rule('platform_done', r"平台已记账完成，本讲结束", lambda m, t: ('ok', '这一讲平台已确认完成，准备下一讲')),
]
BY_KEY = {r.key: r for r in RULES}


def matches(text):
    # Once the first translation matches, only field/event rules still matter.
    # Progress polling must not walk every unrelated display-only translation.
    found = {}
    rendered = False
    for r in RULES:
        if rendered and r.key not in PARSE_KEYS:
            continue
        m = r.pattern.search(text)
        if m is not None:
            found[r.key] = m
            if r.render is not None:
                rendered = True
    return found


PARSE_KEYS = frozenset((
    'progress', 'summary', 'lecture', 'plan', 'plan_item', 'chapter', 'scan_item',
    'start', 'scan_mode', 'end', 'edge_mode', 'attach', 'edge_start',
    'scope_all', 'scope_current', 'scope_forward', 'scope_chapter', 'scan_done', 'lecture_done',
))


def humanize(ts, level, text, found=None):
    t = text.strip()
    found = matches(t) if found is None else found
    for r in RULES:
        if r.render is not None and r.key in found:
            tone, sentence = r.render(found[r.key], t)
            break
    else:
        tone, sentence = ('warn' if level in ('警告', '错误') else 'info'), t
    if sentence is not None:
        sentence = ACT_RE.sub('', URL_RE.sub('视频页面', sentence))
    return tone, sentence


RESOLVED_BY = (
    ('考勤', ('确认已完成，恢复播放监控', '长按校验通过')),
    ('长按', ('确认已完成，恢复播放监控', '长按校验通过')),
    ('弹窗', ('确认已完成，恢复播放监控', '长按校验通过')),
    ('播起来', ('点击播放按钮', '进度 ')),
    ('播放', ('进度 ', '页面显示已完成', '平台已记账完成')),
    ('后台运行', ('已结束', '没有在运行', '已停止')),
)


# AST 源码契约登记。每条指向语法规则及可执行样例，或明确说明无需翻译。
ENGINE_TEMPLATES = {
    '保存课程结构失败，已保留原文件：{0}': ('structure_save_failed', '保存课程结构失败，已保留原文件：文件正在使用'),
    '接管 Edge 模式：只连接本人授权的现有浏览器': ('edge_mode', '接管 Edge 模式：只连接本人授权的现有浏览器'),
    '--- 第 {0}/{1} 讲：{2}（活动 {3}）---': ('lecture', '--- 第 3/3 讲：3（活动 3）---'),
    'Edge 窗口此刻在后台/最小化 —— 平台在窗口不可见时不累计按住进度，已自动临时拉到前台；按完会自动缩回去，你不用管': (None, '原文已说明操作结果或故障原因，无需翻译'),
    'PowerShell 版本：{0}': ('hidden_5', 'PowerShell 版本：3'),
    '《{0}》已完成，本轮跳过': ('detail_27', '《3》已完成，本轮跳过'),
    '《{0}》还没完成，加入本轮': ('detail_26', '《3》还没完成，加入本轮'),
    '《{0}》这个页面里没有视频（可能是论坛/实验/资源类活动），本轮跳过': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '偶尔读不到播放状态，脚本会自动重试（不影响播放）': ('hidden_7', '偶尔读不到播放状态，脚本会自动重试（不影响播放）'),
    '切讲失败：页面仍停在活动 {0}（目标 {1}），这一讲按失败跳过，避免在错误页面上播放': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '发生错误：{0}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '复用 {0} 个仍有效的页面分类证据（完成状态仍实时核对）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '多次重连都没成功，本讲中止，避免无限重连': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '完成情况：{0} 讲已完成、{1} 讲待处理': ('completion_counts', '完成情况：3 讲已完成、3 讲待处理'),
    '尚未开始播放，第 {0} 次尝试开始': ('message_16', '尚未开始播放，第 3 次尝试开始'),
    '已从当前这一讲开始、按课程顺序排到课程末尾，共 {0} 讲': ('scope_forward_render', '已从当前这一讲开始、按课程顺序排到课程末尾，共 3 讲'),
    '已在 ({0},{1}) 持续按住 {2} 秒，弹窗仍未消失 —— {3}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已把视频页窗口最小化，前台还给你了': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已按全课程章节读取到 {0} 个视频，将按课程顺序播放': ('scope_all', '已按全课程章节读取到 3 个视频，将按课程顺序播放'),
    '已排除 {0} 个非视频活动（文档/课件/压缩包/讨论等），{1} 个按视频处理': ('excluded', '已排除 3 个非视频活动（文档/课件/压缩包/讨论等），3 个按视频处理'),
    '已播完、平台仍未标记完成，先跳过这一讲（建议稍后人工核对）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已暂停页面中的视频': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已识别到课程页面：{0}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已读取课程结构：{0} 个章节，共 {1} 个活动': ('structure', '已读取课程结构：3 个章节，共 3 个活动'),
    '已重新连接浏览器': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已重新连接浏览器，继续监控本讲': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '已附着到浏览器窗口：{0}': ('message_3', '已附着到浏览器窗口：3'),
    '干跑模式：仅完成环境检查、附着与列表读取，不进行实际播放': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '平台已记账完成，本讲结束{0}': ('platform_done', '平台已记账完成，本讲结束3'),
    '当前处于未登录状态，请在 Edge 窗口中完成登录（脚本会自动等待，最长 10 分钟）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '当前标签页不是课程页面，等待你在 Edge 中打开': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '当前章共 {0} 讲': ('scope_current', '当前章共 3 讲'),
    '打开页面：$Url': ('hidden_1', '打开页面：3'),
    '按住期间窗口离开了前台，已自动拉回（窗口不可见时平台不累计按住进度）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '收到停止指令，保存当前进度并退出': ('message_9', '收到停止指令，保存当前进度并退出'),
    '收到停止指令，结束等待': ('message_9', '收到停止指令，结束等待'),
    '无法开始播放，稍后重试': ('message_15', '无法开始播放，稍后重试'),
    '无法重新连接浏览器，本讲中止。可重新点「开始刷课」继续': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '无法重新连接浏览器，脚本停止。可稍后重新点「开始刷课」继续': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '有 {0} 个活动需要页面证据，正在逐个只读核对…': ('need_evidence', '有 3 个活动需要页面证据，正在逐个只读核对…'),
    '有 {0} 讲读不到平台完成状态，正在实时核对…': ('completion_probe', '有 3 讲读不到平台完成状态，正在实时核对…'),
    '本次将处理 {0} 个视频：': ('message_5', '本次将处理 3 个视频：'),
    '本讲已经 {0} 分钟没有任何播放进展，跳过它（后面可在汇总里看到）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '本讲章节：{0}': ('chapter', '本讲章节：3'),
    '检测到页面上有 {0} 个视频在同时播放，先清掉多余的（避免平台判定为同时观看）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '上一讲媒体已停止，在当前标签页切换到活动 {0}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '上一讲媒体未能确认停止，跳过本讲以避免平台判定同时观看': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '仍在等待你处理平台提示：{0}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '平台提示已消失，继续播放': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '平台提示持续存在超过 {0} 分钟，本轮停止，避免继续请求；处理后可重新开始': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '平台风控提示未解除，本轮停止；处理后可重新开始': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '未能确认上一讲媒体已完全停止，等待后重试一次': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '检测到平台风控提示：{0}。已暂停播放，等待你处理（不会自动重试、不会提交完成）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '还有 {0} 讲读不到平台完成状态；为避免逐页打开产生额外请求，本轮按未完成处理': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '课程读取间隔检查失败，本次不请求网站': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '汇总：{0}': ('summary', '汇总：1. 第1讲-示例 —— 已完成（进度 100%）'),
    '没能确认已切到目标讲（页面地址不含活动 id？），按页面就绪继续': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '注意：「按住确认」坐标 ({0},{1}) 的最顶层元素是 [{2}]，不是按钮本身 —— 若本次失败，多半是被它挡住了': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '注意：当前播放速率为 {0}x，请保持 1 倍速播放': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '浏览器连接似乎断开了，正在尝试重新附着（第 {0}/3 次）…': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '浏览器连接已断开，无法继续等待视频页，脚本停止': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '浏览器连接已断开，正在重新附着…': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '清理陈旧的 run.pid（进程 {0} 已不是当前引擎）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '点击播放按钮': ('hidden_2', '点击播放按钮'),
    '点击视频画面尝试开始播放': ('hidden_3', '点击视频画面尝试开始播放'),
    '登录已完成，继续执行': ('message_10', '登录已完成，继续执行'),
    '确认已完成，恢复播放监控': ('message_11', '确认已完成，恢复播放监控'),
    '章节「{1}」共 {0} 讲': ('scope_chapter', '章节「3」共 3 讲'),
    '第 {0} 讲《{1}》弹出【考勤确认】，自动长按「按住确认」进行校验（第 {2}/{3} 次，每次最多按住 {4} 秒）': ('message_18', '第 3 讲《3》弹出【考勤确认】，自动长按「按住确认」进行校验（第 3/3 次，每次最多按住 3 秒）'),
    '第 {0} 讲《{1}》执行出错：{2}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '等人工确认已超过 {0} 分钟，先跳过这一讲（稍后可在汇总里看到）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '等你在浏览器里打开视频页已超过 {0} 分钟，脚本先退出。想继续请重新点「开始刷课」': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '等待被中断': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '脚本启动': ('message_0', '脚本启动'),
    '脚本结束': ('hidden_4', '脚本结束'),
    '脚本编码自检未通过，已中止': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '自动长按未能通过，改为你本人确认：请在 Edge 窗口里按住「按住确认」直到进度条满': ('message_14', '自动长按未能通过，改为你本人确认：请在 Edge 窗口里按住「按住确认」直到进度条满'),
    '视频已播放到结尾，等待平台记账（最长 90 秒）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '视频播完了但平台进度还没满（它可能要求 100%、而记的时长比视频长）—— 重播一遍补时长（第 {0}/{1} 次）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '视频暂停已超过 {0:N0} 秒，第 {1} 次尝试恢复播放': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '计划 {0}. {1}（活动 {2}）': ('plan_item', '计划 3. 3（活动 3）'),
    '识别完成：本轮需要播放 {0} 讲': ('identified', '识别完成：本轮需要播放 3 讲'),
    '识别结果：这门课的讲都已经完成了，本轮没有需要播放的内容': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '识别过程被停止': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '该讲此前已完成，跳过播放（平台记录进度 {0}）': ('message_8', '该讲此前已完成，跳过播放（平台记录进度 3）'),
    '请在这个 Edge 窗口里打开你要看的那一讲视频页面（脚本会自动识别并开始，无需其它操作）': ('message_22', '请在这个 Edge 窗口里打开你要看的那一讲视频页面（脚本会自动识别并开始，无需其它操作）'),
    '读取课程结构失败（{0}）：请确认已登录，并停在课程页或任意一讲页面': ('structure_retry', '读取课程结构失败（3）：请确认已登录，并停在课程页或任意一讲页面'),
    '读取课程结构失败：{0}': ('structure_retry', '读取课程结构失败：3'),
    '课程结构没读到，正在重连浏览器后重试一次…': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '还有 {0} 个活动证据不足，保留为待确认，暂不加入播放清单': ('unverified', '还有 3 个活动证据不足，保留为待确认，暂不加入播放清单'),
    '进度 {0}%（{1:N0}/{2:N0} 秒）': ('progress', '进度 3%（3/3 秒）'),
    '连续 $maxRetry 次无法恢复播放，跳过本讲': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '逐项核对完成：{0}/{1} 讲已判定（耗时 {2} 秒）': ('completion_result_current', '逐项核对完成：3/3 讲已判定（耗时 3 秒）'),
    '配置 auto_confirm=false：跳过自动长按，等你本人按「按住确认」': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '采集课程结构时出错：{0}': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '重播了 1 分钟、平台进度仍停在 {0}%（没涨）—— 说明这门课重播补时长没用，先跳过这一讲': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '重播没能开始（播放器状态异常），按"已播完"处理': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '重新识别完成：核对到 0 讲还没完成（只识别，不播放）': ('message_2', '重新识别完成：核对到 0 讲还没完成（只识别，不播放）'),
    '重新识别完成：核对到 {0} 讲还没完成（只识别，不播放）': ('message_2', '重新识别完成：核对到 3 讲还没完成（只识别，不播放）'),
    '重新识别模式：只核对每一讲的完成情况，不播放视频': ('message_1', '重新识别模式：只核对每一讲的完成情况，不播放视频'),
    '长按校验通过，弹窗已关闭': ('message_12', '长按校验通过，弹窗已关闭'),
    '页面上没找到「按住确认」按钮（弹窗可能已自行消失，或结构与预期不同）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '页面反复被跳离目标讲，放弃这一讲（避免无限拉锯）': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '页面在 $TimeoutSec 秒内未就绪：$Url': (None, '原文已说明操作结果或故障原因，无需翻译'),
    '页面显示已完成，本讲结束{0}': ('message_7', '页面显示已完成，本讲结束3'),
    '页面被跳走了（当前 {0}，目标 {1}）—— 直接导航回来继续': (None, '原文已说明操作结果或故障原因，无需翻译'),
}

DYNAMIC_EXPRESSIONS = {
    "$r.error": "范围选择器返回的用户可读错误",
    "$msg": "单实例互斥失败提示，包含占用进程信息",
}
