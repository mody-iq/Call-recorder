THEOS_PACKAGE_SCHEME = roothide
TARGET := iphone:clang:latest:15.0
ARCHS = arm64e

INSTALL_TARGET_PROCESSES = InCallService mediaserverd audiomxd callservicesd

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallRecorder

CallRecorder_FILES = Tweak.x AudioRecorderEngine.m
CallRecorder_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
CallRecorder_FRAMEWORKS = UIKit Foundation AudioToolbox AVFoundation CoreAudio
CallRecorder_LIBRARIES = substrate roothide

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += callrecorderprefs
include $(THEOS_MAKE_PATH)/aggregate.mk
