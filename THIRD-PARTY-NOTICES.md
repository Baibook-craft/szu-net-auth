# 第三方代码与许可声明

本项目的**认证协议实现并非从零编写**，而是从下列上游项目逐步演绎而来。
按上游 MIT 许可的要求，此处保留其完整版权与许可声明。

---

## 1. ceynri/szu-network-connecter

| 项 | 内容 |
|---|---|
| 仓库 | https://github.com/ceynri/szu-network-connecter |
| 作者 | [@ceynri](https://github.com/ceynri) |
| 许可 | MIT |
| 版权 | Copyright (c) 2020 Ceynri |
| 本项目引用的版本 | **v1.4.1**，commit `9d45765ca7a5b1f134e02073e6b298f8439339b6`（2022-01-02） |
| 引用文件 | `src/js/login-post.js` |

上游是一个**浏览器扩展**（Chrome / Firefox），把深大校园网的登录门户操作
变成一次点击。本项目把它读出来的认证协议，用 shell 在路由器上重新实现了一遍。

### 本项目具体沿用了什么

`login-post.js` 里的两个函数，是本项目认证逻辑的直接来源：

| 上游函数 | 本项目对应实现 | 沿用的内容 |
|---|---|---|
| `login(type)` | `auth.sh` → `login_drcom()` | 两个旧 Drcom 门户 URL（`https://drcom.szu.edu.cn/a70.htm`、`http://172.30.255.2/0.htm`）；POST 字段名 `DDDDD` / `upass` / `0MKKey`；`0MKKey` 的两个取值 —— WIFI 线为 `123456`，有线为「登　录」二字的 GBK 编码 `%B5%C7%A1%A1%C2%BC`；从响应里用 `msga='...'` 提取错误信息 |
| `newLogin()` | `auth.sh` → `login_eportal()` | eportal 门户地址 `http://172.30.255.42:801/eportal/portal/login`；完整查询参数（`callback=dr1003`、`login_method=1`、`user_account=,0,{卡号}`、`wlan_user_mac=000000000000`、`jsVersion=4.1.3`、`terminal_type=1` 等）；JSONP 剥壳方式；以及判定规则 —— `result==1` 成功，`ret_code==2`（IP 已在线）也视为成功 |

字符串常量 `123456` 与 `000000000000` 是**协议本身规定的固定值**，不是任何人的账号信息。

### 上游许可原文

```
MIT License

Copyright (c) 2020 Ceynri

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. 完整的演绎链

本项目是这条链上的第四环：

```
ceynri/szu-network-connecter         浏览器扩展（JavaScript），MIT，2020
  └── src/js/login-post.js
         │  登录协议的原始实现
         ▼  改写为 C#（Windows 桌面版）
      Windows 桌面版（C# WinForms）
      src/CampusAuth.cs
         │  "移植自浏览器插件 szu-network-connecter"
         ▼  改写为 POSIX shell + procd + LuCI
      路由器版（shell 脚本，本仓库的前身）
      files/etc/szu-netauth/auth.sh
         ▼  打包为标准 .ipk
      本仓库 luci-app-szu-netauth
```

每一环都不是简单的复制粘贴：语言、运行环境、进程模型都换了，
但**认证协议这一层的事实**（URL、参数名、参数取值、成功判据）始终沿用上游。

### 本仓库相对上游的改动

- 语言：JavaScript / C# → POSIX shell（BusyBox 兼容）
- 运行环境：浏览器 / Windows 桌面 → OpenWrt 路由器，procd 常驻守护进程
- 新增：断电重启友好、重连节流（每分钟一次、最多 5 次）、
  IPv4 强制 ICMP、HTTP 重定向检测、心跳看门狗、LuCI 网页界面
- 修正：上游 C# 版对 `ret_code` 的解析在遇到带引号的字符串值时会误判，
  本版已兼容

---

## 3. 其他第三方内容

| 内容 | 来源 | 许可 |
|---|---|---|
| LuCI 框架 API | [openwrt/luci](https://github.com/openwrt/luci) | Apache-2.0 |
| procd / ubus / uci 用法示例 | [openwrt/openwrt](https://github.com/openwrt/openwrt) | GPL-2.0 |
| 公共 DNS 地址（114.114.114.114、223.5.5.5 等） | 公开服务，出现在文档示例中 | — |

---

## 4. 本仓库自身

Copyright (c) 2026 baibook —— 以 [MIT](LICENSE) 许可发布。

---

## 5. 商标与免责

「深圳大学」「SZU」等名称仅用于说明本软件适用于该校网络环境，
本项目与深圳大学无任何隶属关系，也未获得其授权或背书。
