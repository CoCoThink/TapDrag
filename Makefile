.PHONY: build build-release build-debug build-adhoc clean run release setup-local-signing signing-status test verify

APP := build/TapDrag.app
TEST_BINARY := build/tests/touch_state_tests

build: build-release

build-release:
	TAPDRAG_BUILD_CONFIGURATION=Release ./TapDrag/build.sh

build-debug:
	TAPDRAG_BUILD_CONFIGURATION=Debug ./TapDrag/build.sh

build-adhoc:
	TAPDRAG_BUILD_CONFIGURATION=Release TAPDRAG_CODESIGN_IDENTITY=- ./TapDrag/build.sh

setup-local-signing:
	./scripts/create-local-signing-identity.sh

signing-status:
	./scripts/signing-status.sh "$(APP)"

run: build-release
	open "$(APP)"

test:
	mkdir -p "$(dir $(TEST_BINARY))"
	clang -fobjc-arc -Wall -Wextra -Wswitch-enum -Werror \
		tests/touch_state_tests.m -o "$(TEST_BINARY)" \
		-framework AppKit -framework ApplicationServices \
		-framework IOKit \
		-framework ServiceManagement \
		-framework UniformTypeIdentifiers
	"$(TEST_BINARY)"

verify: build-release test
	test "$(shell /usr/libexec/PlistBuddy -c 'Print TapDragBuildConfiguration' "$(APP)/Contents/Info.plist" 2>/dev/null)" = "Release"
	codesign --verify --deep --strict --verbose=4 "$(APP)"
	file "$(APP)/Contents/MacOS/TapDrag"

release:
	./scripts/package-release.sh

clean:
	rm -rf build dist
