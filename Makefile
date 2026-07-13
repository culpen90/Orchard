PROJECT := Orchard.xcodeproj
SCHEME := Orchard
CONFIGURATION ?= Debug
DERIVED_DATA ?= .build/DerivedData
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Orchard.app

.PHONY: generate build test run install clean

generate:
	xcodegen generate

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -derivedDataPath $(DERIVED_DATA) build

test: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED_DATA) test

run: build
	open "$(APP)"

install: CONFIGURATION=Release
install: build
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/Orchard.app"
	cp -R "$(APP)" "$(HOME)/Applications/Orchard.app"
	open "$(HOME)/Applications/Orchard.app"

clean:
	rm -rf "$(DERIVED_DATA)" "$(PROJECT)"
