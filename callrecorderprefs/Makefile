export THEOS_PACKAGE_SCHEME = roothide
GO_EASY_ON_ME = 1

TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

ifneq ($(wildcard $(THEOS)/sdks/iPhoneOS16.5.sdk),)
export SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
export ISYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
endif

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CallRecorderPrefs

CallRecorderPrefs_FILES = CRPRootListController.m
CallRecorderPrefs_FRAMEWORKS = UIKit Foundation AVFoundation CoreGraphics QuartzCore
CallRecorderPrefs_PRIVATE_FRAMEWORKS = Preferences
CallRecorderPrefs_LIBRARIES = roothide
CallRecorderPrefs_INSTALL_PATH = /Library/PreferenceBundles
CallRecorderPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CallRecorderPrefs_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences$(ECHO_END)
	$(ECHO_NOTHING)cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/CallRecorderPrefs.plist$(ECHO_END)
