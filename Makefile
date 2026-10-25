.PHONY: project open test run build build-appstore icon pricing clean

# Generate Kvota.xcodeproj from project.yml (needs `brew install xcodegen`).
project:
	xcodegen generate

open: project
	open Kvota.xcodeproj

# Core parsers and UI snapshot tests.
test:
	cd KvotaKit && swift test

# Run the app straight from SwiftPM (no Xcode project needed).
run:
	cd KvotaKit && swift run kvota-dev

build: project
	xcodebuild -project Kvota.xcodeproj -scheme Kvota -configuration Release -derivedDataPath build build

build-appstore: project
	xcodebuild -project Kvota.xcodeproj -scheme KvotaAppStore -configuration Release -derivedDataPath build build

icon:
	python3 scripts/make-icon.py

pricing:
	python3 scripts/update-pricing.py

clean:
	rm -rf build KvotaKit/.build Kvota.xcodeproj
