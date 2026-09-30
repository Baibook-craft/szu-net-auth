# DEPLOY.md — 深大校园网自动认证（路由器版）部署与运维

本文档是整个方案的落地手册。**设计思路、为什么这么选** 见 `PLAN.md`；本文只讲
**怎么装、怎么验、踩过哪些坑、出问题怎么查**。

---

## 1. 一句话说明

把原来 Windows 桌面版（`E:/tools/szuWeb/szu-net-auth-win/`，C# WinForms）的校园网
自动认证，改写成路由器上常驻运行的 shell 脚本 + procd 服务 + LuCI 网页，
让**路由器自己完成认证，家里所有设备共用这一条已认证的 WAN**，
掉线自动重连，不用每台设备各自登录。

```
┌────────────────────────────────────────────────────────────┐
│  LuCI 网页（薄壳）  /www/luci-static/resources/view/...     │
│    ├── 状态页 overview.js   只读状态 + 点按钮               │
│    └── 设置页 settings.js   纯 form.Map，直接读写 UCI        │
└───────────────────────────┬────────────────────────────────┘
                            │ ubus: file.exec / rc.init
┌───────────────────────────▼────────────────────────────────┐
│  procd 服务   /etc/init.d/szu-netauth                       │
│    └── 监督 /etc/szu-netauth/auth.sh --daemon               │
│        respawn 3600 5 10 · stdout/stderr 进 logd            │
└───────────────────────────┬────────────────────────────────┘
                            │ 每轮循环重读配置
┌───────────────────────────▼────────────────────────────────┐
│  auth.sh  ← 真正的认证逻辑全在这里                           │
│    cfg() → wan_ip() → is_campus() → is_online()             │
│      → login_eportal() / login_drcom() → write_status()     │
└────────────────────────────────────────────────────────────┘
```

**关键设计约束**：网页挂了、UCI 改错了，`auth.sh` 里的自动重连**照常工作**。
业务逻辑与界面完全解耦。

### 运行节奏与重连状态机

默认参数下（`net_check=3600` / `retry_interval=60` / `retry_max=5`），守护循环长这样：

```
开机 → 立即检测一次（不等任何周期）
  │
  ├─ WAN 还没拿到地址 ──► 每 10 秒重试，直到接口就绪（不占用长周期）
  │
  ├─ 不在校园网 ────────► 每 3600 秒重试（认证无意义，只探测）
  │
  ├─ 在线 ──────────────► 等 3600 秒 → 再检测            ┐ 主心跳
  │                                                      │
  └─ 离线 ──► 进入重连轮次                                ┘
        第 1 次尝试（立即）
          失败 → 等 60 秒 → 第 2 次
          失败 → 等 60 秒 → 第 3 次
          失败 → 等 60 秒 → 第 4 次
          失败 → 等 60 秒 → 第 5 次
          失败 → 停手（giveup），等 3600 秒 → 回到主心跳
```

要点：

- **开机不等周期**：`S99` 拉起服务后立刻做第一次检测，那时 WAN 通常已就绪。
- **WAN 未就绪单独处理**：这条分支是专为断电重启准备的。若不单独拎出来，
  `is_campus ""` 会失败并落入「不在校园网」，而那里等的是 3600 秒 —— 于是
  **来电后要等整整一小时才会去认证**。改用 10 秒轮询就没这个问题。
- **重连有次数上限**：一轮最多 5 次、每次隔 60 秒（掉线后 4 分钟内试完），
  然后停手一小时。刻意不做无限重试，免得反复撞 `error hid` 风控。
- **停手 ≠ 放弃**：下一个 3600 秒到了照样重新检测；若仍离线，会**再开一轮** 5 次重试。
- **ICMP 探测不影响判定**：判定以 HTTP 为准，ping 只用于给「为什么离线」分类（见 §6.2）。

状态值对照（状态页徽章 / `status.json` 的 `state` 字段）：

| state | 含义 |
|---|---|
| `online` | 在线（已认证） |
| `waiting` | WAN 尚未获取地址（断电重启后的正常过渡态） |
| `offline` | 检测到离线，正在尝试登录 |
| `fail` | 本次登录失败，等 `retry_interval` 秒再试 |
| `giveup` | 本轮重连次数用尽，已停手，等下一个常规周期 |
| `nocampus` | WAN 不在校园网段，认证无意义 |
| `disabled` | 配置里 `enabled=0` |
| `stopped` | 服务未运行（只在从未写过状态时出现） |

> **权衡提醒**：`net_check=3600` 意味着**掉线后最多一小时才被发现**（发现后 4 分钟内试完 5 次）。
> 这是「少打扰、不触发风控」换来的代价。若觉得太久，把 `net_check` 调小即可
> （如 600 = 10 分钟），设页里就能改。

---

## 2. 文件清单与路径映射

本仓库 `files/` 目录 **1:1 对应**路由器的绝对路径，`deploy.sh` 只是照搬。

| 本仓库路径 | 路由器路径 | 权限 | 作用 |
|---|---|---|---|
| `files/etc/szu-netauth/auth.sh` | `/etc/szu-netauth/auth.sh` | 755 | **核心脚本**，全部认证逻辑 |
| `files/etc/szu-netauth/uninstall.sh` | `/etc/szu-netauth/uninstall.sh` | 755 | 一键回滚 |
| `files/etc/init.d/szu-netauth` | `/etc/init.d/szu-netauth` | 755 | procd 服务定义 |
| `files/etc/config/szu-netauth.example` | （模板，不直接部署） | — | UCI 配置样板；真实文件由 `deploy.sh` 生成 |
| `files/www/luci-static/resources/view/szu-netauth/overview.js` | 同路径 | 644 | 状态页 |
| `files/www/luci-static/resources/view/szu-netauth/settings.js` | 同路径 | 644 | 设置页 |
| `files/usr/share/luci/menu.d/luci-app-szu-netauth.json` | 同路径 | 644 | 菜单注册（服务 → 校园网认证） |
| `files/usr/share/rpcd/acl.d/luci-app-szu-netauth.json` | 同路径 | 644 | 权限声明 |
| `deploy.sh` | （只在本机跑） | — | 分阶段部署脚本 |
| `backup/` | — | — | 部署前参考快照 |

**不在本仓库留明文**：`/etc/config/szu-netauth` 里含卡号密码，由 `deploy.sh` 从
`szu-net-auth-win/config/settings.ini` 读入、在内存里拼好、直接管道写进路由器，
本机不落地；路由器上立即 `chmod 600`。

---

## 3. 前置条件

- 路由器地址 `192.168.2.1`（账号密码用你自己的路由器设置）
- 本机有 OpenSSH（Windows 自带即可，无需 `sshpass`，本方案用 `SSH_ASKPASS` 免交互）
- 目标路由器为 OpenWrt 系（本项目实测 Kwrt 25.12.0-rc3 / kernel 6.12.66 / aarch64）
- 路由器上**不需要** python3 —— 全部用 BusyBox 工具实现

> 本机 Git Bash 环境下 `PATH` 是坏的，跑任何命令前先：
> `export PATH="/c/Windows/System32:/usr/bin:/bin:$PATH"`
> `deploy.sh` 里已经自动加好，直接 `bash deploy.sh ...` 即可。

---

## 4. 部署

```bash
cd E:/tools/szuWeb/szu-net-auth-openwrt

bash deploy.sh backup     # S0 备份（改动前必做）
bash deploy.sh scripts    # S1 上传 auth.sh + 生成 UCI 配置
bash deploy.sh verify     # S2 脚本层验证（单测 + --check + --login）
bash deploy.sh service    # S3 上传 init.d + enable + start
bash deploy.sh ui         # S4 上传 LuCI 页面 + 清缓存 + 重启 rpcd
bash deploy.sh all        # 以上全部，按顺序
bash deploy.sh uninstall  # 一键回滚
```

各阶段在干什么：

- **S0**：把路由器上将要涉及的路径打包存到 `/root/szu-netauth-backup/`，
  同时把 `network`/`firewall`/`dhcp` 三个关键配置拉回本机存 `backup/*.reference.txt`，
  并记录 md5 —— 部署完要核对它们**没被改动**。
- **S1**：上传脚本层 + 从 `settings.ini` 读凭据生成 UCI 配置。
- **S2**：先用**抓到的真实响应串**跑解析器离线单测（含 C# 版踩过的 `ret_code`
  带引号用例），再 `--check` / `--login` / `--status`。
- **S3**：上传服务定义、`enable`（建 `S99`/`K10` 软链）、`start`，打印服务状态与日志。
- **S4**：上传两个 JS + 菜单 + ACL，清 `/tmp/luci-indexcache*`，重启 `rpcd` 和 `nginx`。

部署完浏览器打开 `http://192.168.2.1` → **服务 → 校园网认证**。

---

## 5. 验证清单

以下命令都在路由器上跑（`ssh root@192.168.2.1`，或包在 `deploy.sh` 里）。

### 5.1 服务层

```sh
ubus call rc list | jsonfilter -e '@["szu-netauth"]'
# 期望：{ "start": 99, "stop": 10, "enabled": true, "running": true }
#   ↑ 四个字段缺任何一个都说明踩了 §6.1 的坑

ubus call service list '{"name":"szu-netauth"}' | \
  jsonfilter -e '@["szu-netauth"]["instances"]'
# 期望：running=true，command 含 auth.sh --daemon，respawn {threshold:3600,timeout:5,retry:10}

ls -l /etc/rc.d/ | grep szu-netauth
# 期望：S99szu-netauth 与 K10szu-netauth 两个软链都在（开机自启）
```

### 5.2 运行状态

```sh
cat /var/run/szu-netauth/status.json
# 期望字段：
#   state=online  campus=1  online=1  wan_ip=172.17.x.x
#   daemon_running=1  fail_count=0  interval=180
```

### 5.3 认证线路

```sh
/etc/szu-netauth/auth.sh --login
# 已在线时期望：已在线：IP: 172.17.x.x 已经在线！
# 这条命令不改变任何状态，可以随时安全执行
```

### 5.4 界面

```sh
# 静态资源可服务（在路由器上本地回环测）
curl -s -o /dev/null -w '%{http_code}\n' \
  http://127.0.0.1/luci-static/resources/view/szu-netauth/overview.js
# 期望 200

# 菜单注册
cat /usr/share/luci/menu.d/luci-app-szu-netauth.json   # 应含 admin/services/szu-netauth
```

### 5.5 未污染检查

```sh
md5sum /etc/config/network /etc/config/firewall /etc/config/dhcp
# 应与 backup/*.reference.txt 里记录的值完全一致
# 参考值（2026-09-30 部署前）：
#   network  7fc50e31c634c9aa79ac8dcb7782f371
#   firewall 8baffa8153dad63ac14b42b37fccad14
#   dhcp     4ec3a150020b8aec163607212ec8249b
```

---

## 6. 已知坑（都是实测踩出来的）

### 6.1 ★ rpcd 的 `rc` 对象只解析 init 脚本的**前缀约 580 字节**

**症状**：

```sh
ubus call rc list | jsonfilter -e '@["szu-netauth"]'
# 得到 { "enabled": false }      ← 少了 start / stop / running
```

但与此同时：

```sh
/etc/init.d/szu-netauth enabled        # 真
ubus call luci getInitList '{"name":"szu-netauth"}'
# { "index": 99, "stop": 10, "enabled": true }   ← 这个是对的
```

于是 LuCI 把服务显示成「未启用」，而 `rc init enable/disable` 又能正常工作。

**根因**：`rc` 对象读 init 脚本时有一个约 **580 字节**的前缀窗口，超出部分直接丢弃。
`START=99` 若落在窗口外，`rc list` 就解析不到 start/stop；而 `enabled` 字段要靠
解析出的 `START` 值去推导 rc.d 软链名（`S99szu-netauth`），推不出来就一律报 `false`。

**实测数据**（路由器上二分测得，两种构造互相印证）：

| 构造 | `START=99` 的字节偏移 | `rc list` 返回 |
|---|---|---|
| 合成头（全 ASCII 注释） | 578 | 完整（start/stop/enabled/running） |
| 合成头 | 657 | 丢 `running` |
| 合成头 | 736 | 丢 `stop` |
| 合成头 | 815 | 只剩 `enabled` |
| 真实脚本逐行截断 | 590 | 只剩 `start` |
| 真实脚本逐行截断 | **627（当时线上版本）** | 只剩 `enabled` |

另外做过对照：把头部里那句含 `START/STOP` 字样的注释改掉，**结果不变** ——
排除「关键字干扰」，**纯粹是长度问题**。

**修法**：`#!` 之后紧跟标题注释，然后**立刻**写死这三行：

```sh
#!/bin/sh /etc/rc.common
# SZU campus network auto authentication (procd service)
START=99
STOP=10
USE_PROCD=1
```

修复后 `START` 偏移 **82 字节**，余量充足，`rc list` 恢复正常：

```
{ "start": 99, "stop": 10, "enabled": true, "running": true }
```

> **教训**：这个文件里 `START/STOP/USE_PROCD` 的上方**不要再加注释**。
> 长篇说明一律写在变量下方，或写进本文档。
> `overview.js` 里另外保留了 `luci.getInitList` 作为兜底，双保险。

### 6.2 ★ ICMP 探测必须强制 IPv4（`-4`），否则会「假在线」

**症状**：IPv4 侧早已掉线（未认证），但探测仍报告「在线」，于是自动重连**永不触发**。

**根因**：这台机器上 IPv6 走**独立的 `wan6` 接口**（`network.interface.wan` 的
`ipv6-address` 是空的 `[]`）。不带 `-4` 时 `ping www.baidu.com` 会解析到 `2409:...`
的 v6 地址：

```
$ ping    -c 1 www.baidu.com   → PING www.baidu.com (2409:8c54:870:310:0:ff:b0ed:40ac)
$ ping -4 -c 1 www.baidu.com   → PING www.baidu.com (183.2.172.177)
```

而校园网的 IPv6 常常**不经过认证**（或走另一套通道）。结果是 v4 认证早就失效了、
v6 还通着、ping 说「通」—— 这是自动重连最怕的判据错误。
（顺带一提，强制 IPv4 后延迟也正常得多：v6 那次 48.6 ms，v4 只要 7.2 ms。）

**做法**：`auth.sh` 的 `ping_probe()` 一律写 `ping -4 -c 1 -W 2`。
而且**不用 ping 当作「在线」的判据** —— 门户可能只劫持 TCP/HTTP 而放行 ICMP，
ping 通推不出已认证。ICMP 只在 HTTP 判失败之后用于**分类成因**：

| 现象 | 判定 | 含义 |
|---|---|---|
| HTTP 通 | `online` | 已认证 |
| HTTP 不通、ping 通 | `offline` + `offline_kind=hijack` | 被门户劫持 —— 典型的未认证 |
| HTTP 不通、ping 也不通 | `offline` + `offline_kind=noroute` | 网络层就不通（WAN 断了 / DNS 挂了） |

### 6.3 procd 下 `reload` 默认是 no-op —— 必须自己写 `reload_service()`

`rc.common` 在 `USE_PROCD=1` 分支里，`reload()` 的实现是
「**若定义了 `reload_service` 就调用它，否则只再 `start` 一次**」。
对已经在运行的常驻服务来说，后者什么也不会发生 —— 于是「改了配置立即生效」
这件事其实是失效的。

**修法**：显式定义

```sh
reload_service() {
	logger -t szu-netauth "配置已变更，唤醒常驻循环以应用新配置"
	touch "$STATE_DIR/wake"
}
```

`auth.sh` 每轮循环开头都会重新 `config_load`，睡眠是 5 秒分片且能被 `wake`
文件打断，所以新配置最多 5 秒内生效，又不会掐断正在进行中的登录请求。

配合 `service_triggers()` 里的 `procd_add_reload_trigger "szu-netauth"`
（UCI 改动即触发）和 `procd_add_interface_trigger ... wan ... reload`
（WAN 口 up/down 立刻响应，不必死等 sleep 周期）。

验证：改任意一项配置后 `logread -e szu-netauth | tail`，应看到
`配置已变更，唤醒常驻循环以应用新配置` 紧跟 `收到手动唤醒信号`。

### 6.4 `/etc/init.d/` 下不要留 `.bak` 这类**可执行**备份

`cp -f` 出来的 `.bak.<时间戳>` 继承了 755 权限，会被 `rc list` 当成一个独立服务
列出来，在 LuCI「启动项」页面里显示成莫名其妙的条目。

**修法**：备份挪到别处。

```sh
mkdir -p /root/szu-netauth-backup
mv /etc/init.d/szu-netauth.bak.* /root/szu-netauth-backup/
```

### 6.5 路由器上没有的工具（BusyBox 阉割）

写脚本时**不能**假设以下东西存在：

| 命令 | 状况 | 替代写法 |
|---|---|---|
| `python3` | 无 | 用 `sed` / `awk` / `jsonfilter` |
| `iconv` | 无 | 用 **GBK 字节常量**直接 `grep`（见下） |
| `od` | 无 | `wc -c` 数字节 |
| `diff` | 无 | md5 比对 |
| `nc -z` | 不支持 | 用 `curl` 探测 |
| `grep -b` | 不支持 | `head -c N \| wc -c` 算偏移 |
| `cat -n` | 不支持 | `awk '{print NR": "$0}'` |
| `sleep 1.5` | 不支持小数 | `sleep 1` 循环 |

**GBK 字节常量匹配**（替代 `iconv`，用于旧 Drcom 线路的中文页面判定）：

```sh
认证成功页 = \310\317\326\244\263\311\271\246\322\263
登录成功窗 = \265\307\302\274\263\311\271\246\264\260
信息页     = \320\305\317\242\322\263
信息返回窗 = \320\305\317\242\267\265\273\330\264\260
```

### 6.6 本机（Windows Git Bash）侧的坑

- **`mktemp -t` 不要用**：返回 Windows 盘符路径（`C:\Users\...\Temp`），
  退出时 `rm` 会被安全层以 `embedded drive prefix is not allowed` 拒绝，
  结果把**含路由器密码的 askpass 文件**残留在临时目录里。
  → 改用工作区内固定路径 `$HERE/.tmp/askpass.sh` + `trap 'rm -f "$ASKPASS"' EXIT`。
- **`SSH_ASKPASS` 免交互**（本机 OpenSSH 无 `sshpass`）：

  ```sh
  export SSH_ASKPASS=/path/to/askpass.sh
  export SSH_ASKPASS_REQUIRE=force
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password -o PubkeyAuthentication=no \
      root@192.168.2.1 'command'
  ```

- **Bash 工具的 stdout 会把 UTF-8 中文显示成乱码** —— 这是**显示层**问题，
  不代表文件坏了。判定文件是否一致请用 **md5**，不要看 `cat` 输出。

### 6.7 从 C# 版移植时修掉的 bug：`ret_code` 带引号

原始抓包响应里既有 `"ret_code":1`，也有 `"ret_code":"1"`（字符串）。
C# 版只处理了数值型，遇到字符串型会误判。

`auth.sh` 的 `jnum()` 同时兼容两种写法：

```sh
jnum() {
	_jn=$(printf '%s' "$2" \
	  | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([-0-9][0-9]*\)".*/\1/p' | head -n1)
	if [ -z "$_jn" ]; then
		_jn=$(printf '%s' "$2" \
		  | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([-0-9][0-9]*\).*/\1/p' | head -n1)
	fi
	printf '%s' "$_jn"
}
```

`deploy.sh verify` 里的离线单测覆盖了这个用例，共 6 条，应全 `[ OK ]`。

---

## 7. 日常运维

```sh
# 看状态（人和机器都友好）
/etc/szu-netauth/auth.sh --status      # 输出 JSON
/etc/szu-netauth/auth.sh --check       # 只探测，不登录
/etc/szu-netauth/auth.sh --login       # 强制登录一次（在线时安全）
/etc/szu-netauth/auth.sh --tail 50     # 看最近日志

# 立即唤醒常驻循环做一次检测（不阻塞，最迟 5 秒响应）
/etc/szu-netauth/auth.sh --trigger check
/etc/szu-netauth/auth.sh --trigger login

# 日志（走 logd 内存环形缓冲，重启即清、不磨损 flash）
logread -e szu-netauth | tail -50

# 服务控制
/etc/init.d/szu-netauth start | stop | restart | reload | enable | disable

# 改配置（命令行；网页在「服务 → 校园网认证 → 设置」）
uci set szu-netauth.global.net_check=300
uci commit szu-netauth      # commit 后自动触发热重载
```

**全部可调参数**（`/etc/config/szu-netauth`；网页上在「服务 → 校园网认证 → 设置」）：

| 键 | 默认 | 作用 |
|---|---|---|
| `enabled` | `1` | 总开关。0 = 只检测不登录 |
| `cardid` / `password` | — | 校园网卡号（**不是学号**）/ 密码 |
| `net_check` | `3600` | 常规检测周期（秒）= 主心跳；掉线后最多这么久被发现 |
| `retry_interval` | `60` | 离线后重连尝试间隔（秒） |
| `retry_max` | `5` | 单轮最多尝试次数；用尽即停手，等下一个 `net_check` |
| `campus_check` | `3600` | 判定「不在校园网」时的重试周期（秒） |
| `net_check_method` | `http+ping` | 判定方式：`http` / `http+ping` / `ping` |
| `ping_host` | `www.baidu.com` | ICMP 目标；想避开 DNS 依赖可填 IP（如 `223.5.5.5`） |
| `login_paths` | `eportal` | 登录线路，按顺序试，第一条成功即停 |
| `login_min_interval` | `30` | 两次登录之间的绝对下限（秒），防连点 |
| `persist_log` | `0` | 是否把运行日志落盘到 flash |

改完后一条命令生效（不需要重启服务）：

```sh
uci set szu-netauth.global.net_check='600'
uci commit szu-netauth          # commit 会触发 reload → 唤醒循环重读配置，最多 5 秒生效
```

**几个概念别混淆**：

- `enabled`（**UCI 业务开关**）：关掉后常驻服务还在跑，但只检测、不登录。
  在「设置」页。
- `enable` / `disable`（**开机自启**）：控制 `/etc/rc.d/S99szu-netauth` 软链。
  在「状态」页的服务按钮里。
- `start` / `stop`（**进程本身**）：控制 `auth.sh --daemon` 跑不跑。

**日志策略**：默认 `persist_log=0`，日志只进 logd 的内存环形缓冲 ——
**有短期日志可看，又不写 flash**。只有确实需要长期留档时才在设置页打开
`persist_log`（会追加写 `/etc/szu-netauth/state.log`，超 128KB 轮转，**会磨损闪存**）。

---

## 8. 回滚

```bash
bash deploy.sh uninstall        # 本机发起
# 或直接在路由器上：
sh /etc/szu-netauth/uninstall.sh          # 交互确认
sh /etc/szu-netauth/uninstall.sh --yes    # 免确认
```

`uninstall.sh` 会：停服务 + `disable` → 删除本方案新增的 8 个路径 →
清 `/tmp/luci-indexcache*` → 重启 `rpcd` → 做残留检查。

**它不会碰** `network` / `firewall` / `dhcp`（本方案从头到尾没改过它们，
§5.5 的 md5 比对可以证明）。

路由器上的历史备份在 `/root/szu-netauth-backup/`，本机参考快照在 `backup/`。

---

## 9. 排错速查

| 现象 | 先查什么 |
|---|---|
| 网页「校园网认证」菜单不出现 | `ls /usr/share/luci/menu.d/luci-app-szu-netauth.json`；`rm -f /tmp/luci-indexcache*` 后刷新；`ubus call luci getMenu` 里搜 `szu-netauth` |
| 状态页全「—」/ 报读不到状态 | ACL 是否生效：`/etc/init.d/rpcd restart`；`ubus call file exec '{"command":"/etc/szu-netauth/auth.sh","params":["--status"]}'` |
| 显示「未启用」但手工 `enabled` 为真 | 就是 §6.1，检查 `START` 是否在文件前 580 字节内 |
| 改了配置不生效 | 是否 `uci commit`；`logread -e szu-netauth` 有没有「配置已变更」；§6.3 |
| 状态一直 `waiting` | WAN 没拿到地址。`ubus call network.interface.wan status` 看 `ipv4-address`；检查 WAN 口/网线/DHCP |
| 状态是 `giveup` | **这是正常的**：本轮 5 次重连都用尽了，正等下一个 `net_check`。想立刻再试一次就点「立即登录」 |
| 状态一直 `nocampus` | WAN 拿到的不是校园网段：看 `ipv4-address` 是否 `172.17.*` / `172.30.*` |
| **明明断网了却显示 `online`** | 最可能是 §6.2（IPv6 假在线）；其次看 `status.json` 的 `ping_ok` 与 `offline_kind` 是否自相矛盾。注意 `net_check=3600` 也意味着最多一小时才发现 |
| 断电重启后一小时才认证 | 应该不会发生了（`waiting` 分支专治此病，§6.1 节下方）。若真出现，确认 `auth.sh` 是新版：`grep -c WAN_READY_WAIT /etc/szu-netauth/auth.sh` 应 ≥ 2 |
| 一直登录失败 | `--check` 看是否真离线；`login_paths` 是否只留了 `eportal`；卡号是不是**校园网卡号**（不是学号） |
| 服务反复重启 | `logread -e szu-netauth`；`ps w \| grep auth.sh`；respawn 阈值 `3600 5 10`；看门狗阈值 `WATCHDOG_LIMIT=180` |
| 页面按钮点了没反应 | 浏览器 F12 看 ubus 报错；多半是 ACL 的 `write` 段缺 `rc.init` 或 `file.exec` |

---

## 10. 参考

- 上游 Windows 版（行为基准）：`E:/tools/szuWeb/szu-net-auth-win/`
- 设计文档：`PLAN.md`
- 认证线路（三条，本项目实测仅第一条可达）：
  - **eportal**（唯一可用）：`http://172.30.255.42:801/eportal/portal/login`，
    JSONP 返回 `dr1003({...})`，`result==1` 或 `ret_code==2` 算成功
  - drcom_wifi：`https://drcom.szu.edu.cn/a70.htm`，`0MKKey=123456`
  - drcom_nth（有线）：`http://172.30.255.2/0.htm`，`0MKKey=%B5%C7%A1%A1%C2%BC`
- 探测目标：
  - **HTTP（权威判据）**：`http://www.msftconnecttest.com/connecttest.txt`（要求 200 且正文含
    `Microsoft Connect Test`）或 `http://connect.rom.miui.com/generate_204`（要求 204）。
    **不跟随重定向** —— 被门户 302 劫持即判离线。
  - **ICMP（辅助分类）**：`ping -4 -c 1 -W 2 <ping_host>`，默认 `www.baidu.com`。
- 版本注记：`auth.sh` 自 2026-09-30 起为「重连轮次」版
  （新增 `retry_interval` / `retry_max` / `net_check_method` / `ping_host`，
   并新增 `waiting` 与 `giveup` 两个状态）。旧版的 `backoff_max` 指数退避已移除。

---

_最后更新：2026-09-30_
