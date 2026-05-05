APP_NAME := WindowLockRecorder
DIST_DIR := dist
INSTALL_DIR ?= /Applications
RESET_TCC ?= 1
RELAUNCH_APP ?= 1

.PHONY: build release package release-archives install clean

build:
	swift build

release:
	swift build -c release

package:
	./Scripts/package_app.sh

release-archives:
	CREATE_ZIP=1 CREATE_DMG=1 ./Scripts/package_app.sh

install:
	INSTALL_APP=1 INSTALL_DIR="$(INSTALL_DIR)" RESET_TCC="$(RESET_TCC)" RELAUNCH_APP="$(RELAUNCH_APP)" ./Scripts/package_app.sh

clean:
	rm -rf $(DIST_DIR)
	swift package clean
