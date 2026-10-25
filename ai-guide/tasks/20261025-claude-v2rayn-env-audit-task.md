# 任务：在 v2rayN 机器上做 Claude 环境十四项安检

- 日期：2026-10-25
- 交给：另一台电脑上的 agent（下称"你"）
- 依据：claude-switcher 的 Windows 版（`windows/claude-switch.ps1`），它只认 Clash Verge。这份文档说明哪些检查要改成 v2rayN 的写法
- 适用：Windows 10/11 + v2rayN 7.x。如果这台机器不是 Windows，先停下来问用户

## 1. 目标与边界

要交的东西：

1. 一份适配 v2rayN 的检测脚本，装在 `%USERPROFILE%\.claude-switcher\claude-switch.ps1`
2. `checkdetail` 的十四项结果，每项不是 `ok` 的都要写清原因
3. 一份报告（格式见第 10 节）

不做的事：

- 不改仓库代码，不 commit，不 push。v2rayN 支持要不要合进仓库，由用户另外决定
- 不切换账号，不调用 `switch`
- 检测阶段只读。要改系统或 v2rayN 设置的修复项，先列清单，用户确认后再改

## 2. 安全红线

1. 出口不是美国（`loc=US`）时，不启动 Claude，也不锁时区
2. 报告、日志、聊天里不写出口 IP、节点地址、订阅链接和任何凭据。确实要提到 IP 时打码，例如 `x.x.x.12`
3. 不直接改 v2rayN 的 `guiNDB.db`、`guiNConfig.json`：v2rayN 运行时会覆盖它们，也可能把库写坏。v2rayN 的设置只在它的界面里改（让用户改，或用桌面自动化）
4. 改任何文件之前先备份，报告里写明备份位置

## 3. 准备

仓库是公开的，直接克隆：

```powershell
git clone https://github.com/ShengLin1001/claude-switcher.git
```

克隆超时多半是 TUN 没开，可以临时走 v2rayN 的本地端口：`git -c http.proxy=http://127.0.0.1:10808 clone ...`。

仓库里的 Windows 脚本已经带上在 Clash Verge 机器上做过的修复（截至 commit `fcfaf8e`）：置顶检查只认 `rules:` 段、IPv6 排除 TUN 网卡、curl 用绝对路径、可达性按白名单判断、不误杀 CLI、`stun-probe.py` 兼容 Windows。就在这个版本上改，不要另找别的版本。本文档也在仓库里：`ai-guide/tasks/20261025-claude-v2rayn-env-audit-task.md`。

先读 `AGENTS.md` 的"Windows 版"一节和 `windows/claude-switch.ps1`。

然后摸清这台机器的情况，把结果填进报告的"环境"表：

| 要查的 | 怎么查 | v2rayN 默认值（以实测为准） |
|---|---|---|
| v2rayN 目录 | `(Get-Process v2rayN).Path` 所在目录 | 便携版，配置跟 exe 放在一起；设了 v2rayN 的 LocalAppData 环境变量时在 `%LOCALAPPDATA%\v2rayN` |
| v2rayN 版本、当前内核 | 界面"关于"；内核进程用下面的命令查 | — |
| 生效的内核配置 | 下面命令输出的命令行里 `-c` 后面的文件；取不到（内核进程是管理员身份）就看 `<v2rayN目录>\binConfigs\` 下最近修改的文件 | `config.json`；开 TUN 且内核是 xray 时，还有一份给 sing-box 的 `configPre.json`。**路由规则在 xray 读的那份里** |
| TUN 是否开、网卡名 | 界面主窗口的 TUN 开关；`Get-NetAdapter`、`Get-NetIPAddress` | 网卡名 `singbox_tun`，地址 `172.18.0.1/30`（**不是** Clash 的 198.18.\*） |
| TUN 严格路由 | 设置 → TUN 设置 | 关 |
| FakeIP | 设置 → DNS 设置 | 关；开了以后默认范围 `198.18.0.0/15` |
| 本地监听端口 | 设置 → 参数设置 | 10808。HTTP 能不能走这个端口，用 `curl.exe -x http://127.0.0.1:10808 https://www.cloudflare.com/cdn-cgi/trace` 试 |
| 允许局域网连接 | 设置 → 参数设置 | — |
| 当前路由规则集 | 设置 → 路由设置 | — |
| Claude 用法 | 桌面版：`%LOCALAPPDATA%\AnthropicClaude`；CLI：`%USERPROFILE%\.local\bin\claude.exe`；也可能只用网页 | 判断不了就问用户 |
| 出口与时区 | `curl.exe -s https://www.cloudflare.com/cdn-cgi/trace` 看 `loc=`；`curl.exe -s https://ipinfo.io/json` 看 `timezone` | 必须是 US |

查内核进程和命令行：

```powershell
Get-CimInstance Win32_Process | Where-Object Name -match '^(xray|sing-box|mihomo)\.exe$' | Select-Object Name, CommandLine
```

## 4. 安装检测脚本

`install.ps1` 不能用：它找不到 Clash Verge 目录就直接退出。手动装：

1. 建 `%USERPROFILE%\.claude-switcher\`，把 `windows/claude-switch.ps1`、`windows/claude-bodyguard.ps1`、`windows/SwitcherUI.ps1` 复制进去
2. 把 `$TZ_TARGET` 改成出口时区对应的 Windows 时区 ID，对照表在 `windows/install.ps1` 的 `$tzMap`（例如 `America/Los_Angeles` → `Pacific Standard Time`）
3. 按第 5 节改函数
4. 保持 **UTF-8 with BOM**。改完用 `Format-Hex` 看前 3 个字节是不是 `EF BB BF`；没有的话 Windows PowerShell 5.1 会把中文读成乱码

## 5. 要改的地方

不在表里的检查（出口 IP、IP 一致、时区、地区、WebRTC、客户端语言、ASN、生态可达性）跟代理软件无关，照原样用。

| # | 检查 | 原来（Clash Verge） | 改成（v2rayN） |
|---|---|---|---|
| 1 | 代理内核 | 有 `verge-mihomo` 进程 | 有 `xray`、`sing-box`、`mihomo` 中任一进程 |
| 2 | TUN 网卡 | 有 198.18.\* 地址 | TUN 网卡存在且状态为 Up |
| 7 | IPv6 | 排除 198.18.\* 那块网卡 | 排除 TUN 网卡 |
| 8 | DNS | `claude.ai` 解析到 198.18.\* | FakeIP 开：解析结果在 FakeIP 范围内。FakeIP 关：拿到的是真实 IP，脚本判不了，输出 `warn`，在报告里按第 6 节说明 |
| 10 | 保镖 | 计划任务；判定用 verge-mihomo 和 198.18.\* | 计划任务名不变；`claude-bodyguard.ps1` 里的两行判定换成 #1、#2 的写法。只有用桌面版才需要装 |
| 11 | 规则置顶 | 读 `clash-verge.yaml` 的 `rules:` 段 | 读生效内核配置：第一条按域名匹配的规则必须含 `claude.ai`，出站是 `proxy` |
| fix | 一键修复 | 拉起 Clash Verge；写 `Script.js` 再重启 Clash | 内核没起来就拉起 v2rayN（TUN 要管理员身份才能开，开不了就提示用户）；置顶规则不自动写，提示用户按第 6 节在界面里加。时区、IPv6、DNS 缓存、保镖这段不用改 |
| — | `pinrules`、`$PROXY_GROUP` | Clash 专用 | 不调用；`$PROXY_GROUP` 用不到 |

参考写法。没有在 v2rayN 真机上跑过，按第 3 节的实测结果调整：

```powershell
$TUN_ALIAS = 'singbox_tun'                         # 第 3 节实测的 TUN 网卡名
$CORE_CONF = 'D:\...\v2rayN\binConfigs\config.json' # 含路由规则的那份生效配置
$FAKEIP_PREFIX = ''                                 # FakeIP 开着就填 '198.18.'

function Test-CoreUp { [bool](Get-Process -Name 'xray','sing-box','mihomo' -ErrorAction SilentlyContinue) }
function Test-TunUp  { [bool](Get-NetAdapter -Name $TUN_ALIAS -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up') }

function Get-V6Binding {
    Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -and $_.Name -ne $TUN_ALIAS }
}

# 跳过 sniff、hijack-dns 这类动作规则和只看 IP/端口的规则,第一条按域名匹配的规则必须是 Claude → proxy
function Test-RulesPinned {
    if (-not (Test-Path $CORE_CONF)) { return $false }
    $c = Get-Content $CORE_CONF -Raw -Encoding utf8 | ConvertFrom-Json
    $rules = if ($c.route) { $c.route.rules } else { $c.routing.rules }   # sing-box / xray
    foreach ($r in $rules) {
        # 外层 @() 不能省:只剩一个元素时管道会返回标量,-match 就变成返回布尔值
        $d = @(@($r.domain_suffix) + @($r.domain) + @($r.domain_keyword) + @($r.rule_set) | Where-Object { $_ })
        if (-not $d) { continue }
        $out = if ($r.outbound) { $r.outbound } else { $r.outboundTag }
        return [bool](@($d -match 'claude\.ai$').Count -and $out -eq 'proxy')
    }
    return $false
}
```

DNS 那一项在 `Invoke-CheckDetail` 里改成：

```powershell
$dns = (Resolve-DnsName claude.ai -Type A -ErrorAction SilentlyContinue | Select-Object -First 1).IPAddress
if (-not $FAKEIP_PREFIX) { "DNS=warn:未开FakeIP,看报告($dns)" }
elseif ($dns -like "$FAKEIP_PREFIX*") { "DNS=ok:走隧道" }
else { "DNS=fail:未走隧道($dns)" }
```

## 6. 预计会碰到的问题

| 现象 | 原因 | 处理（都要用户确认） |
|---|---|---|
| 规则置顶 fail | v2rayN 默认规则集里没有 Claude 专用规则 | 设置 → 路由设置 → 编辑当前启用的规则集 → 添加规则：outboundTag 选 `proxy`，Domain 填下面的名单，再把这条移到最上面。保存后 v2rayN 会重新生成配置，重跑检查 |
| WebRTC fail，暴露的是国内 IP | 规则集是"绕过大陆"时，`stun.miwifi.com`、`stun.chat.bilibili.com` 按国内规则直连，国内 STUN 服务器看到的就是真实 IP | 再加一条规则，放在 Claude 规则下面、国内直连规则上面：Network `udp`，Port `3478,19302`，outboundTag `proxy`。不能按域名写：FakeIP 关着的时候，UDP 包里没有域名可匹配 |
| DNS 是 warn | FakeIP 关着，`claude.ai` 解析到的是真实 IP，看不出查询有没有走隧道 | 两种办法：① 在 DNS 设置里打开 FakeIP，把 `$FAKEIP_PREFIX` 设成 `'198.18.'`；② 不开 FakeIP，就在报告里写明生效配置的 DNS 规则会不会把 `claude.ai` 交给走 `proxy` 的远程 DNS，并且确认严格路由已打开 |
| 严格路由没开 | v2rayN 默认关。Windows 会同时向每块网卡上配置的 DNS 发查询，其中物理网卡那份不进隧道 | 建议在 TUN 设置里打开 |
| 允许局域网连接开着 | 本地端口监听 `0.0.0.0` 且没有密码，同一局域网里谁都能用这条线路 | 不需要给别的设备共享时，建议关掉 |
| 出口 IP fail | 节点不在美国，或 TUN 没开 | 换节点、开 TUN 后重测；没恢复前不要启动 Claude |

置顶域名名单（与 `Set-PinScript` 里的一致）：

```text
domain:claude.ai
domain:claude.com
domain:anthropic.com
domain:claudeusercontent.com
domain:challenges.cloudflare.com
domain:datadoghq.com
domain:segment.io
domain:stripe.com
domain:stripe.network
domain:stripecdn.com
domain:intercom.io
domain:intercomcdn.com
domain:intercomassets.com
```

## 7. 运行与验收

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude-switcher\claude-switch.ps1" checkdetail
```

验收条件：

- [ ] 输出正好 14 行，格式是 `名称=ok|warn|fail[:说明]`
- [ ] 每项不是 `ok` 的都有原因和处理建议；`ASN属性=warn`（机房 IP）只能靠换住宅线路解决，如实写上即可
- [ ] **做过一次反向验证**：先确认 Claude 没在运行，用户同意后关掉 TUN，再跑一次。`TUN网卡` 必须变成 fail，`出口IP` 和 `WebRTC` 也应变化；验完恢复 TUN。这一步是为了证明脚本不会误报通过：原脚本以前就出过"curl 没跑起来，结果却算 ok"的 bug
- [ ] 改过的 `.ps1` 都还是 UTF-8 with BOM，`[System.Management.Automation.Language.Parser]::ParseFile` 解析无错误

## 8. 附加检查（只用 CLI 或有其他会访问 Anthropic 的程序时做）

1. **Claude Code CLI 断线不直连**：看 `%USERPROFILE%\.claude\settings.json` 的 `env` 里有没有 `HTTPS_PROXY`、`HTTP_PROXY`（指向 v2rayN 的本地端口）和 `NO_PROXY=localhost,127.0.0.1,::1`。没有的话，建议加上（用户确认后再改，先备份）。验证：把代理地址临时指向一个不通的端口，CLI 应报连接被拒，而不是改走直连
2. **其他会访问 Anthropic 的开机自启程序**（用量监控之类）：查注册表 Run 键和启动文件夹。这类程序不读 settings.json，代理一断就可能直连；列出来交给用户决定

## 9. 坑（在 Clash Verge 机器上踩过的）

- 用 `%SystemRoot%\System32\curl.exe` 的绝对路径：程序被精简过 PATH 的环境拉起时，会找不到 curl
- `Get-Process -Name 'Claude'` 不区分大小写，会把 CLI 的 `claude.exe` 也匹配进来。脚本里的 `Get-ClaudeApp` 已经排除了 CLI，改代码时不要绕开它
- 可达性判断用白名单：只有拿到三位 HTTP 状态码才算可达
- 在 Windows PowerShell 5.1 里用 `Start-Process -Verb RunAs -ArgumentList '-Command', $cmd` 提权，命令里的双引号会被吃掉，隐藏窗口里的报错也看不到。改用 `-EncodedCommand`（UTF-16LE 编码后再 Base64）
- 往 `settings.json` 的 `env.PATH` 里写字面量 `$PATH` 不会被展开，子进程会找不到 curl、powershell。要么不写 PATH，要么写展开后的完整值

## 10. 报告

写到克隆下来的仓库里：`ai-guide/reports/<YYYYMMDD>-<你的agent名>-v2rayn-env-audit.md`，不要提交（这个目录已在 `.gitignore` 里，报告里有本机细节，不能进公开仓库）。

内容：

1. 结论：十四项各几项 ok、warn、fail，一句话总评
2. 环境：第 3 节那张表的实测值，IP 打码
3. 十四项结果表：检查项、结果、说明
4. 适配改动：改了哪些函数，和第 5 节的参考写法有什么不同、为什么
5. 本机改动：改了什么、在哪改的、备份在哪；没做的也写上
6. 待办：需要用户决定的事项
