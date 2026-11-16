param([ValidateSet('close','cleanup')][string]$Action = 'close')
$ErrorActionPreference = 'Stop'
if ($Action -eq 'cleanup') { Write-Host '接管模式不清理浏览器进程或资料。'; exit 0 }
$python = Join-Path $PSScriptRoot 'runtime\python\python.exe'
if (-not (Test-Path -LiteralPath $python)) { $python = 'python' }
& $python -X utf8 (Join-Path $PSScriptRoot 'edge_attach.py') --disconnect
exit $LASTEXITCODE
