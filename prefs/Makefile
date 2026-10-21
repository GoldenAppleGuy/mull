TARGET := iphone:clang:latest:14.0
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = MullPrefs
MullPrefs_FILES = SCRootListController.m
MullPrefs_CFLAGS = -fobjc-arc
MullPrefs_FRAMEWORKS = UIKit
MullPrefs_PRIVATE_FRAMEWORKS = Preferences
MullPrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks
MullPrefs_INSTALL_PATH = /Library/PreferenceBundles

include $(THEOS_MAKE_PATH)/bundle.mk
