.PHONY: build build-adhoc clean run release setup-local-signing signing-status test verify

APP := build/3FDragUnstuck.app
TEST_BINARY := build/tests/touch_state_tests

build:
	./3FDragUnstuck/build.sh

build-adhoc:
	THREE_F_DRAG_CODESIGN_IDENTITY=- ./3FDragUnstuck/build.sh

setup-local-signing:
	./scripts/create-local-signing-identity.sh

signing-status:
	./scripts/signing-status.sh "$(APP)"

run: build
	open "$(APP)"

test:
	mkdir -p "$(dir $(TEST_BINARY))"
	clang -fobjc-arc -Wall -Wextra -Wswitch-enum -Werror \
		-framework Cocoa -framework ApplicationServices -framework CoreGraphics \
		-framework UniformTypeIdentifiers \
		tests/touch_state_tests.m -o "$(TEST_BINARY)"
	"$(TEST_BINARY)"

verify: build test
	codesign --verify --deep --strict --verbose=4 "$(APP)"
	file "$(APP)/Contents/MacOS/3FDragUnstuck"

release:
	./scripts/package-release.sh

clean:
	rm -rf build dist
