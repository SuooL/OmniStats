# OmniStats — Apple Silicon menu-bar thermal/fan monitor with fan control.
# Requires only the Command Line Tools (clang + swiftc); full Xcode not needed.

APP        := OmniStats
HELPER     := omnistats-smcd
BUILD      := build
DIST       := dist
SRC        := src

CLANG      := clang
SWIFTC     := swiftc
OBJC_FLAGS := -fobjc-arc -mmacosx-version-min=13.0
C_FRAMEWORKS := -framework Foundation -framework IOKit -framework CoreFoundation
SWIFT_FRAMEWORKS := -framework Cocoa -framework IOKit -framework CoreFoundation

.PHONY: all app helper bundle dmg clean install uninstall run test

all: bundle helper

$(BUILD):
	@mkdir -p $(BUILD)

# --- C/ObjC objects for the Swift app ---
$(BUILD)/sensors.o: $(SRC)/sensors.m $(SRC)/sensors.h $(SRC)/smc.h | $(BUILD)
	$(CLANG) $(OBJC_FLAGS) -c $(SRC)/sensors.m -o $@

$(BUILD)/control.o: $(SRC)/control.m $(SRC)/control.h | $(BUILD)
	$(CLANG) $(OBJC_FLAGS) -c $(SRC)/control.m -o $@

# --- SwiftUI menu-bar app binary ---
SWIFT_SRCS := $(wildcard $(SRC)/*.swift)
$(BUILD)/$(APP): $(SWIFT_SRCS) $(BUILD)/sensors.o $(BUILD)/control.o $(SRC)/bridge.h | $(BUILD)
	$(SWIFTC) -O -parse-as-library $(SWIFT_SRCS) \
	  $(BUILD)/sensors.o $(BUILD)/control.o \
	  -import-objc-header $(SRC)/bridge.h \
	  $(SWIFT_FRAMEWORKS) -o $@

app: $(BUILD)/$(APP)

# --- Privileged helper daemon ---
$(BUILD)/$(HELPER): $(SRC)/smcd.m $(SRC)/smc.h | $(BUILD)
	$(CLANG) $(OBJC_FLAGS) $(SRC)/smcd.m -framework Foundation -framework IOKit -o $@

helper: $(BUILD)/$(HELPER)

# --- .app bundle (ad-hoc signed) ---
# The privileged helper + LaunchDaemon plist are embedded in Contents/Resources so
# the app can self-install them via a single native admin prompt (no Terminal needed).
bundle: $(BUILD)/$(APP) $(BUILD)/$(HELPER) packaging/Info.plist packaging/com.omnistats.smcd.plist
	@rm -rf $(DIST)/$(APP).app
	@mkdir -p $(DIST)/$(APP).app/Contents/MacOS $(DIST)/$(APP).app/Contents/Resources
	@cp packaging/Info.plist $(DIST)/$(APP).app/Contents/Info.plist
	@cp $(BUILD)/$(APP) $(DIST)/$(APP).app/Contents/MacOS/$(APP)
	@cp $(BUILD)/$(HELPER) $(DIST)/$(APP).app/Contents/Resources/$(HELPER)
	@cp packaging/com.omnistats.smcd.plist $(DIST)/$(APP).app/Contents/Resources/com.omnistats.smcd.plist
	@codesign --force --sign - --timestamp=none $(DIST)/$(APP).app >/dev/null 2>&1 || true
	@echo "Built $(DIST)/$(APP).app"

run: bundle
	@open $(DIST)/$(APP).app

# --- distributable .dmg (drag-to-Applications) ---
dmg: bundle
	@rm -f $(DIST)/$(APP).dmg
	@STAGING=$$(mktemp -d); \
	 cp -R $(DIST)/$(APP).app "$$STAGING/"; \
	 ln -s /Applications "$$STAGING/Applications"; \
	 hdiutil create -volname "$(APP)" -srcfolder "$$STAGING" -ov -format UDZO "$(DIST)/$(APP).dmg" >/dev/null; \
	 rm -rf "$$STAGING"; \
	 echo "Built $(DIST)/$(APP).dmg"

# --- helper install / uninstall (need sudo) ---
install: helper
	@bash packaging/install-helper.sh $(BUILD)/$(HELPER)

uninstall:
	@bash packaging/uninstall-helper.sh

# --- CLI smoke test for the sensor/control layer (no GUI) ---
test: $(BUILD)/sensors.o $(BUILD)/control.o
	@$(CLANG) $(OBJC_FLAGS) $(SRC)/clitest.m $(BUILD)/sensors.o $(BUILD)/control.o \
	  $(C_FRAMEWORKS) -o $(BUILD)/clitest
	@$(BUILD)/clitest

clean:
	@rm -rf $(BUILD) $(DIST)
	@echo "cleaned"
