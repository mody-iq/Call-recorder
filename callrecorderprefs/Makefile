THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = CallRecorderPrefs

CallRecorderPrefs_FILES = CRPRootListController.m
CallRecorderPrefs_FRAMEWORKS = UIKit Foundation AVFoundation
CallRecorderPrefs_PRIVATE_FRAMEWORKS = Preferences
CallRecorderPrefs_LIBRARIES = roothide
CallRecorderPrefs_INSTALL_PATH = /Library/PreferenceBundles
CallRecorderPrefs_CFLAGS = -fobjc-arc -Wno-deprecated-declarations

include $(THEOS_MAKE_PATH)/bundle.mk
