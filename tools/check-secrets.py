#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""凭据自检 —— 防止把真实的校园网卡号 / 密码提交进仓库或打进 ipk。

为什么需要这个：
    LuCI 的默认配置里 `cardid` / `password` 必须是空的，但真实凭据很容易
    从别的地方漏出去 —— 最常见的是「拿自己的卡号当注释里的例子」。
    v1.1.0 发布前就真的漏过一次：`auth.sh` 的注释和 `settings.js` 的
    `placeholder` 里都写了自己的真实卡号，而当时的 CI 只检查了配置模板，
    完全没发现。所以这里改成「宁可误报」的粗暴规则。

规则（任一不过就退出码 1）：
    1. root/etc/config/szu-netauth 里的 cardid / password 必须是空字符串。
    2. 全仓库（含 dist/*.ipk 内部）不允许出现 6 位及以上的纯数字串，
       除非它在下面的 ALLOW 白名单里。
       依据：校园网卡号是 6 位数字，密码常含长数字；而仓库里本来
       就没有需要写 6 位数字的地方 —— 白名单只有 6 条，肉眼可核对。
    3. 不允许出现「5 位以上数字紧跟 2 位以上字母」的 token，
       这能抓住「以数字开头的口令」这种写法（ALLOW_PWD_LIKE 目前为空）。
       **注意这条不是万能的**：字母开头的口令它管不到，
       所以凡是 password 相关的那几行，人还是得自己看一眼。
       也别在本文件里写口令形状的示例 —— 本脚本会扫自己，写了就报警。
    4. ALLOW / ALLOW_PWD_LIKE 里的每一条都必须真的出现在仓库里，否则说明
       白名单过期了，要顺手删掉（避免它悄悄变成新的藏身处）。

用法：
    python3 tools/check-secrets.py            # 检查仓库
    python3 tools/check-secrets.py --ipk dist/luci-app-szu-netauth_1.1.1-1_all.ipk
"""
import argparse
import io
import gzip
import os
import re
import sys
import tarfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# 允许出现的 6 位以上数字串。加新条目**必须**先确认它不是任何人的真实凭据。
# key = 数字串，value = 它是什么（写清楚，否则下次没人敢删）。
ALLOW = {
    "000000000000": "文档里的占位标识 / auth.sh 里的全零桩值",
    "123456":       "README / CHANGELOG 里的示例卡号（脱敏后统一用它）",
    "131072":       "auth.sh 里读取响应的字节上限",
    "1767225600":   "tools/make_ipk.py 的 SOURCE_DATE_EPOCH（2026-01-01）",
    "240120311":    "tools/make_ipk.py 里维护者 GitHub 用户 ID",
    "757575":       "overview.js 里的颜色值 #757575",
}

# 同上，但给「数字+字母」那种口令形状的 token 用。目前是空的，
# 本仓库里本来就没有任何口令形状的东西。
ALLOW_PWD_LIKE = {}

# 6 位以上数字串。前后不能紧邻字母/数字/下划线/点/连字符，
# 这样 sha256 十六进制串里的数字段不会误报（后面紧跟 a-f 会被 lookahead 挡掉）。
NUM_RUN = re.compile(r"(?<![0-9A-Za-z_.\-])[0-9]{6,}(?![0-9A-Za-z_\-])")

# 口令形状：5 位以上数字紧跟 2 位以上字母。
# 单靠 NUM_RUN 抓不到它 —— 数字后面紧跟着字母，边界规则会把整串当成一个词。
# 这条规则很窄（本仓库实测零误报），但**不是**万能的：
# 字母开头的口令它管不到，所以 password 那几行该肉眼看的还得看。
PWD_LIKE = re.compile(r"(?<![0-9A-Za-z_])[0-9]{5,}[A-Za-z]{2,}[0-9A-Za-z]*(?![0-9A-Za-z_])")

# 整行豁免：这些行的数字是打包器/工具自己算出来的，不是人写的，也不稳定。
# 白名单（ALLOW）只适合放**固定不变**的数字；这种会随文件大小浮动的要用行豁免。
LINE_EXEMPT = [
    re.compile(r"^\s*Installed-Size:\s*[0-9]+\s*$"),   # ipk/control，打包时按目录大小估算
]

SKIP_DIRS = {".git", "dist", "build", "__pycache__", ".tmp-verify", "node_modules"}

TEXT_EXT = {
    ".sh", ".js", ".json", ".md", ".py", ".yml", ".yaml", ".txt",
    ".conf", ".config", ".ipk", ".postinst", ".prerm", ".postrm", ".preinst",
}
TEXT_NAMES = {"control", "conffiles", "debian-binary", "Makefile", "LICENSE"}


def is_text(name):
    base = os.path.basename(name)
    if base in TEXT_NAMES:
        return True
    return os.path.splitext(base)[1].lower() in TEXT_EXT


def scan_text(label, text, hits, used, used2):
    """逐行扫，方便按行豁免并给出准确行号。"""
    for i, line in enumerate(text.split("\n"), 1):
        if any(rx.match(line) for rx in LINE_EXEMPT):
            continue
        for m in NUM_RUN.finditer(line):
            num = m.group(0)
            if num in ALLOW:
                used.add(num)
                continue
            hits.append((label, i, num, "纯数字串"))
        for m in PWD_LIKE.finditer(line):
            tok = m.group(0)
            if tok in ALLOW_PWD_LIKE:
                used2.add(tok)
                continue
            hits.append((label, i, tok, "数字+字母，像密码"))


def scan_dir(root, hits, used, used2):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for fn in filenames:
            p = os.path.join(dirpath, fn)
            if not is_text(fn):
                continue
            try:
                text = open(p, encoding="utf-8").read()
            except (UnicodeDecodeError, OSError):
                continue
            scan_text(os.path.relpath(p, root), text, hits, used, used2)


def unpack_ipk(path):
    """本项目 .ipk = gzip(tar(debian-binary, data.tar.gz, control.tar.gz))。
    同时兼容传统 ar 归档。"""
    raw = open(path, "rb").read()
    if raw.startswith(b"!<arch>\n"):
        out, pos = [], 8
        while pos + 60 <= len(raw):
            hdr = raw[pos:pos + 60]
            size = int(hdr[48:58].decode("ascii", "replace").strip() or 0)
            out.append((hdr[0:16].decode("ascii", "replace").strip().rstrip("/"),
                        raw[pos + 60:pos + 60 + size]))
            pos += 60 + size + (size & 1)
        members = out
    elif raw[:2] == b"\x1f\x8b":
        with tarfile.open(fileobj=io.BytesIO(gzip.decompress(raw)), mode="r:") as tf:
            members = [(m.name.lstrip("./"), tf.extractfile(m).read())
                       for m in tf.getmembers() if not m.isdir()]
    else:
        raise ValueError("认不出的 ipk 容器格式：开头 %r" % raw[:16])

    for name, blob in members:
        if name.endswith(".tar.gz"):
            with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tf:
                for m in tf.getmembers():
                    if m.isdir():
                        continue
                    f = tf.extractfile(m)
                    if f is not None:
                        yield "%s:%s" % (name, m.name), f.read()
        else:
            yield name, blob


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ipk", action="append", default=[],
                    help="额外扫描已打好的 ipk（可多次）")
    ap.add_argument("--root", default=REPO)
    args = ap.parse_args()

    hits, used, used2 = [], set(), set()
    scan_dir(args.root, hits, used, used2)

    # 规则 1：配置模板里的卡号 / 密码必须为空
    cfg = os.path.join(args.root, "root/etc/config/szu-netauth")
    cfg_bad = []
    if os.path.exists(cfg):
        for i, line in enumerate(open(cfg, encoding="utf-8"), 1):
            if re.match(r"\s*option (cardid|password)\s+'[^']+'", line):
                cfg_bad.append("root/etc/config/szu-netauth:%d: %s" % (i, line.strip()))

    n_members = 0
    for ipk in args.ipk:
        for label, blob in unpack_ipk(ipk):
            n_members += 1
            try:
                text = blob.decode("utf-8")
            except UnicodeDecodeError:
                continue
            scan_text("%s!%s" % (os.path.basename(ipk), label),
                      text, hits, used, used2)

    ok = True
    print("检查范围：%s%s" % (args.root, "".join(" + " + i for i in args.ipk)))
    print("  数字白名单 %d 条，本次用到 %d 条；密码形白名单 %d 条，用到 %d 条"
          % (len(ALLOW), len(used), len(ALLOW_PWD_LIKE), len(used2)))
    if args.ipk:
        print("  ipk 内共 %d 个成员" % n_members)

    if cfg_bad:
        ok = False
        print("\n!! 配置模板里出现了非空的 cardid / password：")
        for x in cfg_bad:
            print("   " + x)

    if hits:
        ok = False
        print("\n!! 发现 %d 处疑似凭据：" % len(hits))
        for label, line, tok, kind in hits:
            print("   %s:%s  ->  %s   （%s）" % (label, line, tok, kind))
        print("\n   如果确认它与个人凭据无关，把它**和它的来历**加进")
        print("   tools/check-secrets.py 的 ALLOW / ALLOW_PWD_LIKE 字典；")
        print("   否则请改成脱敏示例值（卡号用 123456）。")

    stale = sorted(set(ALLOW) - used)
    if stale:
        ok = False
        print("\n!! 数字白名单里有 %d 条已经用不上了（仓库里找不到），请删掉：" % len(stale))
        for s in stale:
            print("   %s  (%s)" % (s, ALLOW[s]))

    stale2 = sorted(set(ALLOW_PWD_LIKE) - used2)
    if stale2:
        ok = False
        print("\n!! 密码形白名单里有 %d 条已经用不上了，请删掉：" % len(stale2))
        for s in stale2:
            print("   %s  (%s)" % (s, ALLOW_PWD_LIKE[s]))

    print()
    if ok:
        print("凭据自检通过。")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
