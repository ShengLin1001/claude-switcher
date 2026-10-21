#!/bin/bash
# Claude 切换器 - 通用安装程序 (macOS)
cd "$(dirname "$0")"
H="$HOME"
clear
echo "=================================="
echo "  Claude 账号切换器 · 安装程序"
echo "=================================="
echo ""

# ---- 0. 前置检查 ----
CLASH_DIR="$H/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
if [ ! -d "$CLASH_DIR" ]; then
    echo "❌ 未检测到 Clash Verge,请先安装并配置好代理再运行本安装程序。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if [ ! -d /Applications/Claude.app ]; then
    echo "⚠️  未检测到 Claude 桌面版(/Applications/Claude.app),请先安装。"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
if ! python3 --version >/dev/null 2>&1; then
    echo "⚠️  未检测到 python3,请先安装 Xcode 命令行工具: xcode-select --install"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
echo "✓ 前置检查通过(Clash Verge / Claude / python3)"

# ---- 1. 自动探测代理组名 ----
GRP=$(awk '
    /^proxy-groups:/ {f=1; next}
    f && /^[a-zA-Z]/ {f=0}
    f && /- name:/ { n=$0; sub(/.*- name: */, "", n); gsub(/"/, "", n) }
    f && /type: *select/ { print n; exit }
' "$CLASH_DIR/clash-verge.yaml" 2>/dev/null)
if [ -z "$GRP" ]; then
    echo ""
    echo "未能自动识别你的代理组名,请打开 Clash Verge 查看「代理」页面顶部的组名。"
    read -r -p "请输入代理组名: " GRP
    [ -z "$GRP" ] && { echo "未输入,退出"; exit 1; }
fi
echo "✓ 代理组: $GRP"

# ---- 2. 自动探测时区(应与出口IP城市一致;必须先挂代理) ----
IPINFO=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null)
CTRY=$(echo "$IPINFO" | grep '"country"' | cut -d'"' -f4)
if [ "$CTRY" != "US" ] && [ -z "$FORCE" ]; then
    echo ""
    echo "❌ 检测到当前出口不在美国(国家: ${CTRY:-未知})。"
    echo "   请先在 Clash Verge 里开启代理(TUN模式)并确认节点可用,再运行本安装程序。"
    echo "   (否则时区会被错误识别)"
    read -n 1 -s -r -p "按任意键退出..."; exit 1
fi
TZV=$(echo "$IPINFO" | grep '"timezone"' | cut -d'"' -f4)
[ -z "$TZV" ] && TZV="America/New_York"
echo "✓ 锁定时区: $TZV (按当前出口IP自动识别)"

# ---- 3. 安装文件 ----
mkdir -p "$H/.local/bin" "$H/.claude-switcher" "$H/Library/Logs"
cp files/claude-switch.sh "$H/.local/bin/"
cp files/stun-probe.py "$H/.claude-switcher/"
chmod +x "$H/.local/bin/claude-switch.sh"
# 写入探测到的代理组名和时区
sed -i '' "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$TZV\"|; s|^PROXY_GROUP=\".*\"|PROXY_GROUP=\"$GRP\"|" "$H/.local/bin/claude-switch.sh"

# 保镖脚本(物化路径)
cat > "$H/.local/bin/claude-bodyguard.sh" <<EOF
#!/bin/bash
LOG="$H/Library/Logs/claude-bodyguard.log"
ok=1
pgrep -f verge-mihomo >/dev/null 2>&1 || ok=0
ifconfig 2>/dev/null | grep -q 'inet 198\\.18\\.' || ok=0
if [ "\$ok" -eq 0 ]; then
    if pgrep -f '/Applications/Claude.app/Contents/MacOS/Claude' >/dev/null 2>&1; then
        pkill -f '/Applications/Claude.app/Contents/MacOS/Claude'
        echo "\$(date '+%Y-%m-%d %H:%M:%S') 代理离线(内核或TUN丢失),已自动关闭 Claude" >>"\$LOG"
    fi
fi
EOF
chmod +x "$H/.local/bin/claude-bodyguard.sh"

# 时区看门狗脚本
cat > "$H/.local/bin/tz-watchdog.sh" <<EOF
#!/bin/bash
TARGET="$TZV"
LOG="$H/Library/Logs/tz-watchdog.log"
current=\$(readlink /etc/localtime 2>/dev/null)
if [ "\$current" != "/var/db/timezone/zoneinfo/\$TARGET" ]; then
    /usr/sbin/systemsetup -settimezone "\$TARGET" >>"\$LOG" 2>&1
    echo "\$(date '+%Y-%m-%d %H:%M:%S %Z') 时区异常: [\$current] 已自动恢复为 \$TARGET" >>"\$LOG"
fi
EOF
chmod +x "$H/.local/bin/tz-watchdog.sh"

# launchd 配置
cat > "$H/.local/bin/local.claude-bodyguard.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>Label</key><string>local.claude-bodyguard</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$H/.local/bin/claude-bodyguard.sh</string></array>
	<key>StartInterval</key><integer>10</integer>
	<key>RunAtLoad</key><true/>
</dict></plist>
EOF
cat > "$H/.local/bin/local.tz-watchdog.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>Label</key><string>local.tz-watchdog</string>
	<key>ProgramArguments</key><array><string>/bin/bash</string><string>$H/.local/bin/tz-watchdog.sh</string></array>
	<key>StartInterval</key><integer>3600</integer>
	<key>RunAtLoad</key><true/>
</dict></plist>
EOF
echo "✓ 核心文件已安装"

# ---- 4. 安装 App 到桌面 ----
mkdir -p "$H/Desktop"
rm -rf "$H/Desktop/Claude切换器.app"
cp -R "files/Claude切换器.app" "$H/Desktop/"
echo "✓ App 已放到桌面"

# ---- 5. 写入置顶规则(由核心脚本写全局扩展脚本 Script.js,域名名单只维护一份) ----
"$H/.local/bin/claude-switch.sh" pinrules && echo "✓ Claude 域名置顶规则已写入(重启 Clash Verge 后生效)"

# ---- 6. 系统级配置(需要一次密码) ----
if [ -n "$DRYRUN" ]; then
    echo "[演练模式] 跳过系统级配置(守护进程/时区/IPv6)"
else
    echo ""
    echo "接下来需要输入一次开机密码,用于: 安装守护进程 + 锁定时区($TZV) + 关闭IPv6"
    sudo bash -c "
        cp '$H/.local/bin/local.claude-bodyguard.plist' '$H/.local/bin/local.tz-watchdog.plist' /Library/LaunchDaemons/
        chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist
        chmod 644 /Library/LaunchDaemons/local.claude-bodyguard.plist /Library/LaunchDaemons/local.tz-watchdog.plist
        launchctl bootout system/local.claude-bodyguard 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist
        launchctl bootout system/local.tz-watchdog 2>/dev/null; launchctl bootstrap system /Library/LaunchDaemons/local.tz-watchdog.plist
        /usr/sbin/systemsetup -settimezone '$TZV'
        networksetup -setv6off Wi-Fi
        dscacheutil -flushcache; killall -HUP mDNSResponder
    " && echo "✓ 系统级配置完成" || echo "✗ 系统级配置被取消,可稍后重新运行安装程序"
fi

# ---- 7. 重启 Clash 使规则生效 ----
if [ -z "$DRYRUN" ]; then
    osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
    sleep 2
    open -a "Clash Verge" >/dev/null 2>&1
fi

echo ""
echo "=================================="
echo "  ✅ 安装完成!"
echo "  使用: 双击桌面「Claude切换器」"
echo "  首次使用: 打开后选账号A(自动收编当前登录)"
echo "=================================="
read -n 1 -s -r -p "按任意键关闭窗口..."
