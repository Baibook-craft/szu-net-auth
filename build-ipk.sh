#!/usr/bin/env bash
#
# build-ipk.sh —— 免 OpenWrt SDK 打 .ipk
#
# 适用场景：手上只有一个跑着 OpenWrt/Kwrt 的路由器，没有编译机、也不想
# 下几 GB 的 SDK。本脚本调用 tools/make_ipk.py 直接产出 .ipk。
#
# 用法：
#   ./build-ipk.sh                 # 打包到 dist/
#   ./build-ipk.sh --inspect       # 打包后顺便把包体结构打印出来自检
#   ./build-ipk.sh --version 1.1.0 --release 2
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# ---- 1. 找一个 Python 3 ----
PY="${PYTHON:-}"
if [ -z "$PY" ]; then
	for c in python3 python py; do
		if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
	done
fi
if [ -z "$PY" ]; then
	echo "错误：找不到 Python 3。请先安装，或用 PYTHON=/path/to/python3 ./build-ipk.sh" >&2
	exit 1
fi
if ! "$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
	echo "错误：$PY 版本过低，需要 Python 3.8+" >&2
	exit 1
fi

# ---- 2. 版本号：以 Makefile 为单一来源，避免两处各写一遍 ----
VER="$(sed -n 's/^PKG_VERSION:=//p' Makefile | head -n1)"
REL="$(sed -n 's/^PKG_RELEASE:=//p' Makefile | head -n1)"
[ -z "$VER" ] && { echo "错误：无法从 Makefile 读出 PKG_VERSION" >&2; exit 1; }
[ -z "$REL" ] && REL=1

# ---- 3. 参数透传（允许命令行覆盖版本）----
ARGS=()
INSPECT=0
while [ $# -gt 0 ]; do
	case "$1" in
		--inspect) INSPECT=1 ;;
		--version) VER="$2"; ARGS+=(--version "$2"); shift ;;
		--release) REL="$2"; ARGS+=(--release "$2"); shift ;;
		--source-url) ARGS+=(--source-url "$2"); shift ;;
		--maintainer) ARGS+=(--maintainer "$2"); shift ;;
		-h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) echo "未知参数：$1" >&2; exit 2 ;;
	esac
	shift
done

echo "== 打包 luci-app-szu-netauth $VER-$REL =="
"$PY" tools/make_ipk.py "${ARGS[@]+"${ARGS[@]}"}"

# ---- 4. 可选自检：把 ar 成员和 tar 内容列出来 ----
if [ "$INSPECT" = "1" ]; then
	IPK="dist/luci-app-szu-netauth_${VER}-${REL}_all.ipk"
	echo
	"$PY" tools/make_ipk.py --inspect "$IPK"
fi

echo
echo "完成。产物在 dist/ ："
ls -la dist/ 2>/dev/null || true
