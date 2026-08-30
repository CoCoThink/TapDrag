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

### Double-Tap Drag Fast Release

The menu includes an experimental **Fast Release for Double-Tap Drag** option. It is off by default.

When enabled, the app reads the trackpad's raw contact states rather than inferring the gesture from mouse click counts. It recognizes a brief first one-finger tap followed, within the system double-click interval, by a second one-finger contact that actually moves. When that second contact leaves the trackpad, it sends an immediate mouse-up rather than waiting for macOS's repositioning grace period. Real movement, rather than a fixed contact-duration threshold, keeps fast drag-and-drop gestures from being missed.

macOS keeps its own tap-to-drag recognizer alive for that grace period even after an application receives the synthetic mouse-up. To make a second double-tap drag possible immediately, this build takes ownership only after it has confirmed the next second contact. Its first movement is paired with a tagged mouse-down, then the drag stream and mouse-up are kept as one sequence. Native button events are filtered only while that confirmed candidate is owned, so a late stale event cannot end the owned drag. The app deliberately does not replay synthetic clicks for taps without movement, which avoids duplicate clicks and accidental file opens.

This option is intended only for the **Without Drag Lock** dragging style. Do not enable it with Drag Lock, where lifting your finger is meant to keep the drag active until the next tap.

It needs permission to synthesize and monitor mouse events. On current macOS releases, Accessibility normally grants both; if macOS asks separately, also grant Input Monitoring to this exact build. The menu's `Double-Tap last` row shows whether a release was posted, a first tap was captured, or a consecutive drag is active or released. The feature remains opt-in because macOS does not provide a public API for this gesture recognition; do not rely on it while dragging with an external mouse and touching a trackpad at the same time.

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

The default build uses an ad-hoc signature. macOS ties Accessibility grants to the app's code signature, so rebuilding after source changes can invalidate an earlier grant. After rebuilding, quit the old process and grant permission again to the current `build/3FDragUnstuck.app` if the menu reports that permission is required. This fork has its own bundle identifier, so it can coexist with the original app without confusing LaunchServices or permission records.

For a stable local developer identity, pass a signing identity when building:

```bash
THREE_F_DRAG_CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make build
```

Use `security find-identity -v -p codesigning` to list identities available on the machine.

## Verification

```bash
make verify
```

## Requirements

* macOS
* Accessibility permission enabled for the exact application build

## License

This project remains licensed under the MIT License, consistent with the original project.

## Credits

**Original Author:** ddugel3

**Fork Maintainer:** efilo1

Special thanks again to ddugel3 for creating the original utility and sharing it with the community.
