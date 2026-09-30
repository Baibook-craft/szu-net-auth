'use strict';
'require view';
'require poll';
'require fs';
'require ui';
'require rpc';

/*
 * 深大校园网自动认证 · 状态页
 *
 * 设计原则（见 PLAN.md 第 3 节）：本页只是**薄壳** —— 读状态 / 点按钮。
 * 真正的认证逻辑全在 /etc/szu-netauth/auth.sh 里，所以本页即使报错，
 * 掉线自动重连照常工作。
 *
 * 「立即检测 / 立即登录」按钮走的是 auth.sh --trigger：只写一个唤醒文件就
 * 立刻返回，由常驻循环去做实际的探测与登录。这样不会让 rpcd 的 exec 调用
 * 因为等 20 秒的 curl 而超时。
 */

var AUTH = '/etc/szu-netauth/auth.sh';
var SVC  = 'szu-netauth';

var callRcList = rpc.declare({
	object: 'rc', method: 'list', params: [ 'name' ], expect: { '': {} }
});

var callRcInit = rpc.declare({
	object: 'rc', method: 'init', params: [ 'name', 'action' ], expect: { result: false }
});

// 备用：LuCI 自己的启动项接口。rpcd 的 rc 对象只解析 init 脚本开头有限字节
// （本机实测约 580–640 B），一旦 START 落在窗口外，rc list 会把 start/stop
// 丢掉并且把 enabled 误报成 false。这里用 getInitList 兜住那种情况。
var callInitList = rpc.declare({
	object: 'luci', method: 'getInitList', params: [ 'name' ], expect: { '': {} }
});

var STATE_LABEL = {
	online:   '在线（已认证）',
	offline:  '离线，正在尝试登录',
	fail:     '登录失败，稍后重试',
	giveup:   '已停手：本轮重连失败',
	waiting:  '等待 WAN 获取地址',
	backoff:  '退避等待中',              // 兼容旧版本可能残留的状态值
	nocampus: '不在校园网',
	disabled: '已停用（enabled=0）',
	stopped:  '服务未运行'
};

var OFFLINE_KIND_LABEL = {
	hijack:  'ping 通但 HTTP 被劫持 —— 典型的未认证',
	noroute: 'ping 也不通 —— 网络层可能有问题'
};

var COLOR_HEX = {
	green:  '#2e7d32',
	orange: '#ef6c00',
	red:    '#c62828',
	grey:   '#757575'
};

function pad2(n) { return (n < 10 ? '0' : '') + n; }

function fmtTs(ts) {
	ts = +ts;
	if (!ts || ts <= 0) return '—';
	var d = new Date(ts * 1000);
	return d.getFullYear() + '-' + pad2(d.getMonth() + 1) + '-' + pad2(d.getDate()) + ' ' +
		pad2(d.getHours()) + ':' + pad2(d.getMinutes()) + ':' + pad2(d.getSeconds());
}

/* 把秒数写成人类看得懂的样子：3600 -> "60 分钟"，90 -> "90 秒" */
function fmtDur(sec) {
	sec = +sec;
	if (!sec || sec <= 0) return '—';
	if (sec % 3600 === 0) return (sec / 3600) + ' 小时';
	if (sec % 60 === 0) return (sec / 60) + ' 分钟';
	return sec + ' 秒';
}

function delay(ms) {
	return new Promise(function(res) { window.setTimeout(res, ms); });
}

function byId(id) { return document.getElementById(id); }

function setText(id, s) {
	var e = byId(id);
	if (e) e.textContent = (s == null || s === '') ? '—' : String(s);
}

function notify(msg, level) {
	ui.addNotification(null, E('p', {}, msg), level || 'info');
}

function vrow(title, node) {
	return E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, title),
		E('div', { 'class': 'cbi-value-field' }, node)
	]);
}

function mkbtn(label, fn, cls) {
	return E('button', {
		'class': 'btn cbi-button ' + (cls || 'cbi-button-neutral'),
		'style': 'margin:0 6px 6px 0',
		'click': function(ev) { if (ev) ev.preventDefault(); return fn(); }
	}, [ label ]);
}

/* ---------------- 数据读取 ---------------- */

function readStatus() {
	return fs.exec(AUTH, [ '--status' ]).then(function(res) {
		var out = (res && res.stdout) ? res.stdout.trim() : '';
		if (out === '') return null;
		try { return JSON.parse(out); } catch (e) { return null; }
	});
}

function readLog() {
	return fs.exec(AUTH, [ '--tail', '50' ]).then(function(res) {
		return (res && res.stdout) ? res.stdout.replace(/\s+$/, '') : '';
	});
}

function readSvc() {
	return Promise.all([
		callRcList(SVC).then(function(res) {
			return (res && res[SVC]) ? res[SVC] : {};
		}).catch(function() { return {}; }),
		callInitList(SVC).then(function(res) {
			return (res && res[SVC]) ? res[SVC] : {};
		}).catch(function() { return {}; })
	]).then(function(r) {
		var rc = r[0] || {}, il = r[1] || {};
		return {
			// running 只有 rc list 给，取不到就退回 status.json 的 daemon_running
			running: (typeof rc.running === 'boolean') ? rc.running : null,
			// rc list 若连 start 都没解析出来，说明踩到了上面那个前缀窗口坑，
			// 此时它的 enabled 不可信，改用 getInitList
			enabled: (rc.start != null) ? rc.enabled
				: ((typeof il.enabled === 'boolean') ? il.enabled : null)
		};
	});
}

/* ---------------- 渲染与刷新 ---------------- */

function paint(st, log, svc) {
	st = st || {};
	svc = svc || {};

	var badge = byId('szu-badge');
	if (badge) {
		badge.textContent = STATE_LABEL[st.state] || (st.state || '未知');
		badge.style.cssText = 'display:inline-block;padding:2px 10px;border-radius:10px;' +
			'color:#fff;font-weight:bold;background:' + (COLOR_HEX[st.color] || COLOR_HEX.grey);
	}

	var noData = (st.state == null && st.ts == null);
	setText('szu-detail', noData
		? '读不到状态：服务可能从未运行过。若服务已在运行，请检查 /usr/share/rpcd/acl.d/luci-app-szu-netauth.json 是否已生效（需重启 rpcd）。'
		: st.detail);

	setText('szu-check', fmtTs(st.ts));
	setText('szu-wan', st.wan_ip);
	setText('szu-campus', st.campus ? '是' : '否');
	setText('szu-online', st.online ? '是（已认证）' : '否');

	// 离线成因：由后端用 ICMP 把「被门户劫持」和「网络层不通」分开
	var kind = st.offline_kind ? OFFLINE_KIND_LABEL[st.offline_kind] : '';
	setText('szu-kind', kind || '—');

	setText('szu-lastlogin',
		(st.last_login ? fmtTs(st.last_login) : '尚无登录记录') +
		(st.last_login_result ? '　·　' + st.last_login_result : ''));

	// 重连轮次：本轮已失败几次 / 上限几次
	var fc = +st.fail_count || 0, rmax = +st.retry_max || 0;
	setText('szu-gate', fc > 0
		? ('本轮第 ' + fc + '/' + (rmax || '?') + ' 次失败' +
		   (st.next_retry ? '，下次重试 ' + fmtTs(st.next_retry) : '') +
		   (st.state === 'giveup' ? '　（已停手，等下一个常规周期）' : ''))
		: '正常（本轮无失败）');

	setText('szu-iv', st.net_check
		? fmtDur(st.interval) + '　（常规 ' + fmtDur(st.net_check) +
		  ' / 非校园网 ' + fmtDur(st.campus_check) + '）'
		: '—');

	// ICMP 探测结果：-1 = 本轮未测，0 = 不通，1 = 通
	var po = (typeof st.ping_ok === 'number') ? st.ping_ok : -1;
	var phost = st.ping_host || '';
	setText('szu-ping', po === 1
		? ('通　' + (st.ping_ms ? st.ping_ms + ' ms' : '') + '　(' + phost + ')')
		: po === 0
			? ('不通　(' + phost + ')')
			: '未测');

	setText('szu-method', st.net_check_method);
	setText('szu-paths', st.login_paths);

	var running = (typeof svc.running === 'boolean') ? svc.running : !!st.daemon_running;
	setText('szu-svc-run', running ? '运行中' : '已停止');
	setText('szu-svc-en',  (typeof svc.enabled === 'boolean') ? (svc.enabled ? '已启用' : '未启用') : '—');

	var lg = byId('szu-log');
	if (lg) lg.textContent = (log && log.trim() !== '')
		? log
		: '（暂无日志：服务刚启动，或 logd 环形缓冲已滚动。日志只进内存，不写 flash。）';
}

function refresh() {
	return Promise.all([
		readStatus().catch(function() { return null; }),
		readLog().catch(function() { return null; }),
		readSvc().catch(function() { return {}; })
	]).then(function(r) {
		paint(r[0], r[1], r[2]);
	});
}

function trigger(what) {
	return fs.exec(AUTH, [ '--trigger', what ]).then(function(res) {
		var out = (res && res.stdout ? res.stdout : '').trim();
		var err = (res && res.stderr ? res.stderr : '').trim();
		if (res && res.code === 0)
			notify(out || '已触发');
		else
			notify(err || out || ('触发失败（返回码 ' + (res ? res.code : '?') + '）'), 'warning');
		return delay(2500);
	}).then(refresh).catch(function(e) {
		notify('执行失败：' + (e.message || e), 'error');
	});
}

function rcAct() {
	var actions = Array.prototype.slice.call(arguments);
	var p = Promise.resolve();
	actions.forEach(function(a) {
		p = p.then(function() { return callRcInit(SVC, a); });
	});
	return p.then(function() {
		notify('已执行：' + actions.join(' → '));
		return delay(1200);
	}).then(refresh).catch(function(e) {
		notify('执行失败：' + (e.message || e), 'error');
	});
}

return view.extend({
	load: function() {
		return Promise.all([
			readStatus().catch(function() { return null; }),
			readLog().catch(function() { return null; }),
			readSvc().catch(function() { return {}; })
		]);
	},

	render: function(data) {
		var container = E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '运行状态'),
				E('div', { 'class': 'cbi-section-node' }, [
					vrow('总体状态', E('div', {}, [
						E('span', { 'id': 'szu-badge' }, '读取中…'),
						E('div', { 'style': 'margin-top:6px;color:#666' }, E('span', { 'id': 'szu-detail' }, '—'))
					])),
					vrow('最近检测', E('span', { 'id': 'szu-check' })),
					vrow('WAN 地址', E('span', { 'id': 'szu-wan' })),
					vrow('校园网判定', E('span', { 'id': 'szu-campus' })),
					vrow('联网判定', E('span', { 'id': 'szu-online' })),
					vrow('离线成因', E('span', { 'id': 'szu-kind' })),
					vrow('ICMP 探测', E('span', { 'id': 'szu-ping' })),
					vrow('判定方式', E('span', { 'id': 'szu-method' })),
					vrow('上次登录结果', E('span', { 'id': 'szu-lastlogin' })),
					vrow('重连轮次', E('span', { 'id': 'szu-gate' })),
					vrow('检测节奏', E('span', { 'id': 'szu-iv' })),
					vrow('登录线路', E('span', { 'id': 'szu-paths' }))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '服务与自启'),
				E('div', { 'class': 'cbi-section-node' }, [
					vrow('常驻服务', E('span', { 'id': 'szu-svc-run' })),
					vrow('开机自启', E('span', { 'id': 'szu-svc-en' })),
					vrow('服务操作', E('div', {}, [
						mkbtn('启动服务', function() { return rcAct('start'); }, 'cbi-button-apply'),
						mkbtn('停止服务', function() { return rcAct('stop'); }),
						mkbtn('启用开机自启', function() { return rcAct('enable'); }),
						mkbtn('关闭开机自启', function() { return rcAct('disable'); })
					])),
					vrow('', E('div', { 'style': 'color:#666' },
						'提示：「启用自动认证」这个业务开关在「设置」页。这里只控制服务进程与开机自启。'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '手动操作'),
				E('div', { 'class': 'cbi-section-node' }, [
					vrow('立即操作', E('div', {}, [
						mkbtn('立即检测', function() { return trigger('check'); }, 'cbi-button-action'),
						mkbtn('立即登录', function() { return trigger('login'); }, 'cbi-button-action'),
						mkbtn('刷新本页', function() { return refresh(); })
					])),
					vrow('', E('div', { 'style': 'color:#666' },
						'「立即登录」会跳过在线判断直接认证一次，并把本轮重连计数清零' +
						'（即重新开始最多「单轮最多尝试次数」次尝试）。两次点击之间仍受' +
						'「两次登录最小间隔」限制。'))
				])
			]),

			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, '运行日志（最近 50 行）'),
				E('div', { 'class': 'cbi-section-node' }, [
					E('pre', {
						'id': 'szu-log',
						'style': 'max-height:340px;overflow:auto;white-space:pre-wrap;word-break:break-all;' +
							'font-size:12px;line-height:1.45;margin:0;padding:8px;' +
							'background:rgba(127,127,127,.08);border-radius:4px'
					}, '（加载中…）'),
					E('div', { 'style': 'margin-top:8px;color:#666' },
						'日志走 logd 的内存环形缓冲，不写 flash。命令行等价查看：logread -e szu-netauth | tail -50')
				])
			])
		]);

		paint(data[0], data[1], data[2]);

		// 每 5 秒自动刷新一次（对齐 Windows 版的实时状态显示）
		poll.add(function() { return refresh(); }, 5);

		return container;
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
