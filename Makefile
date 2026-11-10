.PHONY: app run test icon clean

app:            ## Build and sign build/Subway Worker.app
	scripts/build-app.sh

run: app        ## Build, then (re)launch the app
	-pkill -x SubwayWorker
	open "build/Subway Worker.app"

test:           ## Run the unit tests
	swift test

icon:           ## Regenerate Resources/AppIcon.icns
	swift scripts/make-icon.swift Resources/AppIcon.icns

install: app    ## Copy the app into /Applications
	rm -rf "/Applications/Subway Worker.app"
	cp -R "build/Subway Worker.app" /Applications/

clean:
	rm -rf .build build
