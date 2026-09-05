# TapDrag

TapDrag is a lightweight macOS menu bar utility that provides double-tap dragging with immediate release. It replaces the system tap-to-drag grace period with a raw-contact-driven gesture, so the dragged item is released as soon as the finger actually leaves the trackpad.

## What it does

- Recognizes a short tap followed by a second one-finger contact.
- Starts dragging only after the second contact moves far enough or is deliberately held.
- Preserves normal clicks. In WeChat, Launchpad, and the Dock, the first tap is briefly buffered so immediate click handling does not prevent a drag.
- Sends one complete tagged `mouseDown -> mouseDragged -> mouseUp` transaction.
- Releases immediately on the real raw finger lift.
- Keeps a bounded automatic diagnostic trace for difficult gesture failures.
- Handles drag input at the HID stage and observes downstream events for compatibility diagnostics.

## Requirements

- macOS 13 or later on Apple silicon.
- Tap to click enabled.
- The system trackpad **Dragging** option disabled. TapDrag stays inactive while native dragging is enabled, preventing two drag implementations from competing.
- Accessibility permission and, when macOS requests it separately, Input Monitoring permission.

TapDrag uses Apple's private `MultitouchSupport.framework` to observe raw trackpad contacts. This is suitable for a personal utility but not Mac App Store distribution.

## Use

1. Build and launch `build/TapDrag.app`.
2. Grant the requested permissions.
3. Open the menu bar icon and confirm `Enabled` is checked.
4. Confirm the status reads `TapDrag: Ready`.
5. Tap once, place the finger down again quickly, then move it to drag. Lift the finger to release immediately.

Check `Launch at Login` in the menu to start TapDrag automatically when you log in to macOS; uncheck it to disable automatic startup. The menu reflects the current system setting each time it opens. A dash means macOS approval is pending; use `Approve Launch at Login...` to open Login Items settings. This setting is independent of `Enabled`.

The first contact must be a short, stationary tap. The second contact must begin 30–160 ms after the first raw lift. Movement beyond 1.3 mm confirms the drag immediately; a stationary 180 ms hold can also confirm deliberate drag intent. Multi-finger contact invalidates the candidate.

WeChat tap clicks have a roughly 200 ms decision window. Confirming a drag cancels the buffered first click; otherwise the click is replayed. Real double-clicks are replayed in order. TapDrag tracks WeChat launches and exits automatically, including when WeChat starts after TapDrag. Restarting WeChat does not require restarting TapDrag.

Launchpad and Dock icons use the same first-tap decision window. TapDrag tracks the Dock process that owns both surfaces. This adds a roughly 200 ms delay to ordinary tap clicks on Dock and Launchpad icons, allowing a second contact to turn the gesture into a drag before the application launches.

On 2026-09-05, the user confirmed with a physical trackpad that double-tap text selection works in WeChat 4.1.11 and icon dragging works in both Launchpad and the Dock on macOS 15.7.7. WeChat window dragging still requires separate confirmation. See the [diagnosis and validation record](docs/WECHAT-DRAG-DIAGNOSIS.md).

## Build

```sh
make setup-local-signing
make verify
make run
```

`make build`, `make verify`, and `make run` explicitly use the Release configuration (`-O2 -DNDEBUG`). Use `make build-debug` for an unoptimized build with debug information (`-O0 -g -DDEBUG=1`). The generated app records its configuration as `TapDragBuildConfiguration` in `Contents/Info.plist`; unsupported configuration names fail the build.

`make setup-local-signing` is normally required only once. For authorization continuity, the project deliberately retains the existing bundle identifier and default local signing identity from earlier builds. Changing either can make macOS request Accessibility and Input Monitoring permission again.

Useful targets:

```sh
make build
make build-release
make build-debug
make build-adhoc
make test
make verify
make signing-status
make release
```

For Apple-issued signing, set `TAPDRAG_CODESIGN_IDENTITY`. For release packaging, set `TAPDRAG_RELEASE_CODESIGN_IDENTITY`.

## Diagnostics

While TapDrag is enabled, automatic JSONL traces are stored in:

```text
~/Library/Logs/TapDrag/Diagnostics/
```

The Diagnostics submenu includes an `Automatic Logging` switch. Turning it off stops creating and updating automatic log files while retaining the bounded in-memory trace for manual copy or export. The setting persists across launches and is independent of `Enabled`. Automatic logs are limited to the newest 12 sessions and use owner-only permissions.

## Project layout

```text
TapDrag/Sources/main.m          Application, gesture state machine, event tap, diagnostics
TapDrag/Info.plist              Bundle metadata and version
TapDrag/Resources/AppIcon.png   Application icon
TapDrag/build.sh                Compile, assemble, sign, and verify the app
tests/touch_state_tests.m       State-machine regression tests
scripts/                        Signing, icon generation, and release helpers
docs/MAINTENANCE.md             Maintainer reference
```

## Credits and license

TapDrag began as an enhanced fork of [ddugel3/3FDragUnstuck](https://github.com/ddugel3/3FDragUnstuck). The current product and gesture path are focused exclusively on immediate-release double-tap dragging.

Released under the MIT License. See `LICENSE`.
