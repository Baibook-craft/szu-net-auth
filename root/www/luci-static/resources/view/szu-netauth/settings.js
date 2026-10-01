'use strict';
'require form';
'require view';
'require uci';
'require ui';

/*
 * 深大校园网自动认证 · 设置页
 *
 * 本页**不需要任何后端代码**：form.Map 自带「读取 UCI → 校验 → 写回 → commit」，
 * commit 之后 procd 的 reload trigger 会让常驻循环按新配置重读（最多 5 秒生效）。
 *
 * 密码字段用 o.password = true —— LuCI 的 ui.Textfield 在这个属性下会**自动**
 * 渲染一个「显示/隐藏密码」按钮，不需要自己写。
 *
 * 间隔用 datatype = 'range(...)' 做校验，对应 auth.sh 里的 clamp()。
 *
 * ---------------------------------------------------------------------------
 * 账号列表为什么用 GridSection、顺序又是怎么落盘的
 *
 * form.GridSection 天生具备：增行 / 删行 / 行首 ☰ 拖拽排序（s.sortable）。
 * 拖拽的实现在本机 /www/luci-static/resources/form.js 里：
 *     handleDrop() → this.map.data.move(config, sid1, sid2, after)
 * 而 uci.js 的 move() 会把所有段的 .index 重排一遍，并在 state.reorder[conf]
 * 打上标记；用户点「保存并应用」时 uci.save() 末尾会调 reorderSections()，
 * 按 .index 调 rpcd 的 uci order —— 顺序就这样真正写进 /etc/config/szu-netauth。
 *
 * 所以本页自绘的 ▲▼ 按钮只要调同一个 uci.move()，行为就和拖拽完全一致，
 * 不需要任何后端配合。
 * ---------------------------------------------------------------------------
 */

var CONF = 'szu-netauth';

/* ---------------- 账号排序：上移 / 下移 ---------------- */

function acctIds() {
	return uci.sections(CONF, 'account').map(function(x) { return x['.name']; });
}

/* 把一张表里所有行的 ▲▼ 可用状态按**当前**顺序重算一遍。
 *
 * 为什么必须重算：LuCI 的 textvalue() 只在渲染那一行时调一次，而 disabled 是
 * 那时按当时的行号算出来的。挪完行以后行号变了，按钮状态却还是旧的 ——
 * 会出现「▲ 看着是灰的但其实该能点」「▲ 看着能点，点了没反应」。
 * （disabled 的按钮压根不会触发 click，所以光靠 handler 里的判断救不回来。） */
function refreshArrows(scope, ids) {
	var last = ids.length - 1;
	ids.forEach(function(sid, idx) {
		var tr = scope.querySelector('tr[data-sid="%s"]'.format(sid));
		if (!tr)
			return;
		var up = tr.querySelector('button[data-order="up"]');
		var dn = tr.querySelector('button[data-order="down"]');
		if (up) up.disabled = !(idx > 0);
		if (dn) dn.disabled = !(idx >= 0 && idx < last);
	});
}

/* btn 是发起这次移动的按钮，用来把 DOM 查找限制在**这张表**里 ——
 * 否则「编辑某一行」的弹窗一旦打开，里面克隆出来的行也会被
 * querySelector 命中，就可能挪错元素。 */
function acctMove(section_id, dir, btn) {
	var ids = acctIds();
	var i = ids.indexOf(section_id);
	var j = i + dir;
	if (i < 0 || j < 0 || j >= ids.length)
		return;

	/* 只改浏览器里的顺序（和内置拖拽一模一样），不直接落盘 ——
	 * 统一由页面下方的「保存并应用」去 commit，语义和其他字段一致。 */
	uci.move(CONF, section_id, ids[j], dir > 0);

	/* 顺手把表格里的 <tr> 也挪一下，否则点完看不出任何变化 */
	var scope = (btn && btn.closest && btn.closest('table')) || document;
	var cur = scope.querySelector('tr[data-sid="%s"]'.format(section_id));
	var ref = scope.querySelector('tr[data-sid="%s"]'.format(ids[j]));
	if (cur && ref) {
		if (dir < 0)
			ref.parentNode.insertBefore(cur, ref);
		else
			ref.parentNode.insertBefore(cur, ref.nextElementSibling);
	}

	refreshArrows(scope, acctIds());

	/* 说清楚要点哪个按钮：LuCI 的「保存」只是暂存到当前会话，
	 * 只有「保存并应用」才会真正写进 /etc/config/szu-netauth。 */
	ui.addNotification(null, E('p', {},
		_('顺序已调整。要点「保存并应用」才会写进配置文件（只点「保存」不够）。')), 'info');
}

return view.extend({
	load: function() {
		return Promise.all([
			uci.load(CONF)
		]);
	},

	render: function() {
		var m, s, o;
		var legacyId = uci.get(CONF, 'global', 'cardid');

		m = new form.Map(CONF, _('校园网认证'),
			_('配置深大校园网自动认证。修改后点「保存并应用」，配置变化会让常驻循环自动按新配置读入。'));

		/* ---------------- 基本设置 ---------------- */
		s = m.section(form.NamedSection, 'global', CONF, _('基本设置'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('启用自动认证'),
			_('关闭后常驻服务仍在运行，但只做检测、不再发起登录（状态页会显示「已停用」）。'));
		o.rmempty = false;

		/* ---------------- 账号列表 ---------------- */
		/* 说明写成数组 + E('br')，而不是靠字符串里的 \n ——
		 * LuCI 的 dom 只把字符串当纯文本塞进文本节点，换行怎么处理因版本而异，
		 * 显式给 <br> 最稳。 */
		s = m.section(form.GridSection, 'account', _('账号列表'), [
			_('认证时按这个表从上到下的顺序轮流尝试：'), E('br'),
			_('① 开机后（以及每一轮重新开始重连时）固定先试第 1 行；'), E('br'),
			_('② 这一次没通过 → 等「重连尝试间隔」秒后试第 2 行；'), E('br'),
			_('③ 试到最后一行就绕回第 1 行，如此循环，直到用满「单轮最多尝试次数」次就停手；'), E('br'),
			_('④ 只要有一次成功，下一轮又从第 1 行重新开始。'), E('br'),
			_('想换首次尝试的账号，把它挪到最上面即可：拖动行首的 ☰，或者点「排序」列里的 ▲▼。'), E('br'),
			_('卡号留空的行、以及「启用」没勾的行，都会被自动忽略。'),
			legacyId ? E('div', { 'style': 'margin-top:6px;color:#c62828' },
				_('注意：检测到旧版单账号配置（global.cardid）。账号列表为空时它仍会作为兜底生效；建议把卡号填进下面的列表。')) : ''
		]);
		s.anonymous = true;   /* 不显示 LuCI 自动生成的段名（对用户没意义） */
		s.addremove = true;   /* 可加行、可删行 */
		s.sortable = true;    /* 行首 ☰ 拖拽排序（内置能力，同样会写回配置） */

		o = s.option(form.Value, 'label', _('名称'));
		o.editable = true;    /* 直接在表格里编辑，不必开弹窗 */
		o.rmempty = true;     /* 允许留空：留空时界面按位置叫「账号 1 / 账号 2」 */
		o.placeholder = _('例如：主号');
		o.width = '14%';

		o = s.option(form.Value, 'cardid', _('校园网卡号'));
		o.editable = true;
		o.datatype = 'string';
		o.rmempty = true;     /* 允许留空：留空的账号后端会自动跳过 */
		o.placeholder = '123456';
		o.width = '18%';

		o = s.option(form.Value, 'password', _('密码'));
		o.editable = true;
		o.password = true;    /* 自动带「显示 / 隐藏密码」按钮 */
		o.datatype = 'string';
		o.rmempty = true;
		o.width = '22%';

		o = s.option(form.Flag, 'enabled', _('启用'));
		o.editable = true;
		o.default = '1';
		o.rmempty = false;
		o.width = '8%';

		/* 「排序」列：自绘 ▲▼ 按钮。
		 *
		 * 这里**故意**不设 o.editable，理由有两条（都是读 form.js 得到的）：
		 *   1) CBIGridSection.parse() 的判断是
		 *          if (!this.children[j].editable || this.children[j].modalonly) continue;
		 *      editable 为假 → 整列在保存时被跳过，绝不会去写什么配置；
		 *   2) renderChildren() 里可编辑的用 opt.render()，否则走
		 *      renderTextValue() —— 而后者是把这个值直接塞进 <td>：
		 *          E('td', {...}, (value != null) ? value : E('em', _('none')))
		 *      所以 textvalue() 返回一个 DOM 节点是合法的。
		 * 这样既排掉了「浏览器控件 → UCI」这一整条链，又不用给控件造 id。 */
		o = s.option(form.DummyValue, '_acct_order', _('排序'));
		o.modalonly = false;  /* 只在表格里出现，不进「添加」弹窗 */
		o.width = '92px';
		o.textvalue = function(section_id) {
			var ids = acctIds();
			var idx = ids.indexOf(section_id);
			var last = ids.length - 1;

			function arrow(glyph, dir, on, hint) {
				return E('button', {
					'class': 'btn cbi-button cbi-button-neutral',
					'style': 'padding:0 7px;margin:0 2px;line-height:1.5;font-size:12px',
					'title': hint,
					/* 给 refreshArrows() 一个稳定的钩子 */
					'data-order': dir < 0 ? 'up' : 'down',
					'disabled': on ? null : true,
					'click': function(ev) {
						if (ev) {
							ev.preventDefault();
							/* 别让点击冒泡到 <tr>：行上挂着拖拽的 mousedown
							 * 处理器（s.sortable），虽然它只对 ☰ 生效，但
							 * 断掉冒泡更省心，也不会触发任何行级行为。 */
							ev.stopPropagation();
						}
						/* 注意：**不要**在这里用上面闭包捕获的 on 做判断 ——
						 * 挪过行以后它就是旧的了。边界检查统一交给 acctMove()。 */
						acctMove(section_id, dir, ev && ev.currentTarget);
						return false;
					}
				}, [ glyph ]);
			}

			return E('span', { 'style': 'white-space:nowrap' }, [
				arrow('▲', -1, idx > 0, _('上移：更早尝试')),
				arrow('▼', +1, idx >= 0 && idx < last, _('下移：更晚尝试'))
			]);
		};

		/* ---------------- 账号切换 ---------------- */
		s = m.section(form.NamedSection, 'global', CONF, _('账号切换'));
		s.anonymous = true;

		o = s.option(form.Flag, 'auto_switch', _('登录失败后自动切换账号'),
			_('开启（默认）：一次没通过，就换账号列表里的下一个再试；用满「单轮最多尝试次数」才停手。' +
			  '关闭：永远只用账号列表里的第一个账号 —— 等同于单账号模式。'));
		o.default = '1';
		o.rmempty = false;

		/* ---------------- 检测节奏 ---------------- */
		s = m.section(form.NamedSection, 'global', CONF, _('检测节奏'));
		s.anonymous = true;

		o = s.option(form.Value, 'net_check', _('常规检测间隔'),
			_('秒。每隔这么久确认一次网络是否还通。默认 3600 = 60 分钟。' +
			  '这是「心跳」，也决定了掉线后最多多久会被发现。'));
		o.datatype = 'range(30,86400)';
		o.placeholder = 3600;
		o.rmempty = false;

		o = s.option(form.Value, 'retry_interval', _('重连尝试间隔'),
			_('秒。检测到离线后，重新尝试登录的间隔。默认 60 = 每分钟一次。' +
			  '多账号时，这也是「换下一个账号」的节奏。'));
		o.datatype = 'range(10,3600)';
		o.placeholder = 60;
		o.rmempty = false;

		o = s.option(form.Value, 'retry_max', _('单轮最多尝试次数'),
			_('连续尝试这么多次仍失败就停手，等下一个「常规检测间隔」再重新检测。默认 5。' +
			  '注意这是「总的」尝试次数上限 —— 多账号时每个账号各占一次。'));
		o.datatype = 'range(1,50)';
		o.placeholder = 5;
		o.rmempty = false;

		o = s.option(form.Value, 'campus_check', _('非校园网检测间隔'),
			_('秒。判定「不在校园网」时的重试周期。'));
		o.datatype = 'range(30,86400)';
		o.placeholder = 3600;
		o.rmempty = false;

		/* ---------------- 联网判定 ---------------- */
		s = m.section(form.NamedSection, 'global', CONF, _('联网判定'));
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
		s = m.section(form.NamedSection, 'global', CONF, _('登录与风控'));
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
		s = m.section(form.NamedSection, 'global', CONF, _('日志'));
		s.anonymous = true;

		o = s.option(form.Flag, 'persist_log', _('持久化运行日志到 flash'),
			_('默认关闭。运行日志走 syslog 的内存环形缓冲，重启即清空、不磨损 flash。' +
			  '开启后会在状态变化时追加写 /etc/szu-netauth/state.log（超 128KB 轮转），' +
			  '路由器长期运行会因此磨损闪存，非必要不建议开启。'));
		o.rmempty = false;

		return m.render();
	}
});
