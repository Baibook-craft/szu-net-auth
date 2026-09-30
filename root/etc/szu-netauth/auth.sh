#!/bin/sh
# =============================================================================
#  深大校园网自动认证 · OpenWrt / Kwrt 版
# -----------------------------------------------------------------------------
#  移植自  szu-net-auth-win/src/CampusAuth.cs          （C# WinForms 桌面版）
#  其原始逻辑来自  szu-network-connecter/src/js/login-post.js  （浏览器插件）
#
#  依赖：busybox sh / curl / logger / jsonfilter / ubus
#        —— 全部为 Kwrt 自带，不新增任何 opkg 包。
#
#  与 C# 版的两处**有意修正**：
#    1) 校园网判定补认 172.17. 段。C# 版只认 172.30.，而本路由器 WAN 恰在
#       172.17.x.x/23（当初靠后面的 TCP 探测歪打正着才没出错）。
#    2) ret_code 解析兼容「值两侧带引号」。实测 eportal 会返回
#       "ret_code":"2"（字符串），C# 的 \s*(-?\d+) 匹配失败 → 把「IP 已在线」
#       误判为登录失败。本版用两条 sed 交替匹配，带/不带引号都能解析。
#
#  另外新增（C# 版没有）：
#    - 断电重启友好：开机即检测一次；WAN 还没拿到地址时用短轮询等待，
#      不落入「不在校园网」的长周期（否则来电后要等一小时才认证）
#    - 重连节奏可控：离线后每 retry_interval 秒试一次，单轮最多 retry_max 次
#      （默认 60 秒 / 5 次）；用尽即停手，回到 net_check 常规检测周期
#      （默认 3600 秒 = 60 分钟）。设计目标是「少打扰、不触发风控」。
#    - 双判据探测：HTTP 为权威判据，ICMP 用于给「为什么离线」分类诊断
#      （ICMP 强制 -4，见 ping_probe 注释里的原因）
#    - 防连点闸门：两次登录之间的绝对最小间隔（login_min_interval）
#    - 心跳看门狗：补 procd respawn 抓不到「进程卡死」的短板
#    - 所有出网请求加 --noproxy '*'，避免被本机 passwall/xray 代理层接管
# =============================================================================

export PATH=/usr/sbin:/usr/bin:/sbin:/bin

TAG=szu-netauth
CONF_PKG=szu-netauth
CONF_SEC=global

STATE_DIR=/var/run/szu-netauth
STATUS_FILE=$STATE_DIR/status.json
HEARTBEAT=$STATE_DIR/heartbeat
WAKE_FILE=$STATE_DIR/wake
LOGIN_TS_FILE=$STATE_DIR/last_login
FAIL_FILE=$STATE_DIR/fail_count
PERSIST_LOG=/etc/szu-netauth/state.log

EPORTAL_BASE='http://172.30.255.42:801'
EPORTAL_LOGIN="$EPORTAL_BASE/eportal/portal/login"
DRCOM_WIFI_URL='https://drcom.szu.edu.cn/a70.htm'
DRCOM_NTH_URL='http://172.30.255.2/0.htm'
NCSI_URL='http://www.msftconnecttest.com/connecttest.txt'
GEN204_URL='http://connect.rom.miui.com/generate_204'

UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) SZUNetAuth/1.0'

# 开机 / WAN 重连期间「等接口拿到地址」的轮询间隔。
# 必须远小于 net_check：断电来电后 WAN 一般十几秒内就绪，若这里落入
# 「不在校园网」那条分支（等 campus_check，默认一小时），就会出现
# 「开机后一小时才认证」的尴尬。
WAN_READY_WAIT=10

# 看门狗阈值：心跳停滞超过这个秒数即认为循环卡死，主动退出交给 procd 重启。
# 分片睡眠期间每 5 秒刷新一次心跳，所以阈值只需大于「单轮工作阶段」的
# 耗时上界（各 curl -m 之和约 40 秒 + ping 2 秒），留约 3 倍余量。
WATCHDOG_LIMIT=180

# ICMP 探测等待第一个回包的秒数（BusyBox ping 的 -W）。实测不可达地址
# 会在 2 秒内返回（退出码 1），所以离线时也不会拖长本轮检测。
PING_TIMEOUT=2

# 旧 Drcom 线路的响应是 GBK 编码。本固件**没有 iconv**，所以关键字改用
# GBK 字节常量直接匹配原始字节 —— 比转码更可靠（响应永远是 GBK）。
# 字节由本机 Python 精确生成：'认证成功页'.encode('gbk') 等，见 DEPLOY.md。
GBK_OK1=$(printf '\310\317\326\244\263\311\271\246\322\263')     # 认证成功页
GBK_OK2=$(printf '\265\307\302\274\263\311\271\246\264\260')     # 登录成功窗
GBK_INFO1=$(printf '\320\305\317\242\322\263')                   # 信息页
GBK_INFO2=$(printf '\320\305\317\242\267\265\273\330\264\260')   # 信息返回窗

# 全局状态（sh 没有多返回值，用全局变量传递）
LOGIN_OK=0
LOGIN_MSG=''
WANIP=''
PING_OK=''        # ''=本轮未测；1=ICMP 通；0=ICMP 不通
PING_MS=''        # ICMP 往返毫秒（取得到才有值）
OFFLINE_KIND=''   # 离线成因：hijack=被门户劫持（典型未认证）/ noroute=网络层不通

# -----------------------------------------------------------------------------
# 小工具
# -----------------------------------------------------------------------------

nlog() { logger -t "$TAG" "$*"; }

# 所有出网请求统一入口：禁用代理环境变量 + 固定 UA（对齐 C# 版的 UserAgent）
curlx() { curl -s --noproxy '*' -A "$UA" "$@"; }

clamp() {
	_v=$1; _lo=$2; _hi=$3
	case "$_v" in ''|*[!0-9]*) _v=$_lo ;; esac
	[ "$_v" -lt "$_lo" ] && _v=$_lo
	[ "$_v" -gt "$_hi" ] && _v=$_hi
	printf '%s' "$_v"
}

# JSON 字符串转义（只处理 \\ 和 " 与换行；我们写出的字段都很短）
jesc() {
	printf '%s' "$1" | tr -d '\n\r' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# 从 JSONP/JSON 文本里取**数值**字段，兼容 "key":"2" 与 "key":2 两种写法
# （这正是 C# 版那个 bug 的修法：实测 eportal 会把 ret_code 当字符串返回）
jnum() {
	_jn=$(printf '%s' "$2" \
	  | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([-0-9][0-9]*\)".*/\1/p' \
	  | head -n1)
	if [ -z "$_jn" ]; then
		_jn=$(printf '%s' "$2" \
		  | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([-0-9][0-9]*\).*/\1/p' \
		  | head -n1)
	fi
	printf '%s' "$_jn"
}

# 从 JSON 文本里取**字符串**字段
jstr() {
	printf '%s' "$2" \
	  | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
	  | head -n1
}

# 错误信息翻译（沿用 C# TranslateError 的表）
tr_msg() {
	case "$1" in
		'ldap auth error') printf '%s' '账号或密码错误（ldap auth error）' ;;
		'error hid')       printf '%s' '登录行为异常，请过几分钟后再试（error hid）' ;;
		*)                 printf '%s' "$1" ;;
	esac
}

# 持久日志（默认关；开启会写 flash，超 128KB 轮转一次）
plog() {
	[ "$PERSIST_LOG_ON" = "1" ] || return 0
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$PERSIST_LOG"
	_sz=$(wc -c < "$PERSIST_LOG" 2>/dev/null)
	if [ -n "$_sz" ] && [ "$_sz" -gt 131072 ]; then
		mv -f "$PERSIST_LOG" "$PERSIST_LOG.1"
	fi
}

# -----------------------------------------------------------------------------
# 配置读取（每轮循环重读，因此改配置无需重启服务，最多一个周期后生效）
# -----------------------------------------------------------------------------

cfg() {
	config_load "$CONF_PKG"
	config_get_bool ENABLED        "$CONF_SEC" enabled            1
	config_get      CARDID         "$CONF_SEC" cardid             ''
	config_get      PASSWORD       "$CONF_SEC" password           ''
	config_get      NET_CHECK      "$CONF_SEC" net_check          3600
	config_get      CAMPUS_CHECK   "$CONF_SEC" campus_check       3600
	config_get      RETRY_INTERVAL "$CONF_SEC" retry_interval     60
	config_get      RETRY_MAX      "$CONF_SEC" retry_max          5
	config_get      NET_METHOD     "$CONF_SEC" net_check_method   'http+ping'
	config_get      PING_HOST      "$CONF_SEC" ping_host          'www.baidu.com'
	config_get      LOGIN_PATHS    "$CONF_SEC" login_paths        'eportal'
	config_get      LOGIN_MIN      "$CONF_SEC" login_min_interval 30
	config_get_bool PERSIST_LOG_ON "$CONF_SEC" persist_log        0

	NET_CHECK=$(clamp "$NET_CHECK" 30 86400)
	CAMPUS_CHECK=$(clamp "$CAMPUS_CHECK" 30 86400)
	RETRY_INTERVAL=$(clamp "$RETRY_INTERVAL" 10 3600)
	RETRY_MAX=$(clamp "$RETRY_MAX" 1 50)
	LOGIN_MIN=$(clamp "$LOGIN_MIN" 10 3600)

	case "$NET_METHOD" in
		http|ping|http+ping) ;;
		*) NET_METHOD='http+ping' ;;
	esac
	[ -z "$PING_HOST" ] && PING_HOST='www.baidu.com'
	[ -z "$LOGIN_PATHS" ] && LOGIN_PATHS=eportal
}

# 本轮重连已失败的次数（存文件，跨 sleep 保留）。
# 语义：**当前这一轮**的计数。登录成功、放弃、或手动触发都会清零。
fail_count() {
	_f=$(cat "$FAIL_FILE" 2>/dev/null)
	case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
	printf '%s' "$_f"
}

reset_fail() {
	rm -f "$FAIL_FILE"
}

# -----------------------------------------------------------------------------
# 环境 / 联网探测
# -----------------------------------------------------------------------------

wan_ip() {
	_ip=$(ubus call network.interface.wan status 2>/dev/null \
	      | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
	[ -z "$_ip" ] && _ip=$(ip -4 addr show dev wan 2>/dev/null \
	      | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -n1)
	printf '%s' "$_ip"
}

# 是否处于校园网：WAN 地址落在校园网段（快速路径），否则 curl 探 eportal
is_campus() {
	case "$1" in
		172.17.*|172.30.*) return 0 ;;
	esac
	curlx -m 3 -o /dev/null "$EPORTAL_BASE/" 2>/dev/null
}

# ICMP 探测（轻量、快，但**必须 -4**）。
#
# 为什么必须 -4：本机 IPv6 走独立的 wan6 接口，实测 ping 域名时默认解析到
# 2409:... 的 v6 地址。而校园网的 IPv6 常常不经过认证（或走另一套通道），
# 于是会出现「IPv4 已掉线、ping 却仍通」的假在线 —— 那是自动重连最大的
# 敌人：判据说在线，就永远不会去重新认证。加 -4 强制走 IPv4，才与认证
# 状态对应。（实测见 DEPLOY.md）
#
# 结果写进全局变量：PING_OK=1 通（并给出往返毫秒）；PING_OK=0 不通。
ping_probe() {
	PING_OK=''; PING_MS=''
	[ -z "$PING_HOST" ] && return 1
	_o=$(ping -4 -c 1 -W "$PING_TIMEOUT" "$PING_HOST" 2>/dev/null)
	if printf '%s' "$_o" | grep -q 'bytes from'; then
		PING_OK=1
		PING_MS=$(printf '%s' "$_o" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -n1)
		return 0
	fi
	PING_OK=0
	return 1
}

# HTTP 层探测（**权威判据**）。不跟随重定向：被认证门户 302 劫持即判失败
# （对应 C# 版 HttpWebRequest.AllowAutoRedirect = false）
http_probe() {
	_r=$(curlx -m 6 -w '\n%{http_code}' "$NCSI_URL" 2>/dev/null)
	_code=$(printf '%s' "$_r" | tail -n1)
	_body=$(printf '%s' "$_r" | sed '$d')
	if [ "$_code" = "200" ] && printf '%s' "$_body" | grep -q 'Microsoft Connect Test'; then
		return 0
	fi
	_c2=$(curlx -m 6 -o /dev/null -w '%{http_code}' "$GEN204_URL" 2>/dev/null)
	[ "$_c2" = "204" ]
}

# 是否已认证在线。判定方式由 net_check_method 决定：
#   http      只用 HTTP（最快，不依赖 ICMP；ICMP 被禁的环境用这个）
#   http+ping HTTP 为判据，再用 ICMP 给「为什么离线」分类（默认）
#   ping      只用 ICMP（不推荐：ICMP 可能被校园网关丢弃，另有 v6 绕过坑）
# 无论哪种方式，只要做了 ICMP 探测，结果就留在 PING_OK / PING_MS 里供展示。
#
# 注意：ICMP 通**不能**单独推出「已认证」—— 门户可能只劫持 TCP/HTTP 而
# 放行 ICMP。所以这里只在 HTTP 判失败之后，用 ICMP 去区分成因，绝不
# 用它把「离线」翻成「在线」。
is_online() {
	OFFLINE_KIND=''

	if [ "$NET_METHOD" = "ping" ]; then
		if ping_probe; then return 0; fi
		OFFLINE_KIND=noroute
		return 1
	fi

	if http_probe; then
		# 在线：若配了双判据，顺带采一次 ICMP 用于状态页展示网络质量
		[ "$NET_METHOD" = "http+ping" ] && ping_probe
		return 0
	fi

	# HTTP 判离线 → 用 ICMP 区分两种成因（比笼统一个「离线」有用得多）
	if [ "$NET_METHOD" = "http+ping" ]; then
		if ping_probe; then
			OFFLINE_KIND=hijack    # ICMP 通但 HTTP 被劫持 → 典型的未认证
		else
			OFFLINE_KIND=noroute   # ICMP 也不通 → 网络层就没通
		fi
	fi
	return 1
}

# -----------------------------------------------------------------------------
# 三条登录线路
# -----------------------------------------------------------------------------

# 新版 eportal（本网段实测唯一可达）
# GET /eportal/portal/login?callback=dr1003&...&user_account=,0,{卡号}&...
# 返回 dr1003({"result":1,...});  → result==1 成功；ret_code==2 表示 IP 已在线
login_eportal() {
	_resp=$(curlx -m 8 -G "$EPORTAL_LOGIN" \
		--data-urlencode 'callback=dr1003' \
		--data-urlencode 'login_method=1' \
		--data-urlencode "user_account=,0,$CARDID" \
		--data-urlencode "user_password=$PASSWORD" \
		--data-urlencode 'wlan_user_ip=' \
		--data-urlencode 'wlan_user_ipv6=' \
		--data-urlencode 'wlan_user_mac=000000000000' \
		--data-urlencode 'wlan_ac_ip=' \
		--data-urlencode 'wlan_ac_name=' \
		--data-urlencode 'jsVersion=4.1.3' \
		--data-urlencode 'terminal_type=1' \
		--data-urlencode 'lang=zh' \
		--data-urlencode 'v=10353' 2>/dev/null)

	if [ -z "$_resp" ]; then
		LOGIN_MSG="eportal: 无响应（线路不可达或超时）"
		return 1
	fi

	_result=$(jnum result   "$_resp")
	_ret=$(jnum ret_code "$_resp")
	_msg=$(jstr msg "$_resp")
	[ -n "$_msg" ] && _msg=$(tr_msg "$_msg")

	if [ "$_result" = "1" ]; then
		LOGIN_MSG='认证成功'
		return 0
	fi
	if [ "$_ret" = "2" ]; then
		LOGIN_MSG="已在线：${_msg:-IP 已在线}"
		return 0
	fi
	if [ -z "$_result" ] && [ -z "$_ret" ]; then
		if printf '%s' "$_resp" | grep -q '成功'; then
			LOGIN_MSG='认证成功（按关键字判定）'
			return 0
		fi
		LOGIN_MSG="eportal: 无法识别的响应：$(printf '%s' "$_resp" | head -c 120)"
		return 1
	fi
	LOGIN_MSG="eportal: ${_msg:-未知错误}（result=${_result:-空} ret_code=${_ret:-空}）"
	return 1
}

# 旧 Drcom 协议（wifi = drcom.szu.edu.cn/a70.htm，nth = 172.30.255.2/0.htm 有线）
# 注意：本网段（172.17）这两条实测不可达，默认配置未启用。
login_drcom() {
	case "$1" in
		wifi) _url=$DRCOM_WIFI_URL; _key='123456' ;;
		*)    _url=$DRCOM_NTH_URL;  _key='%B5%C7%A1%A1%C2%BC' ;;
	esac

	_raw=$(curlx -m 8 -k -X POST \
		-H 'Content-Type: application/x-www-form-urlencoded' \
		--data-urlencode "DDDDD=$CARDID" \
		--data-urlencode "upass=$PASSWORD" \
		--data "0MKKey=$_key" \
		"$_url" 2>/dev/null)

	if [ -z "$_raw" ]; then
		LOGIN_MSG="$1: 无响应（线路不可达或超时）"
		return 1
	fi

	if printf '%s' "$_raw" | grep -qa -- "$GBK_OK1" \
	|| printf '%s' "$_raw" | grep -qa -- "$GBK_OK2"; then
		LOGIN_MSG='认证成功'
		return 0
	fi

	if printf '%s' "$_raw" | grep -qa -- "$GBK_INFO1" \
	|| printf '%s' "$_raw" | grep -qa -- "$GBK_INFO2"; then
		_m=$(printf '%s' "$_raw" | sed -n "s/.*msga='\([^']*\)'.*/\1/p" | head -n1)
		if [ -z "$_m" ]; then
			LOGIN_MSG='认证成功（有线登录无 msg）'
			return 0
		fi
		LOGIN_MSG="$1: $(tr_msg "$_m")"
		return 1
	fi

	LOGIN_MSG="$1: 无法识别的响应"
	return 1
}

# 按配置顺序尝试，第一条成功即停（C# 是三路并发，只有一条可用时二者等价）
attempt_login() {
	LOGIN_OK=0
	LOGIN_MSG=''
	if [ -z "$CARDID" ] || [ -z "$PASSWORD" ]; then
		LOGIN_MSG='未设置卡号或密码（/etc/config/szu-netauth）'
		return 1
	fi
	for _p in $LOGIN_PATHS; do
		nlog "尝试线路：$_p"
		case "$_p" in
			eportal)    login_eportal      && LOGIN_OK=1 ;;
			drcom_wifi) login_drcom wifi   && LOGIN_OK=1 ;;
			drcom_nth)  login_drcom nth    && LOGIN_OK=1 ;;
			*)          nlog "未知线路：$_p（跳过）" ;;
		esac
		[ "$LOGIN_OK" = "1" ] && break
	done
	date +%s > "$LOGIN_TS_FILE"
	printf '%s' "$LOGIN_MSG" > "$STATE_DIR/last_login_result"
	return $((1 - LOGIN_OK))
}

# -----------------------------------------------------------------------------
# 状态文件（内存盘，不进 flash）
# -----------------------------------------------------------------------------

write_status() {
	# $1 state  $2 detail  $3 color  $4 campus  $5 online  $6 interval
	mkdir -p "$STATE_DIR"
	_st=$1; _de=$2; _co=$3; _ca=$4; _on=$5; _iv=$6
	_now=$(date +%s)
	_ll=$(cat "$LOGIN_TS_FILE" 2>/dev/null); [ -z "$_ll" ] && _ll=0
	_lr=$(cat "$STATE_DIR/last_login_result" 2>/dev/null)
	_fc=$(fail_count)
	_nr=$(cat "$STATE_DIR/next_retry" 2>/dev/null); [ -z "$_nr" ] && _nr=0
	_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null); [ -z "$_pid" ] && _pid=0
	_dr=0
	[ "$_pid" != "0" ] && kill -0 "$_pid" 2>/dev/null && _dr=1

	# ICMP 结果：-1 = 本轮未测，0 = 不通，1 = 通
	_po=-1
	[ "$PING_OK" = "1" ] && _po=1
	[ "$PING_OK" = "0" ] && _po=0
	_pm=${PING_MS:-0}
	case "$_pm" in ''|*[!0-9.]*) _pm=0 ;; esac

	cat > "$STATUS_FILE.tmp" <<EOF
{"ts":$_now,"time":"$(date '+%Y-%m-%d %H:%M:%S')","state":"$_st","detail":"$(jesc "$_de")","color":"$_co","enabled":$ENABLED,"campus":$_ca,"online":$_on,"wan_ip":"$(jesc "$WANIP")","net_check":$NET_CHECK,"campus_check":$CAMPUS_CHECK,"login_paths":"$(jesc "$LOGIN_PATHS")","last_check":$_now,"last_login":$_ll,"last_login_result":"$(jesc "$_lr")","fail_count":$_fc,"retry_max":$RETRY_MAX,"retry_interval":$RETRY_INTERVAL,"next_retry":$_nr,"daemon_pid":$_pid,"daemon_running":$_dr,"interval":$_iv,"ping_ok":$_po,"ping_ms":$_pm,"ping_host":"$(jesc "$PING_HOST")","net_check_method":"$(jesc "$NET_METHOD")","offline_kind":"$(jesc "$OFFLINE_KIND")"}
EOF
	mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# -----------------------------------------------------------------------------
# 常驻循环
# -----------------------------------------------------------------------------

# 分片睡眠：能被 --trigger 立刻打断，语义对齐 C# MonitorService 的 500ms 分片等待
sleep_loop() {
	_total=$1
	[ "$_total" -lt 1 ] && _total=1
	_left=$_total
	while [ "$_left" -gt 0 ]; do
		_slice=5
		[ "$_left" -lt "$_slice" ] && _slice=$_left
		sleep "$_slice"
		_left=$((_left - _slice))
		# 每个分片刷一次心跳：这样看门狗能区分「在长睡」与「卡死了」——
		# 只要还在睡，心跳就在走；一旦某处阻塞住，心跳停止，超时即重启。
		touch "$HEARTBEAT"
		if [ -f "$WAKE_FILE" ]; then
			nlog "收到手动唤醒信号（$_left 秒剩余）"
			return 0
		fi
	done
}

daemon_main() {
	mkdir -p "$STATE_DIR"
	echo $$ > "$STATE_DIR/daemon.pid"
	trap 'nlog "收到终止信号，退出守护循环"; rm -f "$STATE_DIR/daemon.pid"; exit 0' TERM INT
	nlog "守护循环启动（pid $$）—— 开机即检测一次"

	PREV_INTERVAL=60
	while :; do
		# ---- 看门狗：心跳停滞即自杀，交给 procd 重启 ----
		# 心跳由 sleep_loop 的分片（每 5 秒）持续刷新，所以「心跳停止」就等于
		# 「循环卡住了」—— 无论卡在 curl、ubus 还是别处都能被发现。
		_now=$(date +%s)
		if [ -f "$HEARTBEAT" ]; then
			_hb=$(stat -c %Y "$HEARTBEAT" 2>/dev/null)
			[ -z "$_hb" ] && _hb=$_now
			if [ $((_now - _hb)) -gt "$WATCHDOG_LIMIT" ]; then
				nlog "看门狗：心跳已停滞 $((_now - _hb)) 秒（阈值 ${WATCHDOG_LIMIT}s），主动退出交给 procd 重启"
				rm -f "$STATE_DIR/daemon.pid"
				exit 1
			fi
		fi

		cfg
		WANIP=$(wan_ip)
		# 每轮重置本轮探测痕迹，避免状态页显示上一轮的陈旧结果
		PING_OK=''; PING_MS=''; OFFLINE_KIND=''

		WAKE_REQ=$(cat "$WAKE_FILE" 2>/dev/null)
		rm -f "$WAKE_FILE"

		# ---- 停用 ----
		if [ "$ENABLED" != "1" ]; then
			write_status disabled '已停用（配置中 enabled=0）' grey 0 0 60
			sleep_loop 60
			PREV_INTERVAL=60
			continue
		fi

		# ---- WAN 还没拿到地址 ----
		# 断电重启后最常见的头几轮。**绝不能**落入下面「不在校园网」那条
		# 分支：那里等的是 campus_check（默认一小时），于是来电后要等整整
		# 一小时才会去认证。这里用短轮询等接口就绪，就绪后立刻检测/登录。
		if [ -z "$WANIP" ]; then
			# 只在**首次**进入等待时记一条日志（用 PREV_INTERVAL 判重），
			# 否则接口迟迟不就绪时每 10 秒就会刷一条日志。
			if [ "$PREV_INTERVAL" != "$WAN_READY_WAIT" ]; then
				nlog "WAN 尚未获取地址，${WAN_READY_WAIT} 秒一轮等待接口就绪"
			fi
			write_status waiting "WAN 尚未获取地址，${WAN_READY_WAIT} 秒后重试（等待接口就绪）" grey 0 0 "$WAN_READY_WAIT"
			touch "$HEARTBEAT"
			sleep_loop "$WAN_READY_WAIT"
			PREV_INTERVAL=$WAN_READY_WAIT
			continue
		fi

		# ---- 不在校园网 ----
		if ! is_campus "$WANIP"; then
			reset_fail
			rm -f "$STATE_DIR/next_retry"
			write_status nocampus "不在校园网（WAN $WANIP），待接入后自动重试" grey 0 0 "$CAMPUS_CHECK"
			touch "$HEARTBEAT"
			sleep_loop "$CAMPUS_CHECK"
			PREV_INTERVAL=$CAMPUS_CHECK
			continue
		fi

		# ---- 在线则只记录，不登录（手动「立即登录」时跳过此判断）----
		_force=0
		[ "$WAKE_REQ" = "login" ] && _force=1

		if [ "$_force" = "0" ] && is_online; then
			reset_fail
			rm -f "$STATE_DIR/next_retry"
			write_status online "校园网在线（WAN $WANIP）" green 1 1 "$NET_CHECK"
			touch "$HEARTBEAT"
			_pm_txt=''
			[ -n "$PING_MS" ] && _pm_txt="，ICMP ${PING_MS}ms"
			nlog "在线（WAN $WANIP${_pm_txt}），${NET_CHECK} 秒后再次检测"
			sleep_loop "$NET_CHECK"
			PREV_INTERVAL=$NET_CHECK
			continue
		fi

		# ================= 判定离线：进入重连轮次 =================
		# 「一轮」= 最多 RETRY_MAX 次尝试，每次间隔 RETRY_INTERVAL 秒。
		# 用尽即停手，回到 NET_CHECK 常规周期 —— 刻意不做无限重试，
		# 免得在断网期间反复撞校园网风控（error hid）。
		_fc=$(fail_count)

		if [ "$_force" = "1" ]; then
			# 手动「立即登录」= 开新一轮，计数清零重来
			_fc=0; reset_fail
			nlog "手动触发登录（跳过在线判断，重连计数清零）"
		fi

		# 本轮次数已用尽 → 停手，等下一个常规周期
		if [ "$_fc" -ge "$RETRY_MAX" ]; then
			nlog "本轮已连续失败 $_fc 次（上限 ${RETRY_MAX}），停止重连；转入 ${NET_CHECK} 秒常规检测"
			plog "放弃重连：连续 $_fc 次未成功"
			reset_fail
			rm -f "$STATE_DIR/next_retry"
			write_status giveup "已连续尝试 $_fc 次仍未成功，停止重连；${NET_CHECK} 秒后再检测" red 1 0 "$NET_CHECK"
			touch "$HEARTBEAT"
			sleep_loop "$NET_CHECK"
			PREV_INTERVAL=$NET_CHECK
			continue
		fi

		# ---- 闸门：两次登录之间的绝对下限（防连点 / 防风控）----
		_now=$(date +%s)
		_ll=$(cat "$LOGIN_TS_FILE" 2>/dev/null); [ -z "$_ll" ] && _ll=0
		_elapsed=$((_now - _ll))
		if [ "$_elapsed" -lt "$LOGIN_MIN" ]; then
			_wait=$((LOGIN_MIN - _elapsed))
			nlog "登录闸门：距上次登录仅 $_elapsed 秒（下限 ${LOGIN_MIN} 秒），等待 ${_wait} 秒"
			touch "$HEARTBEAT"
			sleep_loop "$_wait"
			PREV_INTERVAL=$_wait
			continue
		fi

		# ---- 发起登录（本轮第 _fc+1 次）----
		_n=$((_fc + 1))
		_kind=''
		[ "$OFFLINE_KIND" = "hijack" ]  && _kind='（ping 通、HTTP 被劫持 → 典型的未认证）'
		[ "$OFFLINE_KIND" = "noroute" ] && _kind='（ping 也不通 → 网络层可能有问题）'

		if [ "$_force" = "1" ]; then
			write_status offline "手动触发登录（第 ${_n}/${RETRY_MAX} 次）…" orange 1 0 "$RETRY_INTERVAL"
		else
			nlog "检测到离线（WAN $WANIP）$_kind"
			write_status offline "检测到离线${_kind}；第 ${_n}/${RETRY_MAX} 次尝试登录…" orange 1 0 "$RETRY_INTERVAL"
		fi

		attempt_login

		if [ "$LOGIN_OK" = "1" ]; then
			nlog "登录成功（本轮第 ${_n} 次尝试）：$LOGIN_MSG"
			plog "登录成功（本轮第 ${_n} 次）：$LOGIN_MSG"
			reset_fail
			rm -f "$STATE_DIR/next_retry"
			write_status online "已重新认证（$LOGIN_MSG）" green 1 1 "$NET_CHECK"
			touch "$HEARTBEAT"
			sleep_loop "$NET_CHECK"
			PREV_INTERVAL=$NET_CHECK
			continue
		fi

		# ---- 本次失败 ----
		printf '%s' "$_n" > "$FAIL_FILE"
		nlog "登录失败（本轮第 ${_n}/${RETRY_MAX} 次）：$LOGIN_MSG"

		if [ "$_n" -ge "$RETRY_MAX" ]; then
			# 第 RETRY_MAX 次也失败 → 直接进停手态，不必再空等一个间隔
			nlog "本轮重连次数已用尽（${_n}/${RETRY_MAX}），停止重连；转入 ${NET_CHECK} 秒常规检测"
			plog "放弃重连：连续 $_n 次未成功（末次：$LOGIN_MSG）"
			reset_fail
			rm -f "$STATE_DIR/next_retry"
			write_status giveup "已连续尝试 $_n 次仍未成功（末次：$LOGIN_MSG），停止重连；${NET_CHECK} 秒后再检测" red 1 0 "$NET_CHECK"
			touch "$HEARTBEAT"
			sleep_loop "$NET_CHECK"
			PREV_INTERVAL=$NET_CHECK
		else
			plog "登录失败（本轮第 $_n/${RETRY_MAX} 次）：$LOGIN_MSG"
			echo $(( $(date +%s) + RETRY_INTERVAL )) > "$STATE_DIR/next_retry"
			write_status fail "登录失败（第 ${_n}/${RETRY_MAX} 次）：$LOGIN_MSG；${RETRY_INTERVAL} 秒后重试" red 1 0 "$RETRY_INTERVAL"
			touch "$HEARTBEAT"
			sleep_loop "$RETRY_INTERVAL"
			PREV_INTERVAL=$RETRY_INTERVAL
		fi
	done
}

# -----------------------------------------------------------------------------
# 单次执行 / 手动命令
# -----------------------------------------------------------------------------

once_main() {
	mkdir -p "$STATE_DIR"
	cfg
	WANIP=$(wan_ip)
	PING_OK=''; PING_MS=''; OFFLINE_KIND=''

	if [ "$ENABLED" != "1" ]; then
		echo '已停用（enabled=0），未做任何操作'
		write_status disabled '已停用（配置中 enabled=0）' grey 0 0 60
		return 0
	fi
	if [ -z "$WANIP" ]; then
		echo 'WAN 尚未获取地址，未做任何操作'
		write_status waiting 'WAN 尚未获取地址' grey 0 0 "$WAN_READY_WAIT"
		touch "$HEARTBEAT"
		return 0
	fi
	if ! is_campus "$WANIP"; then
		echo "不在校园网（WAN $WANIP），未做任何操作"
		write_status nocampus "不在校园网（WAN $WANIP）" grey 0 0 "$CAMPUS_CHECK"
		touch "$HEARTBEAT"
		return 0
	fi
	if is_online; then
		reset_fail
		rm -f "$STATE_DIR/next_retry"
		echo "在线（WAN $WANIP），无需登录"
		write_status online "校园网在线（WAN $WANIP）" green 1 1 "$NET_CHECK"
		touch "$HEARTBEAT"
		return 0
	fi

	_kind=''
	[ "$OFFLINE_KIND" = "hijack" ]  && _kind='（ping 通、HTTP 被劫持 → 典型的未认证）'
	[ "$OFFLINE_KIND" = "noroute" ] && _kind='（ping 也不通 → 网络层可能有问题）'
	echo "离线${_kind}，开始登录…"

	attempt_login
	if [ "$LOGIN_OK" = "1" ]; then
		reset_fail
		rm -f "$STATE_DIR/next_retry"
		echo "登录成功：$LOGIN_MSG"
		nlog "（--once）登录成功：$LOGIN_MSG"
		write_status online "已重新认证（$LOGIN_MSG）" green 1 1 "$NET_CHECK"
		return 0
	fi
	# --once 是一次性动作，**不写**轮次计数文件（那是常驻循环的状态），
	# 否则会和正在跑的守护循环互相干扰。
	echo "登录失败：$LOGIN_MSG"
	nlog "（--once）登录失败：$LOGIN_MSG"
	write_status fail "登录失败：$LOGIN_MSG" red 1 0 "$NET_CHECK"
	return 1
}

login_main() {
	mkdir -p "$STATE_DIR"
	cfg
	WANIP=$(wan_ip)
	attempt_login
	if [ "$LOGIN_OK" = "1" ]; then
		reset_fail
		echo "登录结果：成功 — $LOGIN_MSG"
		nlog "（--login）登录成功：$LOGIN_MSG"
		return 0
	fi
	echo "登录结果：失败 — $LOGIN_MSG"
	nlog "（--login）登录失败：$LOGIN_MSG"
	return 1
}

check_main() {
	cfg
	WANIP=$(wan_ip)
	PING_OK=''; PING_MS=''; OFFLINE_KIND=''

	echo '=== 1. 环境检测 ==='
	printf 'WAN 地址        : %s\n' "${WANIP:-（无）}"
	if is_campus "$WANIP"; then
		echo '校园网判定      : 是'
	else
		echo '校园网判定      : 否'
	fi

	echo '=== 2. 联网探测 ==='
	printf '判定方式        : %s\n' "$NET_METHOD"
	if is_online; then
		echo '联网状态        : 在线（已认证）'
	else
		case "$OFFLINE_KIND" in
			hijack)  echo '联网状态        : 离线 —— ping 通但 HTTP 被劫持（典型的未认证）' ;;
			noroute) echo '联网状态        : 离线 —— ping 也不通（网络层可能有问题）' ;;
			*)       echo '联网状态        : 离线' ;;
		esac
	fi
	case "$PING_OK" in
		1) printf 'ICMP(%s)   : 通，%s ms\n' "$PING_HOST" "${PING_MS:-?}" ;;
		0) printf 'ICMP(%s)   : 不通\n' "$PING_HOST" ;;
		*) printf 'ICMP(%s)   : 未测（当前判定方式不做 ICMP）\n' "$PING_HOST" ;;
	esac

	echo '=== 3. 认证服务器可达性 ==='
	for _u in "$EPORTAL_BASE/" "$DRCOM_NTH_URL" "$DRCOM_WIFI_URL"; do
		_c=$(curlx -m 4 -o /dev/null -w '%{http_code}' "$_u" 2>/dev/null)
		_rc=$?
		printf '  %-36s HTTP=%-6s curl退出码=%s\n' "$_u" "${_c:-–}" "$_rc"
	done

	echo '=== 4. 当前配置 ==='
	printf 'enabled=%s  net_check=%s  campus_check=%s\n' "$ENABLED" "$NET_CHECK" "$CAMPUS_CHECK"
	printf 'retry_interval=%s  retry_max=%s\n' "$RETRY_INTERVAL" "$RETRY_MAX"
	printf 'net_check_method=%s  ping_host=%s  ping_timeout=%s\n' "$NET_METHOD" "$PING_HOST" "$PING_TIMEOUT"
	printf 'login_paths=%s  login_min_interval=%s  persist_log=%s\n' \
		"$LOGIN_PATHS" "$LOGIN_MIN" "$PERSIST_LOG_ON"
	printf 'cardid=%s  password=%s\n' \
		"$([ -n "$CARDID" ] && echo 已设置 || echo 未设置)" \
		"$([ -n "$PASSWORD" ] && echo 已设置 || echo 未设置)"

	echo '=== 5. 重连轮次 ==='
	_now=$(date +%s)
	_ll=$(cat "$LOGIN_TS_FILE" 2>/dev/null); [ -z "$_ll" ] && _ll=0
	printf 'last_login=%s（%s 秒前）  本轮已失败=%s/%s 次\n' \
		"$_ll" "$((_now - _ll))" "$(fail_count)" "$RETRY_MAX"

	echo '=== 6. 守护进程 ==='
	_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null)
	if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
		echo "守护进程运行中（pid $_pid）"
	else
		echo '守护进程未运行'
	fi
}

status_main() {
	if [ -f "$STATUS_FILE" ]; then
		cat "$STATUS_FILE"
	else
		# 守护进程还没写过状态（例如服务没启动）：给一个兜底结构
		_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null); [ -z "$_pid" ] && _pid=0
		_dr=0
		[ "$_pid" != "0" ] && kill -0 "$_pid" 2>/dev/null && _dr=1
		printf '{"ts":%s,"time":"%s","state":"stopped","detail":"守护进程尚未写入状态（服务未运行或刚启动）","color":"grey","enabled":0,"campus":0,"online":0,"wan_ip":"","net_check":0,"campus_check":0,"login_paths":"","last_check":0,"last_login":0,"last_login_result":"","fail_count":0,"retry_max":0,"retry_interval":0,"next_retry":0,"daemon_pid":%s,"daemon_running":%s,"interval":0,"ping_ok":-1,"ping_ms":0,"ping_host":"","net_check_method":"","offline_kind":""}\n' \
			"$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S')" "$_pid" "$_dr"
	fi
}

tail_main() {
	_n=${1:-50}
	case "$_n" in ''|*[!0-9]*) _n=50 ;; esac
	[ "$_n" -gt 500 ] && _n=500
	# 运行日志走 syslog 的内存环形缓冲（不写 flash）；落盘日志存在时一并附上
	if [ "$PERSIST_LOG_ON" = "1" ] && [ -f "$PERSIST_LOG" ]; then
		echo "----- 持久日志（末尾 $_n 行）：$PERSIST_LOG -----"
		tail -n "$_n" "$PERSIST_LOG"
		echo "----- 系统日志（tag=$TAG）-----"
	fi
	logread -e "$TAG" 2>/dev/null | tail -n "$_n"
}

# 唤醒常驻循环；立即返回（不在 rpcd 里阻塞，避免调用超时）
trigger_main() {
	_what=${1:-check}
	mkdir -p "$STATE_DIR"
	_pid=$(cat "$STATE_DIR/daemon.pid" 2>/dev/null)
	if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
		echo '常驻服务未运行：请先「启用并启动」服务，或在命令行使用 --once'
		return 1
	fi
	case "$_what" in
		login)
			printf '%s' 0 > "$LOGIN_TS_FILE"      # 让闸门立即放行
			rm -f "$FAIL_FILE"
			printf '%s' 'login' > "$WAKE_FILE"
			echo '已请求立即登录（常驻循环最迟 5 秒内响应）'
			;;
		*)
			printf '%s' 'check' > "$WAKE_FILE"
			echo '已请求立即检测（常驻循环最迟 5 秒内响应）'
			;;
	esac
	return 0
}

# -----------------------------------------------------------------------------
# 入口
# -----------------------------------------------------------------------------

. /lib/functions.sh

case "$1" in
	--daemon)       daemon_main ;;
	--once)         once_main ;;
	--login)        login_main ;;
	--check)        check_main ;;
	--status)       status_main ;;
	--tail)         shift; cfg; tail_main "$1" ;;
	--trigger)      shift; cfg; trigger_main "$1" ;;
	-h|--help|help|'')
		sed -n '3,22p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
		;;
	*)
		echo "未知参数：$1（可用：--daemon --once --login --check --status --tail N --trigger [check|login]）" >&2
		exit 2
		;;
esac
