#!/bin/bash
# Claude 账号切换器 - 核心脚本 (通用版)
# 用法: claude-switch.sh check | status | switch A|B | checkdetail | fix | pinrules
set -u
export LC_ALL=en_US.UTF-8

# ============ 安装时可配置项(安装程序会自动改写) ============
TZ_TARGET="America/New_York"     # 锁定时区,应与出口IP所在城市一致
PROXY_GROUP="IpEqual"            # Clash 代理组名(安装时自动探测)
# ============================================================

DATA="$HOME/Library/Application Support/Claude"
BASE="$HOME/.claude-switcher"
LOG="$HOME/Library/Logs/claude-switch.log"
CLASH_DIR="$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"
mkdir -p "$BASE/accounts"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >>"$LOG"; }

# TUN 在线判定:存在 fake-ip 网段地址即视为 TUN 已接管(兼容各种 TUN 设备名)
tun_up() { ifconfig 2>/dev/null | grep -q 'inet 198\.18\.'; }

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

# ---------- 安全检查 ----------
check() {
    fails=""

    pgrep -f verge-mihomo >/dev/null 2>&1 || fails="$fails;代理内核未运行"
    tun_up || fails="$fails;TUN网卡不在线"

    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    [ "$loc" = "US" ] || fails="$fails;出口IP非美国(${ip:-无}/${loc:-未知})"
    ipwarn=""
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -n "$ip" ] && [ -n "$lastip" ] && [ "$ip" != "$lastip" ]; then
        ipwarn="注意:出口IP与上次不同($lastip -> $ip)"
    fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"

    tz=$(readlink /etc/localtime 2>/dev/null)
    [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ] || fails="$fails;时区异常($tz)"

    locale=$(defaults read -g AppleLocale 2>/dev/null)
    [ "$locale" = "en_US" ] || fails="$fails;地区异常($locale)"

    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    echo "$v6" | grep -qi 'off' || fails="$fails;IPv6未关闭"

    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) ;;
        *) fails="$fails;DNS未走隧道(返回${dnsip:-空})" ;;
    esac

    wr=$(webrtc_test)
    if [ "$wr" != "RESULT:NONE" ]; then
        case "$wr" in
            RESULT:*)
                wips=${wr#RESULT:}
                leak=""
                OLDIFS=$IFS; IFS=','
                for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
                IFS=$OLDIFS
                [ -n "$leak" ] && fails="$fails;WebRTC泄漏($leak)" ;;
            *) fails="$fails;WebRTC检测异常" ;;
        esac
    fi

    launchctl print system/local.claude-bodyguard >/dev/null 2>&1 || fails="$fails;保镖未运行"

    rules_pinned || fails="$fails;置顶规则缺失"

    defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' || {
        syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
        [[ "$syslang" == en* ]] || fails="$fails;客户端语言为中文"
    }

    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    # 白名单判定:curl 缺失时结果为空,只排除 000 会放行
    [[ "$r1" =~ ^[1-5][0-9]{2}$ && "$r2" =~ ^[1-5][0-9]{2}$ ]] || fails="$fails;Anthropic生态不可达($r1/$r2)"

    if [ -n "$fails" ]; then
        echo "FAIL:${fails#;}"
        return 1
    fi
    echo "OK:$ip${ipwarn:+|$ipwarn}"
    return 0
}

# WebRTC/STUN 探测:返回 RESULT:ip,ip 或 RESULT:NONE 或空
webrtc_test() {
    python3 "$BASE/stun-probe.py" 2>/dev/null
}

# 逐项输出检查结果(供UI使用): 名称=ok|fail:细节
checkdetail() {
    if pgrep -f verge-mihomo >/dev/null 2>&1; then echo '代理内核=ok'; else echo '代理内核=fail:未运行'; fi
    if tun_up; then echo 'TUN网卡=ok'; else echo 'TUN网卡=fail:不在线'; fi
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "US" ]; then echo "出口IP=ok:$ip"; else echo "出口IP=fail:${ip:-无}/${loc:-未知}"; fi
    lastip=""; [ -f "$BASE/lastip" ] && lastip=$(cat "$BASE/lastip")
    if [ -z "$ip" ]; then echo 'IP一致=fail:未获取到出口IP'
    elif [ -z "$lastip" ]; then echo 'IP一致=ok:首次记录'
    elif [ "$ip" = "$lastip" ]; then echo 'IP一致=ok'
    else echo "IP一致=warn:$lastip → $ip"; fi
    [ -n "$ip" ] && echo "$ip" > "$BASE/lastip"
    tz=$(readlink /etc/localtime 2>/dev/null)
    if [ "$tz" = "/var/db/timezone/zoneinfo/$TZ_TARGET" ]; then echo '时区=ok'; else echo "时区=fail:$tz"; fi
    locale=$(defaults read -g AppleLocale 2>/dev/null)
    if [ "$locale" = "en_US" ]; then echo '地区=ok'; else echo "地区=fail:$locale"; fi
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    if echo "$v6" | grep -qi 'off'; then echo 'IPv6=ok:已关闭'; else echo 'IPv6=fail:未关闭'; fi
    dnsip=$(dig +short +time=3 +tries=1 claude.ai 2>/dev/null | head -1)
    case "$dnsip" in
        198.18.*) echo 'DNS=ok:走隧道' ;;
        *) echo "DNS=fail:未走隧道(${dnsip:-空})" ;;
    esac
    wr=$(webrtc_test)
    case "$wr" in
        RESULT:NONE) echo 'WebRTC=ok:UDP不出网,零暴露' ;;
        RESULT:*)
            wips=${wr#RESULT:}
            leak=""
            OLDIFS=$IFS; IFS=','
            for w in $wips; do [ "$w" != "$ip" ] && leak="$leak $w"; done
            IFS=$OLDIFS
            if [ -n "$leak" ]; then echo "WebRTC=fail:暴露非代理IP:$leak"; else echo 'WebRTC=ok:仅暴露代理IP'; fi ;;
        *) echo 'WebRTC=fail:检测异常' ;;
    esac
    if launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        lastkill=$(tail -1 "$HOME/Library/Logs/claude-bodyguard.log" 2>/dev/null | cut -c1-40)
        echo "保镖=ok:${lastkill:-待命}"
    else
        echo '保镖=fail:未安装'
    fi
    if rules_pinned; then
        echo '规则置顶=ok'
    else
        echo '规则置顶=fail:未生效'
    fi
    # 12. Claude 客户端语言(单独设为英文,或系统首选语言为英文均可;防止 JS 层读出中文)
    clang=$(defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | head -2)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if echo "$clang" | grep -q 'en-US'; then
        echo '客户端语言=ok:en-US'
    elif [[ "$syslang" == en* ]]; then
        echo '客户端语言=ok:跟随系统(英文)'
    else
        echo '客户端语言=fail:跟随系统(中文)'
    fi
    # 13. ASN 网络属性(住宅宽带 vs 机房)
    org=$(curl -s --max-time 6 https://ipinfo.io/json 2>/dev/null | grep '"org"' | cut -d'"' -f4)
    case "$org" in
        '') echo 'ASN属性=warn:未获取' ;;
        *Comcast*|*AT\&T*|*Verizon*|*Spectrum*|*Charter*|*Cox*|*T-Mobile*|*Cable*|*esidential*) echo "ASN属性=ok:$org" ;;
        *) echo "ASN属性=warn:疑似机房($org)" ;;
    esac
    # 14. Anthropic 生态可达性
    r1=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://claude.ai/ 2>/dev/null)
    r2=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models 2>/dev/null)
    if [[ "$r1" =~ ^[1-5][0-9]{2}$ && "$r2" =~ ^[1-5][0-9]{2}$ ]]; then
        echo "生态可达性=ok:claude.ai:$r1 api:$r2"
    else
        echo "生态可达性=fail:claude.ai:$r1 api:$r2"
    fi
}

# 一键修复:按项自动修复,每步输出结果
fix() {
    echo "FIX:开始一键修复"

    # A. 代理内核 + TUN
    if ! pgrep -f verge-mihomo >/dev/null 2>&1; then
        echo "FIX:正在启动 Clash Verge..."
        open -a "Clash Verge"
    fi
    for i in $(seq 1 40); do
        pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up && break
        sleep 1
    done
    if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
        echo "FIX:代理内核+TUN ✓"
    else
        V="$CLASH_DIR/verge.yaml"
        if [ -f "$V" ] && grep -q '^enable_tun_mode: false' "$V"; then
            echo "FIX:检测到 TUN 开关被关闭,正在恢复..."
            osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
            sleep 3
            sed -i '' 's/^enable_tun_mode: false/enable_tun_mode: true/' "$V"
            open -a "Clash Verge"
            for i in $(seq 1 40); do
                tun_up && break
                sleep 1
            done
        fi
        if pgrep -f verge-mihomo >/dev/null 2>&1 && tun_up; then
            echo "FIX:代理内核+TUN ✓(已恢复TUN开关)"
        else
            echo "FIX:代理内核/TUN ✗(请打开 Clash Verge 检查节点/线路)"
        fi
    fi

    # B. 时区/IPv6/DNS缓存/保镖(需管理员权限,会弹一次密码框)
    tz=$(readlink /etc/localtime 2>/dev/null)
    v6=$(networksetup -getinfo Wi-Fi 2>/dev/null | grep -i '^IPv6:')
    adminCmds=""
    [ "$tz" != "/var/db/timezone/zoneinfo/$TZ_TARGET" ] && adminCmds="${adminCmds}/usr/sbin/systemsetup -settimezone $TZ_TARGET; "
    echo "$v6" | grep -qi 'off' || adminCmds="${adminCmds}networksetup -setv6off Wi-Fi; "
    if ! launchctl print system/local.claude-bodyguard >/dev/null 2>&1; then
        adminCmds="${adminCmds}cp $HOME/.local/bin/local.claude-bodyguard.plist /Library/LaunchDaemons/ && chown root:wheel /Library/LaunchDaemons/local.claude-bodyguard.plist && launchctl bootstrap system /Library/LaunchDaemons/local.claude-bodyguard.plist; "
    fi
    if [ -n "$adminCmds" ]; then
        adminCmds="${adminCmds}dscacheutil -flushcache; killall -HUP mDNSResponder"
        echo "FIX:修复时区/IPv6/DNS/保镖(需要密码)..."
        if osascript <<ASEOF >/dev/null 2>&1
do shell script "$adminCmds" with prompt "一键修复需要管理员权限" with administrator privileges
ASEOF
        then
            echo "FIX:时区/IPv6/DNS/保镖 ✓"
        else
            echo "FIX:时区/IPv6/保镖 ✗(取消或失败)"
        fi
    else
        echo "FIX:时区/IPv6/保镖 无需修复 ✓"
    fi

    # B3. Claude 客户端单独设英文(用户级,无需密码;系统首选语言已是英文则跳过)
    syslang=$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2p' | tr -d ' ,"')
    if ! defaults read com.anthropic.claudefordesktop AppleLanguages 2>/dev/null | grep -q 'en-US' && [[ "$syslang" != en* ]]; then
        defaults write com.anthropic.claudefordesktop AppleLanguages -array en-US
        echo "FIX:Claude 客户端语言 → en-US ✓(重启 Claude 后生效)"
    fi

    # B2. 置顶规则缺失 → 重写全局扩展脚本并重启 Clash
    if ! rules_pinned; then
        echo "FIX:重写置顶规则..."
        if pin_rules; then
            osascript -e 'tell application "Clash Verge" to quit' >/dev/null 2>&1
            sleep 3
            open -a "Clash Verge"
            for i in $(seq 1 40); do
                tun_up && break
                sleep 1
            done
            rules_pinned && echo "FIX:置顶规则 ✓" || echo "FIX:置顶规则 ✗"
        fi
    fi

    # C. 出口IP最终验证
    sleep 2
    trace=$(curl -s --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    ip=$(echo "$trace" | grep '^ip=' | cut -d= -f2)
    loc=$(echo "$trace" | grep '^loc=' | cut -d= -f2)
    if [ "$loc" = "US" ]; then
        echo "FIX:出口IP ✓ ($ip)"
    else
        echo "FIX:出口IP ✗ (${ip:-无}/${loc:-未知}) — 可能是节点故障,请到 Clash 里换条线路"
    fi
    echo "FIX:修复流程结束"
}

status() {
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")
    hasA=0; [ -d "$BASE/accounts/A" ] && hasA=1
    hasB=0; [ -d "$BASE/accounts/B" ] && hasB=1
    echo "current=$cur hasA=$hasA hasB=$hasB"
}

quit_claude() {
    pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
    osascript -e 'tell application "Claude" to quit' >/dev/null 2>&1
    for i in $(seq 1 15); do
        pgrep -f "/Applications/Claude.app/Contents/MacOS/Claude" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

archive_current() {
    cur="$1"
    rm -rf "$BASE/accounts/$cur.tmp"
    ditto "$DATA" "$BASE/accounts/$cur.tmp" && rm -rf "$BASE/accounts/$cur" && mv "$BASE/accounts/$cur.tmp" "$BASE/accounts/$cur"
    log "已存档账号$cur"
}

switch_to() {
    target="$1"
    cur="none"; [ -f "$BASE/current" ] && cur=$(cat "$BASE/current")

    # 首次运行:把当前登录中的状态收编为账号A
    if [ "$cur" = "none" ] && [ -d "$DATA" ] && [ -n "$(ls -A "$DATA" 2>/dev/null)" ]; then
        quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }
        archive_current A
        cur="A"; echo "$cur" > "$BASE/current"
        log "首次运行:当前登录状态已收编为账号A"
        echo "NOTE:已将当前登录收编为账号A"
    fi

    if [ "$cur" = "$target" ]; then
        open -a "Claude"
        echo "INFO:当前已是账号$target"
        return 0
    fi

    quit_claude || { echo "FAIL:Claude 未能退出，请手动退出后重试"; return 1; }

    [ "$cur" != "none" ] && [ -d "$DATA" ] && archive_current "$cur"

    rm -rf "$DATA.new"
    if [ -d "$BASE/accounts/$target" ]; then
        ditto "$BASE/accounts/$target" "$DATA.new"
        log "已载入账号$target 存档"
    else
        mkdir -p "$DATA.new"
        log "账号$target 无存档，将以全新状态初始化"
    fi
    rm -rf "$DATA" && mv "$DATA.new" "$DATA"
    echo "$target" > "$BASE/current"

    open -a "Claude"
    log "已切换到账号$target 并启动"
    echo "OK:已切换到账号$target"
    return 0
}

case "${1:-}" in
    check)  check ;;
    checkdetail)
        OUT_FILE="$BASE/last-check.txt"
        {
            echo "# $(date '+%F %T') pid=$$ 开始"
            checkdetail
            echo "# 结束"
        } > "$OUT_FILE" 2>&1
        cat "$OUT_FILE"
        ;;
    fix) fix ;;
    status) status ;;
    switch) switch_to "${2:-}" ;;
    pinrules) pin_rules ;;
    *) echo "用法: claude-switch.sh check|status|switch A|B|checkdetail|fix|pinrules"; exit 2 ;;
esac
