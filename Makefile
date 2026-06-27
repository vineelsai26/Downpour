# Downpour — build / bundle / sign
#
# Requires only the Command Line Tools (no full Xcode). Produces a runnable,
# ad-hoc-signed .app under dist/.

APP_NAME      := Downpour
DISPLAY_NAME  := Downpour
BUNDLE_ID     := dev.vstack.downpour
EXEC          := DownpourApp
CLI           := downpour
CONFIG        := release

# Stable code-signing identity (created by scripts/create-signing-cert.sh).
# If absent, falls back to ad-hoc signing.
SIGN_IDENTITY := Downpour Local Signing

BUILD_DIR     := .build/$(CONFIG)
DIST          := dist
APP           := $(DIST)/$(APP_NAME).app
CONTENTS      := $(APP)/Contents
MACOS         := $(CONTENTS)/MacOS
RESOURCES     := $(CONTENTS)/Resources

.PHONY: all app build cli bundle sign signing-cert run selftest install-agent uninstall-agent clean

all: app

## Build everything in release.
build:
	swift build -c $(CONFIG)

## Run the self-test suite (no Xcode/XCTest required).
selftest:
	swift run backup-selftest

## Assemble + ad-hoc sign the .app bundle.
app: bundle sign
	@echo "Built $(APP)"

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(MACOS)" "$(RESOURCES)"
	@cp "$(BUILD_DIR)/$(EXEC)" "$(MACOS)/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "Assembled $(APP)"

## Code sign. Uses the stable self-signed identity if present (so TCC grants
## survive rebuilds), otherwise falls back to ad-hoc.
sign:
	@if security find-identity -p codesigning 2>/dev/null | grep -qF "$(SIGN_IDENTITY)"; then \
		echo "Signing with '$(SIGN_IDENTITY)' (stable identity)"; \
		codesign --force --sign "$(SIGN_IDENTITY)" --entitlements Resources/entitlements.plist --timestamp=none "$(APP)"; \
	else \
		echo "No '$(SIGN_IDENTITY)' identity — signing ad-hoc. Run 'make signing-cert' for stable TCC across rebuilds."; \
		codesign --force --sign - --entitlements Resources/entitlements.plist --timestamp=none "$(APP)"; \
	fi
	@codesign --verify --verbose "$(APP)" && echo "Signed: $(APP)"

## Create the persistent self-signed code-signing identity.
signing-cert:
	@bash scripts/create-signing-cert.sh

## Build + install the CLI to /usr/local/bin (used by the launchd agent).
cli: build
	@mkdir -p "$(DIST)"
	@cp "$(BUILD_DIR)/$(CLI)" "$(DIST)/$(CLI)"
	@echo "CLI at $(DIST)/$(CLI)"

## Launch the app.
run: app
	@open "$(APP)"

## Install the launchd agent for scheduled backups (daily 02:00 by default).
install-agent: app
	@bash scripts/install-agent.sh

## Remove the launchd agent.
uninstall-agent:
	@bash scripts/uninstall-agent.sh

clean:
	swift package clean
	@rm -rf "$(DIST)"
