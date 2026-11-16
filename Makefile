export THEOS_PACKAGE_SCHEME = roothide
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = xz
GO_EASY_ON_ME = 1

TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

ifneq ($(wildcard $(THEOS)/sdks/iPhoneOS16.5.sdk),)
export SYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
export ISYSROOT = $(THEOS)/sdks/iPhoneOS16.5.sdk
endif

INSTALL_TARGET_PROCESSES = InCallService mediaserverd audiomxd callservicesd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallRecorder

CallRecorder_FILES = Tweak.x AudioRecorderEngine.m
CallRecorder_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CallRecorder_FRAMEWORKS = UIKit Foundation AudioToolbox AVFoundation CoreAudio QuartzCore CoreGraphics
CallRecorder_LIBRARIES = substrate roothide
CallRecorder_USE_MODULES = 0

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += callrecorderprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
