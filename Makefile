APP_DIR = ../scripts/ZoomMeetilyBridge.app
BINARY = $(APP_DIR)/Contents/MacOS/ZoomMeetilyBridge
PLIST_SRC = com.altbar.zoom-meetily-bridge.plist
PLIST_DST = $(HOME)/Library/LaunchAgents/$(PLIST_SRC)

.PHONY: build install uninstall restart

build:
	mkdir -p $(APP_DIR)/Contents/MacOS
	swiftc -o $(BINARY) -framework Cocoa ZoomMeetilyBridge.swift
	cp Info.plist $(APP_DIR)/Contents/Info.plist

install: build
	cp $(PLIST_SRC) $(PLIST_DST)
	launchctl load $(PLIST_DST)

uninstall:
	-launchctl unload $(PLIST_DST)
	-rm $(PLIST_DST)

restart:
	-launchctl unload $(PLIST_DST)
	sleep 1
	launchctl load $(PLIST_DST)
