# luci-app-szu-netauth

深圳大学校园网自动认证 —— OpenWrt / Kwrt 插件（LuCI 网页界面 + procd 常驻服务）。

路由器认证一次，家里所有设备共用这条已认证的 WAN；掉线自动重连，再也不用手动打开门户网页。

> **认证协议来自 [`ceynri/szu-network-connecter`](https://github.com/ceynri/szu-network-connecter)**
> （MIT License，Copyright (c) 2020 Ceynri）。本项目把那套协议用 shell 在路由器上重新实现，
> 详见 [来源与致谢](#来源与致谢) 与 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。
>
> 本插件的直接来源是一台路由器上手工部署的 shell 脚本（见 [`docs/PLAN.md`](docs/PLAN.md)
> 与 [`docs/DEPLOY.md`](docs/DEPLOY.md)）。现在打包成标准 `.ipk`，一条命令即可安装。

---

## 来源与致谢

### 这个项目的源头是一位学长的浏览器插件

深大校园网的登录方式比较绕（有线走 `172.30.255.42:801` 的 eportal 门户，WIFI 走
`drcom.szu.edu.cn`，两套协议还不一样）。**[@ceynri](https://github.com/ceynri)** 在
2020 年写了一款浏览器扩展把这些都封装成一次点击，并**把协议细节完整地读了出来**：

- 仓库：<https://github.com/ceynri/szu-network-connecter>
- 许可：MIT（Copyright (c) 2020 Ceynri）
- 本项目引用的版本：v1.4.1，commit `9d45765`

上游作者已毕业离校，项目不再主动维护，但代码和文档一直是后来者最重要的参考。
**本项目的认证逻辑（URL、参数、成功判据）全部来自这份实现**，
我们只是把它从 JavaScript 翻译到 shell，再包成路由器插件。

### 演绎链

```
ceynri/szu-network-connecter          浏览器扩展（JavaScript）
  └── src/js/login-post.js
         ↓ 改写为 C#
      Windows 桌面版（C# WinForms，src/CampusAuth.cs）
         ↓ 改写为 POSIX shell + procd + LuCI
      路由器版（shell 脚本）
         ↓ 打包为 .ipk
      本仓库 luci-app-szu-netauth
```

每一环都换了语言和运行环境，**但认证协议这一层的事实始终沿用上游**。
具体沿用了哪些常量与参数，[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) 里逐条列了。

---

## 特性

- **纯 shell + procd**，运行时不需要 Python / Lua / Node，对 flash 和内存都很客气
- **多账号轮换**：可以保存多个校园网账号，一次认证失败就换下一个再试；
  开机后固定先试列表里的第一个，顺序可在网页上拖拽或按 ▲▼ 调整（详见「多账号」）
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

在**路由器**上执行：

```sh
# 下载最新的 ipk
wget -O /tmp/luci-app-szu-netauth.ipk \
  https://github.com/Baibook-craft/szu-net-auth/releases/latest/download/luci-app-szu-netauth_1.1.0-1_all.ipk

# 安装
opkg install /tmp/luci-app-szu-netauth.ipk
```

想校验下载完整性的话，同目录还有 `.sha256` 文件：

```sh
wget -O /tmp/pkg.sha256 \
  https://github.com/Baibook-craft/szu-net-auth/releases/latest/download/luci-app-szu-netauth_1.1.0-1_all.ipk.sha256
cd /tmp && sha256sum -c pkg.sha256
```

### 方法二：本地打包再安装

```sh
git clone https://github.com/Baibook-craft/szu-net-auth.git
cd szu-net-auth
./build-ipk.sh                      # 产出 dist/luci-app-szu-netauth_1.1.0-1_all.ipk
scp dist/*.ipk root@192.168.1.1:/tmp/
ssh root@192.168.1.1 opkg install /tmp/luci-app-szu-netauth_1.1.0-1_all.ipk
```

打包只需要 **Python 3.8+**，不需要 OpenWrt SDK。

### 安装后

打开 LuCI：**服务 → 校园网认证 → 设置**，在「账号列表」里填上卡号与密码
（想填几个就填几个），保存并应用。

> 全新安装时账号是空的，插件**不会**自动启动服务（免得无意义地反复登录）。
> 填完账号后回到**状态**页点「启动服务」，或者命令行
> `/etc/init.d/szu-netauth restart`。

---

## 配置项

配置文件是 `/etc/config/szu-netauth`（权限 600，明文保存卡号密码，注意别外传）。

| 配置项 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `1` | 总开关。设 0 则只检测不登录 |
| `auto_switch` | `1` | 登录失败后是否换下一个账号再试（详见下一节「多账号」） |
| `net_check` | `3600` | 常规联网检测周期（秒）。这是「心跳」 |
| `campus_check` | `3600` | 判定「不在校园网」时的重试周期（秒） |
| `retry_interval` | `60` | 检测到离线后，重新尝试登录的间隔（秒） |
| `retry_max` | `5` | **单轮**重连最多尝试几次，用尽即停手。多账号时每个账号各占一次 |
| `net_check_method` | `http+ping` | `http` / `http+ping` / `ping`，见下 |
| `ping_host` | `www.baidu.com` | ICMP 探测目标，可填 IP 以避开 DNS 依赖 |
| `login_paths` | `eportal` | 登录线路，可选 `eportal` / `drcom_wifi` / `drcom_nth` |
| `login_min_interval` | `30` | 两次登录之间的绝对最小间隔（秒），防连点 |
| `persist_log` | `0` | 是否把日志落盘到 `/etc/szu-netauth/state.log`（默认只进内存 syslog，不磨损 flash） |

卡号和密码不在这张表里 —— 它们各自是独立的 `config account` 段，见下一节。

---

## 多账号

认证用的卡号、密码放在**独立的 `config account` 段**里，可以配任意多个：

```uci
config account 'main'
	option label '主号'          # 显示名，可以留空
	option cardid '123456'       # 校园网卡号（注意：不是学号）
	option password '……'
	option enabled '1'           # 0 = 临时停用，但保留在列表里

config account 'backup'
	option label '备用号'
	option cardid '……'
	option password '……'
	option enabled '1'
```

### 顺序规则

**列表顺序就是认证顺序**，规则如下：

1. 开机后（以及每一轮重新开始重连时）**固定先试列表里的第一个账号**；
2. 这一次没通过 → 等 `retry_interval` 秒后试**下一个**账号；
3. 试到最后一行就绕回第一个，如此循环，直到用满 `retry_max` 次就停手；
4. 只要有一次成功，下一轮又从第一个账号重新开始。

举个例子：账号顺序是 `主号, 备用号`，`retry_max = 5`，那么一次掉线会依次尝试

```
主号 → 备用号 → 主号 → 备用号 → 主号        （第 5 次仍失败就停手）
```

然后等下一个心跳周期（`net_check`）再重新检测。

把 `auto_switch` 设成 `0` 就关掉轮换 —— 永远只用第一个账号（等同于旧版的单账号行为）。

> **哪些账号会被跳过**：`enabled` 为 `0` 的、以及卡号留空的，认证时都会被忽略，
> 也不会占用 `retry_max` 的次数。

### 怎么调整顺序

网页上有两种方式，效果完全一样：

- 拖动行首的 **☰** 图标
- 点行尾 **▲▼** 按钮

**改完必须点「保存并应用」**，顺序才会写进 `/etc/config/szu-netauth`。

> 原理：两种方式都是调 LuCI 的 `uci.move()`，它会重排每个段的 `.index`；
> 保存时 LuCI 的 `reorderSections()` 按 `.index` 调 rpcd 的 `uci order` 落盘。
> 命令行等价做法就是直接编辑配置文件里各个 `config account` 段的先后顺序。

### 轮换状态存在哪

「下一次该用哪个账号」记在 `/var/run/szu-netauth/cur_account` 里，内容是账号的段名。
`/var/run` 是 tmpfs，**重启即清空** —— 这正是「开机后第一次必定用第一个账号」
的实现方式，不需要额外逻辑。

### 从 1.0.x 升级

升级时 `postinst` 会自动把旧版的 `global.cardid` / `global.password` 搬成第一个账号
（段名 `main`，名称「主号」）并删掉旧字段；开机时 `uci-defaults` 还会再兜底一次。
迁移是幂等的，重复执行没有副作用。

就算迁移没跑成也不会断网 —— 认证脚本本身仍然兼容旧格式：一个可用账号都没有时，
它会退回读 `global.cardid` / `global.password`。

> **升级后会多出一个 `/etc/config/szu-netauth-opkg`**，这是正常现象，不是出错。
> 它是「新版的默认配置模板」：因为你改过原来的配置，opkg 不愿覆盖，就把它另存了一份。
> 里面那套注释挺有用（账号顺序规则的说明就在里面），想删也可以放心 `rm`；
> 真正生效的永远是你原来的 `/etc/config/szu-netauth`。

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
  └─ 立即检测一次                        ← 账号从列表第一个开始
       ├─ 在线 ──► 等 net_check（60 分钟）→ 再检测       ← 主心跳
       └─ 离线 ──► 第1次(立即) → 60s → 第2次 → 60s → … → 第5次
                      │    （多账号时，这几次会依次换账号）
                      ├─ 某次成功 ──► 回到在线心跳（账号也回到第一个）
                      └─ 5 次用尽 ──► 停手，等下一个 net_check
                                      周期后重新检测（仍离线则再开一轮 5 次）
```

---

## 网页界面

**服务 → 校园网认证**，下分两个页面：

- **状态** —— 当前状态、WAN 地址、校园网判定、离线成因、ICMP 延迟、重连轮次、
  **账号列表 / 下次使用账号 / 上次使用账号**、服务启停与开机自启按钮、
  手动「立即检测」/「立即登录」、最近 50 行日志。每 5 秒自动刷新。
- **设置** —— 上面那张配置表对应的可视化表单，外加：
  - **账号列表**（表格，一个账号一行）：可「添加」增行、行尾 ✕ 删行，
    每行有 `名称` / `卡号` / `密码`（自带显示·隐藏切换）/ `启用`（开关）四个可编辑格。
  - **排序**：两种等效方式 —— ① 按住行首的 ☰ 手柄上下拖动；② 用 `排序` 列里的
    ▲ / ▼ 按钮上下移一行。**表格从上到下的顺序，就是认证时尝试的顺序**。
    改完都要点「保存并应用」才会写进配置文件。
  - **账号切换**：`auto_switch` 开关，对应下面「多账号」章节的轮换行为。

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

**加了多个账号，但它一直在用同一个？**

按顺序排查：

1. `账号切换`（`auto_switch`）是不是被关掉了 —— 关掉时只用列表第一个；
2. 那个账号的 `启用` 开关是不是关着的 —— 关着的账号会被整行跳过（状态页的
   「账号列表」只显示参与轮换的账号，用它对照）；
3. 账号数只有一个 —— 单账号没有轮换可言。

想确认实际行为，看状态页的「上次使用账号 / 下次使用账号」，或者：

```sh
cat /var/run/szu-netauth/cur_account     # 下次尝试用哪个（不存在 = 用第一个）
cat /var/run/szu-netauth/last_account    # 上次实际用的是哪个
/etc/szu-netauth/auth.sh --check | sed -n '/账号列表/,$p'
```

**怎么让某个账号最先被尝试？**

把它移到账号列表的**第一行**（☰ 拖到最上面，或一路点 ▲）。开机后的第一次认证、
以及每次成功后重新进入在线心跳时，都会从第一行开始。

---

## 从源码构建

### 方式一：免 SDK（推荐）

```sh
./build-ipk.sh                 # 打包
./build-ipk.sh --inspect       # 打包并打印包体结构
./build-ipk.sh --version 1.2.0 --release 2   # 临时覆盖版本号
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
│   ├── postinst             # 安装后：迁移旧配置、清 LuCI 缓存、设开机自启
│   ├── prerm                # 卸载前：停服务并等进程真正退出
│   └── postrm               # 删除后：清运行时残留
├── root/                    # 安装到路由器根目录的文件树
│   ├── etc/config/szu-netauth            # 默认配置（含一个空账号骨架）
│   ├── etc/init.d/szu-netauth            # procd 服务定义
│   ├── etc/szu-netauth/auth.sh           # 认证主脚本（约 990 行）
│   ├── etc/uci-defaults/50-luci-app-...  # 装完 / 开机时刷新 LuCI 并存旧配置
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
  **不要**把这个文件提交到任何仓库、不要随备份外传。**本仓库不含任何凭据**
  （默认配置里只留了一个空账号骨架，卡号与密码都是空值）。
- 使用前请确认符合你所在学校的网络使用规定。
- 本项目与深圳大学无隶属关系，也未获得其授权或背书。

---

## 关于本项目的开发方式（AI 参与说明）

这个项目是**人和 AI 协作**完成的。分工如实写在下面 —— 后来读代码的人有权知道
这段代码是怎么来的。

### AI 是什么

- **工具**：[WorkBuddy](https://www.workbuddy.cn) 编程助手
- **本次使用的底层模型**：DeepSeek-V4.1-Flash

### AI 做了什么

- 通读上游浏览器插件的 `login-post.js` 与 Windows 桌面版的 `CampusAuth.cs`，
  把认证协议翻译成 POSIX shell
- 从零编写 `.ipk` 打包器 `tools/make_ipk.py`，其中包括**摸索出**新版 OpenWrt 的
  `.ipk` 真实格式（`gzip(tar(...))`，而不是老资料普遍说的 `ar` 归档）
- 编写 procd 服务定义、LuCI 状态页与设置页、opkg 的四个安装钩子
- 排查「`Malformed package file`」「卸载后留下孤儿进程」这类只在真机上才暴露的问题
- 撰写 README、CHANGELOG、本说明与第三方许可声明

### 人做了什么

- 提出全部需求与约束（60 分钟心跳、掉线每分钟重试最多 5 次、断电重启后立刻认证……）
- 提供真实路由器与校园网环境，在真机上反复执行安装 / 卸载 / 升级 / 重启并回报结果
- 审阅每一版方案，指出问题要求返工
- 核对并确认本文的署名与来源信息
- 决定以 MIT 许可开源、确定仓库名与发布方式

### 请留意

- 代码是**在真实路由器上跑通过的**（装、卸、升级、断电重启均有实测），
  不是「看着对」就交
- 但 AI 生成的内容仍可能有疏漏，尤其是**只在特定网络环境成立**的假设。
  如果你的网段或学校门户与作者的不同，请以 `auth.sh --check` 的实际输出为准
- 真正的功劳在上游：认证协议是 **@ceynri** 读出来的，
  AI 只是把它换了一种语言重写

---

## 许可

本项目以 [MIT](LICENSE) 许可发布，Copyright (c) 2026 baibook。

认证协议的实现源自 [`ceynri/szu-network-connecter`](https://github.com/ceynri/szu-network-connecter)
（MIT，Copyright (c) 2020 Ceynri），其完整许可原文与沿用内容清单见
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。
