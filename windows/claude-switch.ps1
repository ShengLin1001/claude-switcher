# Claude 账号切换器 - Windows 核心脚本
# 用法: powershell -NoProfile -File claude-switch.ps1 check|status|switch A|B|checkdetail|fix|pinrules
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

# ============ 安装时可配置项(安装器自动改写) ============
$TZ_TARGET = "Eastern Standard Time"   # Windows 时区ID
$PROXY_GROUP = "GLOBAL"                # Clash 代理组名
# =======================================================

$BASE = Join-Path $env:USERPROFILE ".claude-switcher"
$DATA = Join-Path $env:APPDATA "Claude"
$LOG  = Join-Path $BASE "claude-switch.log"
$CLASH_DIR = Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev"
# 绝对路径:被精简 PATH 的环境拉起时 curl.exe 会找不到
$CURL = Join-Path $env:SystemRoot "System32\curl.exe"
New-Item -ItemType Directory -Force -Path "$BASE\accounts" | Out-Null

function Log($m) { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m" | Out-File -Append -Encoding utf8 $LOG }

function Test-CoreUp { [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue) }
function Test-TunUp  { [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '198.18.*' }) }

function Get-Egress {
    $trace = & $CURL -s --max-time 8 "https://www.cloudflare.com/cdn-cgi/trace" 2>$null | Out-String
    $ip  = if ($trace -match '(?m)^ip=(\S+)')  { $Matches[1] } else { '' }
    $loc = if ($trace -match '(?m)^loc=(\S+)') { $Matches[1] } else { '' }
    return @{ ip = $ip; loc = $loc }
}

# STUN 探针(纯 .NET UDP,手工构造 RFC5389 报文)
function Get-StunPublicIP([string]$server, [int]$port, [int]$timeoutMs = 2000) {
    try { $addr = ([System.Net.Dns]::GetHostAddresses($server) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1) } catch { return $null }
    if (-not $addr) { return $null }
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Client.ReceiveTimeout = $timeoutMs
    try {
        $txn = New-Object byte[] 12; (New-Object Random).NextBytes($txn)
        $req = [byte[]](0x00, 0x01, 0x00, 0x00) + [byte[]](0x21, 0x12, 0xA4, 0x42) + $txn
        $udp.Connect($addr, $port)
        [void]$udp.Send($req, $req.Length)
        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$remote)
        $pos = 20
        while ($pos + 4 -le $resp.Length) {
            $atype = ([int]$resp[$pos] -shl 8) -bor $resp[$pos + 1]
            $alen  = ([int]$resp[$pos + 2] -shl 8) -bor $resp[$pos + 3]
            if (($atype -eq 0x20 -or $atype -eq 0x01) -and $alen -ge 8 -and $resp[$pos + 5] -eq 0x01) {
                $ipBytes = @($resp[$pos + 8], $resp[$pos + 9], $resp[$pos + 10], $resp[$pos + 11])
                if ($atype -eq 0x20) {
                    $cookie = [byte[]](0x21, 0x12, 0xA4, 0x42)
                    for ($i = 0; $i -lt 4; $i++) { $ipBytes[$i] = $ipBytes[$i] -bxor $cookie[$i] }
                }
                return ($ipBytes -join '.')
            }
            $pos += 4 + $alen + ((4 - ($alen % 4)) % 4)
        }
    } catch { return $null } finally { $udp.Close() }
    return $null
}

function Test-WebRTC($exitIp) {
    $servers = @(@("stun.miwifi.com", 3478), @("stun.chat.bilibili.com", 3478), @("stun.l.google.com", 19302), @("stun.cloudflare.com", 3478))
    $found = @()
    foreach ($s in $servers) {
        $r = Get-StunPublicIP $s[0] $s[1]
        if ($r -and ($found -notcontains $r)) { $found += $r }
    }
    if ($found.Count -eq 0) { return @{ code = 'ok'; detail = 'UDP不出网,零暴露' } }
    $leak = $found | Where-Object { $_ -ne $exitIp }
    if ($leak) { return @{ code = 'fail'; detail = "暴露非代理IP: $($leak -join ',')" } }
    return @{ code = 'ok'; detail = '仅暴露代理IP' }
}

# 只认 rules: 段内的条目:Clash Verge Rev 新版把 Merge 里的 prepend-rules 原样留在顶层且不生效,全文搜索会误报
function Test-RulesPinned {
    $f = "$CLASH_DIR\clash-verge.yaml"
    if (-not (Test-Path $f)) { return $false }
    $inRules = $false
    foreach ($line in Get-Content $f -Encoding utf8) {
        if ($line -match '^rules:') { $inRules = $true; continue }
        if ($line -match '^[^ -]') { $inRules = $false }
        if ($inRules -and $line.Contains("DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP")) { return $true }
    }
    return $false
}

# 用全局扩展脚本 Script.js 把置顶规则插到 rules 最前;用户自写的脚本不覆盖,此时返回提示行,成功返回空
function Set-PinScript {
    $f = "$CLASH_DIR\profiles\Script.js"
    if (Test-Path $f) {
        $s = Get-Content $f -Raw -Encoding utf8
        $bare = ($s -replace '//.*', '') -replace '\s', ''
        if ($s -notmatch 'claude-switcher' -and $bare -notmatch '^functionmain\(config(,profileName)?\)\{returnconfig;?\}$') {
            return "FIX:Script.js 已有自定义内容,未覆盖;请把 Claude 置顶规则手动加进该脚本 ✗"
        }
    }
    New-Item -ItemType Directory -Force -Path "$CLASH_DIR\profiles" | Out-Null
    $js = @"
// claude-switcher: Claude 域名置顶规则,由切换器生成,重装/一键修复会覆盖本文件
// Clash Verge Rev 新版不再处理 Merge.yaml 里的 prepend-rules,改由全局扩展脚本插到 rules 最前
function main(config, profileName) {
  var pinned = ['claude.ai', 'claude.com', 'anthropic.com', 'claudeusercontent.com', 'challenges.cloudflare.com',
    'datadoghq.com', 'segment.io', 'stripe.com', 'stripe.network', 'stripecdn.com',
    'intercom.io', 'intercomcdn.com', 'intercomassets.com'];
  var head = [];
  for (var i = 0; i < pinned.length; i++) head.push('DOMAIN-SUFFIX,' + pinned[i] + ',$PROXY_GROUP');
  config.rules = head.concat(config.rules || []);
  return config;
}
"@
    [IO.File]::WriteAllText($f, $js)
}

# TUN 网卡每次重建都默认带 IPv6 绑定,但它走代理、Clash ipv6:false 时也无 v6 地址,不算直连泄漏;只看其余网卡
function Get-V6Binding {
    $tunNics = @((Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '198.18.*' }).InterfaceAlias)
    Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $_.Name -notin $tunNics }
}

function Invoke-CheckDetail {
    if (Test-CoreUp) { "代理内核=ok" } else { "代理内核=fail:未运行" }
    if (Test-TunUp) { "TUN网卡=ok" } else { "TUN网卡=fail:不在线" }

    $e = Get-Egress
    if ($e.loc -eq 'US') { "出口IP=ok:$($e.ip)" } else { "出口IP=fail:$($e.ip)/$($e.loc)" }

    $lastipFile = "$BASE\lastip.txt"
    $lastip = if (Test-Path $lastipFile) { (Get-Content $lastipFile -Raw).Trim() } else { '' }
    if (-not $e.ip) { "IP一致=fail:未获取到出口IP" }
    elseif (-not $lastip) { "IP一致=ok:首次记录" }
    elseif ($e.ip -eq $lastip) { "IP一致=ok" }
    else { "IP一致=warn:$lastip → $($e.ip)" }
    if ($e.ip) { $e.ip | Out-File -Encoding ascii -NoNewline $lastipFile }

    $tz = (Get-TimeZone).Id
    if ($tz -eq $TZ_TARGET) { "时区=ok" } else { "时区=fail:$tz" }

    $cult = (Get-Culture).Name
    if ($cult -eq 'en-US') { "地区=ok" } else { "地区=fail:$cult" }

    $v6on = @(Get-V6Binding)
    if ($v6on.Count -eq 0) { "IPv6=ok:已关闭" } else { "IPv6=fail:未关闭($($v6on.Name -join ','))" }

    $dns = (Resolve-DnsName claude.ai -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
    if ($dns -like '198.18.*') { "DNS=ok:走隧道" } else { "DNS=fail:未走隧道($dns)" }

    $w = Test-WebRTC $e.ip
    "WebRTC=$($w.code):$($w.detail)"

    $bg = Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue
    if ($bg) { "保镖=ok" } else { "保镖=fail:未安装" }

    if (Test-RulesPinned) { "规则置顶=ok" } else { "规则置顶=fail:未生效" }

    # 客户端语言: Windows 端 Claude 跟随系统区域格式,地区检查已覆盖
    "客户端语言=ok:跟随系统"

    $org = ''
    try { $org = ((& $CURL -s --max-time 6 "https://ipinfo.io/json" 2>$null) | ConvertFrom-Json).org } catch {}
    if (-not $org) { "ASN属性=warn:未获取" }
    elseif ($org -match 'Comcast|AT&T|Verizon|Spectrum|Charter|Cox|T-Mobile|Cable|esidential') { "ASN属性=ok:$org" }
    else { "ASN属性=warn:疑似机房($org)" }

    $r1 = & $CURL -s --max-time 8 -o NUL -w '%{http_code}' "https://claude.ai/" 2>$null
    $r2 = & $CURL -s --max-time 8 -o NUL -w '%{http_code}' "https://api.anthropic.com/v1/models" 2>$null
    # 白名单判定:curl 没跑起来时结果为空,用 -ne '000' 会误判为 ok
    if ($r1 -match '^[1-5]\d\d$' -and $r2 -match '^[1-5]\d\d$') { "生态可达性=ok:claude.ai:$r1 api:$r2" } else { "生态可达性=fail:claude.ai:$r1 api:$r2" }
}

function Invoke-Fix {
    "FIX:开始一键修复"

    # A. 拉起 Clash Verge 并等待内核+TUN
    if (-not (Test-CoreUp)) {
        "FIX:正在启动 Clash Verge..."
        $cv = Get-ClashExe
        if ($cv) { Start-Process $cv } else { "FIX:未找到 Clash Verge 可执行文件,请手动启动" }
    }
    $ok = $false
    for ($i = 0; $i -lt 40; $i++) { if ((Test-CoreUp) -and (Test-TunUp)) { $ok = $true; break }; Start-Sleep 1 }
    if ($ok) { "FIX:代理内核+TUN ✓" } else { "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路及 TUN 开关)" }

    # B. 时区/IPv6/DNS/保镖(需管理员:通过 UAC 弹一次)
    $adminScript = @()
    if ((Get-TimeZone).Id -ne $TZ_TARGET) { $adminScript += "Set-TimeZone -Id '$TZ_TARGET'" }
    if (Get-V6Binding) { $adminScript += "Get-NetAdapterBinding -ComponentID ms_tcpip6 | Disable-NetAdapterBinding -Confirm:`$false" }
    $adminScript += "Clear-DnsClientCache"
    if (-not (Get-ScheduledTask -TaskName 'ClaudeBodyguard' -ErrorAction SilentlyContinue)) {
        $adminScript += "`$a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$BASE\claude-bodyguard.ps1`"'; `$t = New-ScheduledTaskTrigger -AtLogOn; Register-ScheduledTask -TaskName 'ClaudeBodyguard' -Action `$a -Trigger `$t -Force | Out-Null; Start-ScheduledTask -TaskName 'ClaudeBodyguard'"
    }
    if ($adminScript.Count -gt 0) {
        "FIX:修复时区/IPv6/DNS/保镖(需要管理员授权)..."
        $tmp = "$env:TEMP\claude-fix-$([guid]::NewGuid().Guid).ps1"
        ($adminScript -join "`n") | Out-File -Encoding utf8 $tmp
        try { Start-Process powershell -Verb RunAs -Wait -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`"" } catch { "FIX:管理员授权被取消" }
        Remove-Item $tmp -ErrorAction SilentlyContinue
        "FIX:时区/IPv6/DNS/保镖 ✓"
    } else {
        "FIX:时区/IPv6/保镖 无需修复 ✓"
    }

    # B2. 置顶规则
    if (-not (Test-RulesPinned)) {
        "FIX:重写置顶规则..."
        $warn = Set-PinScript
        if ($warn) { $warn } else {
            $cv = Get-ClashExe   # 必须在杀进程前取,杀完就拿不到运行路径了
            Get-Process -Name 'clash-verge','Clash Verge' -ErrorAction SilentlyContinue | Stop-Process -Force
            Start-Sleep 2
            if ($cv) { Start-Process $cv } else { "FIX:未找到 Clash Verge 可执行文件,请手动启动" }
            for ($i = 0; $i -lt 40; $i++) { if (Test-TunUp) { break }; Start-Sleep 1 }
            if (Test-RulesPinned) { "FIX:置顶规则 ✓" } else { "FIX:置顶规则 ✗(请重启 Clash Verge)" }
        }
    }

    # C. 出口IP最终验证
    Start-Sleep 2
    $e = Get-Egress
    if ($e.loc -eq 'US') { "FIX:出口IP ✓ ($($e.ip))" } else { "FIX:出口IP ✗ ($($e.ip)/$($e.loc)) — 请换节点/线路" }
    "FIX:修复流程结束"
}

function Invoke-Status {
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }
    $hasA = if (Test-Path "$BASE\accounts\A") { 1 } else { 0 }
    $hasB = if (Test-Path "$BASE\accounts\B") { 1 } else { 0 }
    "current=$cur hasA=$hasA hasB=$hasB"
}

# -Name 不分大小写,会连带匹配 Claude Code CLI(claude.exe);切换的是桌面版数据,不碰 CLI
function Get-ClaudeApp { Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.Path -ne "$env:USERPROFILE\.local\bin\claude.exe" } }

function Stop-ClaudeApp {
    $p = Get-ClaudeApp
    if (-not $p) { return $true }
    $p | Stop-Process -Force
    for ($i = 0; $i -lt 15; $i++) { if (-not (Get-ClaudeApp)) { return $true }; Start-Sleep 1 }
    return $false
}

# 运行中取进程路径,否则查卸载注册表;旧逻辑只搜 %LOCALAPPDATA%\Programs,装在别的盘就找不到
function Get-ClashExe {
    $p = (Get-Process -Name 'clash-verge' -ErrorAction SilentlyContinue | Select-Object -First 1).Path
    if (-not $p) {
        $p = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
              Where-Object { $_.DisplayName -like 'Clash Verge*' } | Select-Object -First 1).DisplayIcon -replace '"', ''
    }
    if ($p -and (Test-Path $p)) { return $p }
    return $null
}

function Save-Account($name) {
    robocopy "$DATA" "$BASE\accounts\$name" /MIR /NFL /NDL /NJH /NJS | Out-Null
    Log "已存档账号$name"
}

function Start-ClaudeApp {
    $exe = @("$env:LOCALAPPDATA\AnthropicClaude\Claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($exe) { Start-Process $exe } else { Start-Process "shell:AppsFolder" -ErrorAction SilentlyContinue }
}

function Invoke-Switch($target) {
    $cur = if (Test-Path "$BASE\current.txt") { (Get-Content "$BASE\current.txt" -Raw).Trim() } else { 'none' }

    # 首次运行:收编当前登录为账号A
    if ($cur -eq 'none' -and (Test-Path $DATA) -and (Get-ChildItem $DATA -ErrorAction SilentlyContinue)) {
        if (-not (Stop-ClaudeApp)) { "FAIL:Claude 未能退出，请手动退出后重试"; return }
        Save-Account A
        $cur = 'A'; 'A' | Out-File -Encoding ascii -NoNewline "$BASE\current.txt"
        Log "首次运行:当前登录状态已收编为账号A"
        "NOTE:已将当前登录收编为账号A"
    }

    if ($cur -eq $target) { Start-ClaudeApp; "INFO:当前已是账号$target"; return }

    if (-not (Stop-ClaudeApp)) { "FAIL:Claude 未能退出，请手动退出后重试"; return }

    if ($cur -ne 'none' -and (Test-Path $DATA)) { Save-Account $cur }

    if (Test-Path "$BASE\accounts\$target") {
        Remove-Item $DATA -Recurse -Force -ErrorAction SilentlyContinue
        robocopy "$BASE\accounts\$target" "$DATA" /E /NFL /NDL /NJH /NJS | Out-Null
        Log "已载入账号$target 存档"
    } else {
        Remove-Item $DATA -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $DATA | Out-Null
        Log "账号$target 无存档，将以全新状态初始化"
    }
    $target | Out-File -Encoding ascii -NoNewline "$BASE\current.txt"
    Start-ClaudeApp
    Log "已切换到账号$target 并启动"
    "OK:已切换到账号$target"
}

switch ($args[0]) {
    'checkdetail' {
        $r = Invoke-CheckDetail
        $r | Out-File -Encoding utf8 "$BASE\last-check.txt"
        $r
    }
    'status' { Invoke-Status }
    'fix'    { Invoke-Fix }
    'switch' { Invoke-Switch $args[1] }
    'pinrules' { Set-PinScript }
    default  { "用法: claude-switch.ps1 checkdetail|status|fix|switch A|B|pinrules" }
}
