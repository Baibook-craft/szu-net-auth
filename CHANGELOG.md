# 变更记录

本文件记录本插件的版本变更。格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.0] - 2026-09-30

首个正式版本。由一台路由器上手工部署的脚本整理为标准 OpenWrt 插件包。

### 功能

- 校园网认证常驻服务（procd 监督），支持 eportal / drcom_wifi / drcom_nth 三条线路
- LuCI 网页界面：状态页（含服务控制、手动触发、实时日志）与设置页
- 掉线自动重连：固定间隔重试 + 次数上限，用尽后回到低频心跳
- 断电重启友好：WAN 未就绪时短轮询等待接口，就绪后立即认证
- 联网判定支持 `http` / `http+ping` / `ping` 三种方式，并将「被门户劫持」
  与「网络层不通」区分开来
- ICMP 探测强制 IPv4，规避校园网 IPv6 绕过认证门户导致的「假在线」
- 心跳看门狗，能捕获进程存活但卡死的场景
- 认证脚本自带 `--check` / `--status` / `--login` / `--trigger` 等排障子命令

### 打包

- `build-ipk.sh` + `tools/make_ipk.py`：免 OpenWrt SDK 打包，只需 Python 3.8+
- 可复现构建（时间戳固定，同源码产出逐字节相同的 ipk）
- 同时提供标准 luci feed 的 `Makefile`，可用 SDK 构建

### 来源

- 认证协议实现演绎自 [`ceynri/szu-network-connecter`](https://github.com/ceynri/szu-network-connecter)
  （MIT，Copyright (c) 2020 Ceynri），经由 Windows 桌面版（C#）改写而来。
  完整的沿用内容清单与上游许可原文见 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

### 开发方式

- 代码由 AI 编程助手 [WorkBuddy](https://www.workbuddy.cn)（底层模型 DeepSeek-V4.1-Flash）
  在人类作者的需求、决策与实机验证下编写。详见 README 的「关于本项目的开发方式」。

### 已知问题

- 安装时 opkg 会打印一句 `ERROR: truncating field 4 <0x...> to 5 byte`。
  这是 opkg 自身日志格式化（ulog）的噪音，与本插件无关，不影响安装结果。
- 常驻循环采用 5 秒分片的 `sleep`，而 shell 在前台 `sleep` 期间不处理信号，
  因此停止服务最长有 5 秒延迟。`prerm` 已相应等待，不会留下孤儿进程。
- 卸载不会删除 `/etc/szu-netauth/state.log`（若开启了 `persist_log`），
  这是有意为之 —— 方便回查历史日志。
