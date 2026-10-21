#!/bin/bash
# Claude 切换器 Linux 版 - 安装器
# 用法: bash install.sh  (部分步骤需要 sudo)
set -u
BASE="$HOME/.claude-switcher"
CLASH_DIR="$HOME/.config/io.github.clash-verge-rev.clash-verge-rev"
[ -d "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" ] && CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"

echo "=================================="
echo "  Claude 账号切换器 · Linux 安装"
echo "=================================="
echo ""

# ---- 前置检查 ----
[ -d "$CLASH_DIR" ] || { echo "X 未检测到 Clash Verge 配置目录,请先安装并配置代理"; exit 1; }
python3 --version >/dev/null 2>&1 || { echo "X 需要 python3,请先安装 (如: sudo apt install python3)"; exit 1; }
systemctl --user --version >/dev/null 2>&1 || { echo "X 需要 systemd(用户服务)"; exit 1; }
command -v dig >/dev/null 2>&1 || echo "提示: 未找到 dig,将使用 nslookup/getent 回退(建议安装 dnsutils/bind-utils)"
echo "✓ 前置检查通过"

# ---- 出口必须美国 ----
INFO=$(curl -s --max-time 8 https://ipinfo.io/json 2>/dev/null)
CTRY=$(echo "$INFO" | grep '"country"' | cut -d'"' -f4)
[ "$CTRY" = "US" ] || { echo "X 当前出口不在美国($CTRY),请先开代理(TUN模式)再运行"; exit 1; }
echo "✓ 出口: $(echo "$INFO" | grep '"ip"' | cut -d'"' -f4) ($CTRY)"

# ---- 自动识别代理组名 ----
GRP=$(awk '/^proxy-groups:/ {f=1; next} f && /^[a-zA-Z]/ {f=0} f && /- name:/ { n=$0; sub(/.*- name: */, "", n); gsub(/"/, "", n) } f && /type: *select/ { print n; exit }' "$CLASH_DIR/clash-verge.yaml" 2>/dev/null)
[ -z "$GRP" ] && read -r -p "未能自动识别代理组名,请打开 Clash Verge 查看后输入: " GRP
echo "✓ 代理组: $GRP"

# ---- 时区 ----
TZV=$(echo "$INFO" | grep '"timezone"' | cut -d'"' -f4)
[ -z "$TZV" ] && TZV="America/New_York"
echo "✓ 锁定时区: $TZV (按出口IP识别)"

# ---- 安装文件 ----
mkdir -p "$BASE"
DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$DIR/claude-switch.sh" "$BASE/"
cp "$DIR/claude-bodyguard.sh" "$BASE/"
cp "$DIR/stun-probe.py" "$BASE/"
chmod +x "$BASE/claude-switch.sh" "$BASE/claude-bodyguard.sh"
sed -i "s|^TZ_TARGET=\".*\"|TZ_TARGET=\"$TZV\"|; s|^PROXY_GROUP=\".*\"|PROXY_GROUP=\"$GRP\"|" "$BASE/claude-switch.sh"
echo "✓ 核心文件已安装到 $BASE"

# ---- 置顶规则(由核心脚本写全局扩展脚本 Script.js,域名名单只维护一份) ----
"$BASE/claude-switch.sh" pinrules && echo "✓ Claude 域名置顶规则已写入(重启 Clash Verge 生效)"

# ---- 保镖 systemd 用户服务(免 sudo 常驻) ----
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/claude-bodyguard.service" <<EOF
[Unit]
Description=Claude Bodyguard (kill claude CLI when proxy down)

[Service]
ExecStart=/bin/bash $BASE/claude-bodyguard.sh
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now claude-bodyguard.service >/dev/null 2>&1 \
    && echo "✓ 保镖已注册并启动(systemd 用户服务,登录自启)" \
    || echo "✗ 保镖注册失败,可稍后用 fix 自动补装"

# ---- 时区与 IPv6(需要 sudo) ----
echo ""
echo "接下来需要 sudo 密码: 锁定时区($TZV) + 关闭 IPv6"
sudo timedatectl set-timezone "$TZV" && echo "✓ 时区已锁定"
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null && echo "✓ IPv6 已关闭(运行时)"
echo "net.ipv6.conf.all.disable_ipv6=1" | sudo tee /etc/sysctl.d/90-claude-switcher.conf >/dev/null \
    && echo "✓ IPv6 关闭已持久化(/etc/sysctl.d/90-claude-switcher.conf)"
command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null

# ---- 终端入口 ----
mkdir -p "$HOME/.local/bin"
ln -sf "$BASE/claude-switch.sh" "$HOME/.local/bin/claude-switch" 2>/dev/null
echo ""
echo "=================================="
echo "  ✅ 安装完成!"
echo "  使用: 终端运行 claude-switch menu"
echo "  (或 claude-switch checkdetail / fix / switch A|B)"
echo "=================================="
