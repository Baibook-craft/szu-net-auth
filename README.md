# luci-app-szu-netauth

深圳大学校园网自动认证 —— OpenWrt / Kwrt 插件（LuCI 网页界面 + procd 常驻服务）。

路由器认证一次，家里所有设备共用这条已认证的 WAN；掉线自动重连，再也不用手动打开门户网页。

> 本插件的来源是一台路由器上手工部署的 shell 脚本（见 [`docs/PLAN.md`](docs/PLAN.md)
> 与 [`docs/DEPLOY.md`](docs/DEPLOY.md)）。现在打包成标准 `.ipk`，一条命令即可安装。

---

## 特性

- **纯 shell + procd**，运行时不需要 Python / Lua / Node，对 flash 和内存都很客气
- **检测节奏克制**：默认 60 分钟确认一次网络，短时断网不会触发无休止的登录请求
- **重连有节流**：真正掉线后每分钟试一次、**最多 5 次**就停手，等下一个检测周期再来一轮（避免把校园网登录接口刷出风控）
- **ICMP 探测强制 IPv4**（`ping -4`）：校园网 IPv6 常常绕过认证门户，若不强制会出现「IPv4 早掉线、ping 却说通」，导致自动重连**永远不触发**
- **HTTP 探测不跟随重定向**：被认证门户 302 劫持即判定为离线（对应原 C# 版的 `AllowAutoRedirect = false`）
- **断电重启友好**：WAN 还没拿到 DHCP 地址时用 10 秒短轮询等待接口就绪，就绪后立即认证，不会傻等一整个小时
- **自愈**：procd 负责进程崩溃后拉起；脚本内部另有心跳看门狗，能抓到「进程还活着但卡死」的情况
- **网页挂了不影响认证**：LuCI 只是一层薄壳，业务逻辑与界面完全解耦

---

## 安装

### 方法一：直接下载 ipk 安装（推荐）

在**路由器**上执行（把 `Baibook-craft` 换成仓库所属账号）：

```sh
# 下载最新的 ipk
wget -O /tmp/luci-app-szu-netauth.ipk \
  https://github.com/Baibook-craft/szu-net-auth/releases/latest/download/luci-app-szu-netauth_1.0.0-1_all.ipk

# 安装
opkg install /tmp/luci-app-szu-netauth.ipk
```

想校验下载完整性的话，同目录还有 `.sha256` 文件：

```sh
wget -O /tmp/pkg.sha256 \
  https://github.com/Baibook-craft/szu-net-auth/releases/latest/download/luci-app-szu-netauth_1.0.0-1_all.ipk.sha256
cd /tmp && sha256sum -c pkg.sha256
```

### 方法二：本地打包再安装

```sh
git clone https://github.com/Baibook-craft/szu-net-auth.git
cd szu-net-auth
./build-ipk.sh                      # 产出 dist/luci-app-szu-netauth_1.0.0-1_all.ipk
scp dist/*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 opkg install /tmp/luci-app-szu-netauth_1.0.0-1_all.ipk
```

打包只需要 **Python 3.8+**，不需要 OpenWrt SDK。

### 安装后

打开 LuCI：**服务 → 校园网认证 → 设置**，填入卡号与密码，保存并应用。

> 全新安装时凭据是空的，插件**不会**自动启动服务（免得无意义地反复登录）。
> 填完凭据后回到**状态**页点「启动服务」，或者命令行
> `/etc/init.d/szu-netauth restart`。

---

## 配置项

配置文件是 `/etc/config/szu-netauth`（权限 600，明文保存卡号密码，注意别外传）。

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `1` | 总开关。设 0 则只检测不登录 |
| `cardid` | 空 | **校园网卡号**（不是学号） |
| `password` | 空 | 校园网密码 |
| `net_check` | `3600` | 常规联网检测周期（秒）。这是「心跳」 |
| `campus_check` | `3600` | 判定「不在校园网」时的重试周期（秒） |
| `retry_interval` | `60` | 检测到离线后，重新尝试登录的间隔（秒） |
| `retry_max` | `5` | 单轮重连最多尝试几次，用尽即停手 |
| `net_check_method` | `http+ping` | `http` / `http+ping` / `ping`，见下 |
| `ping_host` | `www.baidu.com` | ICMP 探测目标，可填 IP 以避开 DNS 依赖 |
| `login_paths` | `eportal` | 登录线路，可选 `eportal` / `drcom_wifi` / `drcom_nth` |
| `login_min_interval` | `30` | 两次登录之间的绝对最小间隔（秒），防连点 |
| `persist_log` | `0` | 是否把日志落盘到 `/etc/szu-netauth/state.log`（默认只进内存 syslog，不磨损 flash） |

### 关于 `net_check_method`

插件**不把 ping 当作「已认证」的判据**，因为认证门户完全可能只劫持 TCP/HTTP 而放行
ICMP —— ping 通推不出「已认证」。所以默认设计是 **HTTP 判定 + ICMP 分类**：

| HTTP | ICMP | 判定 | 含义 |
|---|---|---|---|
| 通 | — | 在线 | 已认证，正常 |
| 不通 | 通 | 离线（被门户劫持） | 网络层可达，典型未认证 |
| 不通 | 不通 | 离线（网络层不通） | WAN 断了 / DNS 挂了 / 上游故障 |

状态页会直接显示这个区别，排障时比笼统的一句「离线」有用得多。

### 运行节奏

```
开机 / 服务启动
  └─ 立即检测一次
       ├─ 在线 ──► 等 net_check（60 分钟）→ 再检测       ← 主心跳
       └─ 离线 ──► 第1次(立即) → 60s → 第2次 → 60s → … → 第5次
                      │
                      ├─ 某次成功 ──► 回到在线心跳
                      └─ 5 次用尽 ──► 停手，等下一个 net_check
                                      周期后重新检测（仍离线则再开一轮 5 次）
```

---

## 网页界面

**服务 → 校园网认证**，下分两个页面：

- **状态** —— 当前状态、WAN 地址、校园网判定、离线成因、ICMP 延迟、重连轮次、
  服务启停与开机自启按钮、手动「立即检测」/「立即登录」、最近 50 行日志。
  每 5 秒自动刷新。
- **设置** —— 上面那张配置表对应的可视化表单，密码框自带显示/隐藏切换。

两个页面都依赖 `ubus` 的 `file exec` 去调用 `/etc/szu-netauth/auth.sh --status`。

---

## 命令行

脚本本身也能直接用，排障时很方便：

```sh
/etc/szu-netauth/auth.sh --status        # 打印当前状态
/etc/szu-netauth/auth.sh --check         # 完整环境 + 联网自检
/etc/szu-netauth/auth.sh --login         # 强制登录一次（跳过在线判断）
/etc/szu-netauth/auth.sh --once          # 检测一次，需要则登录，然后退出
/etc/szu-netauth/auth.sh --trigger check # 唤醒常驻循环，立刻重新检测
/etc/szu-netauth/auth.sh --tail 100      # 看最近 100 行运行日志
```

服务管理：

```sh
/etc/init.d/szu-netauth start|stop|restart|enable|disable
logread -e szu-netauth          # 看 syslog
```

---

## 卸载

```sh
opkg remove luci-app-szu-netauth
```

- **用户配置会被保留**（`/etc/config/szu-netauth` 是 conffile，opkg 会明确告知
  `Not deleting modified conffile`）。想连配置一起删，卸载后手动 `rm` 即可。
- 卸载时服务会被停掉，`/etc/rc.d/S99szu-netauth` 软链会被清理。
- `/etc/szu-netauth/state.log`（若开启了 `persist_log`）会保留，方便你回查。

---

## 常见问题

**装完菜单里看不到「校园网认证」？**

清一下 LuCI 缓存再刷新页面：

```sh
rm -f /tmp/luci-indexcache* /tmp/luci-modulecache -r
/etc/init.d/rpcd reload
```

正常情况下安装脚本（`/etc/uci-defaults/`）已经自动做过这件事了。

**安装时输出一句 `ERROR: truncating field 4 <0x...> to 5 byte`？**

这是 opkg 自身的日志格式化噪音（它底层用的 ulog 对某个格式说明符处理不好），
**与本插件无关，不影响安装结果**。判断安装是否成功看有没有
`Installing ... to root...` 和 `Configuring ...` 这两行。

**状态页一直显示「不在校园网」？**

说明 WAN 拿到的地址不在校园网段。查一下：

```sh
ubus call network.interface.wan status | grep -A3 ipv4-address
```

校园网通常是 `172.17.*` / `172.30.*` / `10.*`。

**一直登录失败？**

先用 `--check` 确认是不是真的离线；确认 `login_paths` 里只留了实际可达的线路；
再确认填的是**校园网卡号**而不是学号。

---

## 从源码构建

### 方式一：免 SDK（推荐）

```sh
./build-ipk.sh                 # 打包
./build-ipk.sh --inspect       # 打包并打印包体结构
./build-ipk.sh --version 1.1.0 --release 2
```

底层是 `tools/make_ipk.py`，纯 Python 手工构造 `.ipk`，不依赖 binutils 的 `ar`。
构建是**可复现**的：时间戳固定，同样的源码必定产出逐字节相同的 ipk。

### 方式二：OpenWrt SDK

本仓库是标准 luci feed 包布局，可以放进 SDK 构建：

```sh
# 把本目录放到 SDK 的 package/ 下（或作为 feed 引入）
make package/luci-app-szu-netauth/compile V=s
```

> SDK 路径产出的包由 `luci.mk` 生成 control 与钩子，与免 SDK 路径的
> `ipk/control`、`ipk/postinst` 是两套等价实现，行为一致。

### `.ipk` 到底是什么格式（重要）

**新版 OpenWrt / Kwrt 的 `.ipk` 不是 `ar` 归档**（很多老资料会说是，那是旧格式）。
实测结构是：

```
.ipk = gzip( tar( ./debian-binary, ./data.tar.gz, ./control.tar.gz ) )
```

opkg 的 `libbb/unarchive.c` 里 `deb_extract()` 先把整个文件 `gzip -d`，再当作 tar
遍历找 `control.tar.gz` 成员，然后对该成员**再** `gzip -d`，才得到 control 所在的 tar。

如果按老资料打成 `ar` 归档，opkg 第一步 `gzip -d` 就会失败，接着解不出 control，
最后抛出一句极具误导性的错误：

```
* pkg_init_from_file: Malformed package file /tmp/xxx.ipk.
```

`tools/make_ipk.py` 已按正确格式产出，注释里写明了依据。

---

## 目录结构

```
.
├── Makefile                 # 标准 OpenWrt feed 包（供 SDK 构建）
├── build-ipk.sh             # 免 SDK 打包入口
├── tools/make_ipk.py        # 纯 Python 的 ipk 构造器
├── ipk/                     # ipk 元数据（免 SDK 路径使用）
│   ├── control              # 包描述与依赖
│   ├── conffiles            # 哪些文件算「用户配置」，升级不覆盖
│   ├── postinst             # 安装后：清 LuCI 缓存、设开机自启
│   ├── prerm                # 卸载前：停服务并等进程真正退出
│   └── postrm               # 删除后：清运行时残留
├── root/                    # 安装到路由器根目录的文件树
│   ├── etc/config/szu-netauth            # 默认配置
│   ├── etc/init.d/szu-netauth            # procd 服务定义
│   ├── etc/szu-netauth/auth.sh           # 认证主脚本（约 830 行）
│   ├── etc/uci-defaults/50-luci-app-...  # 装完自动刷新 LuCI
│   ├── usr/share/luci/menu.d/            # 菜单注册
│   ├── usr/share/rpcd/acl.d/             # 权限声明
│   └── www/luci-static/resources/view/szu-netauth/
│       ├── overview.js                   # 状态页
│       └── settings.js                   # 设置页
└── docs/                    # 方案与部署纪实（含踩坑记录）
```

---

## 免责声明

- 本项目仅用于**自动化你自己账号的正常认证流程**，不绕过任何计费或访问控制。
- 卡号与密码以明文保存在路由器的 `/etc/config/szu-netauth`（权限 600）。
  **不要**把这个文件提交到任何仓库、不要随备份外传。仓库本身不含任何凭据。
- 使用前请确认符合你所在学校的网络使用规定。

## 许可

[MIT](LICENSE)
