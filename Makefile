libs: update-all libscrcpy

update-all:
	git submodule update --init --recursive

libscrcpy:
	mkdir -pv output/{iphone,android}
	make -C porting

# Debug IPA with debug symbols
.PHONY: debug-ipa
debug-ipa:
	@bash scripts/build-debug-ipa.sh

# Upload an already-built Debug IPA to the internal OTA service.
# Pass an explicit path with: make upload-dev-ipa IPA=path/to/App.ipa
.PHONY: upload-dev-ipa
upload-dev-ipa:
	@bash scripts/upload-dev-ipa.sh $(IPA)

# Release archive + upload to App Store Connect / TestFlight
.PHONY: upload-appstore
upload-appstore:
	@bash scripts/upload.sh

.PHONY: help
help:
	@echo "Targets:"
	@echo "  libs           - update submodules and build the scrcpy porting libs"
	@echo "  update-all     - git submodule update --init --recursive"
	@echo "  libscrcpy      - build the porting libraries (output/{iphone,android})"
	@echo "  debug-ipa      - archive + export a Debug IPA with full debug symbols"
	@echo "                   (build/debug/{*.xcarchive,*.ipa,dSYMs/}), then upload"
	@echo "                   it to dev-ipa.wsen.me"
	@echo "  upload-dev-ipa - upload an existing IPA to dev-ipa.wsen.me"
	@echo "                   (override path with IPA=path/to/App.ipa)"
	@echo "  upload-appstore- archive Release and upload to App Store Connect /"
	@echo "                   TestFlight (build number managed by Xcode)"
