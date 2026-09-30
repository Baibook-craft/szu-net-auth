#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make_ipk.py —— 免 OpenWrt SDK，直接在普通机器上把包目录打成 .ipk

.ipk 的真实格式（2024 之后的 OpenWrt / Kwrt）
---------------------------------------------
网上很多老资料会说 "ipk 就是 ar 归档（和 .deb 一样）"，**那是旧格式**。
在较新的 OpenWrt（含本项目的目标 Kwrt 25.12）上实测：

    .ipk = gzip( tar( ./debian-binary, ./data.tar.gz, ./control.tar.gz ) )

也就是说 **外层既不是 ar，也没有第三层的成员头**，而是一个普通的
gzip 压缩 tar；里面再套两个各自独立 gzip 压缩的 .tar.gz 成员。

这不是猜的 —— opkg 的 libbb/unarchive.c 里 deb_extract() 是这么干的：

    gzip_exec(&tar_outer, NULL);                     /* 先把整个文件 gzip -d */
    while ((tar_header = get_header_tar(&tar_outer))) {
        if (strncmp(tar_header->name, "./", 2) == 0) name_offset = 2;
        if (strcmp("control.tar.gz", tar_header->name + name_offset) == 0) {
            gzip_exec(&tar_inner, NULL);              /* 再把该成员 gzip -d */
            unarchive(&tar_inner, ...);               /* 得到 control 所在的 tar */
        }
        seek_forward(&tar_outer, tar_header->size);
    }

所以如果你把 ipk 打成 ar 归档，opkg 第一步 gzip -d 就会失败，接着解不出
control，最后报一句极具误导性的错误：

    * pkg_init_from_file: Malformed package file /tmp/xxx.ipk.

（这个坑本项目实际踩过，详见 docs/DEPLOY.md 的"打包"章节。）

可复现构建
----------
所有时间戳固定为 SOURCE_DATE_EPOCH，gzip 不写文件名，条目按名字排序 ——
同样的源码必定产出逐字节相同的 ipk，方便校验发布物。

用法
----
    python3 tools/make_ipk.py                          # 打包
    python3 tools/make_ipk.py --inspect dist/xxx.ipk   # 只解析
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import sys
import tarfile
from pathlib import Path

# 2026-01-01 00:00:00 UTC —— 固定时间戳，保证构建可复现
SOURCE_DATE_EPOCH = 1767225600

PKG_NAME = "luci-app-szu-netauth"
DEFAULT_VERSION = "1.0.0"
DEFAULT_RELEASE = "1"
DEFAULT_ARCH = "all"
DEFAULT_SOURCE = "https://github.com/OWNER/szu-net-auth"
DEFAULT_MAINTAINER = "baibook <240120311+Baibook-craft@users.noreply.github.com>"

# 用 GNU tar 格式：实测官方 ipk 的外层 tar magic 就是 b"ustar  \\0"（GNU 风格），
# 而 opkg 的 get_header_tar() 只要求前 5 字节为 "ustar"。
TAR_FORMAT = tarfile.GNU_FORMAT

# data.tar.gz 里按路径决定权限。
# 为什么不读磁盘 st_mode：Windows / Git Bash 上 chmod 基本无效，读出来一律
# 是 0o666，打出来的包在路由器上缺可执行位，服务直接起不来。所以用路径规则
# 显式决定，跨平台结果一致。
EXEC_PREFIXES = ("etc/init.d/", "etc/uci-defaults/", "etc/rc.d/", "usr/bin/", "usr/sbin/")


def _file_mode(rel: str) -> int:
    if rel.startswith(EXEC_PREFIXES):
        return 0o755
    if rel.endswith(".sh"):
        return 0o755
    return 0o644


# ---------------------------------------------------------------------------
# tar 构造
# ---------------------------------------------------------------------------

def _tar_bytes(entries, compress: bool) -> bytes:
    """entries 为 (归档名, 内容, 权限, 是否目录)。

    compress=True  → 返回 .tar.gz 字节（用于 control/data 成员）
    compress=False → 返回裸 tar 字节（用于外层）
    """
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=TAR_FORMAT) as tf:
        for arcname, content, mode, is_dir in entries:
            ti = tarfile.TarInfo(arcname)
            ti.mode = mode
            ti.uid = 0
            ti.gid = 0
            ti.uname = "root"
            ti.gname = "root"
            ti.mtime = SOURCE_DATE_EPOCH
            if is_dir:
                ti.type = tarfile.DIRTYPE
                ti.size = 0
                tf.addfile(ti)
            else:
                ti.type = tarfile.REGTYPE
                ti.size = len(content)
                tf.addfile(ti, io.BytesIO(content))

    if not compress:
        return raw.getvalue()

    gz = io.BytesIO()
    # filename="" -> gzip 头不写原始文件名（FLG 的 FNAME 位保持 0），
    # 与官方产出一致，也避免把打包机的路径泄漏进包体。
    with gzip.GzipFile(filename="", fileobj=gz, mode="wb",
                       compresslevel=9, mtime=SOURCE_DATE_EPOCH) as f:
        f.write(raw.getvalue())
    return gz.getvalue()


# ---------------------------------------------------------------------------
# 文件树
# ---------------------------------------------------------------------------

def _collect_tree(root: Path) -> tuple[list, int]:
    """扫描 root/ 目录，返回 (tar 条目, Installed-Size 估算值)。"""
    if not root.is_dir():
        raise SystemExit(f"找不到包目录：{root}")

    files = sorted(p for p in root.rglob("*") if p.is_file())

    dirs: set[str] = set()
    for p in files:
        for parent in p.relative_to(root).parents:
            if parent.as_posix() != ".":
                dirs.add(parent.as_posix())

    entries = [(".", b"", 0o755, True)]
    entries += [(f"./{d}", b"", 0o755, True) for d in sorted(dirs)]

    # Installed-Size：按「每个文件/目录各占 4 KiB 块」估算，
    # 这是 opkg 显示用的数字，不参与任何安装决策。
    total = 4096 * (1 + len(dirs))
    for p in files:
        rel = p.relative_to(root).as_posix()
        content = p.read_bytes()
        total += ((len(content) + 4095) // 4096) * 4096
        entries.append((f"./{rel}", content, _file_mode(rel), False))

    return entries, total


def _read_control_files(ipk_dir: Path) -> list:
    """读取 ipk/ 下的元数据文件。control 和 conffiles 必需，其余可选。"""
    plan = [("control", 0o644), ("conffiles", 0o644),
            ("postinst", 0o755), ("prerm", 0o755), ("postrm", 0o755)]
    out = []
    for name, mode in plan:
        p = ipk_dir / name
        if p.is_file():
            body = p.read_bytes()
            if not body.endswith(b"\n"):
                body += b"\n"
            out.append((f"./{name}", body, mode, False))
        elif name in ("control", "conffiles"):
            raise SystemExit(f"缺少必需文件 {p}")
    return out


def _patch_control(body: bytes, **repl: str) -> bytes:
    text = body.decode("utf-8")
    for key, val in repl.items():
        text = text.replace(f"@@{key}@@", val)
    if "@@" in text:
        left = [ln for ln in text.splitlines() if "@@" in ln]
        raise SystemExit("control 里还有未替换的占位符：\n  " + "\n  ".join(left))
    return text.encode("utf-8")


# ---------------------------------------------------------------------------
# 构建
# ---------------------------------------------------------------------------

def build(repo: Path, out_dir: Path, version: str, release: str, arch: str,
          source_url: str, maintainer: str) -> Path:
    root_dir = repo / "root"
    ipk_dir = repo / "ipk"

    data_entries, installed_size = _collect_tree(root_dir)

    # ---- control.tar.gz ----
    ctrl_entries = [(".", b"", 0o755, True)]
    for arcname, body, mode, is_dir in _read_control_files(ipk_dir):
        if arcname == "./control":
            body = _patch_control(
                body,
                VERSION=f"{version}-{release}",
                INSTALLED_SIZE=str(installed_size),
                SOURCE_URL=source_url,
                MAINTAINER=maintainer,
            )
        ctrl_entries.append((arcname, body, mode, is_dir))

    control_tar_gz = _tar_bytes(ctrl_entries, compress=True)
    data_tar_gz = _tar_bytes(data_entries, compress=True)

    # ---- 外层：gzip(tar(debian-binary, data.tar.gz, control.tar.gz)) ----
    outer_entries = [
        ("./debian-binary", b"2.0\n", 0o644, False),
        ("./data.tar.gz", data_tar_gz, 0o644, False),
        ("./control.tar.gz", control_tar_gz, 0o644, False),
    ]
    outer_tar = _tar_bytes(outer_entries, compress=False)

    gz = io.BytesIO()
    with gzip.GzipFile(filename="", fileobj=gz, mode="wb",
                       compresslevel=9, mtime=SOURCE_DATE_EPOCH) as f:
        f.write(outer_tar)
    blob = gz.getvalue()

    out_dir.mkdir(parents=True, exist_ok=True)
    ipk_path = out_dir / f"{PKG_NAME}_{version}-{release}_{arch}.ipk"
    ipk_path.write_bytes(blob)

    digest = hashlib.sha256(blob).hexdigest()
    sha_path = ipk_path.with_suffix(ipk_path.suffix + ".sha256")
    # 必须写字节、不能用 write_text：后者在 Windows 上会把 \n 转成 \r\n，
    # 而 sha256sum -c 解析到行尾的 \r 会当成文件名的一部分，直接报
    # "No such file or directory"。实测踩过。
    sha_path.write_bytes(f"{digest}  {ipk_path.name}\n".encode("ascii"))

    n_files = sum(1 for e in data_entries if not e[3])
    n_dirs = sum(1 for e in data_entries if e[3])
    print(f"[ipk] {ipk_path}")
    print(f"      格式        gzip(tar) 现代格式  {'（不是 ar）'}")
    print(f"      版本        {version}-{release}   架构 {arch}")
    print(f"      体积        {len(blob):,} 字节")
    print(f"      内含        {n_files} 个文件 / {n_dirs} 个目录")
    print(f"      Installed-Size {installed_size:,} 字节")
    print(f"      sha256      {digest}")
    print(f"      校验文件    {sha_path.name}")
    return ipk_path


# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------

def inspect(path: Path) -> None:
    blob = path.read_bytes()
    kind = "gzip(tar) 现代格式" if blob[:2] == b"\x1f\x8b" else (
        "ar 归档（旧格式，本机 opkg 不接受）" if blob[:8] == b"!<arch>\n" else "未知")
    print(f"== {path.name} ==")
    print(f"  体积        {len(blob):,} 字节")
    print(f"  头 8 字节   {blob[:8]!r}")
    print(f"  格式        {kind}")

    if blob[:2] != b"\x1f\x8b":
        print("  （非现代格式，无法继续解析）")
        return

    outer = gzip.decompress(blob)
    print(f"  外层 tar    {len(outer):,} 字节   magic@257 = {outer[257:265]!r}")
    print("\n  -- 外层 tar 成员 --")
    with tarfile.open(fileobj=io.BytesIO(outer), mode="r:") as tf:
        for m in tf.getmembers():
            print(f"     {m.name:<22} type={m.type.decode()} mode={m.mode:o} size={m.size:,}")

        print("\n  -- control.tar.gz --")
        ctrl = tf.extractfile("./control.tar.gz")
        ctrl_bytes = ctrl.read() if ctrl else b""
        with tarfile.open(fileobj=io.BytesIO(ctrl_bytes), mode="r:gz") as t2:
            for m in t2.getmembers():
                print(f"     {m.name:<22} type={m.type.decode()} mode={m.mode:o} size={m.size:,}")
            body = t2.extractfile("./control")
            if body:
                print("\n  ---- control ----")
                for ln in body.read().decode("utf-8", "replace").rstrip().splitlines():
                    print(f"  | {ln}")
                print("  -----------------")

        print("\n  -- data.tar.gz --")
        dd = tf.extractfile("./data.tar.gz")
        dd_bytes = dd.read() if dd else b""
        with tarfile.open(fileobj=io.BytesIO(dd_bytes), mode="r:gz") as t3:
            for m in t3.getmembers():
                print(f"     {m.name:<52} type={m.type.decode()} mode={m.mode:o}")


def main() -> int:
    ap = argparse.ArgumentParser(description="把包目录打成可 opkg install 的 .ipk")
    ap.add_argument("--repo", default=str(Path(__file__).resolve().parent.parent))
    ap.add_argument("--out", default=None, help="输出目录（默认 <repo>/dist）")
    ap.add_argument("--version", default=DEFAULT_VERSION)
    ap.add_argument("--release", default=DEFAULT_RELEASE)
    ap.add_argument("--arch", default=DEFAULT_ARCH)
    ap.add_argument("--source-url", default=DEFAULT_SOURCE)
    ap.add_argument("--maintainer", default=DEFAULT_MAINTAINER)
    ap.add_argument("--inspect", metavar="IPK", help="只解析已有 ipk，不构建")
    args = ap.parse_args()

    if args.inspect:
        inspect(Path(args.inspect))
        return 0

    repo = Path(args.repo).resolve()
    out_dir = Path(args.out).resolve() if args.out else repo / "dist"
    build(repo, out_dir, args.version, args.release, args.arch,
          args.source_url, args.maintainer)
    return 0


if __name__ == "__main__":
    sys.exit(main())
