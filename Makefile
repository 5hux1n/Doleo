# Doleo — Theos 构建文件
#
# rootless： make package THEOS_PACKAGE_SCHEME=rootless
# roothide： make package THEOS_PACKAGE_SCHEME=roothide   （需要 roothide 的 Theos 分支）
# 切换方案前请先 make clean

ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
TARGET := iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
TARGET := iphone:clang:latest:15.0
else
TARGET := iphone:clang:latest:14.0
endif

ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = Sileo
THEOS_PACKAGE_DIR_NAME = .theos/packages

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Doleo

Doleo_FILES = Tweak.x $(wildcard Sources/*.swift) $(wildcard Sources/UI/*.swift)
Doleo_CFLAGS = -fobjc-arc
Doleo_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk

# roothide 不自动加 rpath，弱链接的 CydiaSubstrate 解析不到会导致 hook 静默失效
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
Doleo_LDFLAGS += -Wl,-rpath,@loader_path/.jbroot/Library/Frameworks \
                     -Wl,-rpath,@loader_path/.jbroot/usr/lib
endif

# 脚本里的路径：
# - rootless：bootstrap 在 /var/jb，脚本解释器也在那里
# - roothide：dpkg/apt/sh 由 vroot 把随机的 jbroot 映射成 "/"，所以按 rootful 写法即可
# - rootful：传统路径
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
DK_ROOT := /var/jb
DK_SHEBANG := /var/jb/bin/sh
else
DK_ROOT :=
DK_SHEBANG := /bin/sh
endif

DK_DATA_DIR = /var/lib/doleo

DK_SED = sed -e 's|@SCHEME@|$(THEOS_PACKAGE_SCHEME)|g' -e 's|@DATA_DIR@|$(DK_DATA_DIR)|g' -e 's|@ROOT@|$(DK_ROOT)|g' -e 's|@SHEBANG@|$(DK_SHEBANG)|g'
# Theos 在 package 阶段统一添加方案前缀，staging 内不能再加一次 /var/jb。
DK_STAGE = $(THEOS_STAGING_DIR)

before-package::
	$(ECHO_NOTHING)$(DK_SED) "$(THEOS_STAGING_DIR)/DEBIAN/control" > "$(THEOS_STAGING_DIR)/DEBIAN/control.tmp"; \
		mv "$(THEOS_STAGING_DIR)/DEBIAN/control.tmp" "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)

# RootHide 交付要求 control 的显示名带 (Roothide) 后缀，幂等处理
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
before-package::
	$(ECHO_NOTHING)sed -i '' 's/^Package: .*/Package: im.mjh.doleo.roothide/' "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
	$(ECHO_NOTHING)grep -qi '^Name: .*([Rr]oothide)' "$(THEOS_STAGING_DIR)/DEBIAN/control" || \
		sed -i '' 's/^Name: \(.*\)/Name: \1 (Roothide)/' "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
endif

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(DK_STAGE)/usr/share/doleo"$(ECHO_END)
	$(ECHO_NOTHING)cp Doleo-icon/png/package/icon-256.png "$(DK_STAGE)/usr/share/doleo/icon.png"$(ECHO_END)
	$(ECHO_NOTHING)cp -R Resources/Doleo.bundle "$(DK_STAGE)/usr/share/doleo/"$(ECHO_END)
	$(ECHO_NOTHING)cp Resources/entry*.png "$(DK_STAGE)/usr/share/doleo/"$(ECHO_END)
ifneq ($(THEOS_PACKAGE_SCHEME),rootless)
	$(ECHO_NOTHING)mkdir -p "$(DK_STAGE)/usr/libexec/doleo" "$(DK_STAGE)/etc/apt/apt.conf.d"$(ECHO_END)
	$(ECHO_NOTHING)$(DK_SED) scripts/prebackup.in > "$(DK_STAGE)/usr/libexec/doleo/prebackup"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(DK_STAGE)/usr/libexec/doleo/prebackup"$(ECHO_END)
	$(ECHO_NOTHING)$(DK_SED) scripts/apt.conf.in > "$(DK_STAGE)/etc/apt/apt.conf.d/99doleo"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0644 "$(DK_STAGE)/etc/apt/apt.conf.d/99doleo"$(ECHO_END)
endif
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)$(DK_SED) scripts/postinst.in > "$(THEOS_STAGING_DIR)/DEBIAN/postinst"$(ECHO_END)
	$(ECHO_NOTHING)$(DK_SED) scripts/postrm.in > "$(THEOS_STAGING_DIR)/DEBIAN/postrm"$(ECHO_END)
	$(ECHO_NOTHING)chmod 0755 "$(THEOS_STAGING_DIR)/DEBIAN/postinst" "$(THEOS_STAGING_DIR)/DEBIAN/postrm"$(ECHO_END)

after-package::
	$(ECHO_NOTHING)set -e; deb="$(_THEOS_DEB_PACKAGE_FILENAME)"; \
		version=$$(dpkg-deb -f "$$deb" Version); \
		case $$(dpkg-deb -f "$$deb" Architecture) in \
			iphoneos-arm64) arch=arm64 ;; \
			iphoneos-arm64e) arch=arm64e ;; \
			*) echo "Unsupported delivery architecture" >&2; exit 1 ;; \
		esac; \
		mkdir -p "$(THEOS_PROJECT_DIR)/dist"; \
		cp "$$deb" "$(THEOS_PROJECT_DIR)/dist/Doleo_$${version}_$${arch}.deb"$(ECHO_END)
