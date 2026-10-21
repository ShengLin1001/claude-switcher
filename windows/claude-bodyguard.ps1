# Claude 保镖 (Windows) —— 代理离线时自动关闭 Claude
# 由安装器注册为计划任务,登录时启动,隐藏窗口常驻
$ErrorActionPreference = 'SilentlyContinue'
$LOG = Join-Path $env:USERPROFILE ".claude-switcher\bodyguard.log"

while ($true) {
    $coreUp = [bool](Get-Process -Name 'verge-mihomo' -ErrorAction SilentlyContinue)
    $tunUp  = [bool](Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like '198.18.*' })
    if (-not ($coreUp -and $tunUp)) {
        # -Name 不分大小写,会连带匹配 Claude Code CLI(claude.exe);排除它,免得掉线时连带杀掉正在跑的 CLI 会话
        $p = Get-Process -Name 'Claude' -ErrorAction SilentlyContinue | Where-Object { $_.Path -ne "$env:USERPROFILE\.local\bin\claude.exe" }
        if ($p) {
            $p | Stop-Process -Force
            "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 代理离线(内核或TUN丢失),已自动关闭 Claude" | Out-File -Append -Encoding utf8 $LOG
        }
    }
    Start-Sleep -Seconds 10
}
