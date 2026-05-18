PROJECT    := OnAirCompanion.xcodeproj
SCHEME     := OnAirCompanion
DEST       := platform=macOS
UNIVARCH   := ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
APP        := dist/Release/OnAirCompanion.app
INSTALL_DIR := ~/Applications

.PHONY: build release test clean open install uninstall

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug build

release:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release $(UNIVARCH) build

test:
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)' $(UNIVARCH)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf dist/

install: release
	@mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/OnAirCompanion.app
	cp -R $(APP) $(INSTALL_DIR)/
	@echo "Installed to $(INSTALL_DIR)/OnAirCompanion.app"

uninstall:
	rm -rf $(INSTALL_DIR)/OnAirCompanion.app
	@echo "Removed $(INSTALL_DIR)/OnAirCompanion.app"

open:
	open $(PROJECT)
