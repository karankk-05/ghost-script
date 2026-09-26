# GhostScreen — build & bundle.
#
# `swift run` is UNSUPPORTED for this app: without a bundle there is no stable
# TCC identity, no Dock drops, no Info.plist. The dev loop is `make run`.
#
# SIGN_ID: "-" (ad-hoc) works but macOS forgets the Screen Recording grant on
# every rebuild. For a persistent grant, create a self-signed code-signing
# certificate once (Keychain Access → Certificate Assistant → Create a
# Certificate… → name "GhostScreen Dev", type "Code Signing") and build with:
#   make run SIGN_ID="GhostScreen Dev"

APP_NAME  := GhostScreen
CONFIG    := release
BUILD_DIR := .build/$(CONFIG)
APP       := $(APP_NAME).app
SIGN_ID   ?= -

# SwiftPM resource bundle name is <package>_<target>.bundle — derived once;
# if the package or target is ever renamed, the guard below fails loudly
# instead of shipping an app that fatalErrors on Bundle.module at launch.
PKG       := GhostScreen
TARGET    := GhostScreen
RESBUNDLE := $(PKG)_$(TARGET).bundle

.PHONY: build bundle run clean vendor

build:
	swift build -c $(CONFIG)

bundle: build
	@test -d "$(BUILD_DIR)/$(RESBUNDLE)" || { \
	  echo "ERROR: $(BUILD_DIR)/$(RESBUNDLE) not found — package/target renamed without updating Makefile?"; exit 1; }
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/"
	cp -R "$(BUILD_DIR)/$(RESBUNDLE)" "$(APP)/Contents/Resources/"
	cp packaging/Info.plist "$(APP)/Contents/Info.plist"
	printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	codesign --force --deep --sign "$(SIGN_ID)" "$(APP)"
	@echo "bundled $(APP) (SIGN_ID=$(SIGN_ID))"

run: bundle
	open "$(APP)"

vendor:
	./scripts/fetch-vendor.sh

clean:
	rm -rf .build "$(APP)"
