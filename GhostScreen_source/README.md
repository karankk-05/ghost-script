# GhostScreen

Presenter notes that only *you* can see.

GhostScreen shows a floating markdown notes window that is **invisible to
every capture path on macOS** — screen sharing (Zoom, Meet, Teams), QuickTime
recordings, screenshots — and, with **beamer mirror mode**, even to a
projector that appears to mirror your screen.

## How it works

- **Screen-share protection** — the notes overlay sets
  `NSWindow.sharingType = .none`. The compositor excludes it from the entire
  system capture pipeline and cleanly recomposites whatever is behind it (no
  black box). This needs **no permissions at all**.
- **Beamer mirror mode** — OS display mirroring happens in the compositor,
  with no per-window opt-out. So GhostScreen doesn't use it: it switches the
  arrangement to *extended* (session-scoped, auto-reverts at logout/reboot),
  covers the projector with a fullscreen window, captures the **built-in**
  display with ScreenCaptureKit at ~60 fps, and renders that stream to the
  projector. The notes overlay is excluded from the capture — the audience
  sees your screen exactly as if mirrored, minus your notes.

## Building

```bash
make run
```

That builds with SwiftPM, assembles `GhostScreen.app`, signs it and launches
it. **`swift run` is unsupported** — a bare executable has no bundle identity
(no stable Screen Recording permission, no Dock drops).

### Signing / the Screen Recording permission

Beamer mirror mode needs Screen Recording permission (the overlay alone needs
none). macOS ties that grant to the app's code-signing identity, and an
**ad-hoc** signature changes on every rebuild — macOS forgets the grant each
time. For development, create a self-signed certificate once:

1. Keychain Access → Certificate Assistant → *Create a Certificate…*
2. Name: `GhostScreen Dev`, Identity Type: *Self-Signed Root*,
   Certificate Type: **Code Signing**
3. Build with:

```bash
make run SIGN_ID="GhostScreen Dev"
```

After granting Screen Recording in System Settings, **relaunch the app** —
macOS only applies the grant at process start.

## Using it

1. Open a markdown file (button, ⌘O, drag & drop onto the window/overlay/Dock
   icon). It live-reloads as you edit — vim/VS Code atomic saves included.
2. The overlay floats above everything, including fullscreen presentations.
   Drag it by the grip strip at its top; resize from the edges; select text
   to copy; hover a code block for a one-click **Copy** button. ⌘⇧N toggles
   it, and the opacity slider keeps it readable over busy slides.
3. For a projector: connect it (mirrored or extended, both fine) and press
   **Start Mirror** — *before* putting your deck in fullscreen. Stop the
   mirror (or quit) to restore your previous arrangement.

## Honest limitations

- **The capture indicator**: while mirror mode runs, macOS shows a screen
  capture indicator in the menu bar — which the audience sees, since the menu
  bar is mirrored. It's small, and it's honest.
- **Notifications** can draw above the beamer output window. Turn on a Focus
  mode while presenting.
- **Start the mirror before fullscreen**: macOS can refuse display
  reconfiguration while another app is fullscreen.
- If GhostScreen ever crashes mid-mirror, your displays stay extended for the
  session (a reboot/logout reverts it); on next launch GhostScreen offers to
  restore the previous arrangement. `Dev → Panic Restore` (with
  `GHOSTSCREEN_DEV=1`) applies the permanent saved configuration.
- A phone camera pointed at your screen still sees your notes. Physics.
- Other external displays are left untouched; one beamer target at a time
  (pick it in *Displays* when several are attached).

## Dev flags

| Env var | Effect |
|---|---|
| `GHOSTSCREEN_DEV=1` | Adds the *Dev* menu (mirror break/restore, test capture) |
| `GHOSTSCREEN_DISABLE_CAPTURE_PROTECTION=1` | Makes the overlay capturable — for testing/screenshots only |
| `GHOSTSCREEN_AUTOTEST_CAPTURE=1` | Starts the test-capture window automatically at launch |

## Repo layout

```
Sources/GhostScreen/
  App/         SwiftUI app, delegate, shared @Observable state
  MainWindow/  control window UI
  Overlay/     the capture-protected notes panel (NSPanel + WKWebView)
  Markdown/    markdown-it/highlight.js pipeline (bundled, offline)
  Files/       open/restore + kqueue live-reload watcher
  Display/     display topology, mirror break/restore, beamer window,
               mirror-mode state machine
  Capture/     ScreenCaptureKit → AVSampleBufferDisplayLayer zero-copy pipeline
Spikes/        throwaway CLI spikes that validated the platform assumptions
```
