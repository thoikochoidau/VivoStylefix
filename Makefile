export ARCHS = arm64 arm64e
export TARGET = iphone:clang:latest:15.0

# rootless (Dopamine/palera1n) by default; build the RootHide variant with
#   make package THEOS_PACKAGE_SCHEME=roothide
# Requires theos-roothide as $THEOS — its <roothide.h> falls back to a
# rootless-compatible stub for the other schemes, so one tree builds both.
export THEOS_PACKAGE_SCHEME ?= rootless

include $(THEOS)/makefiles/common.mk

SUBPROJECTS += tweak
SUBPROJECTS += prefs

include $(THEOS)/makefiles/aggregate.mk
