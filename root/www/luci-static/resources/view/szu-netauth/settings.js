'use strict';
'require form';
'require view';
'require uci';

/*
 * 深大校园网自动认证 · 设置页
 *
 * 本页**不需要任何后端代码**：form.Map 自带「读取 UCI → 校验 → 写回 → commit」，
 * commit 之后 procd 的 reload trigger 会让常驻循环按新配置重启。
 *
 * 密码字段用 o.password = true —— LuCI 的 ui.Textfield 在这个属性下会**自动**
 * 渲染一个「显示/隐藏密码」按钮，不需要自己写。
 *
 * 间隔用 datatype = 'range(...)' 做校验，对应 C# 版 AppSettings 里的 Clamp()。
 */

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('szu-netauth')
		]);
	},

	render: function() {
		var m, s, o;

		m = new form.Map('szu-netauth', _('校园网认证'),
			_('配置深大校园网自动认证。修改后点「保存并应用」，配置变化会让常驻循环自动按新配置重启。'));

		/* ---------------- 基本设置 ---------------- */
		s = m.section(form.NamedSection, 'global', 'szu-netauth', _('基本设置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用自动认证'),
			_('关闭后常驻服务仍在运行，但只做检测、不再发起登录（状态页会显示「已停用」）。'));
		o.rmempty = false;

		o = s.option(form.Value, 'cardid', _('校园网卡号'),
			_('注意：是校园网卡号，不是学号。'));
		o.datatype = 'string';
		o.rmempty = false;

		o = s.option(form.Value, 'password', _('密码'),
			_('以明文保存在 /etc/config/szu-netauth（权限 600，仅 root 可读）。输入框右侧的按钮可显示/隐藏。'));
		o.password = true;
		o.datatype = 'string';
		o.rmempty = false;

		/* ---------------- 检测节奏 ---------------- */
		s = m.section(form.NamedSection, 'global', 'szu-netauth', _('检测节奏'));
		s.anonymous = true;

		o = s.option(form.Value, 'net_check', _('常规检测间隔'),
			_('秒。每隔这么久确认一次网络是否还通。默认 3600 = 60 分钟。' +
			  '这是「心跳」，也决定了掉线后最多多久会被发现。'));
		o.datatype = 'range(30,86400)';
		o.placeholder = 3600;
		o.rmempty = false;

		o = s.option(form.Value, 'retry_interval', _('重连尝试间隔'),
			_('秒。检测到离线后，重新尝试登录的间隔。默认 60 = 每分钟一次。'));
		o.datatype = 'range(10,3600)';
		o.placeholder = 60;
		o.rmempty = false;

		o = s.option(form.Value, 'retry_max', _('单轮最多尝试次数'),
			_('连续尝试这么多次仍失败就停手，等下一个「常规检测间隔」再重新检测。' +
			  '默认 5。设为 1 表示一次不成就等下一轮。'));
		o.datatype = 'range(1,50)';
		o.placeholder = 5;
		o.rmempty = false;

		o = s.option(form.Value, 'campus_check', _('非校园网检测间隔'),
			_('秒。判定「不在校园网」时的重试周期。'));
		o.datatype = 'range(30,86400)';
		o.placeholder = 3600;
		o.rmempty = false;

		/* ---------------- 联网判定 ---------------- */
		s = m.section(form.NamedSection, 'global', 'szu-netauth', _('联网判定'));
		s.anonymous = true;

		o = s.option(form.ListValue, 'net_check_method', _('判定方式'),
			_('决定怎么判断「网络通不通」。'));
		o.value('http+ping', _('HTTP + ping（推荐）：HTTP 为准，ping 用于区分「被门户劫持」与「网络层不通」'));
		o.value('http', _('仅 HTTP：最快，完全不依赖 ICMP'));
		o.value('ping', _('仅 ping：不推荐 —— 校园网可能丢弃 ICMP，且 IPv6 会绕过认证状态'));
		o.rmempty = false;

		o = s.option(form.Value, 'ping_host', _('ping 目标'),
			_('ICMP 探测目标。域名或 IP 都行；想完全避开 DNS 依赖就填 IP，例如 223.5.5.5。' +
			  '探测固定走 IPv4（-4）——不带的话会走 IPv6，而校园网 IPv6 常常不用认证，' +
			  '会造成「IPv4 已掉线但检测仍说在线」的假象。'));
		o.datatype = 'hostname';
		o.placeholder = 'www.baidu.com';
		o.rmempty = false;

		/* ---------------- 登录与风控 ---------------- */
		s = m.section(form.NamedSection, 'global', 'szu-netauth', _('登录与风控'));
		s.anonymous = true;

		o = s.option(form.ListValue, 'login_paths', _('登录线路'),
			_('按顺序尝试，第一条成功即停止。本网段（WAN 172.17.x）实测只有 eportal 可达。'));
		o.value('eportal', _('仅 eportal（推荐；当前网段唯一可用）'));
		o.value('eportal drcom_wifi drcom_nth', _('三路全试：eportal → 旧 Drcom WIFI → 旧 Drcom 有线'));
		o.value('drcom_wifi', _('仅旧 Drcom WIFI（drcom.szu.edu.cn）'));
		o.value('drcom_nth', _('仅旧 Drcom 有线（172.30.255.2）'));
		o.rmempty = false;

		o = s.option(form.Value, 'login_min_interval', _('两次登录最小间隔'),
			_('秒。两次登录之间的绝对下限，防连点、避免触发校园网 error hid 风控。' +
			  '一般保持 30 即可（只要它比「重连尝试间隔」小就不会起作用）。'));
		o.datatype = 'range(10,3600)';
		o.placeholder = 30;
		o.rmempty = false;

		/* ---------------- 日志 ---------------- */
		s = m.section(form.NamedSection, 'global', 'szu-netauth', _('日志'));
		s.anonymous = true;

		o = s.option(form.Flag, 'persist_log', _('持久化运行日志到 flash'),
			_('默认关闭。运行日志走 syslog 的内存环形缓冲，重启即清空、不磨损 flash。' +
			  '开启后会在状态变化时追加写 /etc/szu-netauth/state.log（超 128KB 轮转），' +
			  '路由器长期运行会因此磨损闪存，非必要不建议开启。'));
		o.rmempty = false;

		return m.render();
	}
});
