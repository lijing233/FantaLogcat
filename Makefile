.PHONY: generate test build check-public test-release-check test-dmg ci release-clean release

DERIVED_DATA := build/DerivedData
RELEASE_DIR := build/releases
RELEASE_APP := $(RELEASE_DIR)/FantaLogcat.app
RELEASE_ZIP := $(RELEASE_DIR)/FantaLogcat-macos-arm64.zip
RELEASE_DMG := $(RELEASE_DIR)/FantaLogcat-macos-arm64.dmg
BUILT_APP := $(DERIVED_DATA)/Build/Products/Release/FantaLogcat.app

generate:
	mint run xcodegen xcodegen generate

test: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' test

build: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' build

check-public:
	Scripts/check-public-release.sh

test-release-check:
	Scripts/test-public-release-check.sh

test-dmg:
	Scripts/test-dmg.sh

ci: test-release-check test-dmg test

release-clean:
	mkdir -p "$(RELEASE_DIR)"
	rm -rf "$(RELEASE_APP)"
	rm -f "$(RELEASE_ZIP)"
	rm -f "$(RELEASE_ZIP).sha256"
	rm -f "$(RELEASE_DMG)"
	rm -f "$(RELEASE_DMG).sha256"

release: release-clean
	$(MAKE) build
	APP_PATH="$(BUILT_APP)" Scripts/check-public-release.sh
	ditto "$(BUILT_APP)" "$(RELEASE_APP)"
	test -s "$(RELEASE_APP)/Contents/MacOS/FantaLogcat"
	lipo -archs "$(RELEASE_APP)/Contents/MacOS/FantaLogcat" | grep -qx arm64
	test -s "$(RELEASE_APP)/Contents/Resources/AppIcon.icns"
	codesign --verify --deep --strict "$(RELEASE_APP)"
	ditto -c -k --sequesterRsrc --keepParent "$(RELEASE_APP)" "$(RELEASE_ZIP)"
	cd $(RELEASE_DIR) && shasum -a 256 $(notdir $(RELEASE_ZIP)) > $(notdir $(RELEASE_ZIP)).sha256.tmp && mv $(notdir $(RELEASE_ZIP)).sha256.tmp $(notdir $(RELEASE_ZIP)).sha256
	Scripts/create-dmg.sh "$(RELEASE_APP)" "$(RELEASE_DMG)"
	cd $(RELEASE_DIR) && shasum -a 256 $(notdir $(RELEASE_DMG)) > $(notdir $(RELEASE_DMG)).sha256.tmp && mv $(notdir $(RELEASE_DMG)).sha256.tmp $(notdir $(RELEASE_DMG)).sha256
