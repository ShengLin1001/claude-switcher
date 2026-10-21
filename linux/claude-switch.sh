#!/bin/bash
# Claude 账号切换器 - Linux 核心脚本
# 用法: claude-switch.sh checkdetail|status|fix|switch A|B|menu|pinrules
set -u
export LC_ALL=en_US.UTF-8

# ============ 安装时可配置项(安装器自动改写) ============
TZ_TARGET="America/New_York"     # 锁定时区,与出口IP城市一致
PROXY_GROUP="GLOBAL"             # Clash 代理组名
# =======================================================

BASE="$HOME/.claude-switcher"
DATA="$HOME/.config/google-chrome"   # Web 版登录态目录(Chrome)
[ -d "$HOME/.config/chromium" ] && [ ! -d "$DATA" ] && DATA="$HOME/.config/chromium"
LOG="$BASE/claude-switch.log"
CLASH_DIR="$HOME/.config/io.github.clash-verge-rev.clash-verge-rev"
[ -d "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev" ] && CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
mkdir -p "$BASE/accounts"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

tun_up() { ip addr 2>/dev/null | grep -q 'inet 198\.18\.'; }
core_up() { pgrep -f 'verge-mihomo|mihomo' >/dev/null 2>&1; }

# 只认 rules: 段内的条目:Clash Verge Rev 新版把 Merge 里的 prepend-rules 原样留在顶层且不生效,全文 grep 会误报
rules_pinned() {
    awk -v pat="DOMAIN-SUFFIX,claude.ai,$PROXY_GROUP" '/^rules:/{r=1; next} /^[^ -]/{r=0} r && index($0, pat){f=1} END{exit !f}' \
        "$CLASH_DIR/clash-verge.yaml" 2>/dev/null
}

# 用全局扩展脚本 Script.js 把置顶规则插到 rules 最前;用户自写的脚本不覆盖
pin_rules() {
    local f="$CLASH_DIR/profiles/Script.js"
    local re='^functionmain\(config(,profileName)?\)\{returnconfig;?\}$'
    if [ -f "$f" ] && ! grep -q 'claude-switcher' "$f" && [[ ! "$(sed 's#//.*##' "$f" | tr -d ' \t\r\n')" =~ $re ]]; then
        echo "FIX:Script.js 已有自定义内容,未覆盖;请把 Claude 置顶规则手动加进该脚本 ✗"
        return 1
    fi
    mkdir -p "$CLASH_DIR/profiles"
    cat > "$f" <<JSEOF
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
JSEOF
}

dns_query() {
    # dig → nslookup → getent 逐级回退
    if command -v dig >/dev/null 2>&1; then dig +short +time=3 +tries=1 "$1" 2>/dev/null | head -1
    elif command -v nslookup >/dev/null 2>&1; then nslookup -timeout=3 "$1" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1
    else getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; fi
}

egress() {
    local t
    t=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    echo "$(echo "$t" | grep '^ip=' | cut -d= -f2) $(echo "$t" | grep '^loc=' | cut -d= -f2)"
}

webrtc_test() { python3 "$BASE/stun-probe.py" 2>/dev/null; }

checkdetail() {
    core_up && echo '代理内核=ok' || echo '代理内核=fail:未运行'
    tun_up && echo 'TUN网卡=ok' || echo 'TUN网卡=fail:不在线'

    read -r ip loc <<< "$(egress)"
    [ "$loc" = "US" ] && echo "出口IP=ok:$ip" || echo "出口IP=fail:${ip:-无}/${loc:-未知}"

    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -z "$ip" ]; then echo 'IP一致=fail:未获取到出口IP'
    elif [ -z "$lastip" ]; then echo 'IP一致=ok:首次记录'
    elif [ "$ip" = "$lastip" ]; then echo 'IP一致=ok'
    else echo "IP一致=warn:$lastip → $ip"; fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"

    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ "$tz" = "$TZ_TARGET" ] && echo '时区=ok' || echo "时区=fail:$tz"

    lang="${LANG:-$(localectl status 2>/dev/null | grep 'LANG=' | head -1 | cut -d= -f2)}"
    case "$lang" in en_US*) echo '地区=ok' ;; *) echo "地区=fail:$lang" ;; esac

    v6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    [ "$v6" = "1" ] && echo 'IPv6=ok:已关闭' || echo 'IPv6=fail:未关闭'

    dnsip=$(dns_query claude.ai)
    case "$dnsip" in 198.18.*) echo 'DNS=ok:走隧道' ;; *) echo "DNS=fail:未走隧道(${dnsip:-空})" ;; esac

    wr=$(webrtc_test)
    case "$wr" in
        RESULT:NONE) echo 'WebRTC=ok:UDP不出网,零暴露' ;;
        RESULT:*)
            wips=${wr#RESULT:}; leak=""
            OLDIFS=$IFS; IFS=','
            for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
            IFS=$OLDIFS
            [ -n "$leak" ] && echo "WebRTC=fail:暴露非代理IP:$leak" || echo 'WebRTC=ok:仅暴露代理IP' ;;
        *) echo 'WebRTC=fail:检测异常' ;;
    esac

    if systemctl --user is-active claude-bodyguard.service >/dev/null 2>&1; then
        lastkill=$(tail -1 "$BASE/bodyguard.log" 2>/dev/null | cut -c1-40)
        echo "保镖=ok:${lastkill:-待命}"
    else
        echo '保镖=fail:未运行'
    fi

    rules_pinned && echo '规则置顶=ok' || echo '规则置顶=fail:未生效'

    echo '客户端语言=ok:跟随系统'

    org=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    case "$org" in
        '') echo 'ASN属性=warn:未获取' ;;
        *Comcast*|*AT\&T*|*Verizon*|*Spectrum*|*Charter*|*Cox*|*T-Mobile*|*Cable*|*esidential*) echo "ASN属性=ok:$org" ;;
        *) echo "ASN属性=warn:疑似机房($org)" ;;
    esac

    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    # 白名单判定:curl 缺失时结果为空,只排除 000 会放行
    if [[ "$r1" =~ ^[1-5][0-9]{2}$ && "$r2" =~ ^[1-5][0-9]{2}$ ]]; then
        echo "生态可达性=ok:claude.ai:$r1 api:$r2"
    else
        echo "生态可达性=fail:claude.ai:$r1 api:$r2"
    fi
}

fix() {
    echo "FIX:开始一键修复"

    if ! core_up; then
        echo "FIX:正在尝试启动 Clash Verge..."
        (clash-verge >/dev/null 2>&1 &) || (clash-verge-rev >/dev/null 2>&1 &) || echo "FIX:未找到启动命令,请手动启动 Clash Verge"
    fi
    for i in $(seq 1 40); do
        core_up && tun_up && break
        sleep 1
    done
    if core_up && tun_up; then
        echo "FIX:代理内核+TUN ✓"
    else
        echo "FIX:代理内核/TUN ✗(请检查 Clash Verge 的 TUN 开关与节点)"
    fi

    # 时区/IPv6/DNS(sudo)
    adminCmds=""
    tz=$(timedatectl show -p Timezone --value 2>/dev/null)
    [ "$tz" != "$TZ_TARGET" ] && adminCmds="${adminCmds}timedatectl set-timezone $TZ_TARGET; "
    [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" != "1" ] && adminCmds="${adminCmds}sysctl -w net.ipv6.conf.all.disable_ipv6=1; "
    if [ -n "$adminCmds" ]; then
        echo "FIX:修复时区/IPv6(需要 sudo 密码)..."
        sudo bash -c "$adminCmds" && echo "FIX:时区/IPv6 ✓" || echo "FIX:时区/IPv6 ✗"
    else
        echo "FIX:时区/IPv6 无需修复 ✓"
    fi
    command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches 2>/dev/null
    command -v systemd-resolve >/dev/null 2>&1 && systemd-resolve --flush-caches 2>/dev/null

    # 保镖(systemd user 服务,免 sudo)
    if ! systemctl --user is-active claude-bodyguard.service >/dev/null 2>&1; then
        echo "FIX:注册并启动保镖服务..."
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
            && echo "FIX:保镖 ✓" || echo "FIX:保镖 ✗"
    fi

    # 置顶规则
    if ! rules_pinned; then
        echo "FIX:重写置顶规则..."
        pin_rules && echo "FIX:置顶规则已写入(请重启 Clash Verge 生效)"
    fi

    sleep 2
    read -r ip loc <<< "$(egress)"
    [ "$loc" = "US" ] && echo "FIX:出口IP ✓ ($ip)" || echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知}) — 请换节点/线路"
    echo "FIX:修复流程结束"
}

status() {
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    hasA=0; [ -d "$BASE/accounts/A" ] && hasA=1
    hasB=0; [ -d "$BASE/accounts/B" ] && hasB=1
    echo "current=$cur hasA=$hasA hasB=$hasB"
}

quit_browser() {
    pgrep -f 'chrome|chromium' >/dev/null 2>&1 || return 0
    pkill -f "$DATA" 2>/dev/null
    for i in $(seq 1 15); do
        pgrep -f "$DATA" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

archive_current() {
    cur="$1"
    rm -rf "$BASE/accounts/$cur.tmp"
    cp -a "$DATA" "$BASE/accounts/$cur.tmp" && rm -rf "$BASE/accounts/$cur" && mv "$BASE/accounts/$cur.tmp" "$BASE/accounts/$cur"
    log "已存档账号$cur(浏览器登录态)"
}

switch_to() {
    target="$1"
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")

    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_browser || { echo "FAIL:浏览器未能退出,请手动关闭后重试"; return 1; }
        archive_current A
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前浏览器登录态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_browser || { echo "FAIL:浏览器未能退出,请手动关闭后重试"; return 1; }
    [ "$cur" != "none" ] && [ -d "$DATA" ] && archive_current "$cur"

    rm -rf "$DATA.new"
    if [ -d "$BASE/accounts/$target" ]; then
        cp -a "$BASE/accounts/$target" "$DATA.new"
        log "已载入账号$target 存档"
    else
        mkdir -p "$DATA.new"
        log "账号$target 无存档,将以全新状态初始化"
    fi
    rm -rf "$DATA" && mv "$DATA.new" "$DATA"
    echo "$target" > "$BASE/current"
    log "已切换到账号$target"
    echo "OK:已切换到账号$target(请重新打开浏览器)"
}

menu() {
    while true; do
        clear
        echo "=============================="
        echo "  Claude 账号切换器 (Linux)"
        echo "=============================="
        echo ""
        echo "  1) 安全检查 (checkdetail)"
        echo "  2) 一键修复 (fix)"
        echo "  3) 切换到账号 A"
        echo "  4) 切换到账号 B"
        echo "  5) 查看状态 (status)"
        echo "  0) 退出"
        echo ""
        read -r -p "选择: " c
        case "$c" in
            1) checkdetail; read -r -p "回车继续..." _ ;;
            2) fix; read -r -p "回车继续..." _ ;;
            3) switch_to A; read -r -p "回车继续..." _ ;;
            4) switch_to B; read -r -p "回车继续..." _ ;;
            5) status; read -r -p "回车继续..." _ ;;
            0) exit 0 ;;
        esac
    done
}

case "${1:-menu}" in
    checkdetail) OUT="$BASE/last-check.txt"; { checkdetail; } > "$OUT" 2>&1; cat "$OUT" ;;
    status) status ;;
    fix) fix ;;
    switch) switch_to "${2:-}" ;;
    pinrules) pin_rules ;;
    menu|*) menu ;;
esac
