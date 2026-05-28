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

.PHONY: help
help:
	@echo "Targets:"
	@echo "  libs        - update submodules and build the scrcpy porting libs"
	@echo "  update-all  - git submodule update --init --recursive"
	@echo "  libscrcpy   - build the porting libraries (output/{iphone,android})"
	@echo "  debug-ipa   - archive + export a Debug IPA with full debug symbols"
	@echo "                (build/debug/{*.xcarchive,*.ipa,dSYMs/})"
