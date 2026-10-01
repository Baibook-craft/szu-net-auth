#
# Copyright (C) 2026 baibook
#
# This is free software, licensed under the MIT License.
#
# 这是「标准 OpenWrt feed 包」形式的 Makefile，供装了 SDK / 完整源码树的
# 人用 `make package/luci-app-szu-netauth/compile` 构建。
#
# 如果你手上只有一个跑着 OpenWrt 的路由器（没有 SDK），请改用免 SDK 方式：
#     ./build-ipk.sh
# 它用 tools/make_ipk.py 直接产出 .ipk，不依赖 buildroot。
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-szu-netauth
PKG_VERSION:=1.1.1
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=baibook <240120311+Baibook-craft@users.noreply.github.com>

LUCI_TITLE:=LuCI app: campus network auto authentication (procd daemon)
LUCI_DEPENDS:=+luci-base +rpcd +rpcd-mod-file +curl +jsonfilter
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# ---------------------------------------------------------------------------
# 显式写 install 规则，覆盖 luci.mk 的默认目录映射。
#
# 为什么不让 luci.mk 自动映射 root/：显式写死之后，装到路由器上的路径
# 一目了然，不依赖 luci.mk 的版本差异。
#
# 为什么需要在 install 之后补一次 chmod：Git 的 core.fileMode 在 Windows
# 上默认关闭，clone 出来的 auth.sh / init.d 脚本很可能丢掉可执行位。
# 打出来的包缺 x 位 = 服务起不来，所以这里强制纠正一次。
# ---------------------------------------------------------------------------
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/
	$(CP) ./root/* $(1)/
	chmod 0755 $(1)/etc/init.d/szu-netauth
	chmod 0755 $(1)/etc/uci-defaults/50-luci-app-szu-netauth
	chmod 0755 $(1)/etc/szu-netauth/auth.sh
	# 0600：配置文件里是明文卡号密码，只有 root 该读到（OpenWrt 自带的那几个
	# 含口令的 config 也都是 0600）。tools/make_ipk.py 里用 SECRET_FILES 对齐。
	chmod 0600 $(1)/etc/config/szu-netauth
endef

# 用户改过的卡号密码，升级时不能被覆盖（opkg 会保留并生成 .opkg 后缀的新文件）
define Package/$(PKG_NAME)/conffiles
/etc/config/szu-netauth
endef

# luci.mk 已经提供了默认的 postinst / postrm（清 LuCI 索引缓存 + 重启 rpcd），
# 这里只需要补一个 prerm：卸载前把常驻服务停掉并取消开机自启，
# 否则 init.d 脚本被删了、进程还在后台跑。
#
# 升级（$1 = upgrade）时故意什么都不做 —— 让认证服务继续跑，不要白掉一次线。
define Package/$(PKG_NAME)/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
case "$$1" in
	remove|purge)
		if [ -x /etc/init.d/szu-netauth ]; then
			/etc/init.d/szu-netauth stop    2>/dev/null
			/etc/init.d/szu-netauth disable 2>/dev/null
		fi
		;;
esac
exit 0
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
