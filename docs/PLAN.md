# 深大校园网自动认证 · 路由器部署方案

> **目标**：把 `szu-net-auth-win`（C# WinForms 桌面程序）的校园网认证逻辑移植到路由器 `192.168.2.1` 上常驻运行，
> 由**路由器**完成认证，局域网内所有设备共用这条已认证的 WAN，不再依赖某一台电脑开机。
>
> **当前状态**：⛔ **仅完成只读侦察，尚未在路由器上写入任何文件。**
> 用户已选定：认证线路 = **仅 eportal**；配置层级 = **L3（含 LuCI 图形页）**。

---

## 0. 为什么是"移植"而不是"部署"

| 约束 | 实测结果 | 推论 |
|---|---|---|
| 现有程序 | C# / WinForms / .NET Framework 4.x | 路由器是 aarch64 Linux，**跑不了** |
| 路由器平台 | Kwrt 25.12.0-rc3（OpenWrt 系）/ aarch64 | 可用 `opkg` + `procd` + `uci` |
| Python | **不存在**（`python3` / `python` 均无） | 不能用 Python 移植 |
| 已有工具 | `curl 8.15.0`、`wget-ssl 1.25.0`、`jsonfilter`、`logger`、`ucode` | **用 shell + curl 实现最合适** |

结论：认证逻辑本身只有「HTTP 请求 + 字符串判断」，用 **busybox sh + curl** 可以 1:1 复刻，
体积不到 30 KB，零额外依赖、零额外包安装。

---

## 1. 现场实测档案

### 1.1 系统

```
NAME="Kwrt"  VERSION="25.12.0-rc3"  ID_LIKE="lede openwrt"
DISTRIB_TARGET='mediatek/mt7622'   DISTRIB_ARCH='aarch64_cortex-a53'
DISTRIB_REVISION='01.22.2026'      DISTRIB_TAINTS='busybox'
uname: Linux Kwrt 6.12.66 #0 SMP aarch64 GNU/Linux
```

### 1.2 存储与内存（空间账）

| 区域 | 挂载 | 大小 | 已用 | 可用 | 可写 |
|---|---|---|---|---|---|
| 固件只读区 | `/rom` (squashfs, ro) | 50.8 MB | 50.8 MB | 0 | ❌ 不能删 |
| **可写覆盖层** | `/overlay` (ubifs, rw) | 45.4 MB | 5.1 MB | **37.9 MB** | ✅ |
| 内存盘 | `/tmp` (tmpfs) | 117.8 MB | 0.6 MB | 117.2 MB | ✅ 重启清空 |

内存：总 241 MB / **available 106 MB**；swap 79 MB（已用 21 MB）。

**空间判定**：本方案新增文件合计 ≈ **28 KB**，占可用空间 **0.07%**。按"占用 < 可用 × 0.8"的安全线衡量，
**空间完全不构成约束**，无需删除任何内置组件。（本机 `/rom` 里内置 passwall/xray/sing-box，但本方案不碰它们。）

### 1.3 网络

| 项 | 值 | 说明 |
|---|---|---|
| WAN 口 | `172.17.x.x/23`，网关 `172.17.x.x` | **属于深大校园网段** |
| WAN 获取方式 | `proto=dhcp`，设备 `wan`（`eth0`） | IP 由校园网 DHCP 下发 |
| WAN MAC | `d4:da:**:**:**:fa` | |
| LAN | `br-lan` = `192.168.2.1/24`（lan1/lan2/lan3） | 家里设备所在网段 |
| 出口公网 IP | `223.74.x.x`（China / Guangzhou） | 说明 WAN **已被认证** |
| 上游 DNS | `114.114.114.114`, `192.168.247.6`, `202.96.134.133` | |
| 时区 | CST（`Wed Sep 30 18:50:06 CST 2026`） | 日志时间正确 |

**关键推论**：路由器 WAN 口本身就是校园网接口 → 在路由器上认证，等于认证 `172.17.x.x` 这个 IP，
其后的所有 NAT 设备自动可用。**这正是用户想要的架构。**

### 1.4 认证服务器可达性（从路由器 WAN 侧实测）

| 目标 | 结果 | 结论 |
|---|---|---|
| `http://172.30.255.42:801/`（新版 eportal） | curl 退出码 **0**，返回合法 JSONP | ✅ **唯一可用线路** |
| `http://172.30.255.2/`（旧 Drcom 有线） | curl 退出码 **7**（连接失败） | ❌ 本网段不通 |
| `https://drcom.szu.edu.cn/a70.htm`（旧 Drcom WIFI） | curl 退出码 **7**（连接失败） | ❌ 本网段不通 |
| `http://172.17.x.x/`（网关） | curl 退出码 28（超时） | 网关不提供 HTTP，无意义 |

**当前认证状态**（2026-09-30 18:50）：

```
NCSI  http://www.msftconnecttest.com/connecttest.txt → HTTP 200，正文 "Microsoft Connect Test"
204   http://connect.rom.miui.com/generate_204        → HTTP 204
```

两路探测均通过 → **此刻在线**。部署不会破坏现有连通性。

> `drcom.szu.edu.cn` 在公网 DNS 可解析到 `192.168.254.220`（RFC1918 私网地址，仅校内可达），
> 但因本机在 `172.17` 段而该地址在 `172.30` 段，故 TCP 不可达。与上述结论一致。

### 1.5 已装组件（与本方案相关）

`curl 8.15.0` · `wget-ssl 1.25.0` · `dnsmasq-full 2.91` · `nftables-json` · `jsonfilter` · `logger`
· `ucode 2025.12.01`（含 `ucode-mod-fs` / `-uci` / `-ubus` / `-html`）
· `luci-base 27.020.52094` · `luci-compat` · `rpcd 2025.12.03` · `rpcd-mod-file` · `rpcd-mod-luci`
· `luci-app-passwall 26.2.6` + `xray-core` + `sing-box 1.12.20`
· **无 python3**

### 1.6 procd 能力清单（逐条来自 `/lib/functions/procd.sh` 与 `/etc/init.d/*` 实际用法统计）

`procd_set_param` 实际被使用的参数（括号内为本机出现次数）：
`command`(25) · `respawn`(15) · `file`(6) · `stderr`(6) · `user`(3) · `group`(3) · `stdout`(3)
· `no_new_privs`(3) · `limits`(3) · `capabilities`(3) · `data`(2) · `watch`(1) · `netdev`(1) · `reload_signal`(1) · `env`(1)

触发器实际被使用：`procd_add_reload_trigger`(13) · `procd_add_validation`(5) · `procd_add_config_trigger`(5)
· `procd_add_raw_trigger`(4) · `procd_add_interface_trigger`(4) · `procd_add_action_mount_trigger`(1)

状态查询：procd 暴露 ubus 对象 `service`，`ubus call service list '{"name":"dnsmasq"}'` 实测返回
`running` / `pid` / `command` / `respawn` 等字段 → **现成可用**。

范例脚本：`/etc/init.d/nginx`（`USE_PROCD=1`、`START=80`、`procd_set_param stdout/stderr/file/respawn`、`service_triggers()`）。

### 1.7 LuCI 形态（决定界面层怎么做）

- 版本 `27.020.52094`，**现代 JS 版 LuCI**（`/www/luci-static/resources/view/<app>/*.js` + `/usr/share/luci/menu.d/*.json` + `/usr/share/rpcd/acl.d/*.json`）
- 同时装了 `luci-compat`，Lua 控制器路线（如 `luci-app-passwall`）也仍可用
- **关键工具箱实测存在**：

| 模块 | 体积 | 用途 |
|---|---|---|
| `/www/luci-static/resources/form.js` | 60,594 B | 表单：`Map` `NamedSection` `TypedSection` `Value` `Flag` `ListValue` `DynamicList` `TextValue` `MultiValue` `Button` —— **自动读写 UCI 并自动提交** |
| `/www/luci-static/resources/fs.js` | 3,783 B | `read` / `write` / `exec` / `exec_direct` / `lines` / `stat` / `list` —— **直接读写文件、执行脚本** |
| `/www/luci-static/resources/ui.js` | 85,375 B | 通知、对话框、组件 |
| `/www/luci-static/resources/rpc.js` | 3,901 B | ubus / rpcd 调用 |
| `/www/luci-static/resources/network.js` | 51,121 B | 网络信息 |

> 官方页面 `/www/luci-static/resources/view/system/system.js` 里同时 `require` 了
> `view poll ui uci rpc form tools.widgets`，可作为写法范本。
> （`poll` 未以独立文件存在，应由 luci-base 的 bundle 提供；实现时确认。）

**结论**：有了 `form.js` + `fs.js`，**不需要写任何 rpcd/ucode 后端**，LuCI 页即可完成
「读状态 → 显示 → 改设置 → 保存生效 → 手动触发」的完整闭环。

---

## 2. 顺带发现的既有 Bug（建议一并修）

实测抓到的 eportal 真实响应（裸请求，不带凭据）：

```
dr1003({"result":0,"msg":"无法获取用户认证账号！","ret_code":"1"});
```

注意 `ret_code` 的值是**带引号的字符串** `"1"`。

而 `szu-net-auth-win/src/CampusAuth.cs:183` 是：

```csharp
Match mRetCode = Regex.Match(text, "\"ret_code\"\\s*:\\s*(-?\\d+)");
```

要求冒号后**紧跟数字**；遇到 `"` 直接匹配失败 → `ret_code` 被当作 `-1`。

**后果**：服务器若返回 `"ret_code":"2"`（IP 已在线），C# 版**识别不出"已在线"，会误判为登录失败**。
上游插件 `login-post.js` 用 `JSON.parse` + `responseJson.ret_code === 2`（严格比较数字），**同样脆弱**。

日志证据：`2026-09-14 23:43:56 手动登录成功：已在线：IP: 172.17.100.3 已经在线！`
说明服务器**有时**返回不带引号的 `2` —— **该字段格式不稳定**。

**移植版处理**：解析器同时兼容两种写法（引号可有可无）。

---

## 3. 架构：四层，逐层解耦

```
① 界面层   LuCI JS 页（状态卡片 / 设置表单 / 手动按钮）
② 服务层   procd：respawn 拉活 · 配置变化自动 reload · 接口事件触发
③ 脚本层   auth.sh：环境检测 / 联网探测 / 登录 / 心跳看门狗
④ 数据层   /etc/config/szu-netauth（凭据，600） + /var/run/szu-netauth/status.json（状态，tmpfs）
```

**控制流**：界面层改 UCI → `unc commit` 触发 `config.change` → 服务层 reload → 脚本层按新配置运行
**状态流**：脚本层写 `status.json`（内存盘）→ 界面层轮询读取显示

**设计原则（重要）**：**界面层故障不得影响认证层。**
真正干活的逻辑全部在 `auth.sh` 里，LuCI 页只做「读状态 / 写配置 / 点按钮」。
因此即使将来 Kwrt 升级 LuCI 导致页面报错，**掉线自动重连依然照常工作**——这也是把界面层放在最后部署的原因。

---

## 4. 文件清单（全部为新增，不改动任何现有配置）

| # | 路径 | 作用 | 体积 |
|---|---|---|---|
| 1 | `/etc/szu-netauth/auth.sh` | 认证主脚本（子命令 + 常驻循环 + 看门狗） | ~12 KB |
| 2 | `/etc/config/szu-netauth` | UCI 配置（凭据、间隔、线路），权限 `600 root:root` | <1 KB |
| 3 | `/etc/init.d/szu-netauth` | procd 服务定义 | ~2 KB |
| 4 | `/www/luci-static/resources/view/szu-netauth/overview.js` | LuCI「状态」页 | ~4 KB |
| 5 | `/www/luci-static/resources/view/szu-netauth/settings.js` | LuCI「设置」页 | ~4 KB |
| 6 | `/usr/share/luci/menu.d/luci-app-szu-netauth.json` | 菜单注册 | <1 KB |
| 7 | `/usr/share/rpcd/acl.d/luci-app-szu-netauth.json` | 权限声明（ACL） | <1 KB |
| 8 | `/etc/szu-netauth/uninstall.sh` | 一键回滚 | ~3 KB |

合计 ≈ **28 KB**。**不新增依赖、不安装任何 opkg 包。**

运行时会额外产生（均为**内存盘**，不进 flash）：
`/var/run/szu-netauth/status.json`、`/var/run/szu-netauth/heartbeat`、`/var/run/szu-netauth/*.tmp`

---

## 5. `auth.sh` 设计

### 5.1 子命令

| 命令 | 用途 |
|---|---|
| `--daemon` | 常驻循环 + 心跳看门狗（`/etc/init.d/szu-netauth` 调用） |
| `--once` | 跑一轮「检测 → 探测 → 必要时登录」（供 cron / 手动） |
| `--login` | 只发起一次登录，不做检测（供页面按钮 / 手动救急） |
| `--check` | 只做检测与探测，输出结果，不登录（排障用） |
| `--status` | 输出当前状态 JSON |
| `--tail [N]` | 输出最近 N 行运行日志（供页面日志框） |

### 5.2 三段核心逻辑（语义对齐 C# 版，但有两处修正）

**`is_campus()` —— 环境检测**

```sh
# 快速路径：WAN 口 IP 落在校园网段
ip -4 addr show dev wan | grep -qE 'inet (172\.17|172\.30)\.'  && return 0
# 兜底：TCP 探测 eportal
curl -s -m 3 -o /dev/null --noproxy '*' "http://172.30.255.42:801/" && return 0
```

> **修正 1**：C# 版 `IsCampusNetwork()` 只认 `172.30.` 段，**漏了 `172.17.` 段**——
> 而本路由器的 WAN 恰好在 `172.17.x.x`，属于它认不出的那一段（当初靠后面的 TCP 探测歪打正着）。
> 移植版补上 `172.17.`。

**`is_online()` —— 联网探测（是否掉线）**

```sh
# 主探测：NCSI，要求 200 且正文含特征串
body=$(curl -s -m 6 --noproxy '*' -w '\n%{http_code}' http://www.msftconnecttest.com/connecttest.txt)
# 备探测：generate_204，要求 204
code=$(curl -s -m 6 -o /dev/null -w '%{http_code}' --noproxy '*' http://connect.rom.miui.com/generate_204)
```

> 严格**不跟随重定向**（不加 `-L`），被认证门户 302 劫持即判离线 —— 对应 C# 的 `AllowAutoRedirect = false`。
>
> **修正 2**：全部 curl 加 `--noproxy '*'`。本机装有 `passwall` + `xray` + `sing-box`，
> 这个参数确保路由器自身的探测与登录**走直连**，不被代理层接管。

**`do_login()` —— 登录（当前配置：仅 eportal）**

```sh
curl -s -m 8 --noproxy '*' -G "http://172.30.255.42:801/eportal/portal/login" \
  --data-urlencode "callback=dr1003" --data-urlencode "login_method=1" \
  --data-urlencode "user_account=,0,${CARDID}" \
  --data-urlencode "user_password=${PASSWORD}" \
  --data-urlencode "wlan_user_ip=" --data-urlencode "wlan_user_ipv6=" \
  --data-urlencode "wlan_user_mac=000000000000" --data-urlencode "wlan_ac_ip=" \
  --data-urlencode "wlan_ac_name=" --data-urlencode "jsVersion=4.1.3" \
  --data-urlencode "terminal_type=1" --data-urlencode "lang=zh" --data-urlencode "v=10353"
```

使用 `-G --data-urlencode` 而不是手工拼 URL —— 转义交给 curl，密码含特殊字符也安全。

**响应解析**（兼容带/不带引号，修掉第 2 节的 Bug）：

```sh
result=$(jnum "$resp" result)   # → 1 成功
ret=$(jnum "$resp" ret_code)    # → 2 表示 IP 已在线，同样算成功
msg=$(jstr  "$resp" msg)

[ "$result" = 1 ] && ok "认证成功"
[ "$ret"    = 2 ] && ok "已在线：$msg"
```

其中 `jnum()` 用 sed 允许值两侧有可选的 `"`：

```sh
jnum() { printf '%s' "$2" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([-0-9][0-9]*\)\"\{0,1\}.*/\1/p"; }
```

错误翻译沿用 C# 的表：`ldap auth error` → 账号或密码错误；`error hid` → 登录行为异常，请稍后重试。

> **顺序执行 vs 并发**：C# 版用 `Task.Factory.StartNew` 三路并发。移植版按配置**顺序**尝试、
> **第一条成功即退出**。在只有一条线路可用时二者结果等价，但 shell 版避开了并发竞态与临时文件管理，简单得多。
> 配置项 `login_paths` 默认 `eportal`；将来若换到 172.30 宿舍区网段，改成 `eportal drcom_wifi drcom_nth` 即可启用另外两条。

### 5.3 防"刷登录"闸门（C# 版没有，必须补）

常驻循环比桌面程序更容易在判据失灵时反复登录，会撞上校园网的 `error hid` 风控。规则：

1. 只有**一次新鲜的**联网探测判定离线，才发起登录（不用缓存的旧判断）
2. 两次登录之间至少间隔 `login_min_interval`（默认 30 秒）
3. 连续失败指数退避：30s → 60s → 120s → 240s → 上限 `backoff_max`（默认 600 秒）
4. 一旦登录成功或探测转为在线，退避计数清零

### 5.4 心跳看门狗（补 procd 的短板）

`procd_set_param respawn` **只能拉活"进程退出"**的情况；如果脚本卡死（例如某个 curl 挂住），
procd 察觉不到，服务会静静假活 —— "自动重连"就此失效。

对策：
- 每个 curl 强制 `-m` 超时
- 主循环每轮成功结束后 `touch /var/run/szu-netauth/heartbeat`
- 下一轮开始前检查心跳文件的 mtime；若 `now - mtime > 3 × 当前间隔`，脚本**主动 `exit 1`**，交给 procd 重启

### 5.5 日志策略（保护 flash）

- **运行日志 → `logger -t szu-netauth`**，进 syslog 的**内存环形缓冲**（`logread -e szu-netauth` 查看，LuCI「系统日志」也能看到）
- 默认**不落盘**。原 Windows 版每行都写文件；路由器上 60 秒一条 = 每天约 1440 次写 ubifs，长期磨损 flash
- 可选开关 `persist_log`（默认 `0`）：开启后仅在**状态变化**时追加到
  `/etc/szu-netauth/state.log`，超过 128 KB 自动轮转
- 状态机日志遵循 C# 版语义：**只在状态翻转时记录**，避免刷屏

### 5.6 UCI 配置结构

```uci
config szu-netauth 'global'
	option enabled '1'                 # 总开关
	option cardid ''                   # 校园网卡号（注意不是学号）
	option password ''                 # 密码（明文，文件权限 600）
	option net_check '60'              # 校园网内：联网检测间隔（秒）
	option campus_check '300'          # 不在校园网：重新检测间隔（秒）
	option login_paths 'eportal'       # 登录线路，空格分隔
	option login_min_interval '30'     # 两次登录最小间隔（秒）
	option backoff_max '600'           # 退避上限（秒）
	option persist_log '0'             # 是否落盘持久日志
```

视为已达成一致：**`login_paths` 保持仅 `eportal`**（实测本网段只有它可达）。

---

## 6. `/etc/init.d/szu-netauth` 设计

```sh
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
	config_load szu-netauth
	config_get_bool enabled global enabled 1
	[ "$enabled" -eq 1 ] || return 0

	procd_open_instance
	procd_set_param command /etc/szu-netauth/auth.sh --daemon
	procd_set_param respawn 3600 5 5      # 1 小时内最多重试 5 次，间隔 5 秒
	procd_set_param stdout 1              # 输出进 logd
	procd_set_param stderr 1
	procd_set_param term_timeout 10
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger "szu-netauth"       # 配置变化 → 自动 reload（本机 13 处在用）
	procd_add_interface_trigger "interface.*" wan /etc/init.d/szu-netauth reload
}
```

要点：

- `START=99`：排在 `network`（S20）之后，确保 WAN 已就绪
- `procd_add_reload_trigger`：LuCI 保存表单 → `uci commit` → `config.change` 事件 → **自动 reload**。
  这正是 Windows 版"保存设置后生效"的等价物，**不需要页面自己调用重启**
- `procd_add_interface_trigger`：WAN 口一有事件立刻重测，比 Windows 版死等 sleep 周期更快
- 开机自启：`/etc/init.d/szu-netauth enable`（生成 `/etc/rc.d/S99szu-netauth` 软链）
- 触发器与 `procd_set_param` 的确切参数签名，实现时对照 `/etc/init.d/nginx` 等真实脚本逐条核对

---

## 7. LuCI 界面设计（L3）

### 7.1 页面一：状态（`szu-netauth/overview`）

对照 Windows 版 `MainForm` 的上半部分 + 日志框：

| UI 元素 | 实现 | 对应的 Windows 版控件 |
|---|---|---|
| 主状态文字 + 颜色 | 读 `status.json` 的 `state` / `color` 渲染 | `_lblStatusMain` |
| 副状态文字 | 同上的 `detail` | `_lblSubStatus` |
| WAN IP / 校园网判定 / 在线判定 | `status.json` 字段 | （新增） |
| 最近检测、最近登录结果与时间 | `status.json` 字段 | 日志区信息 |
| 退避状态、下次重试时间 | `status.json` 字段 | （新增，便于排查风控） |
| **立即检测** 按钮 | `fs.exec('/etc/szu-netauth/auth.sh', ['--once'])` | `btnCheckNow` |
| **立即登录** 按钮 | `fs.exec('/etc/szu-netauth/auth.sh', ['--login'])` | `btnLoginNow` |
| 运行日志（最近 50 行） | `fs.exec('/etc/szu-netauth/auth.sh', ['--tail','50'])` | `_txtLog` |
| 自动刷新 | `poll.add()` 定时重读 | 无（Windows 版靠推送） |

### 7.2 页面二：设置（`szu-netauth/settings`）

用 `form.js` 构建，**自动读写 UCI、自动 commit**：

```js
var m = new form.Map('szu-netauth', _('校园网认证'), _('...'));
var s = m.section(form.NamedSection, 'global', 'szu-netauth', _('基本设置'));
s.anonymous = true;

var o = s.option(form.Flag,    'enabled',    _('启用自动认证'));
o = s.option(form.Value,       'cardid',     _('校园网卡号'), _('注意：卡号，不是学号'));
o = s.option(form.Value,       'password',   _('密码'));
o.password = true;                                   // 输入框打码
o = s.option(form.Value,       'net_check',  _('联网检测间隔'), _('秒'));
o.datatype = 'range(10,3600)';                       // 对应 C# 的 Clamp()
o = s.option(form.Value,       'campus_check', _('校园网检测间隔'), _('秒'));
o.datatype = 'range(30,86400)';
o = s.option(form.ListValue,   'login_paths', _('登录线路'));
o.value('eportal', _('仅 eportal（当前网段实测唯一可用）'));
o.value('eportal drcom_wifi drcom_nth', _('三路全试'));
o = s.option(form.Flag,        'persist_log', _('持久化运行日志'), _('开启会写 flash，非必要不建议'));
return m.render();
```

**这一层不需要任何后端代码** —— `form.Map` 自带读取、校验、保存、commit，
commit 之后 procd 的 reload trigger 自动让新配置生效。

### 7.3 菜单与权限

菜单（`menu.d/luci-app-szu-netauth.json`，挂到「服务」下）：

```json
{
  "admin/services/szu-netauth": {
    "title": "校园网认证", "order": 70,
    "action": { "type": "firstchild" },
    "depends": { "acl": [ "luci-app-szu-netauth" ] }
  },
  "admin/services/szu-netauth/overview": {
    "title": "状态", "order": 10,
    "action": { "type": "view", "path": "szu-netauth/overview" }
  },
  "admin/services/szu-netauth/settings": {
    "title": "设置", "order": 20,
    "action": { "type": "view", "path": "szu-netauth/settings" }
  }
}
```

权限（`acl.d/luci-app-szu-netauth.json`，语法照抄本机 `luci-app-syscontrol.json`）：

```json
{
  "luci-app-szu-netauth": {
    "description": "校园网自动认证",
    "read": {
      "ubus": { "file": [ "read" ], "service": [ "list" ] },
      "uci": [ "szu-netauth" ],
      "file": {
        "/var/run/szu-netauth/status.json": [ "read" ],
        "/etc/szu-netauth/auth.sh": [ "exec" ],
        "/etc/init.d/szu-netauth": [ "exec" ],
        "/sbin/logread": [ "exec" ]
      }
    },
    "write": {
      "uci": [ "szu-netauth" ],
      "file": {
        "/etc/szu-netauth/auth.sh": [ "exec" ],
        "/etc/init.d/szu-netauth": [ "exec" ]
      }
    }
  }
}
```

> ACL 是**白名单**：页面只能读 `status.json`、执行 `auth.sh` 与 `init.d` 脚本，**不能任意读写文件**。

### 7.4 两个已知坑（实现时会处理）

1. **静态资源缓存**：新增 JS 后需清 LuCI 索引缓存（`rm -f /tmp/luci-indexcache*`）+ 重启 `rpcd`，
   浏览器还要强制刷新。注意本机 LuCI 跑在 **nginx**（`luci-nginx`）而非 uhttpd，重启的服务名不同。
2. **掉线时页面仍可用**：LuCI 是局域网访问（`192.168.2.1`），校园网掉线不影响局域网 → 页面照常能打开、能手动救急。
   （从外网访问则不行，这属于预期。）

---

## 8. 分阶段部署顺序（关键：界面层放最后）

| 阶段 | 动作 | 失败影响 |
|---|---|---|
| **S0 备份** | `tar` 打包涉及路径 → 路由器留一份 + 拉回本机一份 | — |
| **S1 脚本层** | 放 `auth.sh` + `/etc/config/szu-netauth`(600)，**先不 enable** | 无（没人调用它） |
| **S2 脚本验证** | 跑 `--check` / `--login`，确认解析与凭据正确 | 可原地修脚本 |
| **S3 服务层** | 放 `/etc/init.d/szu-netauth` → `enable` + `start`，观察一轮 | `stop` + `disable` 即回退 |
| **S4 界面层** | 放 2 个 JS + `menu.d` + `acl.d`，清缓存重启 rpcd | **不影响认证**（认证已由 S3 独立工作） |
| **S5 界面验证** | 逐页打开、改一次设置保存、点一次按钮 | 删文件即回退 |

先做 S0–S3 能立刻拿到"掉线自动重连"的核心价值；界面是增量增强，且**任何一层失败都不影响已完成的层**。

---

## 9. 验证清单

**S2（脚本层）**

- [ ] `auth.sh --check`：正确识别 WAN 在校园网、联网探测为在线
- [ ] `auth.sh --login`：因当前**已在线**，预期返回 `ret_code=2`「IP 已经在线」
      —— 这一步同时验证线路可达、凭据被接受、解析正确，且**不改变任何状态**
- [ ] 解析器**离线单测**：用抓到的真实响应串（含带引号的 `ret_code`）跑 `jnum`/`jstr`，确认两种写法都能解析
- [ ] 日志出现在 `logread -e szu-netauth`

**S3（服务层）**

- [ ] `/etc/init.d/szu-netauth start` 后 `ubus call service list '{"name":"szu-netauth"}'` 显示 `running: true`
- [ ] `/etc/init.d/szu-netauth enable` 生成 `/etc/rc.d/S99szu-netauth` 软链
- [ ] 改一次 `net_check` → 观察 `logread` 里出现 reload → 确认配置闭环
- [ ] 心跳文件 `/var/run/szu-netauth/heartbeat` 的 mtime 在正常刷新

**S4/S5（界面层）**

- [ ] 菜单「服务 → 校园网认证」出现，无 `ACL` 报错
- [ ] 状态页正确显示主/副状态与颜色
- [ ] 设置页保存后，`uci show szu-netauth` 值确实变了，且服务自动 reload
- [ ] 「立即检测」「立即登录」按钮可用，日志框有输出
- [ ] 浏览器控制台无 JS 报错

> ❗ **无法验证的部分（如实说明）**：真正的「掉线后自动重连」只能在下次真实掉线时才能证实。
> **我不会为了测试人为断开你的网络。** 可行的替代证据是：`--login` 的 `ret_code=2` 响应
> 已证明登录链路与解析逻辑正确，加上 S3 的服务在跑，即可合理推断掉线时能自动恢复。

---

## 10. 回滚

```sh
sh /etc/szu-netauth/uninstall.sh
```

该脚本会依次：
1. `/etc/init.d/szu-netauth stop && /etc/init.d/szu-netauth disable`
2. 删除本方案新增的 8 个文件
3. 清理 `/var/run/szu-netauth/`（内存盘）与 `/tmp/luci-indexcache*`
4. 重启 `rpcd`（让 LuCI 菜单消失）
5. 校验：确认全机没有残留的本方案文件

另外 S0 阶段会在**路由器**与**你本机**各留一份 `tar` 备份。

**风险等级说明**：全部改动均为**新增文件**，不修改 `network` / `firewall` / `dhcp` / `passwall` 等任何现有配置。
最坏情况是"认证脚本不工作"，此时路由器的网络行为与现在**完全一致**，不会有更差的结果。

---

## 11. 风险与未知

| # | 风险 | 说明 | 缓解 |
|---|---|---|---|
| 1 | 凭据明文 | `/etc/config/szu-netauth` 明文存卡号密码 | 权限 `600 root:root`；不加入任何 git；再加密需引入密钥管理，性价比低 |
| 2 | 一号多设备 | 认证落在路由器 WAN 一个 IP 上，家里设备共用 | 目前未观察到冲突（你 PC 之前自己登也正常）；是否合规由你判断 |
| 3 | 刷新鉴权不生效 | 若校园网后续增加"一号一设备/MAC 绑定"策略 | 无法预知；届时需改协议或换回单机模式 |
| 4 | procd 抓不到卡死 | `respawn` 只响应进程退出 | 已在 5.4 设计心跳看门狗 |
| 5 | 触发风控 `error hid` | 反复登录会被限流 | 已在 5.3 设计闸门 + 指数退避；页面也能看到退避状态 |
| 6 | LuCI 兼容性 | Kwrt 版本号自定（27.020.x），将来升级 LuCI 可能导致页面报错 | 认证层与界面层解耦；页面只做薄壳 |
| 7 | flash 磨损 | 常驻日志写 ubifs | 日志默认只进内存 syslog |
| 8 | 代理层干扰 | 本机有 passwall/xray/sing-box | 所有 curl 加 `--noproxy '*'` |
| 9 | 协议变更 | 校园网改认证协议 | 脚本与现有 exe 会同时失效，需重新对协议（无法预防） |

**未知项（实现时确认，不猜）**

- `poll` 模块的实际加载路径（官方 `system.js` 里有 `require poll`，但无独立 `poll.js` 文件）
- `procd_add_interface_trigger` 的确切 pattern 参数
- LuCI 静态资源缓存在本机 nginx 环境下的确切清理命令
- `/etc/init.d/szu-netauth reload` 是否必须显式定义 `reload_service()`

---

## 12. 待确认项

1. 菜单挂载位置：建议「**服务 → 校园网认证**」（备选：状态 / 顶层）
2. 是否需要 **「启用 / 停用服务」按钮**（需要额外授予 `exec /etc/init.d/szu-netauth` 的写权限，
   已含在 7.3 的 ACL 里；若不要可以去掉以缩小权限面）
3. 设置页密码字段默认打码显示，是否需要一个"显示密码"切换
4. 是否开启持久日志（默认关。开启会写 flash，非必要不建议）

---

*本文档中所有"实测"数据均来自 2026-09-30 对 `192.168.2.1` 的**只读**侦察，未做任何写入。*
