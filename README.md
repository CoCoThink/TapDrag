# TapDrag

TapDrag is a lightweight macOS menu bar utility that provides double-tap dragging with immediate release. It replaces the system tap-to-drag grace period with a raw-contact-driven gesture, so the dragged item is released as soon as the finger actually leaves the trackpad.

## What it does

- Recognizes a short tap followed by a second one-finger contact.
- Starts dragging only after the second contact moves far enough or is deliberately held.
- Preserves normal clicks. In WeChat, the first tap is briefly buffered so a drag does not become a double-click.
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

The first contact must be a short, stationary tap. The second contact must begin 30–160 ms after the first raw lift. Movement beyond 1.3 mm confirms the drag immediately; a stationary 180 ms hold can also confirm deliberate drag intent. Multi-finger contact invalidates the candidate.

WeChat tap clicks have a roughly 200 ms decision window. Confirming a drag cancels the buffered first click; otherwise the click is replayed. Real double-clicks are replayed in order. TapDrag tracks WeChat launches and exits automatically, including when WeChat starts after TapDrag. Restarting WeChat does not require restarting TapDrag.

On 2026-09-05, the user confirmed that double-tap text selection works with a physical trackpad in WeChat 4.1.11 on macOS 15.7.7. WeChat window dragging still requires separate confirmation. See the [diagnosis and validation record](docs/WECHAT-DRAG-DIAGNOSIS.md).

## Build

```sh
make setup-local-signing
make verify
make run
```

`make setup-local-signing` is normally required only once. For authorization continuity, the project deliberately retains the existing bundle identifier and default local signing identity from earlier builds. Changing either can make macOS request Accessibility and Input Monitoring permission again.

Useful targets:

```sh
make build
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

The menu also supports copying a diagnostic summary, exporting a trace, revealing automatic logs, and clearing the in-memory trace. Automatic logs are limited to the newest 12 sessions and use owner-only permissions.

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
