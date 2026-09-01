# 3FDragUnstuck Enhanced Fork

An enhanced fork of 3FDragUnstuck, a lightweight macOS menu bar utility designed to reduce the release delay associated with native Three Finger Drag.

## Original Project

This project is based on the excellent work by **ddugel3**.

A sincere thank you to the original author for the brilliant idea and implementation. The original project solved a very specific macOS usability issue in an elegant and lightweight way, making native Three Finger Drag feel significantly more responsive.

Original repository:

https://github.com/ddugel3/3FDragUnstuck

## What's Included In This Fork

This fork preserves the original functionality while adding several quality of life improvements:

### Features

* Reduced Three Finger Drag release delay
* Experimental fast release for double-tap dragging
* Menu bar utility with minimal resource usage
* Configurable Override Modifiers

  * Shift
  * Control
  * Option
  * Fn (Globe)
* Hide Menu Bar Icon
* Accessibility Status Indicator
* Persistent settings between launches
* Custom Application Icon
* Additional Icon Designs Included In Repository

### Override Modifiers

The original override functionality has been expanded into a configurable system that lets you select which modifier key suppresses the fast release while it is held.

Available options:

* Shift
* Control
* Option
* Fn (Globe)

This allows users to choose a modifier that best fits their workflow and avoids conflicts with common shortcuts such as screenshot selection. Holding the selected modifier as the drag ends keeps the native release behavior, and your choice is saved between launches.

**Note on Fn (Globe):** Fn (Globe) works best on Apple built-in keyboards and Apple Magic Keyboards. Support on third-party keyboards depends on whether the keyboard exposes the Fn key to macOS; some keyboards handle Fn internally and never report it to the system, so the override cannot trigger.

### Double-Tap Drag Replacement

macOS intentionally keeps **Without Drag Lock** alive briefly after the finger lifts so the finger can be repositioned. It exposes dragging on/off and dragging style settings, but no separate preference for shortening that release grace. Changing the global double-click interval also changes whether a double tap is recognized, so it is not an independent release-delay control.

The recommended mode therefore removes the native recognizer from this gesture and lets the app own the drag:

1. In **System Settings -> Accessibility -> Pointer Control -> Trackpad Options**, turn off **Use trackpad for dragging**.
2. Keep ordinary **Tap to click** enabled in Trackpad settings.
3. Enable **Double-Tap Drag Replacement (Experimental)** in the `3F+` menu.
4. Confirm that the status row says **Double-Tap Drag: Full replacement ready**.

The first tap remains a normal macOS tap-to-click, preserving Finder selection and background-window activation. A physical click whose native mouse-down occurs while the finger is still touching the trackpad is not accepted as that first tap. A second raw contact qualifies only when it begins 30–160ms after the first raw lift (or within a shorter system double-click interval). This tight inter-contact window is the actual intent boundary: successful double-tap drags in captured traces begin after 40–160ms, while confirmed one-click-then-move false positives begin at 176ms or later. Once the second contact qualifies, movement beyond 1.3mm confirms the drag immediately, while a stationary 180ms hold also confirms it. The app then publishes one complete tagged `down -> dragged -> up` transaction. If the trackpad driver reassigns the raw contact identity while one finger remains down, the app transfers that identity without ending the mouse transaction. A real raw finger lift owns the up and returns the state machine directly to `Idle`; there is no native tap-to-drag grace or shadow session to clean up. A 40ms start allowance lets the normal first click reach Finder/AppKit before the synthetic drag down, but it does not delay release.

If native trackpad dragging remains enabled, the replacement stays inactive and does not filter or synthesize double-tap drag events. There is no legacy compatibility or shadow path.

This feature needs permission to synthesize and monitor mouse events. Accessibility normally grants both; if macOS asks separately, also grant Input Monitoring to this exact build. Diagnostics are written to `~/Library/Logs/3FDragUnstuck/DoubleTap/` while the feature is enabled. The feature remains opt-in because raw contact capture uses Apple's private `MultitouchSupport.framework`. Do not combine the experimental gesture with simultaneous external-mouse button input. If the app is not running, double-tap dragging is unavailable until either the app is restarted or native trackpad dragging is turned back on.

For implementation details, state-machine invariants, release steps, and a regression test checklist, see [the maintenance guide](docs/MAINTENANCE.md).

### Launching the enhanced build

This is a menu bar utility, not a windowed app. After launching it, look for **3F+** in the menu bar; it does not show a Dock icon or a main window. Quit the original Downloads copy before launching the enhanced build so that only one drag-release helper is active.

### Menu Bar Icon

The menu bar icon can be temporarily hidden while the application continues running.

Launching the application again restores the icon without affecting the underlying functionality.

### Accessibility Status

The application displays the current Accessibility permission state directly in the menu, making troubleshooting easier for new users.

## Building

```bash
make build
```

### Local-build permissions

Run this once before the first local build:

```bash
make setup-local-signing
```

It creates a local-only self-signed Code Signing identity named `3FDragUnstuck Local Development` in the login keychain. Normal `make build` then uses that same identity every time. macOS ties Accessibility and Input Monitoring grants to the app's designated requirement; unlike an ad-hoc signature, this requirement remains stable after source changes.

After migrating from an older ad-hoc build, grant permission once more to the newly signed `build/3FDragUnstuck.app`. Subsequent rebuilds do not require reauthorization as long as the bundle identifier and the local signing certificate/private key remain unchanged. Check the active identity and designated requirement with:

```bash
make signing-status
```

If a certificate with the same local identity name remains but its private key
is missing, `make setup-local-signing` stops instead of silently replacing it.
Restore that key, or deliberately remove the certificate and grant permission
once again after creating a new identity.

For an Apple-issued local identity, override the default explicitly:

```bash
THREE_F_DRAG_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make build
```

`make build-adhoc` is retained only for a temporary build that does not need persistent privacy permissions. The local self-signed identity is not a release identity: `make release` deliberately does not inherit it. Use a Developer ID identity and notarization before distributing outside this Mac.

## Verification

```bash
make verify
```

## Requirements

* macOS
* Accessibility permission enabled once for the stable local application identity

## License

This project remains licensed under the MIT License, consistent with the original project.

## Credits

**Original Author:** ddugel3

**Fork Maintainer:** efilo1

Special thanks again to ddugel3 for creating the original utility and sharing it with the community.
