.PHONY: app run test icon install clean

APP    := build/Subway Worker.app
APP_ID := dev.sarvad.SubwayWorker
DEST   ?= /Applications

# Asks a running copy to quit, so a session can put its window back, and waits for it.
define quit_running
if pgrep -x SubwayWorker >/dev/null; then \
  osascript -e 'tell application id "$(APP_ID)" to quit' >/dev/null 2>&1 || true; \
  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x SubwayWorker >/dev/null || break; sleep 0.5; done; \
fi
endef

app:            ## Build and sign build/Subway Worker.app
	@scripts/build-app.sh

run: app        ## Build, then (re)launch the app from the build folder
	@$(quit_running)
	@pkill -x SubwayWorker 2>/dev/null || true
	@open "$(APP)"
	@echo "Subway Worker is open. Pick an app and a clip, then press Lock in."

test:           ## Run the unit tests
	swift test

icon:           ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift Resources/AppIcon.icns

install: app    ## Build, then put the app in /Applications (DEST=... for somewhere else)
	@$(quit_running)
	@mkdir -p "$(DEST)"
	@rm -rf "$(DEST)/Subway Worker.app"
	@cp -R "$(APP)" "$(DEST)/"
	@echo ""
	@echo "Subway Worker is installed in $(DEST)."
	@echo ""
	@echo "  1. Open Subway Worker from Applications or Spotlight."
	@echo "  2. First time only: click Allow… and switch it on in"
	@echo "     System Settings ▸ Privacy & Security ▸ Accessibility."
	@echo "  3. Pick an app and a clip, then press Lock in."
	@echo ""

clean:
	rm -rf .build build
