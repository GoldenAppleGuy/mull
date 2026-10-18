TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MullModule
MullModule_FILES = SCModule.m
MullModule_CFLAGS = -fobjc-arc
MullModule_FRAMEWORKS = UIKit
MullModule_PRIVATE_FRAMEWORKS = ControlCenterUIKit
MullModule_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
MullModule_INSTALL_PATH = /Library/ControlCenter/Bundles

include $(THEOS_MAKE_PATH)/bundle.mk
