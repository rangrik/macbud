SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

DERIVED := build
APP     := $(DERIVED)/Build/Products/Debug/MacBud.app
XCB     := xcodebuild -project MacBud.xcodeproj -scheme MacBud -configuration Debug -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=arm64'
RELEASE_DERIVED := build-release
RELEASE_APP := $(RELEASE_DERIVED)/Build/Products/Release/MacBud.app
RELEASE_XCB := xcodebuild -project MacBud.xcodeproj -scheme MacBud -configuration Release -derivedDataPath $(RELEASE_DERIVED) -destination 'generic/platform=macOS'

.PHONY: gen build run stop test clean log release package install

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
	rm -rf $(DERIVED) $(RELEASE_DERIVED) MacBud.xcodeproj

log:
	log stream --predicate 'subsystem == "com.rangrik.macbud"' --style compact --level debug

release: gen
	$(RELEASE_XCB) build 2>&1 | ./scripts/xcfilter.sh
	codesign --verify --deep --strict "$(RELEASE_APP)"

package: release
	./scripts/package-release.sh "$(RELEASE_APP)"

install: release
	./scripts/install-release.sh "$(RELEASE_APP)"
