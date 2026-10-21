# Claude 切换器 Windows 版 - 安装器
# 右键 -> 使用 PowerShell 以管理员身份运行(或在管理员 PowerShell 里执行)
$ErrorActionPreference = 'Stop'
$BASE = "$env:USERPROFILE\.claude-switcher"
$CLASH_DIR = "$env:APPDATA\io.github.clash-verge-rev.clash-verge-rev"

Write-Host "==================================" -ForegroundColor Cyan
Write-Host "  Claude 账号切换器 · Windows 安装" -ForegroundColor Cyan
Write-Host "==================================" -ForegroundColor Cyan
Write-Host ""

# ---- 0. 前置检查 ----
if (-not (Test-Path $CLASH_DIR)) { Write-Host "X 未检测到 Clash Verge,请先安装并配置好代理" -ForegroundColor Red; pause; exit 1 }
Write-Host "[OK] 前置检查通过" -ForegroundColor Green

# ---- 1. 出口必须是美国(否则时区会锁错) ----
$info = try { (& "$env:SystemRoot\System32\curl.exe" -s --max-time 8 "https://ipinfo.io/json" 2>$null | ConvertFrom-Json) } catch { $null }
if (-not $info -or $info.country -ne 'US') {
    Write-Host "X 当前出口不在美国($($info.country)),请先开启代理(TUN模式)再运行" -ForegroundColor Red
    pause; exit 1
}
Write-Host "[OK] 出口: $($info.ip) ($($info.country))" -ForegroundColor Green

# ---- 2. 自动识别代理组名 ----
$grp = $null
$inGroups = $false; $name = $null
foreach ($line in Get-Content "$CLASH_DIR\clash-verge.yaml" -ErrorAction SilentlyContinue) {
    if ($line -match '^proxy-groups:') { $inGroups = $true; continue }
    if ($inGroups -and $line -match '^[a-zA-Z]') { $inGroups = $false }
    if ($inGroups -and $line -match '- name:\s*(.+)') { $name = $Matches[1].Trim('"',"'",' ') }
    if ($inGroups -and $line -match 'type:\s*select') { $grp = $name; break }
}
if (-not $grp) { $grp = Read-Host "未能自动识别代理组名,请打开 Clash Verge 查看后输入" }
Write-Host "[OK] 代理组: $grp" -ForegroundColor Green

# ---- 3. IANA 时区 -> Windows 时区ID ----
$tzMap = @{
    'America/New_York'    = 'Eastern Standard Time'
    'America/Chicago'     = 'Central Standard Time'
    'America/Denver'      = 'Mountain Standard Time'
    'America/Los_Angeles' = 'Pacific Standard Time'
    'Asia/Singapore'      = 'Singapore Standard Time'
    'Asia/Tokyo'          = 'Tokyo Standard Time'
    'Europe/London'       = 'GMT Standard Time'
}
$tzId = $tzMap[$info.timezone]
if (-not $tzId) { $tzId = 'Eastern Standard Time' }
Write-Host "[OK] 锁定时区: $tzId (按出口IP识别)" -ForegroundColor Green

# ---- 4. 安装文件 ----
New-Item -ItemType Directory -Force -Path $BASE | Out-Null
Copy-Item "$PSScriptRoot\claude-switch.ps1"   "$BASE\claude-switch.ps1" -Force
Copy-Item "$PSScriptRoot\SwitcherUI.ps1"      "$BASE\SwitcherUI.ps1" -Force
Copy-Item "$PSScriptRoot\claude-bodyguard.ps1" "$BASE\claude-bodyguard.ps1" -Force

# 写入探测到的代理组名和时区
(Get-Content "$BASE\claude-switch.ps1" -Raw) -replace '\$TZ_TARGET = "[^"]*"', "`$TZ_TARGET = `"$tzId`"" -replace '\$PROXY_GROUP = "[^"]*"', "`$PROXY_GROUP = `"$grp`"" | Set-Content -Encoding utf8 "$BASE\claude-switch.ps1"
Write-Host "[OK] 核心文件已安装到 $BASE" -ForegroundColor Green

# ---- 5. 桌面快捷方式 ----
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut("$env:USERPROFILE\Desktop\Claude切换器.lnk")
$sc.TargetPath = "powershell.exe"
$sc.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\SwitcherUI.ps1`""
$sc.WorkingDirectory = $BASE
$sc.Save()
Write-Host "[OK] 桌面快捷方式已创建" -ForegroundColor Green

# ---- 6. 置顶规则(由核心脚本写全局扩展脚本 Script.js,域名名单只维护一份) ----
$warn = & "$BASE\claude-switch.ps1" pinrules
if ($warn) { Write-Host "! $warn" -ForegroundColor Yellow }
else { Write-Host "[OK] Claude 域名置顶规则已写入(重启 Clash Verge 后生效)" -ForegroundColor Green }

# ---- 7. 系统级配置 ----
Set-TimeZone -Id $tzId
Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled } | Disable-NetAdapterBinding -Confirm:$false
Clear-DnsClientCache
Write-Host "[OK] 时区已锁定 / IPv6 已关闭 / DNS 缓存已刷新" -ForegroundColor Green

# ---- 8. 注册保镖计划任务 ----
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\claude-bodyguard.ps1`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
Register-ScheduledTask -TaskName 'ClaudeBodyguard' -Action $action -Trigger $trigger -Force | Out-Null
Start-ScheduledTask -TaskName 'ClaudeBodyguard'
Write-Host "[OK] 保镖已注册并启动(计划任务,登录自动运行)" -ForegroundColor Green

# ---- 9. 重启 Clash 使规则生效 ----
# 杀进程前先取运行路径;旧逻辑只搜 %LOCALAPPDATA%\Programs,装在别的盘就拉不起来
$cv = (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1).Path
Get-Process -Name 'clash-verge','Clash Verge' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep 2
if ($cv) { Start-Process $cv } else { Write-Host "! 未找到 Clash Verge 进程路径,请手动重新打开 Clash Verge" -ForegroundColor Yellow }

Write-Host ""
Write-Host "==================================" -ForegroundColor Green
Write-Host "  安装完成! 双击桌面「Claude切换器」使用" -ForegroundColor Green
Write-Host "  首次使用: 打开后选账号A(自动收编当前登录)" -ForegroundColor Green
Write-Host "==================================" -ForegroundColor Green
pause
