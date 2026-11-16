<#
=====================================================================
 砺儒云课堂 · 课程视频播放辅助脚本   auto_course.ps1
---------------------------------------------------------------------
 工作方式（浏览器由你自己操作）：
   1. 你先打开日常 Edge，允许调试连接，再运行「1-接管Edge.bat」，
      登录后自己点进任意一讲的视频页面，并把左上角的课程索引打开；
   2. 再双击「2-开始刷课.bat」：脚本附着到那个 Edge 窗口，
      自动识别你当前打开的视频，从课程索引里读取本小节的视频列表，
      然后从当前这一讲开始，逐讲播放、读取进度、写完自动切下一讲；
   3. 出现「考勤确认 / 学习确认」弹窗时：自动长按「按住确认」按钮完成校验
      （按住不放，直到进度条走满、弹窗关闭才松开）；
      自动未通过时退回提醒模式，由你本人按住完成后自动继续。

 它不做什么（有意为之）：
   * 不修改页面脚本、不拦截或伪造进度上报、不改 cookie/localStorage；
   * 不倍速、不拖动跳播、不静默后台空跑；
   * 不保存账号密码（登录由你在浏览器里手动完成）。

 运行：
   常规使用：双击 2-开始刷课.bat
   接管浏览器：双击 1-接管Edge.bat（旧文件名也兼容）
   只识别不播放：-ScanOnly（控制台「重新识别」按钮用的就是它：读课程结构 +
               实时核对每讲完成情况，写完 课程结构.json 就退出）
   干跑自检：  powershell -NoProfile -ExecutionPolicy Bypass -File auto_course.ps1 -DryRun
               （只做环境检查、附着、列表读取，不实际播放）
   链路自检：  powershell -NoProfile -ExecutionPolicy Bypass -File auto_course.ps1 -SelfTest
               （只连接现有课堂标签，不登录、不播放、不启动浏览器）

 依赖：PowerShell 5.1 + Microsoft Edge + Python 标准库，无需联网安装组件。
=====================================================================
#>

param(
    [switch]$DryRun,
    [switch]$SelfTest,
    [switch]$AttachEdge,
    [switch]$ScanOnly,      # 只识别：读课程结构 + 实时核对每讲完成情况，写完 课程结构.json 就退出（不播放）
    [string]$ConfigPath = '',
    [int]$Limit = 0,        # 只处理计划列表的前 N 讲（0 = 按配置/全部）
    [string]$Scope = 'forward',   # forward=从当前讲刷到课程末尾（默认）；current=只刷当前章（从当前讲开始+回绕）；chapter=刷完某一章；all=刷完全部章节
    [string]$Chapter = ''         # Scope=chapter 时的章节名（支持部分匹配）
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
# 0. 路径与全局状态
# =====================================================================
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
}
if ([string]::IsNullOrEmpty($ConfigPath)) { $ConfigPath = Join-Path $ScriptDir '配置.json' }
$LogPath  = Join-Path $ScriptDir '运行日志.txt'
$StopFlag = Join-Path $ScriptDir 'stop.flag'
$PidFile  = Join-Path $ScriptDir 'run.pid'
$PaceStateFile = Join-Path $ScriptDir '请求节奏.json'

# 识别规则单独一个文件：引擎与控制台共用同一套判定，且能被独立测试。
# 用点源加载会受执行策略限制（用户机器默认可能是 Restricted），
# 所以改成"读文本 + Invoke-Expression"—— 等价于把规则内联进来，但不触发策略检查。
$RulesFile = Join-Path $ScriptDir '识别规则.ps1'
if (-not (Test-Path -LiteralPath $RulesFile)) {
    throw "找不到识别规则文件：$RulesFile（它必须和 auto_course.ps1 放在同一目录）"
}
try {
    $rulesText = [System.IO.File]::ReadAllText($RulesFile, [System.Text.Encoding]::UTF8)
    Invoke-Expression $rulesText
} catch {
    throw ("加载识别规则失败：{0}" -f $_.Exception.Message)
}

$script:CdpId      = 0
$script:Ws         = $null
$script:NotifyIcon = $null
$script:LastMsg    = ''      # 日志限流：上一句日志正文（原始，不含重复计数后缀）
$script:RepeatN    = 0       # 日志限流：同一句连续重复了多少次
$script:LastMsgAt  = $null   # 日志限流：上一句日志的写入时间
$script:Cfg = $null           # 当前配置（供风险暂停等助手读取）
$script:SiteRiskStop = $false          # 平台风控提示未解除时停止本轮

# CDP 接收缓冲整个引擎复用：262KB 超过 85KB 的大对象堆门槛，按次新建会持续制造 GC 压力
# （长按心跳每 220ms、播放轮询每几秒都要走一次接收）；引擎单线程，无并发风险。
$script:CdpRecvBuffer = New-Object byte[] 262144

# 防休眠：挂机刷课期间保持系统与屏幕唤醒（进程退出后 Windows 自动恢复默认行为）
try {
    Add-Type -Namespace Native -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);' -ErrorAction Stop
    $null = [Native.Power]::SetThreadExecutionState(0x80000003)   # CONTINUOUS | SYSTEM | DISPLAY
} catch { }

# =====================================================================
# 1. 日志与提醒
# =====================================================================
function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('信息','提醒','警告','错误','成功')][string]$Level = '信息'
    )
    # 日志限流：同一句话 60 秒内最多记一条，之后的重复只在正文里追加累计次数。
    # 2026-09-15 曾出现"读取状态失败"每 5 秒刷一行、连刷 2000+ 行的情况。
    $now = Get-Date
    $orig = $Message
    if ($orig -eq $script:LastMsg) {
        $script:RepeatN++
        $quiet = $false
        if ($script:LastMsgAt) {
            $quiet = ((New-TimeSpan -Start $script:LastMsgAt -End $now).TotalSeconds -lt 60)
        }
        if ($quiet) { return }
        $Message = '{0}（同一句提示已重复 {1} 次）' -f $orig, ($script:RepeatN + 1)
    } else {
        $script:RepeatN = 0
    }
    $script:LastMsg = $orig
    $script:LastMsgAt = $now

    $line = '{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        '提醒' { 'Yellow' }
        '警告' { 'DarkYellow' }
        '错误' { 'Red' }
        '成功' { 'Green' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
}

function Initialize-Notification {
    # 气泡提醒：不会抢焦点，避免打断使用者按住「按住通过」按钮
    try {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        Add-Type -AssemblyName System.Drawing | Out-Null
        $script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
        $script:NotifyIcon.Visible = $true
        $script:NotifyIcon.Text = '砺儒云课堂脚本'
    } catch {
        $script:NotifyIcon = $null
    }
}

function Show-Reminder {
    param([string]$Title, [string]$Text)
    try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    if ($script:NotifyIcon) {
        try {
            $script:NotifyIcon.BalloonTipTitle = $Title
            $script:NotifyIcon.BalloonTipText  = $Text
            $script:NotifyIcon.ShowBalloonTip(10000)
        } catch { }
    }
    Write-Host ''
    Write-Host ('*' * 62) -ForegroundColor Yellow
    Write-Host ('  ' + $Title) -ForegroundColor Yellow
    Write-Host ('  ' + $Text) -ForegroundColor Yellow
    Write-Host ('*' * 62) -ForegroundColor Yellow
    Write-Host ''
}

function Close-Notification {
    if ($script:NotifyIcon) {
        try { $script:NotifyIcon.Visible = $false; $script:NotifyIcon.Dispose() } catch { }
        $script:NotifyIcon = $null
    }
}

# =====================================================================
# 2. 配置
# =====================================================================
function Read-Config {
    param([string]$Path)
    # 发行包不携带本机配置；首次运行直接使用下方内置默认值。
    $cfg = [pscustomobject]@{}
    if (Test-Path -LiteralPath $Path) {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        if (-not $raw -or -not $raw.TrimStart().StartsWith('{')) { throw '配置文件必须是 JSON 对象' }
        $cfg = ConvertFrom-Json -InputObject $raw
        if ($null -eq $cfg -or $cfg -isnot [pscustomobject]) { throw '配置文件必须是 JSON 对象' }
    } elseif ($Path -ne (Join-Path $ScriptDir '配置.json')) {
        throw "找不到配置文件：$Path"
    }
    $defaults = @{
        section_url         = ''
        debug_port          = 9222
        edge_attach_port    = 9232  # 本机兼容层端口；真实 Edge 端口自动发现
        poll_seconds        = 5
        progress_log_seconds= 30
        paused_stuck_seconds= 60
        max_retries         = 3
        auto_confirm         = $true
        confirm_hold_seconds = 25
        confirm_max_attempts = 3
        # 视频播完但平台进度还没满时，最多重播几次去补时长（详见 README 的说明）
        replay_max = 1
        auto_next           = $true
        start_from_current  = $true
        wrap_around         = $true
        limit_videos        = 0
        # 安全阀（防止无人看管时无限期卡住；配错或填 0 时用上面的内置默认值）
        wait_video_max_minutes   = 30   # 等你打开视频页最多等多久
        wait_confirm_max_minutes = 15   # 等人工按住确认最多等多久
        stuck_minutes            = 20   # 单个视频多久没有播放进展就跳过
        scan_min_seconds         = 60   # 两次课程读取之间的最小间隔（防重复扫描）
        risk_pause_max_minutes   = 10   # 验证码/限流/同时观看时最多等待多久
        pacing_jitter            = $true # 请求/轮询间隔加入随机抖动
    }
    foreach ($k in $defaults.Keys) {
        $has = @($cfg.PSObject.Properties.Name) -contains $k
        if (-not $has) {
            $cfg | Add-Member -NotePropertyName $k -NotePropertyValue $defaults[$k] -Force
        }
    }
    $cfg.debug_port = [int]$cfg.edge_attach_port
    if ($cfg.debug_port -lt 1 -or $cfg.debug_port -gt 65535) { throw 'edge_attach_port 必须在 1 到 65535 之间' }
    return $cfg
}

# =====================================================================
# 2.1 节奏与请求保护
# =====================================================================
function Get-JitterMs {
    # 给轮询/请求间隔加入 ±Percent 的随机抖动，避免固定节拍过于机械。
    param([int]$BaseMs, [int]$Percent = 20)
    if ($BaseMs -le 0) { return 0 }
    if ($Percent -le 0) { return $BaseMs }
    $d = [int]($BaseMs * $Percent / 100)
    if ($d -lt 1) { $d = 1 }
    return [int]($BaseMs + (Get-Random -Minimum (-$d) -Maximum ($d + 1)))
}

function Read-PaceGuard {
    try {
        if (Test-Path -LiteralPath $PaceStateFile) {
            return [IO.File]::ReadAllText($PaceStateFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        }
    } catch { }
    return [pscustomobject]@{ lastScanAt = '' }
}

function Save-PaceGuard {
    param($Guard)
    try {
        $json = $Guard | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($PaceStateFile, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

function Enter-RequestGuard {
    # 所有启动/重新识别在读取课程前统一经过这里，避免交替开始/停止导致重复扫描。
    param($Cfg)
    $min = 60
    if ($Cfg -and [int]$Cfg.scan_min_seconds -gt 0) { $min = [int]$Cfg.scan_min_seconds }
    $g = Read-PaceGuard
    if (-not $g) { $g = [pscustomobject]@{ lastScanAt = '' } }
    $age = $null
    if ($g.lastScanAt) {
        try { $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$g.lastScanAt)).TotalSeconds } catch { $age = $null }
    }
    if ($null -ne $age -and $age -lt $min) {
        throw ("课程读取间隔不足 {0} 秒（上次在 {1:N0} 秒前），本次不请求网站；请稍后再试。" -f $min, $age)
    }
    $g | Add-Member lastScanAt ([DateTimeOffset]::UtcNow.ToString('o')) -Force
    Save-PaceGuard -Guard $g
}


function Get-SiteRisk {
    # 只读当前页面的可见提示，不额外发请求。考勤弹窗不在此列（由自动长按处理）。
    param($Ws)
    try {
        $raw = Invoke-Js -Ws $Ws -Expression $JsSiteRiskProbe -TimeoutMs 5000
        if ([string]::IsNullOrEmpty($raw)) { return $null }
        $o = ConvertFrom-Json -InputObject $raw
        if ($o -and -not [string]::IsNullOrWhiteSpace([string]$o.risk)) { return $o }
    } catch { }
    return $null
}

function Pause-ForSiteRisk {
    # 检测到验证码/限流/同时观看/登录失效时暂停等待本人处理；
    # 不自动识别验证码、不自动重试、不提交完成。处理完成后自动继续。
    param($Ws, $Risk, [int]$Index = 0, [string]$Title = '', $Cfg = $null)
    if (-not $Risk) { return 'ok' }
    $reason = [string]$Risk.reason
    if ([string]::IsNullOrWhiteSpace($reason)) { $reason = [string]$Risk.risk }
    $maxMin = 10
    if ($Cfg -and [int]$Cfg.risk_pause_max_minutes -gt 0) { $maxMin = [int]$Cfg.risk_pause_max_minutes }
    Write-Log ("检测到平台风控提示：{0}。已暂停播放，等待你处理（不会自动重试、不会提交完成）" -f $reason) '警告'
    try { $null = Invoke-Js -Ws $Ws -Expression $JsPauseVideo -TimeoutMs 4000 } catch { }
    Show-Reminder -Title '平台风控提示，需要你处理' -Text ("{0}。请在 Edge 中完成验证/关闭其它视频/等待限制解除；脚本最多等你 {1} 分钟。" -f $reason, $maxMin)
    $deadline = (Get-Date).AddMinutes($maxMin)
    $round = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-StopRequested) { return 'stopped' }
        Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 8000 -Percent 20)
        $again = Get-SiteRisk -Ws $Ws
        if (-not $again) {
            Write-Log '平台提示已消失，继续播放' '成功'
            return 'ok'
        }
        $round++
        if (($round % 3) -eq 0) { Write-Log ("仍在等待你处理平台提示：{0}" -f [string]$again.reason) '提醒' }
    }
    Write-Log ("平台提示持续存在超过 {0} 分钟，本轮停止，避免继续请求；处理后可重新开始" -f $maxMin) '错误'
    return 'timeout'
}

# =====================================================================
# 3. 环境与 Edge
# =====================================================================


function Test-ProcessAlive {
    # 判断某个 PID 是否还活着（用于"已有脚本在跑吗"的单实例保护）
    param([int]$Id)
    if ($Id -le 0) { return $false }
    try {
        $p = [System.Diagnostics.Process]::GetProcessById($Id)
        return (-not $p.HasExited)
    } catch {
        return $false
    }
}


# =====================================================================
# 4. CDP（Chrome DevTools Protocol）最小客户端
# =====================================================================
function Get-CdpTarget {
    param([int]$Port)
    # 只认本工具的适配器，不能把端口上的其他服务或浏览器误当成目标。
    $attachState = Get-EdgeAttachState -Port $Port
    if (-not $attachState.connected) { throw ([string]$attachState.message) }
    # 用 .NET 直接请求，绕过系统代理设置
    $url = "http://127.0.0.1:$Port/json/list"
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Proxy = $null
    $req.Timeout = 4000
    $resp = $req.GetResponse()
    $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
    $json = $reader.ReadToEnd()
    $reader.Close(); $resp.Close()
    $parsed = ConvertFrom-Json -InputObject $json
    $pages = @($parsed | Where-Object {
        if ($_.type -ne 'page') { return $false }
        if ($SelfTest) { return $true }
        try {
            $u = [Uri]([string]$_.url)
            return $u.Scheme -in @('http', 'https') -and $u.Host -eq 'moodle.scnu.edu.cn' -and -not $u.UserInfo
        } catch { return $false }
    })
    if ($pages.Count -eq 0) { return $null }
    # 仅本站目标：已识别视频 > 候选视频 > 课程页 > 本站其它页。
    # 只用 /mod/*/view.php 会把资料/讨论页也排进来；如果同时开着视频和资料两个标签，
    # 引擎可能附着到资料页，后面自然一路报错。结构文件里 video=true 的 id 是最可靠的锚。
    $videoIds = @()
    $nonVideoIds = @()
    try {
        $cf = Join-Path $PSScriptRoot '课程结构.json'
        if (Test-Path -LiteralPath $cf) {
            $cs = Get-Content -LiteralPath $cf -Raw -Encoding UTF8 | ConvertFrom-Json
            $items = @($cs.sections | ForEach-Object { $_.items })
            $videoIds = @($items | Where-Object { $_.video -eq $true } | ForEach-Object { [string]$_.id })
            $nonVideoIds = @($items | Where-Object { $_.video -eq $false } | ForEach-Object { [string]$_.id })
        }
    } catch { }
    # 视频插件白名单直接用 识别规则.ps1 的 $script:VideoTypes（本脚本启动时已加载该文件），
    # 不再手抄第三份名单 —— 白名单曾经三处各一份，改一处漏两处。
    $videoPlugins = @($script:VideoTypes)
    $activities = @($pages | Where-Object {
        try { ([Uri]$_.url).AbsolutePath -match '^/mod/[a-z][a-z0-9_]*/view\.php$' } catch { $false }
    })
    if ($videoIds.Count -gt 0) {
        $knownVideos = @($activities | Where-Object {
            $m = [regex]::Match(([Uri]$_.url).Query, '(?:^\?|&)id=(\d+)(?:&|$)')
            $m.Success -and ($videoIds -contains $m.Groups[1].Value)
        })
        if ($knownVideos.Count -gt 0) { return $knownVideos[0] }
    }
    # 结构里没有/已过期：只接受视频插件且标题不像课件的活动页；
    # 资料/讨论/作业页绝不能静默当成视频目标。
    $unknownVideos = @($activities | Where-Object {
        $u = [string]$_.url
        $m = [regex]::Match(([Uri]$u).Query, '(?:^\?|&)id=(\d+)(?:&|$)')
        $id = if ($m.Success) { $m.Groups[1].Value } else { '' }
        if (-not $id) { return $false }
        if ($id -and ($nonVideoIds -contains $id)) { return $false }
        $pm = [regex]::Match($u, '/mod/([^/]+)/view\.php')
        $plugin = if ($pm.Success) { $pm.Groups[1].Value.ToLower() } else { '' }
        if ($videoPlugins -notcontains $plugin) { return $false }
        $t = [string]$_.title
        return -not ($t -match '(课件|讲义|资料|文档|大纲|教材|实验指导|\.pdf|\.pptx?|\.docx?|\.xlsx?|\.zip|\.rar|\.7z)')
    })
    if ($unknownVideos.Count -gt 0) { return $unknownVideos[0] }
    $course = @($pages | Where-Object {
        try { ([Uri]$_.url).AbsolutePath -match '^/course/(view|section)\.php$' } catch { $false }
    })
    if ($course.Count -gt 0) { return $course[0] }
    $moodle = @($pages | Where-Object { $_.url -match '^https?://moodle\.scnu\.edu\.cn(/|$)' })
    if ($moodle.Count -gt 0) { return $moodle[0] }
    return $pages[0]
}

function Connect-Cdp {
    param([int]$Port)
    $deadline = (Get-Date).AddSeconds(40)
    $target = $null
    while ((Get-Date) -lt $deadline -and -not $target) {
        try { $target = Get-CdpTarget -Port $Port } catch { }
        if (-not $target) { Start-Sleep -Milliseconds 900 }
    }
    if (-not $target) { throw "无法获取浏览器调试目标（端口 $Port）" }
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.Proxy = $null
    try {
        $connectTask = $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [System.Threading.CancellationToken]::None)
        if (-not $connectTask.Wait(15000)) { throw "连接调试端口超时（15 秒）" }
    } catch {
        try { $ws.Abort(); $ws.Dispose() } catch { }
        throw
    }
    $script:Ws = $ws
    Write-Log ("已附着到浏览器窗口：{0}" -f $target.title) '成功'
    return $ws
}

function Receive-CdpMessage {
    # 关键：ReceiveAsync 不能“超时后还留着 pending 的 receive”再重新调用，
    # 否则同一个 WebSocket 会抛 InvalidOperationException。这里用带取消的 Receive，
    # 超时就 Abort 掉连接，让上层走重连，绝不复用半死的 socket。
    param($Ws, [int]$TimeoutMs = 30000)
    if ($TimeoutMs -lt 100) { $TimeoutMs = 100 }
    # 大多数消息是几百字节；262KB 足够课程扫描，超长消息仍会走 EndOfMessage=false 的循环拼接。
    # 缓冲复用脚本级的 $script:CdpRecvBuffer（见顶部定义处的说明），不再按次新建。
    $buffer = $script:CdpRecvBuffer
    $sb = New-Object System.Text.StringBuilder
    # UTF-8 中文字符可能横跨 WebSocket 分帧，必须用有状态解码器。
    $decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    if (-not $script:CdpRecvChars -or $script:CdpRecvChars.Length -lt ($buffer.Length + 1)) {
        $script:CdpRecvChars = New-Object char[] ($buffer.Length + 1)
    }
    $chars = $script:CdpRecvChars
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $buffer)
        $cts = New-Object System.Threading.CancellationTokenSource
        try {
            $remaining = $TimeoutMs - [int]$watch.ElapsedMilliseconds
            if ($remaining -le 0) { throw "调试连接读取超时（${TimeoutMs}ms）" }
            $cts.CancelAfter($remaining)
            $task = $Ws.ReceiveAsync($seg, $cts.Token)
            try { $task.Wait() } catch { throw "调试连接读取超时（${TimeoutMs}ms）" }
            if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
            if ($task.IsCanceled) { throw "调试连接读取超时（${TimeoutMs}ms）" }
            $res = $task.Result
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw '浏览器调试连接已被关闭（Edge 窗口是否被关掉了？）'
            }
            $count = $decoder.GetChars($buffer, 0, $res.Count, $chars, 0, [bool]$res.EndOfMessage)
            [void]$sb.Append($chars, 0, $count)
            if ($res.EndOfMessage) { break }
        } catch {
            try { $Ws.Abort() } catch { }
            throw
        } finally {
            $cts.Dispose()
        }
    }
    return $sb.ToString()
}

function Send-CdpCommand {
    param($Ws, [string]$Method, $Params, [int]$TimeoutMs = 30000)
    $script:CdpId++
    $id = $script:CdpId
    $payload = @{ id = $id; method = $Method; liruTimeoutMs = $TimeoutMs }
    if ($Params) { $payload['params'] = $Params }
    $json = $payload | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $seg = New-Object 'System.ArraySegment[byte]' -ArgumentList (, $bytes)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    $sendCancel = New-Object System.Threading.CancellationTokenSource
    try {
        $sendCancel.CancelAfter($TimeoutMs)
        $null = $Ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sendCancel.Token).GetAwaiter().GetResult()
    } catch {
        try { $Ws.Abort() } catch { }
        throw
    } finally { $sendCancel.Dispose() }
    while ([DateTime]::UtcNow -lt $deadline) {
        $remain = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($remain -lt 100) { break }
        $msg = Receive-CdpMessage -Ws $Ws -TimeoutMs $remain
        if ([string]::IsNullOrEmpty($msg)) { continue }
        $obj = $null
        try { $obj = ConvertFrom-Json -InputObject $msg } catch { continue }
        if ($obj.id -eq $id) {
            if ($obj.error) { throw ('调试命令失败：{0} ({1})' -f $Method, $obj.error.message) }
            return $obj
        }
    }
    throw "调试命令超时：$Method"
}

function Invoke-Js {
    param($Ws, [string]$Expression, [int]$TimeoutMs = 30000, [switch]$UserGesture)
    $params = @{
        expression    = $Expression
        returnByValue = $true
        awaitPromise  = $true
    }
    # userGesture=true 让页面把这次执行视作用户手势：video.play() 不会被自动播放策略拒绝
    if ($UserGesture) { $params['userGesture'] = $true }
    $r = Send-CdpCommand -Ws $Ws -Method 'Runtime.evaluate' -Params $params -TimeoutMs $TimeoutMs
    if ($r.result -and $r.result.exceptionDetails) {
        $desc = $r.result.exceptionDetails.text
        throw "页面脚本执行出错：$desc"
    }
    if ($r.result -and $r.result.result) {
        $names = @($r.result.result.PSObject.Properties.Name)
        if ($names -contains 'value') { return $r.result.result.value }
    }
    return $null
}

# =====================================================================
# 5. 页面脚本片段（在页面里执行的 JS）
# =====================================================================
# =====================================================================
# 统一的「完成判定」函数（2026-09-19 泛化：适配本平台**所有课程**）
# 供 Get-PlayerState（当前页面）与批量核对（fetch 各讲页面）共用同一套逻辑。
# ⚠ 为什么必须通用：本平台上不同课程的**完成线不同**（有 90%、有 100%），
#   旧判据把阈值硬编码成 100 —— 对 90% 完成线的课会把"平台已判定完成"的讲
#   误判成未完成（反复重刷）；而"页面出现『已完成』字样"的过宽匹配又会误判。
#   新判据顺序：① 平台自己给的结论 → ② 平台写明的完成线 + 真实观看进度
#   → ③ Moodle 标准完成标记 → ④ 判不出来返回 null（交给上层回退，绝不瞎猜）。
# =====================================================================
$JudgeFnJs = @'
  function judgeCompletion(doc, main) {
    // 返回 true=已完成 / false=未完成 / null=判不出来
    // ⚠ 2026-09-20 用户明确要求：**不管平台的完成线是 90% 还是 80%，都要把进度刷到 100%**
    //   才算这一讲做完。所以这里**不再看完成线、也不看平台那句「当前状态为已完成」**
    //   （平台可能 90% 就标已完成，但那不是用户要的），**只认平台进度真的满 100%**。
    var html = (main && main.innerHTML) || '';
    var txt = ((main && main.textContent) || '').replace(/\s+/g, ' ');
    // 平台记录的观看进度：百分比必须**紧跟在标签后面**（只允许少量空白/冒号），
    // 否则会跨字符咬到"需要达到90%"里的数字。
    var mProg = txt.match(/我的播放进度[\s:：]{0,4}?(\d{1,3}(?:\.\d+)?)\s*[%％]/);
    if (mProg) { return parseFloat(mProg[1]) >= 100; }
    // 页面没有进度信息时，退回平台标准完成标记（别的插件/主题可能用这套）
    if (/data-completionstate="(1|2)"/.test(html)) { return true; }
    if (/completion-complete/.test(html) && !/completion-incomplete/.test(html)) { return true; }
    // 判不出来 → null（交给上层回退：课程索引 / 逐讲打开核对）
    return null;
  }
'@

# 读取播放器与页面状态，统一以 JSON 字符串返回
$JsGetState = (@'
(function () {
  var v = document.querySelector('video');
  var st = { hasVideo: false, current: 0, duration: 0, paused: true, ended: false, rate: 1, dialog: false, completed: false, completedKnown: false, platPct: null, activityId: '', href: location.href };
  if (v) {
    st.hasVideo = true;
    st.current  = v.currentTime || 0;
    st.duration = v.duration || 0;
    st.paused   = !!v.paused;
    st.ended    = !!v.ended;
    st.rate     = v.playbackRate || 1;
  }
  // ---- 「考勤确认」弹窗判定（2026-09-16 重写）----
  // 旧版用 `/请长按|学习确认|.../.test(body.innerText)` 全文匹配，两个真实故障：
  //   ① 播放器下方/页脚的说明文字里也含这些词 → 弹窗早就关了，dialog 仍是 true，
  //      脚本永远停在"考勤未通过"，用户手动按完也恢复不了（用户实报的那个 bug）；
  //   ② 真正的判据应该是"那个长按按钮此刻可不可见"，这才是弹窗活着的唯一硬证据。
  // 所以改成：**先按长按按钮的存在性判断**，全文匹配只作为兜底
  // （按钮被包在 iframe/shadow DOM 里时找不到，只能退回全文）。
  var body = document.body ? document.body.innerText : '';
  st.dialog = false;
  var holdAll = document.querySelectorAll('button,[role="button"],a,div,span,p');
  for (var hb = 0; hb < holdAll.length; hb++) {
    var hn = holdAll[hb];
    if (hn.children.length !== 0) { continue; }
    var ht = (hn.textContent || '').replace(/\s+/g, '');
    if (!/^按住(确认|通过)$/.test(ht)) { continue; }
    var hr = hn.getBoundingClientRect();
    if (hr.width < 10 || hr.height < 8) { continue; }
    var hs = window.getComputedStyle(hn);
    if (hs.display === 'none' || hs.visibility === 'hidden' || hs.opacity === '0') { continue; }
    st.dialog = true;
    st.holdX = Math.round(hr.left + hr.width / 2);
    st.holdY = Math.round(hr.top + hr.height / 2);
    break;
  }
  if (!st.dialog) {
    // 全文兜底只在“确实存在可见模态框”时启用：页脚/帮助文字里也常出现这些词，
    // 旧版用 body.innerText 会把已关闭的弹窗永久判成存在。
    var modal = document.querySelector('[role="dialog"], dialog[open], .modal.show, .moodle-dialogue, .modal-dialog');
    if (modal) {
      var ms = window.getComputedStyle(modal);
      if (ms.display !== 'none' && ms.visibility !== 'hidden') {
        st.dialog = /请长按|按住确认|按住通过|确认你仍在观看/.test(modal.innerText || '');
      }
    }
  }
  // 当前页面是哪个活动（供调用方校验"确实切到目标讲了"，别把上一讲的状态当成本讲的）
  var activityUrl = new URL(location.href), activityId = activityUrl.searchParams.get('id') || '';
  st.activityId = /\/mod\/[^/]+\/view\.php$/.test(activityUrl.pathname) && /^\d+$/.test(activityId) ? activityId : '';
  // ---- 完成判定：统一走 judgeCompletion（已泛化到不同完成线，见上方 $JudgeFnJs）----
  var main = document.querySelector('[role="main"]') || document.querySelector('#region-main') || document.body;
  __JUDGE__
  var jc = judgeCompletion(document, main);
  st.completed = (jc === true);        // null/未完成 都按未完成处理（保守：继续播，不误跳）
  st.completedKnown = (jc !== null);   // 是否判得出来（判不出交给上层回退）
  // 平台记录的**真实观看进度**：优先读插件卡片的专用节点（.num-bfjd），
  // 比全文正则更稳：不会咬到"需要达到100%"这类说明文字，也省一次整段文本扫描。
  // 读不到再退回"我的播放进度"文本匹配（其它插件/主题的兜底）。
  var platRoot = main || document;
  var platEl = platRoot.querySelector('.fsresource-info .num-bfjd, .num-bfjd');
  if (platEl) {
    // 只取第一个数字：元素里若出现 "0 / 100" 这类文本，直接剥非数字会拼成 0100。
    var pm = (platEl.textContent || '').match(/(\d+(?:\.\d+)?)/);
    var pv = pm ? parseFloat(pm[1]) : NaN;
    if (!isNaN(pv) && pv >= 0 && pv <= 100) { st.platPct = pv; }
  }
  if (st.platPct === null) {
    var mPlat = ((main && main.textContent) || '').replace(/\s+/g, ' ').match(/我的播放进度[\s:：]{0,4}?(\d{1,3}(?:\.\d+)?)\s*[%％]/);
    st.platPct = mPlat ? parseFloat(mPlat[1]) : null;
  }
  // 平台进度是完成判定的最终依据：.num-bfjd 已经 100% 时，即使文本节点没匹配到，
  // 也不能再继续播/重播（否则白等一整段，最后还报“未确认完成”）。
  if (st.platPct !== null && st.platPct >= 100) { st.completed = true; st.completedKnown = true; }
  return JSON.stringify(st);
})()
'@).Replace('__JUDGE__', $JudgeFnJs)

# 直接调用 video.play()（第一优先用真实点击，这里是兜底）
$JsCallPlay = @'
(function () {
  var v = document.querySelector('video');
  if (!v) { return 'novideo'; }
  if (!v.paused) { return 'already-playing'; }
  try { var p = v.play(); if (p && p.catch) { p.catch(function () { }); } return 'called'; }
  catch (e) { return 'error'; }
})()
'@

# 从头重播本讲（用于"播完了但平台进度仍没满"的情况，见 Invoke-WatchVideo 里的说明）
$JsReplay = @'
(function () {
  var v = document.querySelector('video');
  if (!v) { return 'novideo'; }
  try { v.currentTime = 0; } catch (e) { }
  try { var p = v.play(); if (p && p.catch) { p.catch(function () { }); } return 'replayed'; }
  catch (e) { return 'error'; }
})()
'@

# 停止/退出时把页面里的视频暂停（脚本不跑了，视频也不该在后台继续播）
$JsPauseVideo = @'
(function () {
  var v = document.querySelector('video');
  if (!v) { return 'novideo'; }
  if (v.paused) { return 'already-paused'; }
  try { v.pause(); return 'paused'; } catch (e) { return 'error'; }
})()
'@

$JsReleaseMedia = @'
(async function () {
  var count=0, failed=false, media=[];
  function release(doc) {
    var vs=doc.querySelectorAll('video,audio');
    for(var i=0;i<vs.length;i++) {
      var v=vs[i]; count++; media.push(v);
      try {
        v.pause(); v.autoplay=false; v.removeAttribute('autoplay');
        if(v.srcObject) v.srcObject=null;
        v.querySelectorAll('source').forEach(function(n){n.removeAttribute('src');n.removeAttribute('srcset');});
        v.removeAttribute('src'); v.load();
      } catch(e) { failed=true; }
    }
    var frames=doc.querySelectorAll('iframe');
    for(var f=0;f<frames.length;f++) {
      try {
        var child=frames[f].contentDocument;
        if(child) release(child); else failed=true;
      } catch(e) { failed=true; }
    }
  }
  release(document);
  var released=false;
  for(var attempt=0;attempt<10;attempt++) {
    released=media.every(function(v){return v.paused && !v.srcObject && !v.hasAttribute('src') && !v.querySelector('source[src]') && v.readyState===0 && (v.networkState===0 || v.networkState===3) && v.buffered.length===0;});
    if(released) break;
    await new Promise(function(resolve){setTimeout(resolve,100);});
  }
  if(!released) failed=true;
  return JSON.stringify({ok:!failed,total:count});
})()
'@

# 风控信号探测（只读 DOM；不把考勤弹窗当风险，考勤由自动长按处理）
$JsSiteRiskProbe = @'
(function () {
  var href = location.href || '';
  function vis(n) {
    if (!n) return false;
    var r = n.getBoundingClientRect(), s = getComputedStyle(n);
    return r.width > 0 && r.height > 0 && s.display !== 'none' && s.visibility !== 'hidden' && s.opacity !== '0';
  }
  function noticeText() {
    var out = '', ns = document.querySelectorAll('[role="alert"],[role="dialog"],.toast,.alert-danger,.layui-layer-content,.el-message,.modal.show,.moodle-dialogue');
    for (var i = 0; i < ns.length; i++) { if (vis(ns[i])) out += ' ' + (ns[i].innerText || ns[i].textContent || ''); }
    return out.replace(/\s+/g, ' ').slice(0, 4000);
  }
  var risk = '', reason = '';
  var caps = document.querySelectorAll('input[name*="captcha" i],input[id*="captcha" i],iframe[src*="recaptcha"],iframe[src*="hcaptcha"],.geetest_panel,.geetest_holder,.nc-container,.g-recaptcha,.h-captcha,.cf-turnstile');
  for (var i = 0; i < caps.length; i++) { if (vis(caps[i])) { risk = 'captcha'; reason = '网站要求验证码或安全验证'; break; } }
  if (!risk && /captcha|challenge|security[-_]?check|\/verify(?:\/|\.)/i.test(href)) { risk = 'captcha'; reason = '网站要求安全验证'; }
  if (!risk) {
    var s = noticeText();
    if (/(?:访问|请求)(?:过于|太|过度)?频繁|访问频率.{0,8}(?:限制|超)|too many requests|rate limit/i.test(s)) { risk = 'rate'; reason = '网站限制访问频率'; }
    else if (/(?:禁止|不可|不能).{0,8}同时.{0,6}观看|已关闭上一个视频|同时观看/i.test(s)) { risk = 'simultaneous'; reason = '平台提示同时观看多个视频'; }
    else if (/(?:请输入|请完成|需要通过).{0,12}(?:验证码|安全验证|人机验证)|verify (?:you are|that you are) human|checking your browser/i.test(s)) { risk = 'captcha'; reason = '网站要求验证或安全验证'; }
    else if (/服务(?:暂时)?不可用|系统(?:繁忙|异常)|internal server error|bad gateway|service unavailable/i.test(s)) { risk = 'server'; reason = '网站返回异常服务提示'; }
  }
  if (!risk && /\/login\/index\.php|\/login\?|\/auth\/|\/sso\//i.test(href)) {
    var pw = document.querySelector('input[type="password"]');
    if (pw && vis(pw)) { risk = 'login'; reason = '登录已失效，需要重新登录'; }
  }
  return JSON.stringify({ risk: risk, reason: reason, href: href });
})()
'@

# 视频画面中心坐标（兜底点击，多数播放器点画面即播放/暂停）
$JsVideoRect = @'
(function () {
  var v = document.querySelector('video');
  if (!v) { return ''; }
  var r = v.getBoundingClientRect();
  if (r.width <= 0 || r.height <= 0) { return ''; }
  return JSON.stringify({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
})()
'@

# 按“可见名称”查找按钮并返回中心坐标（用于「播放」「打开课程索引」等）
$JsTemplateClickByName = @'
(function () {
  var name = '__NAME__';
  var nodes = document.querySelectorAll('button,[role="button"],a,div,span');
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i];
    if (n.children.length !== 0) { continue; }
    var t  = (n.textContent || '').trim();
    var al = (n.getAttribute('aria-label') || '').trim();
    var ti = (n.getAttribute('title') || '').trim();
    if (t === name || al === name || ti === name) {
      if (!n.offsetParent) { continue; }
      var r = n.getBoundingClientRect();
      if (r.width > 0 && r.height > 0) {
        return JSON.stringify({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) });
      }
    }
  }
  return '';
})()
'@

# 定位「考勤确认」弹窗里的长按按钮（按住确认/按住通过），返回中心坐标
$JsFindHoldButton = @'
(function () {
  function norm(s) { return (s || '').replace(/\s+/g, ''); }
  var cands = [];
  var nodes = document.querySelectorAll('button,[role="button"],a,div,span,p');
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i];
    var t = norm(n.textContent);
    if (!t || t.length > 12) { continue; }
    if (!/^按住(确认|通过)$/.test(t)) { continue; }
    var r = n.getBoundingClientRect();
    if (r.width < 10 || r.height < 8) { continue; }
    var s = window.getComputedStyle(n);
    if (s.display === 'none' || s.visibility === 'hidden') { continue; }
    cands.push({ x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2), area: r.width * r.height });
  }
  if (!cands.length) { return ''; }
  cands.sort(function (a, b) { return a.area - b.area; });
  return JSON.stringify(cands[0]);
})()
'@

# 长按前的体检：按钮坐标 + **坐标上最顶层的元素是谁** + 窗口可见性/焦点。
# 2026-09-17 新增（自动长按 3×45 秒全失败、手动按就过的复盘）——
#   ① 命中目标：CDP 合成事件落在"那个坐标的最顶层元素"上。按钮上若盖着遮罩/浮层，
#     事件就喂给了别人，按钮的处理器根本不触发 —— 旧版完全看不见这种情况；
#   ② 窗口可见性：这类"确认你在看"的机制大概率在窗口隐藏（最小化/被遮挡）时
#     故意不累计按住进度（防挂机）。用户手动按的时候窗口必然在前台，所以手动能过。
$JsHoldProbe = @'
(function () {
  function norm(s) { return (s || '').replace(/\s+/g, ''); }
  var cands = [];
  var nodes = document.querySelectorAll('button,[role="button"],a,div,span,p');
  for (var i = 0; i < nodes.length; i++) {
    var n = nodes[i];
    var t = norm(n.textContent);
    if (!/^按住(确认|通过)$/.test(t)) { continue; }
    var r = n.getBoundingClientRect();
    if (r.width < 10 || r.height < 8) { continue; }
    var s = window.getComputedStyle(n);
    if (s.display === 'none' || s.visibility === 'hidden' || s.opacity === '0') { continue; }
    cands.push({ n: n, r: r, area: r.width * r.height });
  }
  if (!cands.length) { return ''; }
  // 取**最小面积**的那个：按钮外层的容器 div 文本一样、中心重合，
  // 但拿容器当目标会让 elementFromPoint 命中判定失真（实测踩过）——叶子按钮必然最小。
  cands.sort(function (a, b) { return a.area - b.area; });
  var n = cands[0].n, r = cands[0].r;
  var x = Math.round(r.left + r.width / 2), y = Math.round(r.top + r.height / 2);
  var top = document.elementFromPoint(x, y);
  var path = [], hit = false, e = top, guard = 0;
  while (e && guard++ < 8) {
    var tag = String(e.tagName || '?').toLowerCase();
    if (e.id) { tag += '#' + e.id; }
    else if (e.classList && e.classList.length) { tag += '.' + e.classList[0]; }
    path.push(tag + (e === n ? '*' : ''));
    if (e === n) { hit = true; break; }
    e = e.parentElement;
  }
  return JSON.stringify({ x: x, y: y, w: Math.round(r.width), h: Math.round(r.height),
    vis: document.visibilityState, focus: document.hasFocus(), hit: hit, top: path.join('>') });
})()
'@

# pointer 事件计数器（装在捕获阶段）：失败时区分"事件没到页面"还是"平台没认"。
# 每次长按尝试前重跑一遍 = 顺带把计数清零。
$JsArmLongPressProbe = @'
(function () {
  window.__lp = { down: 0, move: 0, up: 0 };
  if (window.__lpArm) { return 'ok'; }
  window.__lpArm = true;
  document.addEventListener('pointerdown', function () { window.__lp.down++; }, true);
  document.addEventListener('pointermove', function () { window.__lp.move++; }, true);
  document.addEventListener('pointerup',   function () { window.__lp.up++; },   true);
  return 'ok';
})()
'@

$JsReadLongPressProbe = @'
(function () { return window.__lp ? JSON.stringify(window.__lp) : ''; })()
'@

# 按住期间的轻量可见性检查（不跑完整状态，避免每 6 秒白算一遍整页文本）
$JsVisibility = @'
(function () { return JSON.stringify({ vis: document.visibilityState, focus: document.hasFocus() }); })()
'@

# 当前活动的 id
$JsCurrentId = @'
(function () {
  // 只认活动页 /mod/<插件>/view.php?id=N；课程首页的 course/view.php?id=N 是课程 id，
  // 不能当成当前活动 id（否则 current 范围会静默退化成整门课）。
  var u = new URL(location.href), id = u.searchParams.get('id') || '';
  return /\/mod\/[^/]+\/view\.php$/.test(u.pathname) && /^\d+$/.test(id) ? id : '';
})()
'@

# 在「课程索引」抽屉里定位指定活动 id 的那一条，返回它的中心坐标。
# 用于"点索引切换讲次"（用户实报：切页时平台常提示"不可同时观看多个视频"）。
# 需要抽屉是打开状态；关着的话调用方先点「打开课程索引」。
$JsFindIndexItem = @'
(function () {
  var id = '__ID__';
  var drawer = document.querySelector('#courseindex, .courseindex, [data-region="courseindex"]');
  if (!drawer) { return JSON.stringify({ status: 'NODRAWER' }); }
  var r0 = drawer.getBoundingClientRect();
  if (!(r0.width > 0 && r0.height > 0)) { return JSON.stringify({ status: 'CLOSED' }); }
  var links = drawer.querySelectorAll('a[href*="/mod/"][href*="view.php"]');
  for (var i = 0; i < links.length; i++) {
    var a = links[i];
    var m = (a.href || '').match(/[?&]id=(\d+)/);
    if (!m || m[1] !== id) { continue; }
    if (!a.offsetParent) { continue; }
    var r = a.getBoundingClientRect();
    if (!(r.width > 0 && r.height > 0)) { continue; }
    return JSON.stringify({ status: 'OK', x: Math.round(r.left + r.width / 2),
                            y: Math.round(r.top + r.height / 2) });
  }
  return JSON.stringify({ status: 'NOTFOUND' });
})()
'@

# 隐藏但存在的 <video> 元素数量：用来判断"页面上是不是还留着上一个播放器"。
# 平台提示「不可同时观看多个视频」的物理原因就是同时存在多个活跃播放器。
$JsVideoCount = @'
(function () {
  var vs = document.querySelectorAll('video');
  var live = 0, playing = 0;
  for (var i = 0; i < vs.length; i++) {
    var v = vs[i];
    var r = v.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) { live++; }
    if (!v.paused && !v.ended) { playing++; }
  }
  return JSON.stringify({ total: vs.length, visible: live, playing: playing });
})()
'@

# 课程索引抽屉当前是开着还是关着（切讲前要据此决定要不要先点开）
$JsDrawerState = @'
(function () {
  var drawer = document.querySelector('#courseindex, .courseindex, [data-region="courseindex"]');
  if (!drawer) { return JSON.stringify({ status: 'NODRAWER' }); }
  var r = drawer.getBoundingClientRect();
  if (!(r.width > 0 && r.height > 0)) { return JSON.stringify({ status: 'CLOSED' }); }
  return JSON.stringify({ status: 'OPEN' });
})()
'@

# 当前页所属章节名（面包屑里那个 course/section.php 链接的文字，例如「第一周-教学视频」）
$JsSectionName = @'
(function () {
  var a = document.querySelector('.breadcrumb a[href*="course/section.php"]');
  if (a) { var t = (a.textContent || '').replace(/\s+/g, ' ').trim(); if (t) { return t; } }
  a = document.querySelector('a[href*="course/section.php"]');
  if (a) { var t2 = (a.textContent || '').replace(/\s+/g, ' ').trim(); if (t2) { return t2; } }
  return '';
})()
'@

# =====================================================================
# 课程扫描：一次请求拿到整门课的章节 + 每个活动的插件/图标/完成状态
# =====================================================================
# 为什么改成"抓课程页 + 解析图标"（2026-10-19 重写）：
#   · 旧版先试官方 Web Service（本校已禁用，每次都失败并打一条警告，纯噪音）；
#     再退回抽屉 DOM —— 但抽屉里**没有文件类型信息**，只能按插件名猜，
#     而 fsresource 插件既能装视频也能装图文 PDF，于是教学大纲/PPT 全被判成视频。
#   · 课程页 li.activity 上平台已经渲染好了每个活动的图标：
#       fsresource+video → f/video、resource+pptx → f/powerpoint、
#       resource+docx → f/document、resource+rar → f/archive、resource+pdf → f/pdf
#     这是平台自己对"里面装的是什么"的结论，一次 GET 就能拿到整门课（105 个活动约 5 秒），
#     比逐个打开页面探测便宜得多，也比插件名准确得多。
#   · 完成状态也在同一份 DOM 里：视频用 .completion-dropdown（完成/待办事项），
#     资源用 [data-action="toggle-manual-completion"]（完成/标记完成）。
#   · 章节名用 section 容器的 data-sectionname，干净且与命名习惯无关。
# 返回：{status, courseid, current, sections:[{name, items:[...]}]}
#   item = {id,title,mod,url,icon,iconFile,iconPlugin,done,tracked,doneBy}
$JsCourseScan = @'
(async function () {
  function abs(u) { try { return new URL(u, location.href).href; } catch (e) { return u || ''; } }
  function txt(el) { return (el && el.textContent || '').replace(/\s+/g, ' ').trim(); }
  function courseId() {
    var here = new URL(location.href);
    if (/\/course\/view\.php$/.test(here.pathname) && /^\d+$/.test(here.searchParams.get('id') || '')) return here.searchParams.get('id');
    if (window.M && M.cfg && /^\d+$/.test(String(M.cfg.courseId || ''))) { return String(M.cfg.courseId); }
    var links = document.querySelectorAll('.breadcrumb a[href*="course/view.php"], a[href*="course/view.php"]');
    for (var i = 0; i < links.length; i++) {
      try {
        var u = new URL(links[i].getAttribute('href'), location.href), id = u.searchParams.get('id') || '';
        if (u.origin === location.origin && /\/course\/view\.php$/.test(u.pathname) && /^\d+$/.test(id)) return id;
      } catch (e) {}
    }
    return '';
  }
  // 活动图标：平台对"这个活动里装的是什么"的结论
  function iconOf(li) {
    var img = li.querySelector('img[data-region="activity-icon"]') || li.querySelector('img.activityicon');
    if (!img) { return { src: '', file: '', plugin: '' }; }
    var src = img.getAttribute('src') || '';
    var file = (src.match(/\/f\/([a-z0-9]+)/i) || [])[1] || '';
    if (!file) {
      try { file = (new URL(src, location.origin).searchParams.get('image') || '').replace(/^f\//, ''); } catch (e) {}
    }
    var plugin = '';
    var pm = src.match(/theme\/image\.php\/[^\/]+\/([^\/]+)\//i);
    if (pm && pm[1] !== 'core') { plugin = pm[1]; }
    return { src: src, file: file.toLowerCase(), plugin: plugin.toLowerCase() };
  }
  // 完成状态：三种平台原生标记，按可靠性依次尝试
  function completionOf(li) {
    var stateNode = li.matches('[data-completionstate]') ? li : li.querySelector('[data-completionstate]');
    if (stateNode) {
      var state = stateNode.getAttribute('data-completionstate');
      if (state === '0' || state === '1' || state === '2') return {done:state !== '0', tracked:true, by:'state'};
    }
    var dd = li.querySelector('.completion-dropdown');
    if (dd) {
      var t = txt(dd);
      if (/^完成/.test(t)) { return { done: true, tracked: true, by: 'dropdown' }; }
      if (/^待办/.test(t)) { return { done: false, tracked: true, by: 'dropdown' }; }
      return { done: null, tracked: true, by: 'dropdown' };
    }
    var btn = li.querySelector('[data-action="toggle-manual-completion"]');
    if (btn) {
      var tt = String(btn.getAttribute('data-toggletype') || '');
      if (/undo/.test(tt)) { return { done: true, tracked: true, by: 'manual' }; }
      if (/mark-done/.test(tt)) { return { done: false, tracked: true, by: 'manual' }; }
      return { done: null, tracked: true, by: 'manual' };
    }
    var info = li.querySelector('[data-region="completion-info"]');
    if (info) {
      var it = txt(info);
      if (it === '完成') { return { done: true, tracked: true, by: 'info' }; }
      if (it === '标记完成') { return { done: false, tracked: true, by: 'info' }; }
      if (it) { return { done: null, tracked: true, by: 'info' }; }
    }
    return { done: null, tracked: false, by: 'none' };
  }
  // 标题：去掉 accesshide 里的"资源库文件/讨论区"等副标题
  function cleanTitle(a) {
    var inst = a.querySelector('.instancename');
    if (inst) {
      var clone = inst.cloneNode(true);
      var hid = clone.querySelectorAll('.accesshide');
      for (var k = 0; k < hid.length; k++) { hid[k].parentNode.removeChild(hid[k]); }
      var t = txt(clone);
      if (t) { return t; }
    }
    return txt(a);
  }
  var seen = new Set();
  var sectionSelector = 'li.section, div.section, .course-section';
  var activitySelector = 'li.activity[id^="module-"], li[data-for="cmitem"][data-id]';
  function collect(scope, sectionOnly) {
    var arr = [];
    var nodes = scope.querySelectorAll(activitySelector);
    for (var i = 0; i < nodes.length; i++) {
      var li = nodes[i];
      if (sectionOnly && li.closest(sectionSelector) !== scope) continue;
      var domId = (li.id.match(/^module-(\d+)$/) || [])[1] || li.getAttribute('data-id') || '';
      if (!/^\d+$/.test(domId) || seen.has(domId)) continue;
      var links = li.querySelectorAll('a[href*="/mod/"][href*="view.php"]');
      var a = null, target = null, hm = null;
      for (var k = 0; k < links.length; k++) {
        if (links[k].closest(activitySelector) !== li) continue;
        try {
          var candidate = new URL(links[k].getAttribute('href'), location.href);
          var match = candidate.pathname.match(/\/mod\/([a-z][a-z0-9_]*)\/view\.php$/i);
          if (candidate.origin !== location.origin || !match || candidate.searchParams.get('id') !== domId) continue;
          a = links[k]; target = candidate; hm = match; break;
        } catch (e) {}
      }
      // 限制说明中的前置活动链接不是本卡片；不猜测被锁定活动的入口。
      if (!a) continue;
      var activityId = domId;
      var mod = hm[1].toLowerCase();
      if (mod === 'label') { continue; }
      seen.add(activityId);
      var ic = iconOf(li);
      var cp = completionOf(li);
      arr.push({
        id: activityId, title: cleanTitle(a), mod: mod, url: target.href,
        icon: ic.src, iconFile: ic.file, iconPlugin: ic.plugin,
        className: li.className || '', activityName: li.getAttribute('data-activityname') || '',
        done: cp.done, tracked: cp.tracked, doneBy: cp.by
      });
    }
    return arr;
  }
  var cid = courseId();
  if (!cid) { return JSON.stringify({ status: 'NOCOURSE' }); }
  var html = null, lastCode = 0;
  for (var attempt = 0; attempt < 3 && html === null; attempt++) {
    var ctrl = new AbortController(), timer = setTimeout(function(){ctrl.abort();}, 12000);
    try {
      var resp = await fetch('/course/view.php?id=' + cid, { credentials: 'same-origin', mode: 'same-origin', signal: ctrl.signal });
      lastCode = resp.status;
      var final = new URL(resp.url || '/course/view.php?id=' + cid, location.origin);
      if (final.origin !== location.origin || !/\/course\/view\.php$/.test(final.pathname) || final.searchParams.get('id') !== cid) {
        if (resp.body) await resp.body.cancel();
        return JSON.stringify({status:'WRONGPAGE'});
      }
      if (resp.ok) { html = await resp.text(); break; }
      if (resp.body) await resp.body.cancel();
      if (resp.status < 500 && resp.status !== 408 && resp.status !== 429) break;
    } catch (e) { lastCode = 0; }
    finally { clearTimeout(timer); }
    if (attempt < 2) await new Promise(function (r) { setTimeout(r, 400 * (attempt + 1)); });
  }
  if (html === null) { return JSON.stringify({ status: 'HTTPERR', code: lastCode }); }
  var doc = new DOMParser().parseFromString(html, 'text/html');
  if (doc.querySelector('form#login, form[action*="/login/index.php"]')) return JSON.stringify({status:'LOGIN'});
  var bodyCourse = ((doc.body && doc.body.className || '').match(/(?:^|\s)course-(\d+)(?:\s|$)/) || [])[1];
  if (bodyCourse && bodyCourse !== cid) return JSON.stringify({status:'WRONGCOURSE'});
  var out = [];
  var secEls = doc.querySelectorAll(sectionSelector);
  for (var s = 0; s < secEls.length; s++) {
    var sec = secEls[s];
    var name = String(sec.getAttribute('data-sectionname') || '').trim();
    if (!name) { name = txt(sec.querySelector('.sectionname, h3, h2')); }
    var items = collect(sec, true);
    if (items.length) { out.push({ id: sec.getAttribute('data-id') || sec.id || '', name: name || ('第 ' + (s + 1) + ' 部分'), url: '', items: items }); }
  }
  if (!out.length) {
    var all = collect(doc);
    if (all.length) { out.push({ name: txt(doc.querySelector('h1')) || '全部讲次', url: '', items: all }); }
  }
  if (!out.length) { return JSON.stringify({ status: 'EMPTY' }); }
  var here = new URL(location.href), cur = /\/mod\/[^/]+\/view\.php$/.test(here.pathname) ? here.searchParams.get('id') || '' : '';
  if (!/^\d+$/.test(cur)) cur = '';
  return JSON.stringify({ status: 'OK', courseid: cid, origin: location.origin, current: cur, sections: out });
})()
'@

# 页面探测：前几级判据都判不出来时，才逐个打开活动页看"里面到底有没有视频"。
#   · HEAD 请求先看 Content-Type：resource 插件会把 pluginfile 重定向过去，
#     pptx/pdf/rar 的 MIME 直接就能定性（不用下正文，省流量也快）。
#   · 返回 text/html 时再解析：<video> / playerdata(m3u8) / 文件链接 / iframe。
#   · 判定只认硬证据；仍然判不出来就返回 unknown，由上层"保守保留"，绝不硬猜。
# 输入：items=[{id,mod}]；返回 {id: {kind: video|doc|unknown, by, mime, note}}
$JsActivityProbe = @'
(async function () {
  var items = __ITEMS__;
  var PAUSE_MS = 250;
  function mimeKind(ct) {
    ct = String(ct || '').split(';')[0].trim().toLowerCase();
    if (/^video\//.test(ct) || /^(application\/(vnd\.apple\.mpegurl|x-mpegurl|dash\+xml)|audio\/x-mpegurl)$/.test(ct)) return 'video';
    if (/^(audio|image)\//.test(ct) || /^application\/(pdf|msword|vnd\.(openxmlformats-officedocument\.[\w.-]+|ms-excel|ms-powerpoint)|zip|x-rar-compressed|vnd\.rar|x-7z-compressed)$/.test(ct)) return 'doc';
    // octet-stream 只表示二进制，不证明是文档。
    return '';
  }
  function pathKind(src) {
    var path = '';
    try { path = decodeURIComponent(new URL(src, location.origin).pathname).toLowerCase(); } catch (e) { return ''; }
    if (/\.(mp4|m4v|mov|flv|mkv|webm|m3u8|mpd|ogv|mpeg|mpg|avi|wmv|ts)$/.test(path)) return 'video';
    if (/\.(pdf|docx?|pptx?|xlsx?|zip|rar|7z|txt|md|json|js|mp3|wav|m4a|png|jpe?g|gif|svg)$/.test(path)) return 'doc';
    // pluginfile.php 本身并不说明文件类型。
    return '';
  }
  function pageKind(main) {
    if (!main) return {kind:'unknown', by:'none', confidence:'low'};
    if (main.querySelector('video')) return {kind:'video', by:'video', confidence:'high'};
    var sawDoc = false, sawVideo = false;
    var nodes = main.querySelectorAll('source[src],a[href],iframe[src],embed[src],object[data]');
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i], src = n.getAttribute('src') || n.getAttribute('href') || n.getAttribute('data') || '';
      var k = pathKind(src) || mimeKind(n.getAttribute('type'));
      if (n.tagName === 'IFRAME') {
        try {
          var u = new URL(src, location.origin);
          if ((u.hostname === 'player.vimeo.com' && /^\/video\//.test(u.pathname)) ||
              (/^(www\.)?youtube(-nocookie)?\.com$/.test(u.hostname) && /^\/embed\//.test(u.pathname))) k = 'video';
        } catch (e) {}
      }
      if (k === 'video') sawVideo = true;
      if (k === 'doc') sawDoc = true;
    }
    // 只接受播放器配置附近的媒体值，不把正文里提到 mp4 当作播放器。
    var scripts = main.querySelectorAll('script');
    for (var j = 0; j < scripts.length; j++) {
      var s = scripts[j].textContent || '';
      if (/\b(?:var|let|const)\s+playerdata\s*=\s*\{/.test(s) &&
          /["'][^"'\r\n]*\.(?:m3u8|mp4|m4v|flv)(?:[?#][^"'\r\n]*)?["']/i.test(s)) sawVideo = true;
    }
    if (sawVideo) return {kind:'video', by:'media', confidence:'medium'};
    if (sawDoc) return {kind:'doc', by:'file', confidence:'medium'};
    return {kind:'unknown', by:'none', confidence:'low'};
  }
  async function request(url, method) {
    var ctrl = new AbortController(), timer = setTimeout(function(){ctrl.abort();}, 10000);
    try {
      var r = await fetch(url, {method:method, credentials:'same-origin', mode:'same-origin', redirect:'follow', signal:ctrl.signal});
      var final = new URL(r.url || url, location.origin);
      if (!r.ok || final.origin !== location.origin || /\/login\//.test(final.pathname)) {
        if (r.body) await r.body.cancel();
        return null;
      }
      var mime = r.headers.get('content-type') || '', k = mimeKind(mime) || pathKind(final.href);
      // 二进制只看响应头；不下载视频、PDF 或不明文件正文。
      var html = '';
      if (method === 'GET' && !k && /^text\/html(?:;|$)/i.test(mime)) html = await r.text();
      else if (r.body) await r.body.cancel();
      return {kind:k, mime:mime.split(';')[0], html:html};
    } finally { clearTimeout(timer); }
  }
  var out = {};
  for (var b = 0; b < items.length; b++) {
    var it = items[b], rec = {kind:'unknown', by:'none', mime:'', confidence:'low'};
    if (!/^\d+$/.test(String(it.id)) || !/^[a-z][a-z0-9_]*$/i.test(String(it.mod))) { out[it.id] = rec; continue; }
    var url = '/mod/' + it.mod + '/view.php?id=' + it.id;
    try {
      // 页面正文同时提供 MIME 与内容证据；正常 HTML 路径不再重复 HEAD + GET。
      // GET 响应为二进制时 request 会立即取消 body，不下载媒体。
      var g = null;
      try { g = await request(url, 'GET'); } catch (e) {}
      if (g) {
        if (g.kind) rec = {kind:g.kind, by:'mime-get', mime:g.mime, confidence:'high'};
        else if (g.html) {
          var doc = new DOMParser().parseFromString(g.html, 'text/html');
          rec = pageKind(doc.querySelector('[role="main"]') || doc.querySelector('#region-main'));
          rec.mime = g.mime;
        }
      } else {
        // 少数 GET 不可读、HEAD 仍能提供文件 MIME 的服务保留只读兜底。
        var h = null;
        try { h = await request(url, 'HEAD'); } catch (e) {}
        if (h && h.kind) rec = {kind:h.kind, by:'mime', mime:h.mime, confidence:'high'};
      }
    } catch (e) { rec = {kind:'unknown', by:'error', mime:'', confidence:'low'}; }
    out[it.id] = rec;
    if (b + 1 < items.length) await new Promise(function(r){setTimeout(r, PAUSE_MS);});
  }
  return JSON.stringify(out);
})()
'@

# 页面就绪判断
$JsReady      = 'document.readyState === "complete" && !!document.querySelector("video")'
$JsLoaded     = 'document.readyState === "complete"'
$JsHref       = 'location.href'

function Get-ReadyJsForId {
    # 生成"页面已加载完 **且** 地址栏已切到指定 id"的就绪判据。
    # ⚠ 光判 readyState 会误判：点击课程索引切讲是平台自己的页面跳转，浏览器要
    #   几百毫秒才开始导航，而等待循环第一次检查（900ms 后）读到的还是**旧页面**
    #   （readyState 本来就是 complete）→ 判"已就绪"→ 紧接着读到的完成状态其实是
    #   上一讲的 → 判"该讲此前已完成，跳过"（用户实报"刷完一讲后剩下所有讲被秒判完成"）。
    param([string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return $JsLoaded }
    if ($Id -notmatch '^\d+$') { return 'false' }
    return "(function(){var u=new URL(location.href);return document.readyState==='complete' && /\/mod\/[^/]+\/view\.php`$/.test(u.pathname) && u.searchParams.get('id')==='" + $Id + "';})()"
}

# =====================================================================
# 6. 页面操作
# =====================================================================
function Invoke-TrustedClick {
    param($Ws, [int]$X, [int]$Y)
    # 用 CDP 输入通道发送鼠标事件：产生的是「可信事件」，与真人点击等价；
    # 加入 ±2px 抖动，避免每次都点在同一像素。
    if ($X -gt 2) { $X = $X + (Get-Random -Minimum -2 -Maximum 3) }
    if ($Y -gt 2) { $Y = $Y + (Get-Random -Minimum -2 -Maximum 3) }
    $common = @{ x = $X; y = $Y; button = 'left'; clickCount = 1 }
    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params ($common + @{ type = 'mouseMoved' })
    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params ($common + @{ type = 'mousePressed' })
    Start-Sleep -Milliseconds 120
    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params ($common + @{ type = 'mouseReleased' })
}

function Click-ElementByName {
    param($Ws, [string]$Name)
    $js = $JsTemplateClickByName.Replace('__NAME__', $Name.Replace('\', '\\').Replace("'", "\'"))
    $rectRaw = Invoke-Js -Ws $Ws -Expression $js
    if ([string]::IsNullOrEmpty($rectRaw)) { return $false }
    $rect = ConvertFrom-Json -InputObject $rectRaw
    Invoke-TrustedClick -Ws $Ws -X $rect.x -Y $rect.y
    return $true
}

function Get-PlayerState {
    # 超时缩短到 8 秒：偶发读不到时能快速重试，不会一卡就是 30 秒
    param($Ws)
    $raw = Invoke-Js -Ws $Ws -Expression $JsGetState -TimeoutMs 8000
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    try { return ConvertFrom-Json -InputObject $raw } catch { return $null }
}

function Test-StopRequested {
    if (Test-Path -LiteralPath $StopFlag) { return $true }
    return $false
}

function Stop-PageVideo {
    # 先 pause，再清除 video/audio 的 src、子 source 与 srcObject；
    # 旧实现只清 video.src 会重新加载子 source 的旧流，导致平台判定同时观看。
    param($Ws)
    $raw = Invoke-Js -Ws $Ws -Expression $JsReleaseMedia -TimeoutMs 6000
    $facts = $null
    try { $facts = ConvertFrom-Json -InputObject $raw } catch { }
    if (-not $facts -or -not $facts.ok) {
        Write-Log '未能确认上一讲媒体已完全停止，等待后重试一次' '警告'
        Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 1200 -Percent 30)
        $raw = Invoke-Js -Ws $Ws -Expression $JsReleaseMedia -TimeoutMs 6000
        try { $facts = ConvertFrom-Json -InputObject $raw } catch { }
    }
    if (-not $facts -or -not $facts.ok) { return $false }
    return $true
}

function Navigate-ToVideo {
    # 单一标签页只导航一次；不再点击索引后补发导航，避免 target=_blank 和双重加载。
    param($Ws, [string]$Id, [string]$Url, [string]$ReadyJs = $JsLoaded, [int]$TimeoutSec = 90)
    if (Test-StopRequested) { return $false }
    $ready = Get-ReadyJsForId -Id $Id
    $here = Invoke-Js -Ws $Ws -Expression $JsHref
    $samePage = $false
    try {
        $from = [Uri]$here; $to = [Uri]$Url
        $samePage = ($from.GetLeftPart([UriPartial]::Authority) -eq $to.GetLeftPart([UriPartial]::Authority) -and $from.AbsolutePath -eq $to.AbsolutePath)
    } catch { }
    if ($samePage -and (Invoke-Js -Ws $Ws -Expression $ready) -eq $true) { return $true }
    if (-not (Stop-PageVideo -Ws $Ws)) {
        Write-Log '上一讲媒体未能确认停止，跳过本讲以避免平台判定同时观看' '警告'
        return $false
    }
    Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 1200 -Percent 30)
    if (Test-StopRequested) { return $false }
    Write-Log ("上一讲媒体已停止，在当前标签页切换到活动 {0}" -f $Id) '信息'
    $null = Send-CdpCommand -Ws $Ws -Method 'Page.navigate' -Params @{ url = $Url }
    return (Wait-PageReady -Ws $Ws -Url $Url -ReadyJs $ready -TimeoutSec $TimeoutSec)
}

function Wait-PageReady {
    # 等页面就绪；登录时给本人留出时间，登录成功后重新计算超时。
    param($Ws, [string]$Url, [string]$ReadyJs = $JsLoaded, [int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $loginNotified = $false
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-StopRequested) { return $false }
        $tick++
        Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 900 -Percent 25)
        $href = $null
        try { $href = Invoke-Js -Ws $Ws -Expression $JsHref } catch { continue }
        if ([string]::IsNullOrEmpty($href)) { continue }
        if ($href -like '*login*' -or $href -like '*auth*' -or $href -like '*sso*') {
            if (-not $loginNotified) {
                Write-Log '当前处于未登录状态，请在 Edge 窗口中完成登录（脚本会自动等待，最长 10 分钟）' '提醒'
                $loginNotified = $true
            }
            $loginDeadline = (Get-Date).AddMinutes(10)
            $loggedIn = $false
            while ((Get-Date) -lt $loginDeadline) {
                if (Test-StopRequested) { return $false }
                Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 3000 -Percent 20)
                try { $href = Invoke-Js -Ws $Ws -Expression $JsHref } catch { continue }
                if ($href -and $href -like '*view.php*') { $loggedIn = $true; break }
            }
            if ($loggedIn) {
                Write-Log '登录已完成，继续执行' '成功'
                $deadline = (Get-Date).AddSeconds($TimeoutSec)
            }
            continue
        }
        if (($tick % 5) -eq 0) {
            $risk = Get-SiteRisk -Ws $Ws
            if ($risk) {
                $pr = Pause-ForSiteRisk -Ws $Ws -Risk $risk -Cfg $script:Cfg
                if ($pr -ne 'ok') { return $false }
            }
        }
        $ready = $null
        try { $ready = Invoke-Js -Ws $Ws -Expression $ReadyJs } catch { continue }
        if ($ready -eq $true) { return $true }
        if (($ReadyJs -ne $JsLoaded) -and ((Get-Date) -gt $deadline.AddSeconds(-15))) {
            $relax = $null
            try { $relax = Invoke-Js -Ws $Ws -Expression $JsLoaded } catch { }
            if ($relax -eq $true) {
                Write-Log '没能确认已切到目标讲（页面地址不含活动 id？），按页面就绪继续' '警告'
                return $true
            }
        }
    }
    Write-Log "页面在 $TimeoutSec 秒内未就绪：$Url" '警告'
    return $false
}

function Navigate-To {
    param($Ws, [string]$Url, [string]$ReadyJs = $JsLoaded, [int]$TimeoutSec = 90)
    Write-Log "打开页面：$Url" '信息'
    $null = Send-CdpCommand -Ws $Ws -Method 'Page.navigate' -Params @{ url = $Url }
    return (Wait-PageReady -Ws $Ws -Url $Url -ReadyJs $ReadyJs -TimeoutSec $TimeoutSec)
}

function Test-CdpAlive {
    # 快速检查 WebSocket 是否还活着（1 秒超时的 1+1 求值）
    param($Ws)
    try {
        $r = Invoke-Js -Ws $Ws -Expression '1+1' -TimeoutMs 1200
        return ($r -eq 2)
    } catch { return $false }
}

function Wait-ForVideoPage {
    # 等你把视频页面打开；识别到就自动继续
    # 安全阀：等太久（默认 30 分钟）或连接断了就退出，避免无人看管时永远挂在这里
    param($Ws, [int]$PollSeconds = 3, [int]$MaxMinutes = 30)
    $round = 0
    $fail = 0
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    while ($true) {
        if (Test-StopRequested) { return $false }
        if ((Get-Date) -ge $deadline) {
            Write-Log ("等你在浏览器里打开视频页已超过 {0} 分钟，脚本先退出。想继续请重新点「开始刷课」" -f $MaxMinutes) '警告'
            return $false
        }
        $href = $null
        try {
            # 短超时：连接断了要能很快发现，而不是每次白等默认的 30 秒
            $href = Invoke-Js -Ws $Ws -Expression $JsHref -TimeoutMs 5000
            $fail = 0
        } catch {
            $fail++
            if ($fail -ge 10) {
                Write-Log '浏览器连接已断开，无法继续等待视频页，脚本停止' '错误'
                return $false
            }
        }
        # 课程页/章节页也算“进入课程上下文”：扫描本身会自己取课程 id，
        # 不必逼用户必须先点开某一讲。视频是否存在留给播放阶段判断。
        if ($href -and $href -match '(?:/mod/[^/]+/view\.php|/course/(?:view|section)\.php)') {
            $ready = $null
            try { $ready = Invoke-Js -Ws $Ws -Expression $JsLoaded -TimeoutMs 5000 } catch { }
            if ($ready -eq $true) { return $true }
        }
        $round++
        if (($round % 10) -eq 1) {
            Write-Log '请在这个 Edge 窗口里打开你要看的那一讲视频页面（脚本会自动识别并开始，无需其它操作）' '提醒'
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Start-Playback {
    param($Ws)
    Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 900 -Percent 50)
    # 1) 真实点击「播放」按钮（最贴近真人操作）
    if (Click-ElementByName -Ws $Ws -Name '播放') {
        Write-Log '点击播放按钮' '信息'
        Start-Sleep -Seconds 2
        $st = Get-PlayerState -Ws $Ws
        if ($st -and -not $st.paused) { return $true }
    }
    # 2) 兜底：带用户手势调用 video.play()
    $null = Invoke-Js -Ws $Ws -Expression $JsCallPlay -UserGesture
    Start-Sleep -Seconds 2
    $st = Get-PlayerState -Ws $Ws
    if ($st -and -not $st.paused) { return $true }
    # 3) 兜底：点击视频画面中央
    $vr = Invoke-Js -Ws $Ws -Expression $JsVideoRect
    if (-not [string]::IsNullOrEmpty($vr)) {
        $rect = ConvertFrom-Json -InputObject $vr
        Write-Log '点击视频画面尝试开始播放' '信息'
        Invoke-TrustedClick -Ws $Ws -X $rect.x -Y $rect.y
        Start-Sleep -Seconds 2
        $st = Get-PlayerState -Ws $Ws
        if ($st -and -not $st.paused) { return $true }
    }
    return $false
}

# =====================================================================
# =====================================================================
# 7. 课程结构 / 播放列表 / 完成状态
# ---------------------------------------------------------------------
# 数据流（每一层只做一件事）：
#   ① Get-CourseStructure   抓一次课程页 → 章节 + 每个活动的插件/图标/完成状态
#   ② Update-CourseStructureKinds  按 识别规则.ps1 分类（图标→文件→插件）
#                          只对证据不足的活动串行探测，限时且可停止
#   ③ Get-Playlist          只按分类结果挑视频、按范围排序
#   ④ Get-PendingVideos     按平台完成状态过滤；状态缺失的才实时核对
# 关键：分类只做一次，结果写进 $script:CourseStruct 和 课程结构.json，
#       下游（含控制台）不再各自重判 —— 这是旧版"同一条活动被判四五次"的根治。
# =====================================================================

function Get-CourseStructure {
    # 读整门课的章节结构 + 每个活动的类型/图标/完成状态。
    # 只发一次 GET（课程页），不点任何链接、不依赖官方 Web Service（本校已禁用）。
    param($Ws)
    $risk = Get-SiteRisk -Ws $Ws
    if ($risk) {
        $pr = Pause-ForSiteRisk -Ws $Ws -Risk $risk -Cfg $script:Cfg
        if ($pr -ne 'ok') { return $null }
    }

    # 后台标签页会被 Chromium 冻结/降频，fetch 可能卡几十秒甚至不返回。
    # 用 CDP 的焦点模拟临时解除限制；结束后**必须关掉**，否则长按确认那边
    # 会误以为窗口一直可见（它靠 visibilityState 判断要不要把窗口拉到前台）。
    $emu = $false
    try {
        try {
            $null = Send-CdpCommand -Ws $Ws -Method 'Emulation.setFocusEmulationEnabled' `
                -Params @{ enabled = $true } -TimeoutMs 4000
            $emu = $true
        } catch { }

        $raw = $null
        try {
            $raw = Invoke-Js -Ws $Ws -Expression $JsCourseScan -TimeoutMs 90000
        } catch {
            Write-Log ("读取课程结构失败：{0}" -f $_.Exception.Message) '警告'
            return $null
        }
        if ([string]::IsNullOrEmpty($raw)) { return $null }
        $data = $null
        try { $data = ConvertFrom-Json -InputObject $raw } catch { }
        if (-not $data) { return $null }
        if ($data.status -ne 'OK') {
            $why = [string]$data.status
            if ($why -eq 'NOCOURSE') { $why = '当前页面不属于任何课程' }
            Write-Log ("读取课程结构失败（{0}）：请确认已登录，并停在课程页或任意一讲页面" -f $why) '警告'
            return $null
        }

        $data | Add-Member -NotePropertyName source -NotePropertyValue 'scan' -Force
        Update-CourseStructureKinds -Data $data -Ws $Ws
        $n = @($data.sections).Count
        Write-Log ("已读取课程结构：{0} 个章节，共 {1} 个活动" -f $n, (@($data.sections | ForEach-Object { @($_.items).Count }) | Measure-Object -Sum).Sum) '信息'
        return $data
    } finally {
        if ($emu) {
            try {
                $null = Send-CdpCommand -Ws $Ws -Method 'Emulation.setFocusEmulationEnabled' `
                    -Params @{ enabled = $false } -TimeoutMs 4000
            } catch { }
        }
    }
}

function Update-CourseStructureKinds {
    # 分类保留 unknown；只有有证据的视频才进入自动播放。
    param($Data, $Ws)
    $cached = @{}
    try {
        $old = Get-Content -LiteralPath (Join-Path $ScriptDir '课程结构.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($old.classificationVersion -eq 1 -and $Data.courseid -and $Data.origin -and
            [string]$old.courseid -eq [string]$Data.courseid -and [string]$old.origin -eq [string]$Data.origin) {
            foreach ($s in @($old.sections)) { foreach ($it in @($s.items)) { $cached[[string]$it.id] = $it } }
        }
    } catch { }
    $need = New-Object 'System.Collections.Generic.List[object]'; $hits = 0
    foreach ($s in @($Data.sections)) {
        foreach ($it in @($s.items)) {
            $k = Get-ActivityKind -Item $it
            if (Test-NeedsProbe -Item $it -Kind $k) {
                $hit = Get-CachedActivityKind -Item $it -CachedItem $cached[[string]$it.id]
                if ($hit) {
                    $k = $hit; $hits++
                    foreach ($n in @('probeAt', 'probeKey')) { $it | Add-Member -NotePropertyName $n -NotePropertyValue $hit.$n -Force }
                } else {
                    $need.Add($it)
                    $k = [pscustomobject]@{kind='unknown'; by='none'; confident=$false; confidence='low'}
                }
            }
            $it | Add-Member -NotePropertyName kind -NotePropertyValue $k.kind -Force
            $it | Add-Member -NotePropertyName kindBy -NotePropertyValue $k.by -Force
            $it | Add-Member -NotePropertyName kindConfident -NotePropertyValue ([bool]$k.confident) -Force
            $it | Add-Member -NotePropertyName kindConfidence -NotePropertyValue $k.confidence -Force
        }
    }
    if ($hits) { Write-Log ("复用 {0} 个仍有效的页面分类证据（完成状态仍实时核对）" -f $hits) '信息' }
    if ($need.Count) {
        Write-Log ("有 {0} 个活动需要页面证据，正在逐个只读核对…" -f $need.Count) '信息'
        $probe = Invoke-ActivityProbe -Ws $Ws -Items $need.ToArray()
        foreach ($it in $need) {
            $p = $probe[[string]$it.id]
            if ($p -and $p.kind -in @('video', 'doc') -and $p.confidence -in @('high', 'medium')) {
                $it | Add-Member -NotePropertyName kind -NotePropertyValue ([string]$p.kind) -Force
                $it | Add-Member -NotePropertyName kindBy -NotePropertyValue ('probe-' + [string]$p.by) -Force
                $it | Add-Member -NotePropertyName kindConfident -NotePropertyValue $true -Force
                $it | Add-Member -NotePropertyName kindConfidence -NotePropertyValue ([string]$p.confidence) -Force
                $it | Add-Member -NotePropertyName probeKey -NotePropertyValue (Get-ActivityFingerprint -Item $it) -Force
                $it | Add-Member -NotePropertyName probeAt -NotePropertyValue ([DateTimeOffset]::UtcNow.ToString('o')) -Force
            }
        }
    }
    $vidN = 0; $docN = 0; $unknownN = 0
    foreach ($s in @($Data.sections)) {
        foreach ($it in @($s.items)) {
            $isVid = ($it.kind -eq 'video' -and $it.kindConfident)
            $it | Add-Member -NotePropertyName video -NotePropertyValue ([bool]$isVid) -Force
            $it | Add-Member -NotePropertyName videoBy -NotePropertyValue ([string]$it.kindBy) -Force
            if ($isVid) { $vidN++ } elseif ($it.kind -eq 'doc') { $docN++ } else { $unknownN++ }
        }
    }
    Write-Log ("已排除 {0} 个非视频活动（文档/课件/压缩包/讨论等），{1} 个按视频处理" -f $docN, $vidN) '信息'
    if ($unknownN) { Write-Log ("还有 {0} 个活动证据不足，保留为待确认，暂不加入播放清单" -f $unknownN) '提醒' }
}

function Invoke-ActivityProbe {
    # 一次仅核对一个活动，间隔限速；每个活动边界响应停止。
    param($Ws, [array]$Items)
    $map = @{}
    $probeN = 0
    foreach ($it in @($Items)) {
        if (Test-StopRequested) { break }
        $probeN++
        if (($probeN % 3) -eq 1) {
            $risk = Get-SiteRisk -Ws $Ws
            if ($risk) {
                $pr = Pause-ForSiteRisk -Ws $Ws -Risk $risk -Cfg $script:Cfg
                if ($pr -ne 'ok') { break }
            }
        }
        $id = [string]$it.id; $mod = Get-ActivityMod -Item $it
        if ($id -notmatch '^\d+$' -or $mod -notmatch '^[a-z][a-z0-9_]*$') { continue }
        $entry = @([ordered]@{ id = $id; mod = $mod })
        $js = $JsActivityProbe.Replace('__ITEMS__', (ConvertTo-Json -InputObject $entry -Compress))
        try {
            $raw = Invoke-Js -Ws $Ws -Expression $js -TimeoutMs 25000
            $obj = ConvertFrom-Json -InputObject $raw
            foreach ($p in @($obj.PSObject.Properties)) { if ($p.Value) { $map[[string]$p.Name] = $p.Value } }
        } catch { }
        if (Test-StopRequested) { break }
        Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 900 -Percent 35)
    }
    return $map
}

function Write-CourseStructureFile {
    # 把章节结构写成 课程结构.json（UTF-8 BOM）。
    # video / kind / kindBy 是**引擎的最终结论**；控制台只读这些字段，不再自己判。
    param($Data)
    try {
        $out = [ordered]@{
            updated  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            source   = [string]$Data.source
            classificationVersion = 1
            courseid = [string]$Data.courseid
            origin   = [string]$Data.origin
            current  = [string]$Data.current
            sections = New-Object 'System.Collections.Generic.List[object]'
        }
        foreach ($s in @($Data.sections)) {
            $items = New-Object 'System.Collections.Generic.List[object]'
            foreach ($it in @($s.items)) {
                $names = @($it.PSObject.Properties.Name)
                $o = [ordered]@{ id = [string]$it.id; title = [string]$it.title }
                $mod = Get-ActivityMod -Item $it
                if ($mod) { $o['type'] = $mod; $o['mod'] = $mod }
                if ($names -contains 'iconFile' -and $it.iconFile) { $o['icon'] = [string]$it.iconFile }
                foreach ($n in @('iconFile', 'iconPlugin', 'className', 'activityName', 'url', 'doneBy', 'kindConfidence', 'probeKey', 'probeAt')) {
                    if ($names -contains $n) { $o[$n] = [string]$it.$n }
                }
                if ($names -contains 'video') { $o['video'] = [bool]$it.video }
                if ($names -contains 'kind') { $o['kind'] = [string]$it.kind }
                if ($names -contains 'kindBy') { $o['videoBy'] = [string]$it.kindBy }
                if ($names -contains 'done' -and $null -ne $it.done) { $o['done'] = [bool]$it.done }
                if ($names -contains 'tracked') { $o['tracked'] = [bool]$it.tracked }
                $items.Add($o)
            }
            $out.sections.Add([ordered]@{ id = [string]$s.id; name = [string]$s.name; url = [string]$s.url; items = $items.ToArray() })
        }
        $json = $out | ConvertTo-Json -Depth 6
        # 原子替换：控制台每 3 秒轮询，直接 WriteAllText 会读到半个 JSON。
        $target = Join-Path $ScriptDir '课程结构.json'
        $tmp = $target + '.tmp'
        [System.IO.File]::WriteAllText($tmp, $json,
            (New-Object System.Text.UTF8Encoding($true)))
        if ([System.IO.File]::Exists($target)) {
            [System.IO.File]::Replace($tmp, $target, $null)
        } else {
            [System.IO.File]::Move($tmp, $target)
        }
    } catch {
        Write-Log ("保存课程结构失败，已保留原文件：{0}" -f $_.Exception.Message) '警告'
    } finally {
        try { if (Test-Path -LiteralPath ($target + '.tmp')) { Remove-Item -LiteralPath ($target + '.tmp') -Force } } catch { }
    }
}

function Set-StructDone {
    # 把实时核对出来的完成状态合并进章节结构（供控制台显示每章剩余讲数）
    param($Struct, $Results)
    if (-not $Struct -or -not $Results) { return $Struct }
    foreach ($s in @($Struct.sections)) {
        foreach ($it in @($s.items)) {
            $id = [string]$it.id
            if ($Results.ContainsKey($id)) {
                $it | Add-Member -NotePropertyName done -NotePropertyValue ([bool]$Results[$id]) -Force
            }
        }
    }
    return $Struct
}

# 只读核对：每次拉取一讲页面，就地解析完成状态；调用端逐项限速并检查停止。
$JsBatchCompletion = (@'
(function () {
  var items = __ITEMS__;
  var BATCH = 1;
  __JUDGE__
  function pageFacts(html) {
    try {
      var doc = new DOMParser().parseFromString(html, 'text/html');
      var main = doc.querySelector('[role="main"]') || doc.querySelector('#region-main') || doc.body;
      if (!main) { return null; }
      return { done: judgeCompletion(doc, main) };
    } catch (e) { return null; }
  }
  var out = {};
  function runBatch(batch) {
    return Promise.all(batch.map(function (it) {
      var ctrl = new AbortController(), timer = setTimeout(function(){ctrl.abort();}, 10000);
      return fetch(it.url, { credentials: 'same-origin', mode: 'same-origin', signal: ctrl.signal })
        .then(function (r) {
          var expected = new URL(it.url, location.origin), actual = new URL(r.url || it.url, location.origin);
          if (!r.ok || actual.origin !== expected.origin || actual.pathname !== expected.pathname ||
              actual.searchParams.get('id') !== expected.searchParams.get('id') ||
              !/^text\/html(?:;|$)/i.test(r.headers.get('content-type') || '')) {
            if (r.body) r.body.cancel();
            throw new Error('unavailable');
          }
          return r.text();
        })
        .then(function (h) { out[it.id] = pageFacts(h); })
        .catch(function () { out[it.id] = null; })
        .finally(function () { clearTimeout(timer); });
    }));
  }
  var chain = Promise.resolve();
  for (var i = 0; i < items.length; i += BATCH) {
    (function (b) { chain = chain.then(function () { return runBatch(b); }); })(items.slice(i, i + BATCH));
  }
  return chain.then(function () { return JSON.stringify(out); });
})()
'@).Replace('__JUDGE__', $JudgeFnJs)

function Get-CompletionByProbe {
    # 串行拉取活动页面并解析完成状态。返回 @{ results = 哈希; judged = 已判定数; total = 总数 }，整体失败返回 $null
    param($Ws, [array]$Videos)
    $items = @()
    foreach ($v in $Videos) {
        $id = [string]$v.id
        if ($id -notmatch '^\d+$') { continue }
        $mod = Get-ActivityMod -Item $v
        if (-not $mod) { $mod = 'fsresource' }
        if ($mod -notmatch '^[a-z][a-z0-9_]*$') { continue }
        $items += @{ id = $id; url = "/mod/$mod/view.php?id=$id" }
    }
    if ($items.Count -eq 0) { return $null }
    $js = $JsBatchCompletion.Replace('__ITEMS__', (ConvertTo-Json -InputObject $items -Compress -Depth 4))
    $raw = $null
    try { $raw = Invoke-Js -Ws $Ws -Expression $js -TimeoutMs 60000 } catch { return $null }
    if ([string]::IsNullOrEmpty($raw)) { return $null }
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $raw } catch { return $null }
    if (-not $obj) { return $null }
    $res = @{}
    foreach ($p in @($obj.PSObject.Properties)) {
        if ($null -eq $p.Value) { continue }
        $names = @($p.Value.PSObject.Properties.Name)
        if ($names -contains 'done' -and $null -ne $p.Value.done) {
            $res[[string]$p.Name] = [bool]$p.Value.done
        }
    }
    if ($res.Count -eq 0) { return $null }
    return @{ results = $res; judged = $res.Count; total = $items.Count }
}

function Get-PendingVideos {
    # 从视频列表里挑出还没完成的。
    # 完成状态优先用**本次刚抓的课程页**（平台自己的完成标记，最权威）；
    # 只有读不到状态的少数活动才实时核对（串行 fetch），最后才逐页打开兜底。
    # 返回 @{ pending = @(...); results = @{ id = $true/$false } }；被停止时返回 $null。
    param($Ws, [array]$Videos)

    $results = @{}
    $need = @()
    foreach ($v in $Videos) {
        $id = [string]$v.id
        $names = @($v.PSObject.Properties.Name)
        if ($names -contains 'done' -and $null -ne $v.done) {
            $results[$id] = [bool]$v.done
        } else {
            $need += $v
        }
    }

    if ($need.Count -gt 0) {
        Write-Log ("有 {0} 讲读不到平台完成状态，正在实时核对…" -f $need.Count) '信息'
        $probe = $null
        $pStart = Get-Date
        try {
            $res = @{}
            foreach ($v in $need) {
                if (Test-StopRequested) { return $null }
                $risk = Get-SiteRisk -Ws $Ws
                if ($risk) {
                    $pr = Pause-ForSiteRisk -Ws $Ws -Risk $risk -Cfg $script:Cfg
                    if ($pr -ne 'ok') { return $null }
                }
                $one = Get-CompletionByProbe -Ws $Ws -Videos @($v)
                if ($one) { foreach ($id in $one.results.Keys) { $res[$id] = $one.results[$id] } }
                Start-Sleep -Milliseconds (Get-JitterMs -BaseMs 900 -Percent 35)
            }
            if ($res.Count) { $probe = @{results=$res; judged=$res.Count; total=$need.Count} }
        } catch { }
        if ($probe) {
            foreach ($v in $need) {
                $id = [string]$v.id
                if ($probe.results.ContainsKey($id)) { $results[$id] = [bool]$probe.results[$id] }
            }
            $secs = [math]::Round(((Get-Date) - $pStart).TotalSeconds, 1)
            Write-Log ("逐项核对完成：{0}/{1} 讲已判定（耗时 {2} 秒）" -f $probe.judged, $need.Count, $secs) '信息'
        }

        # 不再为了未知状态逐页打开活动页（会额外产生大量导航/请求）；
        # 状态未知按未完成处理，播放阶段会从视频页本身再次核对。
        $unknown = @($need | Where-Object { -not $results.ContainsKey([string]$_.id) }).Count
        if ($unknown -gt 0) {
            Write-Log ("还有 {0} 讲读不到平台完成状态；为避免逐页打开产生额外请求，本轮按未完成处理" -f $unknown) '提醒'
        }
    }

    $pending = @()
    $doneN = 0
    foreach ($v in $Videos) {
        $id = [string]$v.id
        $title = [string]$v.title
        if ([string]::IsNullOrEmpty($title)) { $title = '活动 ' + $id }
        if ($results.ContainsKey($id) -and $results[$id]) {
            Write-Log ("《{0}》已完成，本轮跳过" -f $title) '信息'
            $doneN++
        } else {
            Write-Log ("《{0}》还没完成，加入本轮" -f $title) '信息'
            $pending += $v
        }
    }
    Write-Log ("完成情况：{0} 讲已完成、{1} 讲待处理" -f $doneN, $pending.Count) '信息'
    return @{ pending = @($pending); results = $results }
}

function Get-Playlist {
    # 读取课程结构 → 交给纯函数 Select-PlaylistItems 选 + 排序 → 写日志。
    param($Ws, $Cfg, [string]$Scope = 'forward', [string]$Chapter = '')

    $data = $script:CourseStruct
    if (-not $data -or -not $data.sections) { $data = Get-CourseStructure -Ws $Ws }
    if (-not $data -or -not $data.sections) { return @() }

    $curId = ''
    try { $curId = [string](Invoke-Js -Ws $Ws -Expression $JsCurrentId) } catch { }
    if ([string]::IsNullOrEmpty($curId) -and $data.current) { $curId = [string]$data.current }
    # start_from_current=false：forward 从课程第一讲开始，而不是当前讲。
    if ($null -ne $Cfg.start_from_current -and -not [bool]$Cfg.start_from_current -and $Scope -eq 'forward') {
        $curId = ''
    }

    $r = Select-PlaylistItems -Sections @($data.sections) -Scope $Scope -Chapter $Chapter `
                              -CurrentId $curId -WrapAround ([bool]$Cfg.wrap_around)
    if ($r.error) {
        Write-Log $r.error '错误'
        return @()
    }
    $items = @($r.items)

    switch ($Scope) {
        'forward' { Write-Log ("已从当前这一讲开始、按课程顺序排到课程末尾，共 {0} 讲" -f $items.Count) '成功' }
        'current' { Write-Log ("当前章共 {0} 讲" -f $items.Count) '成功' }
        'chapter' { Write-Log ("章节「{1}」共 {0} 讲" -f $items.Count, $Chapter) '成功' }
        default   { Write-Log ("已按全课程章节读取到 {0} 个视频，将按课程顺序播放" -f $items.Count) '成功' }
    }
    return @($items)
}

# 8. 「考勤确认」弹窗：自动长按校验；自动未通过时退回人工提醒
# =====================================================================
function Invoke-MinimizeVideoWindow {
    # 把视频页窗口最小化，把前台还给用户。
    # （用户明确要求"不想一直把刷课窗口放前台"：视频播放不需要前台，只有弹窗出现的
    #   那几十秒需要窗口可见；按完就缩回去。CDP 的 Browser 域在 page 会话上可路由，
    #   已用 _test_minimize.py 验证过 normal↔minimized 切换。失败静默返回 false。）
    param($Ws)
    try {
        $ti = Send-CdpCommand -Ws $Ws -Method 'Target.getTargetInfo' -TimeoutMs 4000
        $tid = $ti.result.targetInfo.targetId
        if ([string]::IsNullOrEmpty($tid)) { return $false }
        $w = Send-CdpCommand -Ws $Ws -Method 'Browser.getWindowForTarget' -Params @{ targetId = $tid } -TimeoutMs 4000
        $wid = $w.result.windowId
        if (-not ($wid -gt 0)) { return $false }
        $null = Send-CdpCommand -Ws $Ws -Method 'Browser.setWindowBounds' `
            -Params @{ windowId = $wid; bounds = @{ windowState = 'minimized' } } -TimeoutMs 4000
        return $true
    } catch {
        return $false
    }
}

function Invoke-LongPressConfirm {
    # 在「按住确认」按钮上真实按下并保持不放，
    # 直到弹窗消失（进度条走满、校验通过）或到达最长按住时间才松开。
    #
    # ⚠ 2026-09-16 关键修复（用户实报"考勤校验多次未通过"）：
    #   旧版按下后只是 `Start-Sleep` + 每 700ms 读一次状态，**期间一个输入事件都不发**。
    #   实测日志：自动长按连试 10 次 × 每次 45 秒全失败，而用户本人手动按住 10 秒就通过 ——
    #   差别就在这里：平台的长按判定是靠 pointermove/mousemove 事件流累计"手指一直在按"的，
    #   只发一次 mousePressed 之后再无事件，浏览器在若干秒后会认为"指针停了"，
    #   校验进度条根本不走。所以按住期间必须**持续发送 mouseMoved（buttons=1）**，
    #   模拟真实手指的微小抖动，让事件流保持活跃。
    # ⚠ 2026-09-17 二次修复（自动长按又是 3×45 秒全失败、手动按就过 —— 复盘截图发现
    #   三次全按在同一个坐标上）。两个此前从日志完全看不出来的盲区：
    #   ① **窗口可见性**：这类"确认你还在看"的机制几乎必然有这条规则 ——
    #     窗口不可见（最小化/被完全遮挡）时故意不累计按住进度，否则防不住挂机。
    #     用户手动按的时候窗口必然是前台的，所以手动能过、脚本按不过。
    #     现在每次长按前先 Page.bringToFront 把视频页带到前台，按住期间定期复查、
    #     被切走就拉回来。
    #   ② **命中目标**：合成事件落在"坐标处最顶层的元素"上。按钮上若盖着遮罩/浮层，
    #     事件就喂给了别人。按下前用 elementFromPoint 体检；再装 pointer 事件计数器，
    #     失败时日志能区分"事件没到页面"（坐标/遮挡问题）还是"平台没认"
    #     （可见性/策略问题）—— 不再是一句"没被平台接受"让人无从排查。
    param($Ws, [int]$MaxHoldSeconds = 25)

    # ---- 定位按钮 + 体检（命中目标 / 窗口可见性 / 焦点）----
    $probe = $null
    try {
        $raw = Invoke-Js -Ws $Ws -Expression $JsHoldProbe -TimeoutMs 8000
        if (-not [string]::IsNullOrEmpty($raw)) { $probe = ConvertFrom-Json -InputObject $raw }
    } catch { }
    # ---- ① 只在窗口不可见时才把它**临时**带到前台 ----
    # 用户不想一直把刷课窗口放前台：视频播放不需要前台，只有弹窗出现的这几十秒需要。
    # 记下"拉之前是不是在后台"，按完（成功）再自动最小化回去，把前台还给他。
    $wasHidden = $false
    if ($probe -and $null -ne $probe.vis) {
        if ($probe.vis -ne 'visible') {
            $wasHidden = $true
            try { $null = Send-CdpCommand -Ws $Ws -Method 'Page.bringToFront' -TimeoutMs 4000 } catch { }
        }
    } else {
        # 拿不到可见性（体检失败、走兜底坐标时）：保守起见仍拉起，但不去缩回（不确定之前状态）
        try { $null = Send-CdpCommand -Ws $Ws -Method 'Page.bringToFront' -TimeoutMs 4000 } catch { }
    }
    $x = 0; $y = 0
    if ($probe) { $x = [int]$probe.x; $y = [int]$probe.y }
    if (-not ($x -gt 0 -and $y -gt 0)) {
        # 兜底：状态里已解析的坐标 → 再不行单独跑一次旧定位脚本
        $st0 = $null
        try { $st0 = Get-PlayerState -Ws $Ws } catch { }
        if ($st0 -and $null -ne $st0.holdX) { $x = [int]$st0.holdX; $y = [int]$st0.holdY }
    }
    if (-not ($x -gt 0 -and $y -gt 0)) {
        $rectRaw = $null
        try { $rectRaw = Invoke-Js -Ws $Ws -Expression $JsFindHoldButton } catch { }
        if ([string]::IsNullOrEmpty($rectRaw)) {
            Write-Log '页面上没找到「按住确认」按钮（弹窗可能已自行消失，或结构与预期不同）' '警告'
            return $false
        }
        $rect = ConvertFrom-Json -InputObject $rectRaw
        $x = [int]$rect.x; $y = [int]$rect.y
    }

    if ($wasHidden) {
        Write-Log 'Edge 窗口此刻在后台/最小化 —— 平台在窗口不可见时不累计按住进度，已自动临时拉到前台；按完会自动缩回去，你不用管' '提醒'
    }
    if ($probe -and ($null -ne $probe.hit) -and -not $probe.hit) {
        Write-Log ("注意：「按住确认」坐标 ({0},{1}) 的最顶层元素是 [{2}]，不是按钮本身 —— 若本次失败，多半是被它挡住了" -f `
                   $x, $y, $probe.top) '提醒'
    }

    # ---- 装 pointer 事件计数器（每次尝试前重跑 = 顺带清零；失败时用于定位病因）----
    try { $null = Invoke-Js -Ws $Ws -Expression $JsArmLongPressProbe -TimeoutMs 4000 } catch { }

    $common = @{ x = $x; y = $y; button = 'left'; clickCount = 1 }
    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params ($common + @{ type = 'mouseMoved'; buttons = 0 })
    Start-Sleep -Milliseconds 60
    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params ($common + @{ type = 'mousePressed'; buttons = 1 })

    $ok = $false
    $wasStopped = $false
    $deadline = (Get-Date).AddSeconds($MaxHoldSeconds)
    $tick = 0
    $repositionAt = (Get-Date).AddSeconds(2)
    $visCheckLeft = 3        # 每 3 个复查周期（约 6 秒）确认一次窗口还在前台
    try {
    while ((Get-Date) -lt $deadline) {
        if (Test-StopRequested) { $wasStopped = $true; break }   # 长按期间也要能停；finally 会释放鼠标
        Start-Sleep -Milliseconds (Get-Random -Minimum 180 -Maximum 260)
        $tick++
        # ---- 心跳：每 220ms 发一次"还在按着"的移动事件（±1px 微抖，贴近真人手指）----
        # 这是让平台的长按进度条真正走起来的关键，别删。
        $jx = $x + (($tick % 3) - 1)
        $jy = $y + ((($tick + 1) % 3) - 1)
        try {
            $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' `
                -Params @{ x = $jx; y = $jy; button = 'left'; buttons = 1; type = 'mouseMoved' } -TimeoutMs 4000
        } catch { }

        # 每约 2 秒复查一次：弹窗还在不在、按钮位置有没有变、窗口可不可见
        if ((Get-Date) -ge $repositionAt) {
            $repositionAt = (Get-Date).AddSeconds(2)
            $st = $null
            try { $st = Get-PlayerState -Ws $Ws } catch { }
            if ($st -and -not $st.dialog) { $ok = $true; break }
            if ($st -and ($null -ne $st.holdX) -and ($null -ne $st.holdY)) {
                $dx = [Math]::Abs([int]$st.holdX - $x); $dy = [Math]::Abs([int]$st.holdY - $y)
                if ($dx -gt 8 -or $dy -gt 8) {
                    # 按钮挪远了：旧位置上按住的进度平台本来也没在记 —— 松开、移过去、重新按
                    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' `
                        -Params @{ x = $x; y = $y; button = 'left'; buttons = 0; type = 'mouseReleased'; clickCount = 1 }
                    $x = [int]$st.holdX; $y = [int]$st.holdY
                    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' `
                        -Params @{ x = $x; y = $y; button = 'left'; buttons = 0; type = 'mouseMoved' }
                    Start-Sleep -Milliseconds 60
                    $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' `
                        -Params @{ x = $x; y = $y; button = 'left'; buttons = 1; type = 'mousePressed'; clickCount = 1 }
                } elseif ($dx -gt 0 -or $dy -gt 0) {
                    # 小幅挪动（弹窗过渡动画/进度条伸缩）：保持按住把指针跟过去即可 ——
                    # 松开重按会让平台把已累计的进度清零，能不松就不松
                    $x = [int]$st.holdX; $y = [int]$st.holdY
                }
            }
            $visCheckLeft--
            if ($visCheckLeft -le 0) {
                $visCheckLeft = 3
                try {
                    $vRaw = Invoke-Js -Ws $Ws -Expression $JsVisibility -TimeoutMs 4000
                    if (-not [string]::IsNullOrEmpty($vRaw)) {
                        $v = ConvertFrom-Json -InputObject $vRaw
                        if ($v.vis -ne 'visible') {
                            Write-Log '按住期间窗口离开了前台，已自动拉回（窗口不可见时平台不累计按住进度）' '提醒'
                            try { $null = Send-CdpCommand -Ws $Ws -Method 'Page.bringToFront' -TimeoutMs 4000 } catch { }
                        }
                    }
                } catch { }
            }
        }
    }
    }
    finally {
        # 无论成功、失败还是 CDP 异常，都必须松开鼠标，避免页面一直处于“按住”状态。
        # 用当前坐标：按钮可能在按住期间移动过，旧坐标不一定还在按钮上。
        try { $null = Send-CdpCommand -Ws $Ws -Method 'Input.dispatchMouseEvent' -Params @{ x = $x; y = $y; button = 'left'; clickCount = 1; type = 'mouseReleased'; buttons = 0 } } catch { }
    }
    if ($wasStopped) { return $false }
    if (-not $ok) {
        # 松开后再给它一点时间：平台的校验接口可能是异步的，松开瞬间才回执
        Start-Sleep -Milliseconds 1200
        $st2 = $null
        try { $st2 = Get-PlayerState -Ws $Ws } catch { }
        if ($st2 -and -not $st2.dialog) { $ok = $true }
        else {
            # ---- 失败诊断：把"事件到底有没有到页面"也写进日志，下次一眼定位 ----
            $diag = '事件计数器读不到（页面可能已跳转）'
            try {
                $lpRaw = Invoke-Js -Ws $Ws -Expression $JsReadLongPressProbe -TimeoutMs 4000
                if (-not [string]::IsNullOrEmpty($lpRaw)) {
                    $lp = ConvertFrom-Json -InputObject $lpRaw
                    if ([int]$lp.move -gt 0) {
                        $diag = ("页面收到了事件流（pointermove={0}）—— 平台没认：重点看窗口可见性/焦点，其次才是平台策略" -f $lp.move)
                    } else {
                        $diag = '页面一个 pointermove 都没收到 —— 事件没落到按钮上（坐标不对 / 被遮挡 / 按钮在 iframe 里）'
                    }
                }
            } catch { }
            Write-Log ("已在 ({0},{1}) 持续按住 {2} 秒，弹窗仍未消失 —— {3}" -f `
                       $x, $y, $MaxHoldSeconds, $diag) '警告'
        }
    }
    # 按完（成功）把窗口最小化回去，把前台还给用户；失败时保持前台（要人工按，别缩）
    if ($ok -and $wasHidden) {
        if (Invoke-MinimizeVideoWindow -Ws $Ws) {
            Write-Log '已把视频页窗口最小化，前台还给你了' '信息'
        }
    }
    return $ok
}

function Wait-UserConfirm {
    # 兜底：自动长按未能通过时，提醒并等待使用者本人完成确认
    # 安全阀：等太久（默认 15 分钟）就返回 'timeout'，由调用方跳过本讲并在汇总里说明
    # （原来是无条件死等，挂机过夜时会永远停在这一讲上）
    param($Ws, [int]$Index, [string]$Title, [int]$PollSeconds, [int]$MaxMinutes = 15)
    # 要用户本人来按，先把视频页带到前台 —— 窗口最小化时用户可能对着空气干等
    try { $null = Send-CdpCommand -Ws $Ws -Method 'Page.bringToFront' -TimeoutMs 4000 } catch { }
    $round = 0
    $deadline = (Get-Date).AddMinutes($MaxMinutes)
    while ($true) {
        if (Test-StopRequested) {
            Write-Log '收到停止指令，结束等待' '提醒'
            return $false
        }
        if ((Get-Date) -ge $deadline) {
            Write-Log ("等人工确认已超过 {0} 分钟，先跳过这一讲（稍后可在汇总里看到）" -f $MaxMinutes) '警告'
            return 'timeout'
        }
        $st = $null
        try { $st = Get-PlayerState -Ws $Ws } catch { }
        if ($st -and -not $st.dialog) {
            Write-Log '确认已完成，恢复播放监控' '成功'
            return $true
        }
        $round++
        if (($round % 4) -eq 0) {
            # 每约 20 秒再提醒一次（气泡不抢焦点，不会打断长按）
            Show-Reminder -Title '仍在等待你的确认' -Text ("第 {0} 讲《{1}》的确认弹窗还在，请按住「按住确认」按钮。" -f $Index, $Title)
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-AutoConfirm {
    # 弹窗总入口：先自动长按（最多 confirm_max_attempts 次），
    # 全部失败再退回人工提醒模式
    param($Ws, [int]$Index, [string]$Title, $Cfg, [int]$PollSeconds)
    # 安全开关：auto_confirm=false 时完全不自动长按，直接交给用户本人。
    if ($null -ne $Cfg.auto_confirm -and -not [bool]$Cfg.auto_confirm) {
        Write-Log '配置 auto_confirm=false：跳过自动长按，等你本人按「按住确认」' '提醒'
        Show-Reminder -Title '弹窗需要你本人确认' -Text ("第 {0} 讲《{1}》：配置要求人工确认，请在 Edge 窗口中按住「按住确认」。" -f $Index, $Title)
        $maxWait = 15
        if ([int]$Cfg.wait_confirm_max_minutes -gt 0) { $maxWait = [int]$Cfg.wait_confirm_max_minutes }
        return (Wait-UserConfirm -Ws $Ws -Index $Index -Title $Title -PollSeconds $PollSeconds -MaxMinutes $maxWait)
    }
    $attempts = [int]$Cfg.confirm_max_attempts
    if ($attempts -lt 1) { $attempts = 3 }
    $maxHold = [int]$Cfg.confirm_hold_seconds
    if ($maxHold -lt 5) { $maxHold = 25 }
    for ($a = 1; $a -le $attempts; $a++) {
        if (Test-StopRequested) { return $false }
        Write-Log ("第 {0} 讲《{1}》弹出【考勤确认】，自动长按「按住确认」进行校验（第 {2}/{3} 次，每次最多按住 {4} 秒）" -f $Index, $Title, $a, $attempts, $maxHold) '提醒'
        if (Invoke-LongPressConfirm -Ws $Ws -MaxHoldSeconds $maxHold) {
            Write-Log '长按校验通过，弹窗已关闭' '成功'
            return $true
        }
        if (Test-StopRequested) { return $false }
        Start-Sleep -Seconds 2
    }
    Write-Log '自动长按未能通过，改为你本人确认：请在 Edge 窗口里按住「按住确认」直到进度条满' '警告'
    Show-Reminder -Title '弹窗需要你本人确认' -Text ("第 {0} 讲《{1}》：自动长按未通过，请在 Edge 窗口中按住「按住确认」按钮完成校验，脚本会等你。" -f $Index, $Title)
    $maxWait = 15
    if ([int]$Cfg.wait_confirm_max_minutes -gt 0) { $maxWait = [int]$Cfg.wait_confirm_max_minutes }
    return (Wait-UserConfirm -Ws $Ws -Index $Index -Title $Title -PollSeconds $PollSeconds -MaxMinutes $maxWait)
}

# =====================================================================
# 9. 单个视频的播放监控
# =====================================================================
function Invoke-WatchVideo {
    param($Ws, $Video, $Cfg, [int]$Index, [int]$Total)

    $title = $Video.title
    if ([string]::IsNullOrEmpty($title)) { $title = '活动 ' + $Video.id }
    # 按**活动自己的插件类型**拼 URL（别硬编码 fsresource —— resource/H5P 等会 404）
    $vt = Get-ActivityMod -Item $Video
    if ([string]::IsNullOrWhiteSpace($vt)) { $vt = 'fsresource' }
    $url = "https://moodle.scnu.edu.cn/mod/$vt/view.php?id=$($Video.id)"
    $pollSeconds = [int]$Cfg.poll_seconds
    if ($pollSeconds -lt 3) { $pollSeconds = 3 }
    $logEvery   = [int]$Cfg.progress_log_seconds
    if ($logEvery -lt 10) { $logEvery = 30 }
    $maxRetry   = [int]$Cfg.max_retries
    if ($maxRetry -lt 1) { $maxRetry = 3 }

    $result = [pscustomobject]@{
        序号 = $Index
        标题 = $title
        活动 = $Video.id
        状态 = '未开始'
        观看进度 = '0%'
        弹窗次数 = 0
        备注 = ''
    }

    Write-Log ("--- 第 {0}/{1} 讲：{2}（活动 {3}）---" -f $Index, $Total, $title, $Video.id) '信息'

    $risk = Get-SiteRisk -Ws $Ws
    if ($risk) {
        $pr = Pause-ForSiteRisk -Ws $Ws -Risk $risk -Index $Index -Title $title -Cfg $Cfg
        if ($pr -eq 'stopped') { $result.状态 = '已停止'; $result.备注 = '风控处理期间被停止'; return $result }
        if ($pr -ne 'ok') { $script:SiteRiskStop = $true; $result.状态 = '风控停止'; $result.备注 = '平台提示未解除'; return $result }
    }

    # 导航：优先真实点击课程索引（平台自己的链接，会话状态切换才正确）；
    # 无论走哪条路都先停掉上一讲的视频 → 避免平台报「不可同时观看多个视频」。
    # 有些活动（论坛/实验/资源）页面里根本没有视频，所以就绪条件只等"页面加载完"，
    # 而不是"必须有 video"（后者会让这类活动白等 90 秒）。
    if (-not (Navigate-ToVideo -Ws $Ws -Id ([string]$Video.id) -Url $url -ReadyJs $JsLoaded)) {
        $result.状态 = '失败'
        $result.备注 = '页面打开失败或未就绪'
        return $result
    }
    $hasV = $null
    try { $hasV = (Get-PlayerState -Ws $Ws).hasVideo } catch { }
    if ($hasV -ne $true) {
        # 播放器可能是异步创建的；只等 2 秒会把慢加载的讲永久跳过。
        for ($hv = 0; $hv -lt 20 -and $hasV -ne $true; $hv++) {
            Start-Sleep -Seconds 1
            try { $hasV = (Get-PlayerState -Ws $Ws).hasVideo } catch { }
        }
    }
    # 确认切换后页面上没有残留的第二个播放器（有的话再清一次，别把两个播放器同时留在页面里）
    try {
        $vcRaw = Invoke-Js -Ws $Ws -Expression $JsVideoCount -TimeoutMs 6000
        if (-not [string]::IsNullOrEmpty($vcRaw)) {
            $vc = ConvertFrom-Json -InputObject $vcRaw
            if ($vc -and [int]$vc.playing -gt 1) {
                Write-Log ("检测到页面上有 {0} 个视频在同时播放，先清掉多余的（避免平台判定为同时观看）" -f $vc.playing) '警告'
                $null = Stop-PageVideo -Ws $Ws
                Start-Sleep -Milliseconds 600
                $hasV = $null
                try { $hasV = (Get-PlayerState -Ws $Ws).hasVideo } catch { }
            }
        }
    } catch { }
    if ($hasV -ne $true) {
        Write-Log ("《{0}》这个页面里没有视频（可能是论坛/实验/资源类活动），本轮跳过" -f $title) '提醒'
        $result.状态 = '非视频跳过'
        $result.备注 = '页面里没有可播放的视频'
        return $result
    }

    # 记录本讲所属章节（面包屑里的「第X周-教学视频」），供控制台显示
    try {
        $secName = [string](Invoke-Js -Ws $Ws -Expression $JsSectionName)
        if (-not [string]::IsNullOrWhiteSpace($secName)) {
            Write-Log ("本讲章节：{0}" -f $secName.Trim()) '信息'
        }
    } catch { }

    # ⚠ 采信 completed 之前**必须确认页面确实已经是这一讲** —— 切讲走的是平台自己的跳转，
    #   若页面还停在上一讲（导航刚发出、DOM 还没换），读到的 completed 是上一讲的，
    #   会把它当成本讲"此前已完成"直接跳过（用户实报"刷完一讲后剩下所有讲被秒判完成"）。
    $st = $null
    for ($wt = 0; $wt -lt 10; $wt++) {
        $st = $null
        try { $st = Get-PlayerState -Ws $Ws } catch { }
        if ($st -and ([string]$st.activityId -eq [string]$Video.id)) { break }
        Start-Sleep -Milliseconds 700
    }
    if ($st -and ([string]$st.activityId -ne [string]$Video.id)) {
        # ⚠ 页面没能切到目标讲（索引点击失败 / 导航被拦）—— 绝不能在**错误的页面**上继续，
        #   否则会把上一讲的画面当成这一讲在"播放"（用户实报：清单里两讲同时"播放中"）。
        Write-Log ("切讲失败：页面仍停在活动 {0}（目标 {1}），这一讲按失败跳过，避免在错误页面上播放" -f $st.activityId, $Video.id) '错误'
        $result.状态 = '失败'
        $result.备注 = '切讲跳转失败：页面未能切换到目标讲'
        return $result
    }
    if ($st -and $st.completed) {
        # 如实汇报平台记的真实进度：各课完成线不同（90% 的课在 90% 就算完成），
        # 硬写 100% 会让人误以为"平台记了 100%"。
        $seen = '—'
        if ($null -ne $st.platPct) { $seen = "$($st.platPct)%" }
        Write-Log ("该讲此前已完成，跳过播放（平台记录进度 {0}）" -f $seen) '成功'
        $result.状态 = '已完成（跳过）'
        $result.观看进度 = $seen
        $result.备注 = '平台已记账完成'
        return $result
    }

    if (-not (Start-Playback -Ws $Ws)) {
        Write-Log '无法开始播放，稍后重试' '警告'
    }

    $lastLogAt      = Get-Date
    $readFail       = 0
    $reconnectN     = 0
    $pausedSince    = $null
    $retry          = 0
    $endedNotDoneAt = $null
    $everStarted    = $false   # 是否成功开播过（切换讲次后若一直没播起来，用更短的重试间隔）
    $replayCount    = 0        # 已"重播补时长"的次数
    $maxReplay      = 1        # 播完仍未达标时最多重播几次（补平台记账所需的时长）
    if ([int]$Cfg.replay_max -gt 0) { $maxReplay = [int]$Cfg.replay_max }
    $replayBasePct  = 0        # 重播开始时的平台进度（用来判断"重播到底有没有用"）
    $replayCheckAt  = $null    # 重播后何时回头检查"进度涨了没有"
    $escapeN        = 0        # 连续检测到"页面不是这一讲"的次数
    $escapeTotal    = 0        # 本讲累计被跳离的次数（超过 3 次就放弃，防无限拉锯）
    $pollN          = 0        # 轮询计数（定期检查平台风控提示）
    $lastPct        = -1       # 上一个进度百分比（用于"长时间没有进展"看门狗）
    $idleSince      = Get-Date # 进度最后一次推进的时间
    $stuckMinutes   = 20       # 本讲多久没有任何进展就放弃它
    if ([int]$Cfg.stuck_minutes -gt 0) { $stuckMinutes = [int]$Cfg.stuck_minutes }

    while ($true) {
        if (Test-StopRequested) {
            Write-Log '收到停止指令，保存当前进度并退出' '提醒'
            try {
                $pr = Invoke-Js -Ws $Ws -Expression $JsPauseVideo -TimeoutMs 5000
                if ($pr -eq 'paused') { Write-Log '已暂停页面中的视频' '信息' }
            } catch { }
            $result.状态 = '已停止'
            $result.备注 = '由使用者手动停止'
            return $result
        }

        $pollN++
        if (($pollN % 6) -eq 1) {
            $risk = Get-SiteRisk -Ws $Ws
            if ($risk) {
                $pr = Pause-ForSiteRisk -Ws $Ws -Risk $risk -Index $Index -Title $title -Cfg $Cfg
                if ($pr -eq 'stopped') { $result.状态 = '已停止'; $result.备注 = '风控处理期间被停止'; return $result }
                if ($pr -ne 'ok') {
                    $script:SiteRiskStop = $true
                    $result.状态 = '风控停止'
                    $result.备注 = ('平台提示未解除：' + [string]$risk.reason)
                    return $result
                }
            }
        }
        $sleepMs = $pollSeconds * 1000
        if ($Cfg.pacing_jitter) { $sleepMs = Get-JitterMs -BaseMs $sleepMs -Percent 20 }
        Start-Sleep -Milliseconds $sleepMs
        $st = $null
        $stErr = $false
        try { $st = Get-PlayerState -Ws $Ws } catch {
            # 偶发读不到（页面刚跳转/正忙）时立刻再试一次
            Start-Sleep -Milliseconds 900
            try { $st = Get-PlayerState -Ws $Ws } catch { $stErr = $true }
        }
        if ($stErr -or -not $st) {
            # 读不到状态有两种情况：抛异常、或返回空(null)。
            # 原来只统计异常，返回 null 时会把计数清零再 continue ——
            # 于是页面卡住（如标签页被换成空白页）时会静默空转：不记日志、永不退出。
            $readFail++
            if ($readFail -eq 3) {
                Write-Log '偶尔读不到播放状态，脚本会自动重试（不影响播放）' '提醒'
            }
            if ($readFail -ge 6) {
                # 连续半分钟读不到：多半是浏览器连接断了（页面刷新/标签关闭），尝试重新附着
                $reconnectN++
                if ($reconnectN -gt 3) {
                    Write-Log '多次重连都没成功，本讲中止，避免无限重连' '错误'
                    $result.状态 = '失败'
                    $result.备注 = '浏览器连接反复断开'
                    return $result
                }
                Write-Log ('浏览器连接似乎断开了，正在尝试重新附着（第 {0}/3 次）…' -f $reconnectN) '警告'
                $re = $null
                try {
                    $oldWs = $Ws
                    $re = Connect-Cdp -Port ([int]$Cfg.debug_port)
                    if ($oldWs -and $oldWs -ne $re) { try { $oldWs.Dispose() } catch { } }
                } catch { }
                if ($re) {
                    $script:Ws = $re
                    $Ws = $re          # 函数参数也要换；否则 continue 后还在用断开的旧连接
                    $readFail = 0
                    Write-Log '已重新连接浏览器，继续监控本讲' '成功'
                    continue
                }
                Write-Log '无法重新连接浏览器，本讲中止。可重新点「开始刷课」继续' '错误'
                $result.状态 = '失败'
                $result.备注 = '浏览器连接断开'
                return $result
            }
            continue
        }
        $readFail = 0

        # 弹窗：自动长按校验（失败退回人工提醒；长时间没人确认则跳过本讲）
        if ($st.dialog) {
            $result.弹窗次数++
            $confirmed = Invoke-AutoConfirm -Ws $Ws -Index $Index -Title $title -Cfg $Cfg -PollSeconds $pollSeconds
            if ($confirmed -ne $true) {
                if ($confirmed -eq 'timeout') {
                    $result.状态 = '异常跳过'
                    $result.备注 = ('等人工确认超过 {0} 分钟，已跳过本讲' -f [int]$Cfg.wait_confirm_max_minutes)
                } else {
                    $result.状态 = '已停止'
                    $result.备注 = '等待确认期间被停止'
                }
                return $result
            }
            $st2 = Get-PlayerState -Ws $Ws
            if ($st2 -and $st2.paused -and -not $st2.ended) { $null = Start-Playback -Ws $Ws }
            $lastLogAt = Get-Date
            continue
        }

        # ★ 页面逃逸检测：每轮轮询都确认页面**还是这一讲**。被平台/误操作跳走（跳到
        #   课程搜索页、门户、登录页等）就**立即导航回来**继续，而不是傻等到看门狗超时
        #   （用户实报：页面被跳到课程搜索页，脚本卡在"正在播放"十几分钟不动）。
        $aid = [string]$st.activityId
        if ($aid -ne [string]$Video.id) {
            $escapeN++
            if ($escapeN -ge 2) {
                $escapeTotal++
                if ($escapeTotal -gt 3) {
                    Write-Log '页面反复被跳离目标讲，放弃这一讲（避免无限拉锯）' '错误'
                    $result.状态 = '失败'
                    $result.备注 = '页面反复被跳离目标讲（平台跳转/误操作）'
                    return $result
                }
                $shownAid = $aid
                if ([string]::IsNullOrWhiteSpace($shownAid)) { $shownAid = '（无活动 id 的页面）' }
                Write-Log ("页面被跳走了（当前 {0}，目标 {1}）—— 直接导航回来继续" -f $shownAid, $Video.id) '提醒'
                $null = Send-CdpCommand -Ws $Ws -Method 'Page.navigate' -Params @{ url = $url }
                $null = Wait-PageReady -Ws $Ws -Url $url -ReadyJs (Get-ReadyJsForId -Id ([string]$Video.id)) -TimeoutSec 60
                $escapeN = 0
                $lastPct = -1
                $idleSince = Get-Date
                $pausedSince = $null
                $endedNotDoneAt = $null
                $everStarted = $false
                continue
            }
        } else {
            $escapeN = 0
        }

        $pct = 0
        if ($st.duration -gt 0) { $pct = [math]::Round(($st.current / $st.duration) * 100, 1) }
        # 汇报给控制台的进度**优先用平台记的那个**（它才是"能不能算完成"的依据，
        # 也和用户在平台上看到的一致；两者算法不同：播放位置 vs 平台累计观看时长）。
        # 平台读不到时才退回按播放位置算的值。
        if ($null -ne $st.platPct) { $result.观看进度 = "$($st.platPct)%" } else { $result.观看进度 = "$pct%" }

        # 看门狗：进度只要还在推进就重置计时；长时间原地不动（播放器坏了/页面卡住）
        # 就跳过着走，避免整夜耗在同一个视频上
        if ($pct -gt $lastPct) {
            $lastPct = $pct
            $idleSince = Get-Date
        } elseif (((Get-Date) - $idleSince).TotalSeconds -ge ($stuckMinutes * 60)) {
            Write-Log ("本讲已经 {0} 分钟没有任何播放进展，跳过它（后面可在汇总里看到）" -f $stuckMinutes) '错误'
            $result.状态 = '异常跳过'
            $result.备注 = '长时间没有任何播放进展'
            return $result
        }

        if (((Get-Date) - $lastLogAt).TotalSeconds -ge $logEvery) {
            # 展示用平台记录值：视频位置只代表“这一遍播到哪”，平台上可能早已累计到
            # 58%（换过设备/之前看过），拿视频位置当总进度会严重低估。
            # 平台读不到时才退回视频位置；秒数仍用本遍的 current/duration（算本遍剩余）。
            $showPct = $pct
            if ($null -ne $st.platPct) { $showPct = [double]$st.platPct }
            Write-Log ("进度 {0}%（{1:N0}/{2:N0} 秒）" -f $showPct, $st.current, $st.duration) '信息'
            $lastLogAt = Get-Date
        }

        if ($st.rate -ne 1) {
            Write-Log ("注意：当前播放速率为 {0}x，请保持 1 倍速播放" -f $st.rate) '警告'
        }

        # 重播补时长的"有效性观察"：重播 1 分钟后回头看平台进度有没有涨。
        # 没涨 → 这门课不是按累计观看时长记账，重播没用 —— 立即收手，
        # 别再白播一整段（这类课的视频动辄几十分钟）。
        if ($replayCheckAt -and (Get-Date) -ge $replayCheckAt) {
            $replayCheckAt = $null
            if ($null -ne $st.platPct) {
                $nowPlat = [double]$st.platPct
                if ($nowPlat -le $replayBasePct) {
                    Write-Log ("重播了 1 分钟、平台进度仍停在 {0}%（没涨）—— 说明这门课重播补时长没用，先跳过这一讲" -f $nowPlat) '警告'
                    $result.状态 = '已播完（未确认完成）'
                    $result.观看进度 = "$nowPlat%"
                    $result.备注 = '视频已播完、平台进度未满，且重播无效（建议人工核对）'
                    return $result
                }
            }
        }

        $reachedEnd = $st.ended -or ($st.duration -gt 0 -and $st.current -ge ($st.duration - 1))
        if ($reachedEnd) {
            if ($st.completed -and ([string]$st.activityId -eq [string]$Video.id)) {
                $finTxt = ''
                if ($null -ne $st.platPct) { $finTxt = ("（平台进度 {0}%）" -f $st.platPct) }
                Write-Log ("页面显示已完成，本讲结束{0}" -f $finTxt) '成功'
                $result.状态 = '已完成'
                if ($null -ne $st.platPct) { $result.观看进度 = "$($st.platPct)%" } else { $result.观看进度 = "$pct%" }
                return $result
            }
            if (-not $endedNotDoneAt) {
                Write-Log '视频已播放到结尾，等待平台记账（最长 90 秒）' '信息'
                $endedNotDoneAt = Get-Date
            }
            if (((Get-Date) - $endedNotDoneAt).TotalSeconds -ge 90) {
                # ⚠ 用户实报：有的课平台要求「100%」，但它记的**总时长比视频实际长度长**
                #   （或按累计观看时长记账）—— 于是**视频播完了，平台进度仍停在 98%**。
                #   对策：**从头重播一遍把时长补上**（平台按累计时长记账时就能补齐）；
                #   最多补 $maxReplay 次；补不上就如实报告并继续，绝不死循环。
                if ($replayCount -lt $maxReplay) {
                    $replayCount++
                    Write-Log ("视频播完了但平台进度还没满（它可能要求 100%、而记的时长比视频长）—— 重播一遍补时长（第 {0}/{1} 次）" -f $replayCount, $maxReplay) '信息'
                    $rp = ''
                    try { $rp = Invoke-Js -Ws $Ws -Expression $JsReplay -TimeoutMs 6000 } catch { }
                    if ($rp -eq 'replayed' -or $rp -eq 'already-playing') {
                        $endedNotDoneAt = $null
                        $lastPct = -1            # 重置看门狗：进度要从 0 重新走
                        $idleSince = Get-Date
                        $pausedSince = $null
                        $everStarted = $true
                        # 记下重播前的平台进度，60 秒后回来核对"涨了没有"（见循环里的观察点）
                        if ($null -ne $st.platPct) { $replayBasePct = [double]$st.platPct }
                        $replayCheckAt = (Get-Date).AddSeconds(60)
                        continue
                    }
                    Write-Log '重播没能开始（播放器状态异常），按"已播完"处理' '警告'
                }
                Write-Log '已播完、平台仍未标记完成，先跳过这一讲（建议稍后人工核对）' '警告'
                $result.状态 = '已播完（未确认完成）'
                if ($null -ne $st.platPct) { $result.观看进度 = "$($st.platPct)%" } else { $result.观看进度 = "$pct%" }
                $result.备注 = '视频已播完，但平台进度未满（可能平台记的时长比视频长）'
                return $result
            }
            continue
        }

        if ($st.completed -and ([string]$st.activityId -eq [string]$Video.id)) {
            # 平台已认可（「当前状态为已完成」，或"我的播放进度"已达平台写明的完成线）
            # → **立即收工、切下一讲**。
            # ⚠ 用户澄清过："播完再切"指的是**平台那个百分比到了完成线**，
            #   不是"视频必须整段播到结尾" —— 达标就该切，别白播剩下的时长。
            $finTxt = ''
            if ($null -ne $st.platPct) { $finTxt = ("（平台进度 {0}%）" -f $st.platPct) }
            Write-Log ("平台已记账完成，本讲结束{0}" -f $finTxt) '成功'
            $result.状态 = '已完成'
            if ($null -ne $st.platPct) { $result.观看进度 = "$($st.platPct)%" } else { $result.观看进度 = "$pct%" }
            return $result
        }

        if ($st.paused) {
            if (-not $pausedSince) { $pausedSince = Get-Date }
            $stuckSeconds = ((Get-Date) - $pausedSince).TotalSeconds
            # 从未开播：10 秒就重试（切讲后常需多点一两次）；播放中暂停：按配置慢恢复
            $retryGap = 60
            if ([int]$Cfg.paused_stuck_seconds -gt 0) { $retryGap = [int]$Cfg.paused_stuck_seconds }
            if (-not $everStarted) { $retryGap = 10 }
            if ($stuckSeconds -ge $retryGap) {
                $retry++
                if ($retry -gt $maxRetry) {
                    Write-Log "连续 $maxRetry 次无法恢复播放，跳过本讲" '错误'
                    $result.状态 = '异常跳过'
                    $result.备注 = '多次重试后仍未恢复播放'
                    return $result
                }
                if (-not $everStarted) {
                    Write-Log ("尚未开始播放，第 {0} 次尝试开始" -f $retry) '提醒'
                } else {
                    Write-Log ("视频暂停已超过 {0:N0} 秒，第 {1} 次尝试恢复播放" -f $stuckSeconds, $retry) '警告'
                }
                $null = Start-Playback -Ws $Ws
                $pausedSince = $null
            }
        } else {
            $everStarted = $true
            $pausedSince = $null
            if ($retry -gt 0) { $retry = 0 }
        }
    }
}

# =====================================================================
# 10. 编码自检与链路自检
# =====================================================================
function Test-ScriptEncoding {
    # 防线：脚本里的中文常量必须能从文件正确读出。
    # 若文件编码被改动（例如用会改写编码的编辑器保存成 ANSI），
    # 中文会变成乱码，导致「已完成/播放/学习确认」等判断全部失效，这里提前拦下。
    $expect = ([string][char]0x5DF2) + ([string][char]0x5B8C) + ([string][char]0x6210)   # 已完成
    if ('已完成' -ne $expect) {
        Write-Host ''
        Write-Host '[致命错误] 脚本文件编码异常：中文常量读取错误。' -ForegroundColor Red
        Write-Host '           请用原始文件重新覆盖 auto_course.ps1，' -ForegroundColor Red
        Write-Host '           不要用会改变文件编码的编辑器另存。' -ForegroundColor Red
        return $false
    }
    return $true
}

function Invoke-SelfTest {
    # 只验证现有课堂标签的连接和只读脚本，不创建浏览器、不点击、不播放。
    $cfg = Read-Config -Path $ConfigPath
    $state = Get-EdgeAttachState -Port ([int]$cfg.debug_port)
    if (-not $state.connected) { throw '尚未接管 Edge，请先在控制台连接' }
    $ws = Connect-Cdp -Port ([int]$cfg.debug_port)
    if ((Invoke-Js -Ws $ws -Expression '1 + 1') -ne 2) { throw '只读脚本自检失败' }
    $title = Invoke-Js -Ws $ws -Expression 'document.title'
    Write-Host ('接管链路只读自检通过：' + $title) -ForegroundColor Green
}

# =====================================================================
# 11. 主流程
# =====================================================================


function Get-EdgeAttachState {
    param([int]$Port)
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$Port/liru/status")
    $req.Proxy = $null
    $req.Timeout = 1500
    $resp = $null
    $reader = $null
    try {
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $state = ConvertFrom-Json -InputObject $reader.ReadToEnd()
        if ($state.service -ne 'LiruEdgeAttach/1') { throw '接管端口不属于本工具，已拒绝操作未知服务' }
        return $state
    } finally {
        if ($reader) { $reader.Close() }
        if ($resp) { $resp.Close() }
    }
}

function Wait-EdgeAttachConnection {
    param([int]$Port, [int]$TimeoutSeconds = 20)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $state = Get-EdgeAttachState -Port $Port
        if ($state.connected -and $state.state -eq 'connected') { return $state }
        if ($state.state -eq 'error') { throw ([string]$state.message) }
        if ($state.state -ne 'connecting') { throw ([string]$state.message) }
        Start-Sleep -Milliseconds 200
    }
    throw '接管尚未完成：请在 Edge 中点击允许远程控制，然后重新运行本入口或再点一次「接管 Edge」'
}

function Invoke-AttachEdge {
    param($Cfg)
    Write-Log '接管 Edge 模式：只连接本人授权的现有浏览器' '信息'
    $python = Join-Path $ScriptDir 'runtime\python\python.exe'
    if (-not (Test-Path -LiteralPath $python)) {
        $command = Get-Command python.exe -ErrorAction SilentlyContinue
        if (-not $command) { $command = Get-Command python -ErrorAction SilentlyContinue }
        if (-not $command) { throw '找不到 Python，请使用完整发行目录或先打开控制台' }
        $python = $command.Source
    }
    $bridge = Join-Path $ScriptDir 'edge_attach.py'
    if (-not (Test-Path -LiteralPath $bridge)) { throw '缺少 edge_attach.py，请恢复完整程序文件' }
    $result = & $python -X utf8 $bridge --connect --port ([int]$Cfg.debug_port)
    if ($LASTEXITCODE -ne 0) { throw ([string]($result -join "`n")) }
    $state = Wait-EdgeAttachConnection -Port ([int]$Cfg.debug_port)
    Write-Host '已接管，请在日常 Edge 中打开一个课堂标签。' -ForegroundColor Cyan
}

function Invoke-Main {
    Write-Host ''
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host '  砺儒云课堂 · 课程视频播放辅助脚本' -ForegroundColor Cyan
    Write-Host '  说明：1 倍速真实播放；考勤确认弹窗自动长按通过（配置可改回人工）。' -ForegroundColor Cyan
    Write-Host '==============================================================' -ForegroundColor Cyan
    Write-Host ''

    Write-Log '脚本启动' '信息'
    # 这行是给控制台认的：它据此把界面切成"正在重新识别"，
    # 而不是误报成"正在刷课"（识别会附着浏览器、也会跑几十秒）。
    if ($ScanOnly) { Write-Log '重新识别模式：只核对每一讲的完成情况，不播放视频' '信息' }

    $psv = $PSVersionTable.PSVersion
    Write-Log ("PowerShell 版本：{0}" -f $psv.ToString()) '信息'
    if ($psv.Major -lt 5) { throw '需要 PowerShell 5.1 或更高版本' }

    $cfg = Read-Config -Path $ConfigPath
    $script:Cfg = $cfg
    $port = [int]$cfg.debug_port
    $videoWaitMin = 30                                  # 等你打开视频页的最长时间
    if ([int]$cfg.wait_video_max_minutes -gt 0) { $videoWaitMin = [int]$cfg.wait_video_max_minutes }

    if ($AttachEdge) {
        Invoke-AttachEdge -Cfg $cfg
        Write-Log '脚本结束' '信息'
        return
    }

    # 只连接经本人授权的接管适配器。
    try { $attachState = Get-EdgeAttachState -Port $port }
    catch { throw '尚未接管 Edge。请先点控制台的「接管 Edge」，或运行「1-接管Edge.bat」' }
    if (-not $attachState.connected) { throw ([string]$attachState.message) }

    Initialize-Notification
    $ws = Connect-Cdp -Port $port
    $null = Send-CdpCommand -Ws $ws -Method 'Page.enable'
    $null = Send-CdpCommand -Ws $ws -Method 'Runtime.enable'

    # 先确认浏览器停在一个能读到课程的地方（课程页或任意一讲），再抓结构。
    # 旧版顺序反了：先抓结构（失败/抓到别的课）再等页面，等于白跑一次。
    $href = $null
    try { $href = Invoke-Js -Ws $ws -Expression $JsHref } catch { }
    if (-not ($href -and ($href -match '/mod/[^/]+/view\.php' -or $href -match 'course/(?:view|section)\.php'))) {
        Write-Log '当前标签页不是课程页面，等待你在 Edge 中打开' '提醒'
        if (-not (Wait-ForVideoPage -Ws $ws -MaxMinutes $videoWaitMin)) {
            Write-Log '等待被中断' '提醒'
            return
        }
    }
    try { $href = Invoke-Js -Ws $ws -Expression $JsHref } catch { }
    Write-Log ("已识别到课程页面：{0}" -f $href) '成功'

    # 统一读取间隔：普通开始和重新识别共用，避免交替开始/停止造成重复扫描。
    try { Enter-RequestGuard -Cfg $cfg } catch { Write-Log '课程读取间隔检查失败，本次不请求网站' '警告'; throw }

    # 采集整门课的章节结构（一次 GET 课程页），写 课程结构.json 供控制台选章。
    # 这一步同时完成"哪些活动是视频"的分类（见 识别规则.ps1）。
    try {
        $script:CourseStruct = Get-CourseStructure -Ws $ws
        if ($script:CourseStruct) { Write-CourseStructureFile -Data $script:CourseStruct }
    } catch {
        Write-Log ("采集课程结构时出错：{0}" -f $_.Exception.Message) '警告'
    }
    # CDP 超时会把共享 socket abort 掉；不重连的话，紧接着的 Get-Playlist 会继续用死连接，
    # 最后误报“没有识别到视频”。这里只重试一次，避免无限循环。
    if (-not $script:CourseStruct) {
        Write-Log '课程结构没读到，正在重连浏览器后重试一次…' '警告'
        $re = $null
        try { $re = Connect-Cdp -Port ([int]$cfg.debug_port) } catch { }
        if ($re) {
            $ws = $re
            $script:Ws = $re
            try {
                $script:CourseStruct = Get-CourseStructure -Ws $ws
                if ($script:CourseStruct) { Write-CourseStructureFile -Data $script:CourseStruct }
            } catch { }
        }
    }

    # 读取播放列表（分类已在 Get-CourseStructure 里完成，这里只做筛选和排序）
    $videos = Get-Playlist -Ws $ws -Cfg $cfg -Scope $Scope -Chapter $Chapter
    if (-not $videos -or $videos.Count -eq 0) {
        throw '没有识别到要刷的视频：请确认已登录、并停在课程页或任意一讲页面'
    }

    $script:ScanResults = @{}
    if (-not $DryRun) {
        # 完成状态直接用刚抓的课程页（平台自己的标记），读不到的才实时核对
        $scan = Get-PendingVideos -Ws $ws -Videos $videos
        if ($null -eq $scan) {
            Write-Log '识别过程被停止' '提醒'
            return
        }
        $script:ScanResults = $scan.results
        $videos = @($scan.pending)
        # 把识别结果写回章节结构，控制台据此显示每章"还剩几讲"
        if ($script:CourseStruct -and $script:ScanResults.Count -gt 0) {
            try {
                $script:CourseStruct = Set-StructDone -Struct $script:CourseStruct -Results $script:ScanResults
                Write-CourseStructureFile -Data $script:CourseStruct
            } catch { }
        }
        if ($videos.Count -eq 0) {
            if ($ScanOnly) {
                Write-Log '重新识别完成：核对到 0 讲还没完成（只识别，不播放）' '成功'
            } else {
                Write-Log '识别结果：这门课的讲都已经完成了，本轮没有需要播放的内容' '成功'
            }
            return
        }
        Write-Log ("识别完成：本轮需要播放 {0} 讲" -f $videos.Count) '成功'
    }

    # 只识别在这一步就结束：此时 课程结构.json 已包含完整核对结果。
    # 必须放在 -Limit 之前，否则 -ScanOnly -Limit N 会把“还没完成几讲”报小。
    if ($ScanOnly) {
        Write-Log ("重新识别完成：核对到 {0} 讲还没完成（只识别，不播放）" -f $videos.Count) '成功'
        return
    }

    # auto_next=false：只处理本轮列表的第一讲（给“我只要刷这一讲”的场景）
    if ($null -ne $cfg.auto_next -and -not [bool]$cfg.auto_next -and $videos.Count -gt 1) {
        $videos = @($videos[0])
    }

    $limit = [int]$cfg.limit_videos
    if ($Limit -gt 0) { $limit = $Limit }     # 命令行 -Limit 优先于配置文件
    if ($limit -gt 0 -and $videos.Count -gt $limit) { $videos = @($videos[0..($limit - 1)]) }

    Write-Log ("本次将处理 {0} 个视频：" -f $videos.Count) '成功'
    $i = 0
    foreach ($v in $videos) {
        $i++
        $t = $v.title
        if ([string]::IsNullOrEmpty($t)) { $t = '活动 ' + $v.id }
        Write-Log ("计划 {0}. {1}（活动 {2}）" -f $i, $t, $v.id) '信息'
        Write-Host ("   {0}. {1}（id={2}）" -f $i, $t, $v.id) -ForegroundColor Gray
    }
    Write-Host ''

    if ($DryRun) {
        Write-Log '干跑模式：仅完成环境检查、附着与列表读取，不进行实际播放' '成功'
        return
    }

    $results = @()
    $i = 0
    foreach ($v in $videos) {
        $i++
        # 每讲开始前确认浏览器连接还活着；断了就重新附着（上一讲可能刷新过页面）
        if (-not (Test-CdpAlive -Ws $ws)) {
            Write-Log '浏览器连接已断开，正在重新附着…' '警告'
            $re = $null
            try { $re = Connect-Cdp -Port ([int]$cfg.debug_port) } catch { }
            if ($re) { $ws = $re; Write-Log '已重新连接浏览器' '成功' }
            else {
                Write-Log '无法重新连接浏览器，脚本停止。可稍后重新点「开始刷课」继续' '错误'
                break
            }
        }
        try {
            $results += Invoke-WatchVideo -Ws $ws -Video $v -Cfg $cfg -Index $i -Total $videos.Count
        } catch {
            # 单讲异常（CDP 超时、页面脚本异常等）只记这一讲，不能把整轮剩下的讲全放弃。
            $et = $v.title
            if ([string]::IsNullOrEmpty($et)) { $et = '活动 ' + $v.id }
            Write-Log ("第 {0} 讲《{1}》执行出错：{2}" -f $i, $et, $_.Exception.Message) '错误'
            $results += [pscustomobject]@{
                序号 = $i; 标题 = $et; 活动 = $v.id
                状态 = '失败'; 观看进度 = '—'; 弹窗次数 = 0
                备注 = '单讲异常：' + $_.Exception.Message
            }
        }
        # Invoke-WatchVideo 内部重连后会把新连接写进 $script:Ws；下一讲要用新的。
        if ($script:Ws) { $ws = $script:Ws }
        if ($script:SiteRiskStop) {
            Write-Log '平台风控提示未解除，本轮停止；处理后可重新开始' '错误'
            break
        }
        if (Test-StopRequested) { break }
    }

    Write-Host ''
    Write-Host '==================== 汇总 ====================' -ForegroundColor Cyan
    foreach ($r in $results) {
        $note = ''
        if ($r.备注) { $note = '；' + $r.备注 }
        $line = '{0}. {1} —— {2}（进度 {3}{4}）' -f $r.序号, $r.标题, $r.状态, $r.观看进度, $note
        $color = 'Yellow'
        if ($r.状态 -like '已完成*') { $color = 'Green' }
        Write-Host $line -ForegroundColor $color
        Write-Log ("汇总：{0}" -f $line) '信息'
    }
    Write-Host '==============================================' -ForegroundColor Cyan

    # 把本轮的最终结果也写回章节结构：控制台显示的"还剩几讲"用的就是这份实时数据
    try {
        if ($script:CourseStruct -and $script:ScanResults -and $script:ScanResults.Count -gt 0) {
            foreach ($r in $results) {
                if ([string]$r.状态 -like '已完成*') { $script:ScanResults[[string]$r.活动] = $true }
            }
            $script:CourseStruct = Set-StructDone -Struct $script:CourseStruct -Results $script:ScanResults
            Write-CourseStructureFile -Data $script:CourseStruct
        }
    } catch { }
    Write-Log '脚本结束' '信息'
}

# =====================================================================
# 12. 入口
# =====================================================================
try {
    # 单实例保护用命名 Mutex：PID 文件只能“事后判断”，两个进程可以同时通过检查；
    # Mutex 是原子的，进程退出（包括强杀）后内核自动释放。
    $engineMutex = New-Object System.Threading.Mutex($false, 'Local\LiruCourseConsoleEngine')
    $mutexHeld = $false
    try {
        $mutexHeld = $engineMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        $mutexHeld = $true      # 上一个进程异常退出；锁已经归我们
    }
    if (-not $mutexHeld) {
        $msg = '已经有一个刷课脚本在运行，本次不再重复启动。要重新开始请先点控制台的「停止」或双击 停止刷课.bat'
        Write-Log $msg '警告'
        Write-Host ('  ' + $msg) -ForegroundColor Yellow
        exit 3
    }

    # 拿到锁之后再删 stop.flag：不能在检查前删，否则会吞掉正在运行实例的停止请求。
    if (Test-Path -LiteralPath $StopFlag) { Remove-Item -LiteralPath $StopFlag -Force }

    # 锁已经证明没有别的引擎；run.pid 里残留的只能是上次强杀留下的旧记录。
    if (Test-Path -LiteralPath $PidFile) {
        $other = 0
        try { $other = [int]((Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim()) } catch { $other = 0 }
        if (($other -gt 0) -and ($other -ne $PID) -and (Test-ProcessAlive -Id $other)) {
            Write-Log ("清理陈旧的 run.pid（进程 {0} 已不是当前引擎）" -f $other) '警告'
        }
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }

    Set-Content -LiteralPath $PidFile -Value $PID -Encoding ASCII
    if (-not (Test-ScriptEncoding)) {
        Write-Log '脚本编码自检未通过，已中止' '错误'
        exit 2
    }
    if ($SelfTest) {
        Invoke-SelfTest
    } else {
        Invoke-Main
    }
}
catch {
    if ($AttachEdge) { $script:AttachFailed = $true }
    Write-Log ("发生错误：{0}" -f $_.Exception.Message) '错误'
    Write-Log '脚本结束' '信息'
    Write-Host ''
    Write-Host '常见处理办法：' -ForegroundColor Yellow
    Write-Host '  * 尚未接管 → 先在日常 Edge 允许调试，再点控制台「接管 Edge」' -ForegroundColor Yellow

    Write-Host '  * 接管端口冲突 → 修改 edge_attach_port；请勿为此关闭日常 Edge 或重建配置' -ForegroundColor Yellow
    Write-Host '  * 解析不到视频 → 确认课程索引已打开、已登录，或在 配置.json 填写 section_url' -ForegroundColor Yellow
}
finally {
    Close-Notification
    try {
        if ($script:Ws) {
            # 只读自检不改变媒体状态；正常任务退出仍暂停当前课堂视频。
            if (-not $SelfTest) {
                try {
                    $pr = Invoke-Js -Ws $script:Ws -Expression $JsPauseVideo -TimeoutMs 5000
                    if ($pr -eq 'paused') { Write-Log '已暂停页面中的视频' '信息' }
                } catch { }
            }
            $script:Ws.Dispose()
        }
    } catch { }
    # 只删属于自己的 pid 文件：万一有多个脚本交替运行，别把还在跑的那个的记录删掉，
    # 否则那个脚本会变成"控制台看不见、也停不掉"的孤儿
    try {
        if (Test-Path -LiteralPath $PidFile) {
            $mine = 0
            try { $mine = [int]((Get-Content -LiteralPath $PidFile -Raw -ErrorAction Stop).Trim()) } catch { $mine = 0 }
            if ($mine -eq $PID) { Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}
if ($AttachEdge -and $script:AttachFailed) { exit 1 }
