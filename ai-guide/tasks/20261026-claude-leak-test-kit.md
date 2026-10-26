# 绑定网卡绕过 & 断线保护测试包（Windows）

用来在另一台机器上补测两项常规检查测不到的内容：

1. **绑定物理网卡绕过隧道**：浏览器、Electron 应用的 WebRTC 会按网卡逐个绑定套接字收集候选地址。TUN 的 `strict-route` 在 Windows 上只拦 DNS，不拦这类流量。只测默认路由的 STUN 探针（包括项目自带的 `stun-probe.py` 和 `Test-WebRTC`）会显示"ok"，但实际可能泄漏。
2. **断线保护**：分别看节点故障、内核崩溃、TUN 关闭三种情况下，流量是被切断（安全）还是回落到直连（泄漏）。

> 所有输出里的 IP 只显示前两段（如 `a.b.x.x`），可以直接贴回对话里对比。

---

## 0. 准备

- Python 3（只用标准库）、Windows 自带的 PowerShell 5.1。
- **PowerShell 代码块直接复制粘贴到 PowerShell 窗口运行**，不要另存为 `.ps1`：PowerShell 5.1 读取没有 BOM 的 UTF-8 文件时会把中文读成乱码，导致脚本解析失败。
- **注意代理环境变量**：如果当前终端设置了 `HTTPS_PROXY`/`HTTP_PROXY`（例如从 `~/.claude/settings.json` 继承来的），curl 会自动走代理端口，测出来的就不是 TUN 路径了。下面的脚本已经用 `--noproxy '*'` 和 `-x` 把两条路径分开测。

## 1. 查物理网卡 IPv4

```powershell
Get-NetIPAddress -AddressFamily IPv4 |
  Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '198.18.*' -and $_.InterfaceAlias -notmatch 'Mihomo|Meta|Clash|sing|tun|ZeroTier|Tailscale|VMware|vEthernet' } |
  Select-Object InterfaceAlias, IPAddress
```

记下 Wi-Fi 或以太网那一行的 IP，后面用 `<物理IP>` 指代它。

## 2. UDP / STUN 测试（模拟 WebRTC）

把下面的内容保存为 `stun_py.py`：

```python
import socket, struct, os, sys

SERVERS = [("stun.miwifi.com", 3478), ("stun.chat.bilibili.com", 3478),
           ("stun.l.google.com", 19302), ("stun.cloudflare.com", 3478)]

def mask(ip):
    p = ip.split(".")
    return f"{p[0]}.{p[1]}.x.x" if len(p) == 4 else ip

def probe(host, port, bind=None):
    try:
        addr = socket.gethostbyname(host)
    except Exception:
        return "dns-fail"
    txn = os.urandom(12)
    req = struct.pack("!HHI", 0x0001, 0, 0x2112A442) + txn
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.5)
    try:
        if bind:
            s.bind((bind, 0))
        s.sendto(req, (addr, port))
        data, _ = s.recvfrom(1024)
    except Exception:
        return "timeout/blocked"
    finally:
        s.close()
    pos = 20
    while pos + 4 <= len(data):
        atype, alen = struct.unpack("!HH", data[pos:pos + 4])
        aval = data[pos + 4:pos + 4 + alen]
        if atype == 0x0020 and len(aval) >= 8 and aval[1] == 0x01:
            return socket.inet_ntoa(struct.pack("!I", struct.unpack("!I", aval[4:8])[0] ^ 0x2112A442))
        if atype == 0x0001 and len(aval) >= 8 and aval[1] == 0x01:
            return socket.inet_ntoa(aval[4:8])
        pos += 4 + alen + ((4 - alen % 4) % 4)
    return "no-mapped-addr"

bind = sys.argv[1] if len(sys.argv) > 1 else None
for h, p in SERVERS:
    r = probe(h, p, bind)
    print(f"  py {'bind=' + mask(bind) if bind else '默认路由':<16} {h:<24}: {mask(r) if r[0].isdigit() else r}")
```

运行：

```powershell
$env:PYTHONIOENCODING = 'utf-8'
python stun_py.py              # 默认路由
python stun_py.py <物理IP>      # 绑定物理网卡
```

> 说明：FakeIP 模式下，STUN 服务器的域名会被解析成 198.18.x。绑定物理网卡后去连这种地址必然失败，结果显示为 `timeout/blocked`。这时显示安全并不能说明没有泄漏，需要以第 3 步的 TCP 测试（目标是 IP 字面量，不经过 DNS）为准。

## 3. TCP 绑定物理网卡测试

目标直接写 IP 字面量（`208.95.112.1` = ip-api.com，走纯 HTTP），不受 DNS 和 FakeIP 影响；输出的是**对端实际看到的源 IP**：

```powershell
$bind = '<物理IP>'
$c = New-Object System.Net.Sockets.TcpClient (New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($bind)), 0)
try {
  if (-not $c.BeginConnect('208.95.112.1', 80, $null, $null).AsyncWaitHandle.WaitOne(5000) -or -not $c.Connected) { "TCP 绑定物理网卡: 连接失败(未绕过)" }
  else {
    $s = $c.GetStream(); $s.ReadTimeout = 5000
    $req = [Text.Encoding]::ASCII.GetBytes("GET /line/?fields=countryCode,query HTTP/1.1`r`nHost: ip-api.com`r`nConnection: close`r`n`r`n"); $s.Write($req, 0, $req.Length)
    $buf = New-Object byte[] 4096; $n = $s.Read($buf, 0, 4096)
    $body = ([Text.Encoding]::ASCII.GetString($buf, 0, $n) -split "`r`n`r`n", 2)[1]
    $cc = ($body -split "`n")[0].Trim(); $ip = ($body -split "`n")[1].Trim()
    $m = if ($ip -match '^(\d+\.\d+)\.') { "$($Matches[1]).x.x" } else { $ip }
    "TCP 绑定物理网卡: 对端看到 $m 国家=$cc"
  }
} catch { "TCP 绑定物理网卡: 异常 $($_.Exception.InnerException.Message)" } finally { $c.Close() }
```

## 4. 断线保护监测

先确认代理端口（Clash Verge 默认 `7897`，在"设置 → 端口设置"里可以看到），然后粘贴运行。脚本会持续运行 `$DUR` 秒：

```powershell
$CURL = "$env:SystemRoot\System32\curl.exe"; $PORT = 7897; $DUR = 240
function Mask($ip) { if ($ip -match '^(\d+\.\d+)\.') { "$($Matches[1]).x.x" } elseif ($ip) { ($ip -split ':')[0] + ':…' } else { '' } }
function Probe($extra) {
  $t = & $CURL -s --max-time 4 @extra https://www.cloudflare.com/cdn-cgi/trace | Out-String
  if ($t -notmatch '(?m)^ip=(\S+)') { return 'BLOCKED' }
  $ip = $Matches[1]; $loc = if ($t -match '(?m)^loc=(\S+)') { $Matches[1] }
  if ($loc -eq 'US') { "PROXY($(Mask $ip))" } else { "LEAK:$(Mask $ip)/$loc" }
}
$end = (Get-Date).AddSeconds($DUR)
while ((Get-Date) -lt $end) {
  $tun = [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -like '198.18.*' }) -or
         [bool](Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -match 'Meta|Mihomo|sing-tun|Clash' })
  "{0} TUN={1,-5} TUN路径={2,-22} 代理端口路径={3}" -f (Get-Date -Format HH:mm:ss), $tun, (Probe @('--noproxy','*')), (Probe @('-x',"http://127.0.0.1:$PORT"))
  Start-Sleep 2
}
```

- **TUN 路径**：不认代理环境变量、不认系统代理的程序实际走的路径。
- **代理端口路径**：设置了 `HTTPS_PROXY` 的 Claude Code CLI / VS Code 扩展，以及跟随系统代理的浏览器实际走的路径。

监测运行期间，依次做下面三项操作，每项之间等大约 20 秒，并在恢复正常后再做下一项：

| 场景 | 操作（Clash Verge） | 恢复 |
|---|---|---|
| A. 节点故障 | 在代理组里切换到一个明显不可用的节点（延迟测试显示超时的节点） | 切回原节点 |
| B. 内核崩溃 | 用管理员身份打开任务管理器，结束 `verge-mihomo.exe` | Clash Verge 可能会自动重启内核；没有的话手动重启 Clash Verge |
| C. TUN 关闭 | 在 Clash Verge 里关闭"虚拟网卡模式" | 重新打开 |

> 注意：Clash Verge 更新或异常重启后，可能会把 `enable_tun_mode` 重置为 false（见 AGENTS.md 排障表）。做完场景 B 后要确认 TUN 是否真的恢复了。

## 5. 判读

| 测试 | 安全 | 泄漏 |
|---|---|---|
| 第 2 步默认路由 | `timeout/blocked`，或代理 IP | 国内 IP |
| 第 2 步绑定物理 IP | `timeout/blocked`，或代理 IP（FakeIP 下要结合第 3 步看） | **国内 IP → WebRTC 可以绕过隧道** |
| 第 3 步 | 连接失败，或国家=US | **国家=CN → TCP 也可以绕过隧道** |
| 第 4 步 | 断线期间是 `BLOCKED`，或仍是 `PROXY` | 出现 `LEAK:` |

## 6. 参考：第一台机器（v2rayN + sing-box TUN，strict_route=true）的结果

| 测试 | 结果 |
|---|---|
| STUN 默认路由 | 4/4 `timeout/blocked`（安全） |
| STUN 绑定 Wi-Fi | 4/4 返回国内 IP `a.b.x.x` / `c.d.x.x`（**泄漏**） |
| TCP 绑定 Wi-Fi → ip-api.com | 国家=CN（**泄漏**） |
| 断线 A（结束 xray） | 两条路径都是 `BLOCKED`（安全） |
| 断线 B（结束 sing-box，TUN 消失） | TUN 路径出现 `LEAK:…/CN`；代理端口路径仍是 `PROXY(US)` |
| 已采取的缓解措施 | 关闭物理网卡的 IPv6；Chrome/Edge 设置策略 `WebRtcIPHandlingPolicy=disable_non_proxied_udp`；Claude Code 通过 `~/.claude/settings.json` 的 `env` 设置 `HTTPS_PROXY`，不依赖 TUN |

如果第二台机器第 2、3 步也出现泄漏，浏览器一侧的处理方法：在 `edge://policy` 确认 WebRTC 策略或扩展已经生效，再到 browserleaks.com/webrtc 实测一次。
