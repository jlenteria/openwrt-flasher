.PHONY: help icons run-macos run-windows run-linux run-all build-macos build-windows build-linux build-all install-linux uninstall-linux clean get-deps analyze test

# Only dispatch to a platform this machine can actually build for. The old
# targets piped stderr to /dev/null and printed "not available" on any failure,
# which reported a broken compile as success.
IS_MAC := $(filter Darwin,$(shell uname -s))
IS_LINUX := $(filter Linux,$(shell uname -s))
IS_WINDOWS := $(filter Windows_NT MINGW64_NT% MSYS_NT% CYGWIN_NT%,$(OS) $(shell uname -s))

RUN_TARGET := $(strip $(if $(IS_MAC),run-macos,$(if $(IS_LINUX),run-linux,$(if $(IS_WINDOWS),run-windows,))))
BUILD_TARGET := $(strip $(if $(IS_MAC),build-macos,$(if $(IS_LINUX),build-linux,$(if $(IS_WINDOWS),build-windows,))))

# Linux desktop integration. Defaults to a per-user install; use
# `sudo make install-linux PREFIX=/usr/local` for a system-wide one.
PREFIX ?= $(HOME)/.local
APP_ID := com.bling.openwrtFlasher
LINUX_APP_DIR := $(PREFIX)/lib/openwrt-flasher
LINUX_DESKTOP_FILE := $(PREFIX)/share/applications/$(APP_ID).desktop
LINUX_ICON_FILE := $(PREFIX)/share/icons/hicolor/256x256/apps/$(APP_ID).png
# Desktop environments pick up changes without these; they just make it faster.
LINUX_REFRESH_CACHES := \
	if command -v update-desktop-database >/dev/null 2>&1; then update-desktop-database -q "$(PREFIX)/share/applications" || true; fi; \
	if command -v gtk-update-icon-cache >/dev/null 2>&1; then gtk-update-icon-cache -q -f -t "$(PREFIX)/share/icons/hicolor" || true; fi

help:
	@echo "OpenWrt Flasher - Available Commands"
	@echo "======================================"
	@echo "Dependencies:"
	@echo "  make get-deps     - Get Flutter dependencies"
	@echo "  make analyze      - Run Flutter analyze"
	@echo "  make test         - Run tests"
	@echo "  make icons        - Regenerate app icons from assets/icon/app_icon.png"
	@echo ""
	@echo "Run (Development):"
	@echo "  make run-macos    - Run on macOS"
	@echo "  make run-windows  - Run on Windows"
	@echo "  make run-linux    - Run on Linux"
	@echo "  make run-all      - Run on this machine's desktop platform"
	@echo ""
	@echo "Build (Release):"
	@echo "  make build-macos  - Build for macOS"
	@echo "  make build-windows - Build for Windows"
	@echo "  make build-linux  - Build for Linux"
	@echo "  make build-all    - Build for all platforms"
	@echo ""
	@echo "Install (Linux):"
	@echo "  make install-linux   - Install the release build with menu entry and icon (PREFIX=$(PREFIX))"
	@echo "  make uninstall-linux - Remove what install-linux added"
	@echo ""
	@echo "Clean:"
	@echo "  make clean        - Clean build artifacts"

get-deps:
	@echo "Getting dependencies..."
	flutter pub get

analyze:
	@echo "Analyzing code..."
	flutter analyze

test:
	@echo "Running tests..."
	flutter test

icons:
	@echo "Generating app icons..."
	dart run flutter_launcher_icons
	dart run tool/generate_icons.dart

run-macos:
	@echo "Running on macOS..."
	flutter run -d macos

run-windows:
	@echo "Running on Windows..."
	flutter run -d windows

run-linux:
	@echo "Running on Linux..."
	flutter run -d linux

run-all:
	@echo "Running on the desktop platform of this machine..."
ifeq ($(RUN_TARGET),)
	@echo "No Flutter desktop target for $(shell uname -s)." && exit 1
else
	@$(MAKE) $(RUN_TARGET)
endif

build-macos:
	@echo "Building for macOS..."
	flutter build macos --release
	@echo "Build complete: build/macos/Build/Products/Release/openwrt_flasher.app (or rename artifact as needed)"

build-windows:
	@echo "Building for Windows..."
	flutter build windows --release
	@echo "Build complete: build/windows/x64/runner/Release/"

build-linux:
	@echo "Building for Linux..."
	flutter build linux --release
	@echo "Build complete: build/linux/x64/release/bundle/"

build-all:
	@echo "Building for the desktop platform of this machine..."
ifeq ($(BUILD_TARGET),)
	@echo "No Flutter desktop target for $(shell uname -s)." && exit 1
else
	@$(MAKE) $(BUILD_TARGET)
endif

# The .desktop file's Exec is rewritten to the absolute install path so the
# menu entry works without the app being on PATH.
install-linux:
	@bundle=$$(ls -d build/linux/*/release/bundle 2>/dev/null | head -n 1); \
	if [ -z "$$bundle" ]; then echo "No Linux release build found. Run 'make build-linux' first."; exit 1; fi; \
	echo "Installing $$bundle to $(LINUX_APP_DIR)..."; \
	rm -rf "$(LINUX_APP_DIR)" && \
	mkdir -p "$(LINUX_APP_DIR)" && \
	cp -R "$$bundle/." "$(LINUX_APP_DIR)/" && \
	mkdir -p "$(dir $(LINUX_ICON_FILE))" && \
	install -m 644 linux/runner/resources/app_icon.png "$(LINUX_ICON_FILE)" && \
	mkdir -p "$(dir $(LINUX_DESKTOP_FILE))" && \
	sed "s|^Exec=.*|Exec=$(LINUX_APP_DIR)/openwrt-flasher|" \
		linux/packaging/$(APP_ID).desktop > "$(LINUX_DESKTOP_FILE)" && \
	chmod 644 "$(LINUX_DESKTOP_FILE)"
	@$(LINUX_REFRESH_CACHES)
	@echo "Installed. OpenWrt Flasher is now in your application menu."

uninstall-linux:
	rm -rf "$(LINUX_APP_DIR)"
	rm -f "$(LINUX_DESKTOP_FILE)" "$(LINUX_ICON_FILE)"
	@$(LINUX_REFRESH_CACHES)
	@echo "Uninstalled."

clean:
	@echo "Cleaning build artifacts..."
	flutter clean
	rm -rf build/
	@echo "Clean complete"
