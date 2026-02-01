.PHONY: dev build release package clean

dev:
	swift run

build:
	swift build

release:
	swift build -c release
	rm -rf dist/LLMPaperReadingHelper.app
	mkdir -p dist/LLMPaperReadingHelper.app/Contents/MacOS
	mkdir -p dist/LLMPaperReadingHelper.app/Contents/Resources
	cp .build/release/LLMPaperReadingHelper dist/LLMPaperReadingHelper.app/Contents/MacOS/LLMPaperReadingHelper
	cp resource/app_icon.png dist/LLMPaperReadingHelper.app/Contents/Resources/app_icon.png
	printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0">' \
		'<dict>' \
		'    <key>CFBundleName</key>' \
		'    <string>LLMPaperReadingHelper</string>' \
		'    <key>CFBundleDisplayName</key>' \
		'    <string>LLMPaperReadingHelper</string>' \
		'    <key>CFBundleIdentifier</key>' \
		'    <string>com.llm.paper-reading-helper</string>' \
		'    <key>CFBundleExecutable</key>' \
		'    <string>LLMPaperReadingHelper</string>' \
		'    <key>CFBundlePackageType</key>' \
		'    <string>APPL</string>' \
		'    <key>CFBundleShortVersionString</key>' \
		'    <string>0.1.0</string>' \
		'    <key>CFBundleVersion</key>' \
		'    <string>1</string>' \
		'    <key>CFBundleIconFile</key>' \
		'    <string>app_icon</string>' \
		'    <key>NSHighResolutionCapable</key>' \
		'    <true/>' \
		'    <key>LSMinimumSystemVersion</key>' \
		'    <string>13.0</string>' \
		'</dict>' \
		'</plist>' \
		> dist/LLMPaperReadingHelper.app/Contents/Info.plist

package: release
	rm -f dist/LLMPaperReadingHelper.zip
	cd dist && zip -r LLMPaperReadingHelper.zip LLMPaperReadingHelper.app

clean:
	rm -rf .build
	rm -rf dist
	rm -f Package.resolved
