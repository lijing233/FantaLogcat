.PHONY: generate test build release

DERIVED_DATA := build/DerivedData
RELEASE_DIR := build/releases
RELEASE_APP := $(RELEASE_DIR)/FantaLogcat.app
RELEASE_ZIP := $(RELEASE_DIR)/FantaLogcat-macos-arm64.zip
BUILT_APP := $(DERIVED_DATA)/Build/Products/Release/FantaLogcat.app

generate:
	mint run xcodegen xcodegen generate

test: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' test

build: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' build

release: build
	mkdir -p $(RELEASE_DIR)
	rm -rf $(RELEASE_APP)
	rm -f $(RELEASE_ZIP)
	ditto $(BUILT_APP) $(RELEASE_APP)
	test -s $(RELEASE_APP)/Contents/MacOS/FantaLogcat
	test -s $(RELEASE_APP)/Contents/Resources/AppIcon.icns
	codesign --verify --deep --strict $(RELEASE_APP)
	ditto -c -k --sequesterRsrc --keepParent $(RELEASE_APP) $(RELEASE_ZIP)
