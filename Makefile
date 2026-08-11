.PHONY: generate test build

DERIVED_DATA := build/DerivedData

generate:
	mint run xcodegen xcodegen generate

test: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' test

build: generate
	xcodebuild -project FantaLogcat.xcodeproj -scheme FantaLogcat -configuration Release -derivedDataPath $(DERIVED_DATA) -destination 'platform=macOS,arch=arm64' build
