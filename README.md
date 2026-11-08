# TapDrag

TapDrag is a lightweight macOS menu bar utility that provides double-tap dragging with immediate release. It replaces the system tap-to-drag grace period with a raw-contact-driven gesture, so the dragged item is released as soon as the finger actually leaves the trackpad.

## What it does

- Recognizes a short tap followed by a second one-finger contact.
- Starts dragging only after the second contact moves far enough or is deliberately held.
- Preserves normal clicks with global first-tap buffering for matched trackpad taps.
- Sends one complete tagged `mouseDown -> mouseDragged -> mouseUp` transaction.
- Releases immediately on the real raw finger lift.
- Keeps a bounded automatic diagnostic trace for difficult gesture failures.
- Handles drag input at the HID stage and observes downstream events for diagnostics.

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

When started at login, TapDrag runs in the background without a menu bar icon. Open TapDrag from Finder or Spotlight to show the icon, including when it is already running. Manually launching the app always shows the icon. Choose `Hide Menu Bar Icon` to hide it again without stopping the gesture engine.

TapDrag applies the same first-tap decision window to every uniquely matched raw trackpad tap. This adds roughly 180 ms to ordinary tap-to-click actions. Confirming a drag cancels the buffered first click; otherwise its complete down/up pair is replayed. Physical trackpad presses, mouse clicks, and clicks that cannot be uniquely correlated with a raw tap remain immediate.

The first contact must be a short, stationary tap. The second contact must begin 30–160 ms after the first raw lift. Movement beyond 1.3 mm confirms the drag immediately; a stationary 180 ms hold can also confirm deliberate drag intent. Multi-finger contact invalidates the candidate.

The same global path applies in applications, Launchpad, and the Dock, including files in expanded Dock folders. The delay prevents the first tap from selecting content or opening a file or application before a second contact can turn the gesture into a drag.

TapDrag resets pending contacts and releases any owned drag when macOS sleeps or the user session becomes inactive. On wake or session activation it rebuilds raw multitouch device handles and validates the event taps again. Duplicate lifecycle notifications are handled once, and a temporarily unavailable raw device is retried while the app remains active. Runtime trackpad connection changes are detected through IOKit. Changes to the macOS trackpad dragging setting are detected while the app is running, without requiring the menu to be opened.

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

Release testing that requires real macOS UI, session changes, or trackpad hardware is listed in [the manual testing checklist](docs/MANUAL_TESTING.md).
Implementation details and invariants are documented in [the maintainer reference](docs/MAINTENANCE.md).

For Apple-issued signing, set `TAPDRAG_CODESIGN_IDENTITY`. For release packaging, set `TAPDRAG_RELEASE_CODESIGN_IDENTITY`.

Commit tracked changes before running `make release`. Release packages include the license text inside the app, a corresponding source archive from the current commit, and SHA-256 checksums for both downloads.

## Diagnostics

While TapDrag is enabled, automatic JSONL traces are stored in:

```text
~/Library/Logs/TapDrag/Diagnostics/
```

The Diagnostics submenu includes an `Automatic Logging` switch. Turning it off stops creating and updating automatic log files while retaining the bounded in-memory trace for manual copy or export. The setting persists across launches and is independent of `Enabled`. Automatic logs are limited to the newest 12 sessions and use owner-only permissions.

## Project layout

```text
TapDrag/Sources/main.m          Process entry point
TapDrag/Sources/AppDelegate.m   Menu and macOS application lifecycle
TapDrag/Sources/MultitouchManager.m  Private framework loading and device hotplug
TapDrag/Sources/TapDragEngine.m Gesture recognition, event taps, transactions, diagnostics
TapDrag/Info.plist              Bundle metadata and version
TapDrag/Resources/AppIcon.png   Application icon
TapDrag/build.sh                Compile, assemble, sign, and verify the app
tests/touch_state_tests.m       State-machine regression tests
scripts/                        Signing, icon generation, and release helpers
docs/MAINTENANCE.md             Maintainer reference
docs/MANUAL_TESTING.md          Manual macOS UI, lifecycle, and hardware tests
```

## Credits and license

TapDrag began as an enhanced fork of [ddugel3/3FDragUnstuck](https://github.com/ddugel3/3FDragUnstuck). The current product and gesture path are focused exclusively on immediate-release double-tap dragging.

Released under the GNU General Public License version 2 only (`GPL-2.0-only`). See `LICENSE`.
