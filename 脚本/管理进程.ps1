param([ValidateSet('stop', 'close')][string]$Action)
$ErrorActionPreference = 'Stop'

function Test-ManagedProcess {
    param($Process, [string]$Kind, [string]$RootDir)
    if (-not $Process -or -not $Process.CommandLine) { return $false }
    if ($Kind -eq 'stop') {
        if ($Process.Name -notmatch '^(powershell|pwsh)\.exe$') { return $false }
        $filename = 'auto_course.ps1'
    } else {
        if ($Process.Name -notmatch '^pythonw?\.exe$') { return $false }
        $filename = 'webui.py'
    }
    # Parse the actual Windows argv, never a -File/path embedded in -Command/-c text.
    try {
        $tokensForProcess = @(Get-ManagedArguments $Process.CommandLine)
        $index = 1; $path = $null
        while ($index -lt $tokensForProcess.Count) {
            $flag = $tokensForProcess[$index].ToLowerInvariant()
            if ($Kind -eq 'stop') {
                if ($flag -eq '-file' -and $index+1 -lt $tokensForProcess.Count) { $path=$tokensForProcess[$index+1]; break }
                if ($flag -in @('-noprofile','-nologo','-noninteractive','-noexit','-sta','-mta')) { $index++; continue }
                if ($flag -in @('-executionpolicy','-windowstyle','-inputformat','-outputformat') -and $index+1 -lt $tokensForProcess.Count) { $index+=2; continue }
            } else {
                if (-not $flag.StartsWith('-')) { $path=$tokensForProcess[$index]; break }
                if ($flag -in @('-b','-e','-i','-o','-oo','-p','-s','-u','-v')) { $index++; continue }
                if ($flag -in @('-x','-w','--check-hash-based-pycs') -and $index+1 -lt $tokensForProcess.Count) { $index+=2; continue }
            }
            return $false
        }
        if (-not $path -or -not [IO.Path]::IsPathRooted($path)) { return $false }
        return [IO.Path]::GetFullPath($path) -eq (Join-Path $RootDir $filename)
    } catch { return $false }
}

function Get-ManagedProcess {
    param([int]$TargetId)
    if ($TargetId -le 0) { return $null }
    return Get-CimInstance Win32_Process -Filter "ProcessId=$TargetId" -ErrorAction Stop
}

function Initialize-ManagedNative {
    if ('LiruManagedNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LiruManagedNative {
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern IntPtr CommandLineToArgvW(string command, out int count);
    [DllImport("kernel32.dll")]
    public static extern IntPtr LocalFree(IntPtr value);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint WaitForSingleObject(IntPtr handle, uint ms);
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern bool TerminateProcess(IntPtr handle, uint code);
    [DllImport("kernel32.dll")]
    public static extern bool CloseHandle(IntPtr handle);
}
'@
}

function Get-ManagedArguments {
    param([string]$CommandLine)
    Initialize-ManagedNative
    $count=0
    $pointer=[LiruManagedNative]::CommandLineToArgvW($CommandLine,[ref]$count)
    if ($pointer -eq [IntPtr]::Zero) { throw '无法解析进程参数' }
    try {
        for ($index=0; $index -lt $count; $index++) {
            [Runtime.InteropServices.Marshal]::PtrToStringUni([Runtime.InteropServices.Marshal]::ReadIntPtr($pointer,$index*[IntPtr]::Size))
        }
    } finally { $null=[LiruManagedNative]::LocalFree($pointer) }
}

function Open-ManagedHandle {
    param($Process, [string]$Kind, [string]$RootDir)
    if (-not (Test-ManagedProcess $Process $Kind $RootDir)) { throw '身份无法核验，已保留运行记录' }
    Initialize-ManagedNative
    $handle = [LiruManagedNative]::OpenProcess(0x101001, $false, [uint32]$Process.ProcessId)
    if ($handle -eq [IntPtr]::Zero) { throw '无法持有目标进程句柄，已保留运行记录' }
    try {
        $current = Get-ManagedProcess -TargetId $Process.ProcessId
        if (-not (Test-ManagedProcess $current $Kind $RootDir) -or
            $current.CreationDate -ne $Process.CreationDate) {
            throw '身份无法核验，已保留运行记录'
        }
        return [pscustomobject]@{ Handle=$handle; ProcessId=$Process.ProcessId }
    } catch {
        $null = [LiruManagedNative]::CloseHandle($handle)
        throw
    }
}

function Test-ManagedHandleRunning {
    param($Pinned)
    $state = [LiruManagedNative]::WaitForSingleObject($Pinned.Handle, 0)
    if ($state -eq 0) { return $false }
    if ($state -eq 258) { return $true }
    throw '无法确认目标进程是否结束，已保留运行记录'
}

function Stop-ManagedHandle {
    param($Pinned)
    if (-not (Test-ManagedHandleRunning $Pinned)) { return }
    if (-not [LiruManagedNative]::TerminateProcess($Pinned.Handle, 1)) { throw '目标进程未能结束，已保留运行记录' }
    if ([LiruManagedNative]::WaitForSingleObject($Pinned.Handle, 5000) -ne 0) { throw '目标进程尚未退出，已保留运行记录' }
}

function Close-ManagedHandle {
    param($Pinned)
    $null = [LiruManagedNative]::CloseHandle($Pinned.Handle)
}

function Get-ManagedCandidates {
    param([string]$Kind, [string]$RootDir)
    if ($Kind -eq 'stop') {
        return @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop |
            Where-Object { (Test-ManagedProcess $_ 'stop' $RootDir) -and
                $_.CommandLine -notmatch '(?i)(?:^|\s)-AttachEdge(?::\$true)?(?=\s|$)' })
    }
    $listeners = @(Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 8765 -State Listen -ErrorAction SilentlyContinue)
    foreach ($listener in $listeners) {
        $candidate = Get-ManagedProcess -TargetId $listener.OwningProcess
        if (Test-ManagedProcess $candidate 'close' $RootDir) { $candidate }
    }
}

function Read-ManagedRecord {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop).Trim() }
    return $null
}

function Invoke-ManageProcess {
    param([string]$Kind, [string]$RootDir, [int]$WaitSeconds = 15)
    # Both close paths stop playback first. Failure leaves the console and records intact.
    if ($Kind -eq 'close') { Invoke-ManageProcess -Kind stop -RootDir $RootDir -WaitSeconds $WaitSeconds }
    $pidPath = Join-Path $RootDir $(if ($Kind -eq 'stop') { 'run.pid' } else { 'webui.pid' })
    $stopPath = Join-Path $RootDir 'stop.flag'
    $record = Read-ManagedRecord $pidPath
    $targetId = 0
    if ($null -ne $record -and (-not [int]::TryParse($record, [ref]$targetId) -or $targetId -le 0)) {
        throw '运行记录格式无法核验，已保留运行记录'
    }
    $process = Get-ManagedProcess -TargetId $targetId
    if ($process -and -not (Test-ManagedProcess $process $Kind $RootDir)) {
        throw '身份无法核验，已保留运行记录'
    }
    if ($Kind -eq 'stop' -and $process -and $process.CommandLine -match '(?i)(?:^|\s)-AttachEdge(?::\$true)?(?=\s|$)') {
        throw '接管进程仍在等待授权，已保留运行记录；请先完成或取消接管'
    }
    $candidates = @{}
    if ($process) { $candidates[[int]$process.ProcessId] = $process }
    foreach ($candidate in @(Get-ManagedCandidates $Kind $RootDir)) { $candidates[[int]$candidate.ProcessId] = $candidate }
    $pinned = New-Object 'System.Collections.Generic.List[object]'
    try {
        foreach ($candidate in $candidates.Values) { $pinned.Add((Open-ManagedHandle $candidate $Kind $RootDir)) }
        if ($Kind -eq 'stop' -and $pinned.Count -gt 0) {
            Set-Content -LiteralPath $stopPath -Value 'stop' -Encoding ASCII
            Write-Host '已发送停止信号，等待脚本收尾（最多 15 秒）...'
            $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
            while ([DateTime]::UtcNow -lt $deadline) {
                if (@($pinned | Where-Object { Test-ManagedHandleRunning $_ }).Count -eq 0) { break }
                Start-Sleep -Milliseconds 250
            }
        }
        foreach ($target in $pinned) { Stop-ManagedHandle $target }
        if ($Kind -eq 'stop' -and @(Get-ManagedCandidates $Kind $RootDir).Count -gt 0) {
            throw '仍有引擎进程或新实例，已保留运行记录，请重试'
        }
        $remainingRecord = Read-ManagedRecord $pidPath
        # A normal engine removes its own record before exiting; only a new value
        # belongs to a replacement instance and must be preserved.
        if ($null -ne $remainingRecord -and $remainingRecord -ne $record) { throw '原进程已结束，但运行记录已变化；保留新记录，请重试' }
        if (Test-Path -LiteralPath $pidPath) { Remove-Item -LiteralPath $pidPath -Force }
        if ($Kind -eq 'stop' -and (Test-Path -LiteralPath $stopPath)) { Remove-Item -LiteralPath $stopPath -Force }
        Write-Host '操作完成，已确认目标进程结束；未结束任何身份不符的进程。'
    } finally {
        foreach ($target in $pinned) { Close-ManagedHandle $target }
    }
}

try { Invoke-ManageProcess -Kind $Action -RootDir $PSScriptRoot }
catch { Write-Host ('操作失败，保留记录供重试：' + $_.Exception.Message); exit 1 }
