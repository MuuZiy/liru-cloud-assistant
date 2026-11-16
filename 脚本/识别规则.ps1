# =====================================================================
# 识别规则.ps1 —— "哪些活动是要刷的视频" 的唯一判定入口
# ---------------------------------------------------------------------
# 为什么单独一个文件：
#   1) 判定规则可以被独立测试（测试\test_rules.ps1 直接点源本文件）；
#   2) 引擎与控制台不再各维护一套类型表 —— 控制台只读引擎写进
#      课程结构.json 的 video / videoBy 字段；
#   3) 以后平台换主题、换插件，只改这一处。
#
# 判定顺序（从硬到软，先命中的赢）：
#   ① 平台渲染的活动图标（img[data-region="activity-icon"] 的 /f/xxx）
#      —— 这是平台自己对"这个活动里装的是什么文件"的结论，最准也最便宜。
#      实测：fsresource 插件既装视频（icon=f/video）也装图文 PDF（icon=f/pdf），
#      所以**插件名不能一刀切**，图标才是硬证据。
#   ② 平台返回的文件信息（files: mimetype / 扩展名）—— 官方接口可用时才有。
#   ③ 插件类型白名单 / 黑名单 —— 没有图标时的退路。
#   ④ 页面探测（fetch 活动页，看有没有 <video>/playerdata/文件链接）——
#      前三级都判不出来时才做，见 auto_course.ps1 的 Get-ActivityProbe。
#
# 返回约定：Get-ActivityKind 返回 kind = video / doc / unknown。
#   unknown 表示"确实判不出来"，交给页面探测；**绝不默认当视频**。
# =====================================================================

# ---- ① 图标里的文件类型（Moodle 的 /theme/image.php/<theme>/core/<rev>/f/<type>）----
# 视频类
$script:VideoIconFiles = @(
    'video', 'mp4', 'm4v', 'mov', 'flv', 'mkv', 'webm', 'avi', 'wmv',
    'ogv', 'ogg', 'mpeg', 'mpg', '3gp', 'ts', 'm3u8', 'mpd', 'rmvb', 'f4v', 'hls', 'dash'
)
# 明确不是视频的文件类型（文档/课件/压缩包/图片/音频…）
$script:DocIconFiles = @(
    'pdf', 'document', 'word', 'powerpoint', 'presentation', 'spreadsheet',
    'excel', 'archive', 'zip', 'rar', 'text', 'html', 'code', 'sourcecode',
    'image', 'audio', 'odt', 'ods', 'odp', 'csv', 'eps', 'svg', 'json', 'xml',
    'ppt', 'pptx', 'doc', 'docx', 'xls', 'xlsx', 'mp3', 'wav', 'm4a', 'flac'
)

# ---- ③ 插件类型 ----
# 视频插件白名单：这些插件**默认**装视频。注意 fsresource 是"容器"插件，
# 它也能装 PDF —— 所以图标优先，只有在拿不到图标时才用这一层。
$script:VideoTypes = @(
    'fsresource',
    'video', 'vod', 'videofile', 'local_video',
    'hvp', 'h5pactivity',
    'mediasite', 'kaltura', 'vimeo', 'youtube', 'panopto', 'echo360', 'mediacore', 'ivideo'
)
# 明确不是课程视频的插件
$script:NonVideoTypes = @(
    'forum', 'url', 'page', 'book', 'folder', 'label', 'subsection',
    'assign', 'quiz', 'choice', 'feedback', 'questionnaire', 'survey',
    'glossary', 'lesson', 'wiki', 'chat', 'data', 'imscp', 'scorm',
    'workshop', 'lti', 'bigbluebuttonbn', 'recordingsbn', 'geogebra',
    'pdfannotator', 'customcert', 'attendance', 'resource'
)

# ---- ② 文件扩展名（官方接口返回的 contents 或页面里的文件链接）----
$script:VideoExts = @('.mp4', '.m4v', '.mov', '.flv', '.mkv', '.webm', '.avi', '.wmv',
                      '.ts', '.m3u8', '.mpd', '.rmvb', '.f4v', '.3gp', '.ogv', '.mpeg', '.mpg')
$script:DocExts = @('.pdf', '.doc', '.docx', '.ppt', '.pptx', '.xls', '.xlsx', '.csv',
                    '.zip', '.rar', '.7z', '.txt', '.md', '.rtf', '.odt', '.ods', '.odp',
                    '.jpg', '.jpeg', '.png', '.gif', '.bmp', '.webp', '.svg', '.tif', '.tiff',
                    '.json', '.xml', '.html', '.htm', '.js', '.css')

# "容器型"插件：名字本身不能证明里面是视频，拿不到图标时值得再探测一次
$script:ContainerTypes = @('fsresource', 'resource', 'folder', 'url', 'page', 'book')


function Get-ActivityMod {
    # 取活动插件名。兼容 type / mod 两种字段名（不同数据来源写法不同）。
    param($Item)
    if ($null -eq $Item) { return '' }
    $names = @($Item.PSObject.Properties.Name)
    $t = ''
    if ($names -contains 'mod') { $t = [string]$Item.mod }
    if (-not $t -and ($names -contains 'type')) { $t = [string]$Item.type }
    if (-not $t -and ($names -contains 'iconPlugin')) { $t = [string]$Item.iconPlugin }
    if (-not $t -and ($names -contains 'className')) {
        $m = [regex]::Match([string]$Item.className, '(?:^|\s)modtype_([a-z0-9_]+)(?:\s|$)', 'IgnoreCase')
        if ($m.Success) { $t = $m.Groups[1].Value }
    }
    return $t.Trim().ToLower()
}

function Get-ActivityKind {
    # 判定一个活动"是不是要刷的视频"。
    # 返回对象：kind = video / doc / unknown；by = 依据；confident = 是否硬证据。
    param($Item)

    $mod = Get-ActivityMod -Item $Item
    $names = @()
    if ($null -ne $Item) { $names = @($Item.PSObject.Properties.Name) }

    # ① 平台图标（最硬）
    $icon = ''
    if ($names -contains 'iconFile') { $icon = ([string]$Item.iconFile).Trim().ToLower() }
    if ($icon) {
        if ($script:VideoIconFiles -contains $icon) {
            return [pscustomobject]@{ kind = 'video'; by = 'icon'; confident = $true; confidence = 'high' }
        }
        if ($script:DocIconFiles -contains $icon) {
            return [pscustomobject]@{ kind = 'doc'; by = 'icon'; confident = $true; confidence = 'high' }
        }
    }

    # ② 平台给的文件信息（只有官方接口路径才有）
    $files = @()
    if ($names -contains 'files') { $files = @($Item.files) }
    if ($files.Count -gt 0) {
        $hasVideo = $false; $hasDoc = $false
        foreach ($f in $files) {
            $mime = ([string]$f.mime).ToLower()
            $ext = ''
            try { $ext = [System.IO.Path]::GetExtension([string]$f.name).ToLower() } catch { }
            if ($mime -like 'video/*' -or $mime -match '^application/(?:vnd\.apple\.mpegurl|x-mpegurl|dash\+xml)(?:;|$)' -or ($ext -and ($script:VideoExts -contains $ext))) { $hasVideo = $true }
            elseif ($mime -like 'audio/*' -or ($ext -and ($script:DocExts -contains $ext))) { $hasDoc = $true }
        }
        if ($hasVideo) { return [pscustomobject]@{ kind = 'video'; by = 'file'; confident = $true; confidence = 'high' } }
        if ($hasDoc) { return [pscustomobject]@{ kind = 'doc'; by = 'file'; confident = $true; confidence = 'high' } }
    }

    # ③ 插件类型
    if ($mod -and ($script:VideoTypes -contains $mod)) {
        # 容器型插件（fsresource）没图标时只是"很可能"，交给探测复核
        $container = ($script:ContainerTypes -contains $mod)
        return [pscustomobject]@{ kind = 'video'; by = 'mod'; confident = (-not $container); confidence = $(if ($container) { 'low' } else { 'medium' }) }
    }
    if ($mod -and ($script:NonVideoTypes -contains $mod)) {
        return [pscustomobject]@{ kind = 'doc'; by = 'mod'; confident = $true; confidence = 'medium' }
    }

    # ④ 判不出来 —— 交给页面探测，绝不默认当视频
    return [pscustomobject]@{ kind = 'unknown'; by = 'none'; confident = $false; confidence = 'low' }
}

function Test-NeedsProbe {
    # 这个活动值不值得再 fetch 一次页面来判定。
    # 只有两种情况值得：① 完全判不出来；② 容器型插件靠插件名判成视频、没有图标佐证。
    param($Item, $Kind)
    if ($null -eq $Kind) { $Kind = Get-ActivityKind -Item $Item }
    # 通用容器也可能嵌入视频；插件黑名单不能盖过页面证据。
    if ($Kind.by -eq 'mod' -and $script:ContainerTypes -contains (Get-ActivityMod -Item $Item)) { return $true }
    if ($Kind.kind -eq 'unknown') { return $true }
    if ($Kind.kind -eq 'video' -and $Kind.by -eq 'mod' -and (-not $Kind.confident)) { return $true }
    return $false
}

function Get-ActivityFingerprint {
    # 只用于分类缓存；绝不复用完成状态。图标/标题/插件/DOM/地址变化立即失效。
    param($Item)
    $parts = @('classification-v2')
    foreach ($n in @('id', 'title', 'mod', 'type', 'url', 'icon', 'iconFile', 'iconPlugin', 'className', 'activityName')) {
        $parts += [string]$Item.$n
    }
    # 文件证据也是分类输入；同名活动替换媒体后不能复用旧探测。
    foreach ($f in @($Item.files)) {
        if ($null -ne $f) { $parts += @([string]$f.name, [string]$f.mime, [string]$f.url) }
    }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $parts -Compress))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower() }
    finally { $sha.Dispose() }
}

function Get-CachedActivityKind {
    param($Item, $CachedItem, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)
    if (-not $CachedItem -or $CachedItem.kind -notin @('video', 'doc')) { return $null }
    if ([string]$CachedItem.videoBy -notmatch '^probe-' -or -not $CachedItem.probeAt) { return $null }
    if ([string]$CachedItem.probeKey -ne (Get-ActivityFingerprint -Item $Item)) { return $null }
    try { $age = ($Now - [DateTimeOffset]::Parse([string]$CachedItem.probeAt)).TotalHours } catch { return $null }
    if ($age -lt 0 -or $age -ge 6) { return $null }
    if ($CachedItem.kindConfidence -notin @('high', 'medium')) { return $null }
    return [pscustomobject]@{ kind = [string]$CachedItem.kind; by = [string]$CachedItem.videoBy
        confident = $true; confidence = [string]$CachedItem.kindConfidence
        probeAt = [string]$CachedItem.probeAt; probeKey = [string]$CachedItem.probeKey }
}

function Select-VideoItems {
    # 从一组活动里挑出"视频"（unknown 也保留，交给后续探测；doc 剔除）。
    # 安全阀：如果**一个视频都没认出来**（全是 doc 或全是 unknown），说明这门课的图标/插件
    #   都不在已知名单里 —— 这时不做过滤，宁可多试一次也不把整门课判成空。
    #   注意：只要有任何一个活动被明确判成视频，就按结论过滤，不会把已知 doc 混进来。
    param([array]$Items)
    if (-not $Items -or $Items.Count -eq 0) { return @() }
    $kept = @()
    $docN = 0
    $videoN = 0
    foreach ($it in $Items) {
        $k = Get-ActivityKind -Item $it
        if ($k.kind -eq 'doc') { $docN++; continue }
        if ($k.kind -eq 'video') { $videoN++ }
        $it | Add-Member -NotePropertyName kind -NotePropertyValue $k.kind -Force
        $it | Add-Member -NotePropertyName kindBy -NotePropertyValue $k.by -Force
        $it | Add-Member -NotePropertyName kindConfident -NotePropertyValue ([bool]$k.confident) -Force
        $kept += $it
    }
    if ($kept.Count -eq 0 -or $videoN -eq 0) {
        Write-Host '[识别] 没认出任何视频，为免误杀，本轮不做非视频过滤' -ForegroundColor Yellow
        return @($Items)
    }
    if ($docN -gt 0) {
        Write-Host ("[识别] 已排除 {0} 个非视频活动（文档/课件/压缩包等），只处理有视频的讲" -f $docN) -ForegroundColor Gray
    }
    return $kept
}

function Select-PlaylistItems {
    # 纯函数：从课程结构（章节数组）里挑出要刷的视频并按范围排序。
    # 不碰浏览器、不写日志 —— 因此可以被单元测试直接覆盖。
    #   $Sections  : [{name, items:[{id,title,mod,video,kind,done,tracked}]}]
    #   $Scope     : forward / current / chapter / all
    #   $CurrentId : 当前打开的那一讲（用于 forward / current 的起点）
    # 返回 @{ items = @(); error = '' }；error 非空表示范围无效（例如章节名找不到）。
    param([array]$Sections, [string]$Scope = 'forward', [string]$Chapter = '',
          [string]$CurrentId = '', [bool]$WrapAround = $true)

    if (@('forward', 'current', 'chapter', 'all') -notcontains $Scope) {
        return @{ items = @(); error = ("未知的刷课范围：{0}" -f $Scope) }
    }
    $secs = @($Sections)
    if ($Scope -eq 'chapter') {
        $hit = @($secs | Where-Object { [string]$_.name -eq $Chapter })
        if (-not $hit -and -not [string]::IsNullOrEmpty($Chapter)) {
            $hit = @($secs | Where-Object { ([string]$_.name).IndexOf($Chapter, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
        }
        if (-not $hit) { return @{ items = @(); error = ("没有在课程里找到这一章：{0}" -f $Chapter) } }
        if ($hit.Count -ne 1) { return @{ items = @(); error = ('章节名称不唯一，请选择可唯一确定的章节：{0}' -f $Chapter) } }
        $secs = $hit
    }

    # 1) 展开成扁平列表，只保留"可能是视频"的
    $buffer = New-Object 'System.Collections.Generic.List[object]'
    $seen = @{}
    for ($sectionIndex = 0; $sectionIndex -lt $secs.Count; $sectionIndex++) {
        $s = $secs[$sectionIndex]
        foreach ($it in @($s.items)) {
            if ($null -eq $it) { continue }
            $id = [string]$it.id
            if (-not $id -or $seen.ContainsKey($id)) { continue }
            $names = @($it.PSObject.Properties.Name)
            $isVid = $true
            if ($names -contains 'video') { $isVid = ($it.video -is [bool] -and $it.video -eq $true) }
            else {
                $k = Get-ActivityKind -Item $it
                $isVid = ($k.kind -eq 'video' -and $k.confident)
            }
            # 候选活动仍在结构里，但未知/低置信度结论不能进入自动播放计划。
            if ($names -contains 'kind' -and [string]$it.kind -eq 'unknown') { $isVid = $false }
            if ($names -contains 'kindConfident' -and -not $it.kindConfident) { $isVid = $false }
            if (-not $isVid) { continue }
            $seen[$id] = $true
            $mod = Get-ActivityMod -Item $it
            $done = $null
            if ($names -contains 'done') { $done = $it.done }
            $tr = $true
            if ($names -contains 'tracked') { $tr = [bool]$it.tracked }
            $kind = 'unknown'; $kindBy = ''
            if ($names -contains 'kind') { $kind = [string]$it.kind }
            if ($names -contains 'kindBy') { $kindBy = [string]$it.kindBy }
            $buffer.Add([pscustomobject]@{
                id = [string]$it.id; title = [string]$it.title; section = [string]$s.name
                sectionIndex = $sectionIndex
                mod = $mod; type = $mod
                done = $done; tracked = $tr; kind = $kind; kindBy = $kindBy
            })
        }
    }
    $items = $buffer.ToArray()
    if ($items.Count -eq 0) { return @{ items = @(); error = '这门课里没有识别到需要刷的视频' } }

    # 2) 平台不跟踪完成的活动刷了也没有进度；但整门课都不跟踪时全部保留
    $trackedOnes = @($items | Where-Object { $_.tracked -ne $false })
    if ($trackedOnes.Count -gt 0 -and $trackedOnes.Count -lt $items.Count) {
        $items = $trackedOnes
    }

    $idx = -1
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ([string]$items[$i].id -eq $CurrentId) { $idx = $i; break }
    }
    if ($Scope -in @('forward', 'current') -and $CurrentId -and $idx -lt 0) {
        return @{ items = @(); error = ('当前活动 {0} 不在可处理的视频清单里，请重新识别或明确选择全课程' -f $CurrentId) }
    }

    # 3) 按范围切
    if ($Scope -eq 'forward') {
        # 从当前讲切到末尾。idx=0 时切片结果就是全表，等价于"从头开始"。
        if ($idx -ge 0) {
            $items = @($items[$idx..($items.Count - 1)])
        }
        return @{ items = @($items); error = '' }
    }

    if ($Scope -eq 'current') {
        if ([string]::IsNullOrEmpty($CurrentId)) {
            return @{ items = @(); error = '当前讲未知：请先在 Edge 里点开要开始的那一讲，再选「只刷当前章」' }
        }
        # 章节名可能重复或为空，按原结构中的位置确定归属。
        $curSection = $items[$idx].sectionIndex
        if ($idx -ge 0) {
            $items = @($items | Where-Object { $_.sectionIndex -eq $curSection })
            $idx = -1
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ([string]$items[$i].id -eq $CurrentId) { $idx = $i; break }
            }
            if ($idx -gt 0) {
                $head = @($items[$idx..($items.Count - 1)])
                $tail = @($items[0..($idx - 1)])
                if ($WrapAround) { $items = @($head + $tail) } else { $items = @($head) }
            }
        }
        return @{ items = @($items); error = '' }
    }

    if ($Scope -eq 'chapter') { return @{ items = @($items); error = '' } }
    if ($Scope -eq 'all') { return @{ items = @($items); error = '' } }
    return @{ items = @(); error = ("未知的刷课范围：{0}" -f $Scope) }
}
