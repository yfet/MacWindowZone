# MacWindowZone

A native macOS clone of Windows **FancyZones** — define rectangular zones on each display, snap any app's window into a zone, and have windows return to their zones the next time they open.

> Pure Swift / AppKit, no third-party dependencies. Lives in the menu bar.

## Links

| | |
|---|---|
| 🌐 **Website / docs** | https://yfet.github.io/MacWindowZone/ |
| 📦 **Downloads (latest release)** | https://github.com/yfet/MacWindowZone/releases/latest |
| 🗃 **All releases** | https://github.com/yfet/MacWindowZone/releases |
| 🐛 **Issues / bug reports** | https://github.com/yfet/MacWindowZone/issues |
| 📜 **License** | [MIT](LICENSE) |

---

## Features

- **Zone editor per display** — full-screen overlay where you draw, move, resize, split and delete zones with the mouse.
- **Layout templates** — *No Layout / Focus / Left-Right / 3 Columns / 2-3 Rows / 2×2 Grid / 3×3 Grid / Priority Grid* — pick from a picker that lets you apply different templates to different displays independently.
- **Shared-edge resize** — dragging a divider between two adjacent zones resizes both at once, like a tiling window manager.
- **Smart delete** — removing a zone makes its adjacent neighbours expand to absorb the freed space (no orphan gaps), provided the layout is cleanly tileable.
- **Shift-Click / Ctrl-Click splits** — split a zone in half (vertically or horizontally) with a single click.
- **Snap by hotkey** — `⌃⌥1` … `⌃⌥9` snap the focused window to zone 1…9 on the screen that contains it.
- **Snap by drag** — hold the configured modifier (default `⇧ Shift`) while dragging a window; the zone overlay appears and snap happens on release inside a zone.
- **Configurable drag modifier** — `Shift`, `Option`, `Command`, `Control`, none (always), or disabled.
- **Configurable gap** — visual breathing room between snapped windows (default 4 pt, preset choices 0–24 pt, or custom).
- **Window memory** — when a window opens with the same app bundle + title prefix as a previously-snapped one, MacWindowZone restores it to its zone (or fallback frame).
- **Browser-safe ignore list** — Chrome, Edge, Brave, Safari, Firefox, Arc, Vivaldi, Opera (and their Beta/Dev/Canary variants) are excluded from auto-restore by default to avoid interfering with their own session/tab restoration. Configurable per-app via the menu.
- **Cross-screen aware** — accurate AX↔Cocoa coordinate conversion. The shrink-then-grow dance for cross-screen snaps is skipped on same-screen snaps so content-wrapping apps (terminals, editors) keep their layout.
- **Launch at login** — toggle via `SMAppService` (macOS 13+).
- **Custom app icon** — a programmatically-generated squircle icon with a Priority-Grid motif, regenerable with a single Swift script.
- **Native macOS Accessibility prompt** — silent check at startup, no custom dialog over the system one. Subsystems start automatically as soon as access is granted (no relaunch).
- **All data lives in `~/Library/Application Support/MacWindowZone/`** — `zones.json`, `window-memory.json`, `debug.log`.

---

## Requirements

- macOS **14.0 (Sonoma)** or newer
- Xcode command-line tools (`xcode-select --install`)
- Swift 6 / Xcode 15+

---

## Build & install

From the project root:

```bash
./scripts/build-app.sh             # release build → ./build/MacWindowZone.app
open ./build/MacWindowZone.app
```

The build script:

1. Compiles the package with `swift build -c release`.
2. Assembles a proper `.app` bundle in `./build/`.
3. Generates the `AppIcon.icns` from `scripts/generate-icon.swift` if missing.
4. Ad-hoc codesigns with a stable identifier so Accessibility access survives rebuilds (works for most users — for full persistence use a Developer ID cert).

Copy to `/Applications` if you want it permanent:

```bash
cp -R ./build/MacWindowZone.app /Applications/
```

To launch in dev mode without a bundle (some AX behaviours differ):

```bash
swift run
```

To regenerate the icon (e.g. after editing `scripts/generate-icon.swift`):

```bash
swift scripts/generate-icon.swift
./scripts/build-app.sh
```

---

## First-time setup

1. Launch the app. The menu-bar icon (three rectangles) appears in the top-right of the system menu bar.
2. macOS will prompt for **Accessibility** access the first time a feature needs it — or you can trigger the prompt from the menu (`Request Accessibility Access`). This is required because the app moves and resizes other apps' windows via the Accessibility API.
3. Grant access in *System Settings → Privacy & Security → Accessibility*. The app polls every second and starts its AX subsystems as soon as the toggle is on — no relaunch needed.

---

## Usage

### Defining zones

1. Status-bar icon → **Edit Zones…**
2. The template picker opens. Pick the screen tab at the top, then click a template tile — it's applied to that screen only. Switch tabs and apply different templates to other screens.
3. Click **Open Editor** to go into the per-display editor. Each screen gets its own translucent overlay.

### In the zone editor

| Gesture | Effect |
| --- | --- |
| Click + drag on empty area | Create a new zone |
| Drag inside a zone | Move it |
| Drag an edge or corner | Resize (shared edges move adjacent zones together) |
| `⇧ Shift + Click` inside a zone | Split vertically into two equal halves |
| `⌃ Control + Click` inside a zone | Split horizontally into two equal halves |
| `Delete` / `Backspace` | Remove the selected zone (neighbours absorb the space) |
| `⌘R` | Reset the current screen to defaults |
| `Esc` / Done button | Exit the editor |

Cursor changes automatically when hovering edges/corners (resize cursors) or the centre (open-hand move cursor).

### Snapping windows

- **By keyboard:** focus a window, press `⌃⌥1` for zone 1, `⌃⌥2` for zone 2, etc. Snaps within the screen that currently contains the window.
- **By drag:** drag a window while holding the configured modifier (default `Shift`). The zone overlay fades in across every display, the zone under the cursor highlights, and releasing inside a zone snaps the window. Releasing outside any zone is a no-op.
- **From the menu:** *Snap Focused Window → [screen] → [zone]*.

### Window memory

Whenever you snap a window, MacWindowZone records `(bundle ID, first 60 chars of title) → (zone, screen, last frame)` in `window-memory.json`. The next time a window with the same key opens, it's restored to that placement.

Browsers are excluded by default (because attaching AX observers + `setFrame` during their startup tends to disrupt their tab/session restoration). You can toggle individual apps via *Ignored for Auto-Restore* in the menu.

### Status menu reference

```
✓ Accessibility granted · snap ready          (live status)
Edit Zones…                                    open the picker + editor
Snap Focused Window ▸ …                       sub-menu per screen
Gap Between Windows: 4 px ▸ …                 visual gap between snapped windows
Drag Modifier: Shift (⇧) ▸ …                  what modifier (if any) triggers snap-on-drag
Snap on Drag                                  master toggle for drag snap
Restore Windows on Launch                     master toggle for the window restorer
Ignored for Auto-Restore (N) ▸ …              per-app exclusion list
Launch at Login                               toggle SMAppService registration
Reset Zones on Current Screen
Forget All Window Positions
Open Data Folder
Open Debug Log
Request Accessibility Access                  triggers the native macOS prompt
Quit MacWindowZone                            (⌘Q)
```

---

## Architecture

```
Sources/MacWindowZone/
├── main.swift               # Entry point — NSApplication wiring
├── AppDelegate.swift        # Status item, menu, subsystem orchestration
├── Models.swift             # Zone, ScreenLayout, FractionalRect, WindowMemory
├── Persistence.swift        # JSON-backed ZoneStore + WindowMemory singletons
├── Settings.swift           # UserDefaults-backed runtime settings
├── ScreenManager.swift      # Stable display IDs, Cocoa↔AX coordinate conversion
├── WindowAX.swift           # Thin wrapper over the Accessibility API
├── HotkeyManager.swift      # Carbon RegisterEventHotKey for ⌃⌥1–⌃⌥9
├── DragSnap.swift           # Global mouse monitor → overlay + snap on release
├── Snapper.swift            # Applies a Zone to an AXWindow + records memory
├── ZoneTemplate.swift       # Predefined layouts + thumbnail rendering
├── TemplatePicker.swift     # Per-screen template picker NSWindow
├── ZoneEditor.swift         # Per-screen full-screen editor overlay
├── WindowRestorer.swift     # AX observers + app-launch notifications → restore
├── LaunchAtLogin.swift      # SMAppService wrapper
├── Log.swift                # File-backed log (~/Library/Application Support/MacWindowZone/debug.log)
└── …
AppResources/
├── Info.plist               # Bundle manifest (SPM forbids it as a target resource)
├── AppIcon.icns             # Generated icon
└── AppIcon.iconset/         # Source PNGs (gitignored)
scripts/
├── build-app.sh             # Build → bundle → codesign
└── generate-icon.swift      # Regenerate AppIcon.icns from code
```

### Coordinate systems

- **Cocoa:** y-up, origin bottom-left of the primary display.
- **AX / Quartz:** y-down, origin top-left of the primary display.
- `ScreenManager.cocoaToAX(_:)` converts between them; the conversion is the same for any point in the unified screen space (negative coordinates on extended displays included).
- Zones are stored as **fractional rectangles** (0…1) of each display's *visible frame*, so layouts survive resolution and scale changes.

### Cross-screen window manipulation

macOS' AX clamps size changes to the *current* display. Moving a window across screens with a naive `setPosition + setSize` will be clamped back if the size doesn't fit the new display. Solution: shrink to 100×100 first → move → resize → re-position. Done only for **cross-screen** moves so same-screen snaps don't trigger content reflow in terminals/editors.

### Why convenience inits everywhere for `NSWindow` subclasses

AppKit's 5-arg `initWithContentRect:styleMask:backing:defer:screen:` internally calls the 4-arg `initWithContentRect:styleMask:backing:defer:` on `self`. If you subclass `NSWindow` with stored properties and a custom designated init, Swift inserts a trap into the auto-synthesised 4-arg init that AppKit hits → SIGTRAP. Always use `convenience init` that calls the inherited 4-arg designated init.

---

## Known limitations (v0.1)

- Some apps (Electron, certain Java apps) clamp programmatic resize requests.
- Window-key matching uses the first 60 chars of the title — good for most apps, fails on document-style apps with constantly-changing titles (falls back to remembering the last frame instead of the zone).
- The app is ad-hoc signed by the build script. Accessibility permission can be invalidated on rebuild (binary CD-hash changes). With a Developer ID cert this issue goes away.
- The browser ignore list disables auto-restore for browsers; manual snap (Shift+drag, hotkeys, menu) still works for them.

---

## License

MIT — see [LICENSE](LICENSE) if present, otherwise treat as MIT.
