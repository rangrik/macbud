DERIVED := build
APP     := $(DERIVED)/Build/Products/Debug/MacBud.app
XCB     := xcodebuild -project MacBud.xcodeproj -scheme MacBud -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'

.PHONY: gen build run stop test clean log install

gen:
	xcodegen generate --quiet

build: gen $(DERIVED)/mbctl
	$(XCB) build 2>&1 | ./scripts/xcfilter.sh

$(DERIVED)/mbctl: scripts/mbctl.swift
	mkdir -p $(DERIVED) && swiftc -O $< -o $@

run: build stop
	MACBUD_AUTOMATION=1 open -a "$(CURDIR)/$(APP)"

stop:
	-pkill -x MacBud 2>/dev/null; sleep 0.3

test: gen
	$(XCB) test 2>&1 | ./scripts/xcfilter.sh

clean:
	rm -rf $(DERIVED) MacBud.xcodeproj

log:
	log stream --predicate 'subsystem == "com.rangrik.macbud"' --style compact --level debug

install: build stop
	rm -rf /Applications/MacBud.app && cp -R "$(APP)" /Applications/MacBud.app && open -a /Applications/MacBud.app
