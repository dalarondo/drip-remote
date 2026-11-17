# Drip Remote

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Swift 5.10](https://img.shields.io/badge/swift-5.10-orange.svg)](https://swift.org)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-brightgreen.svg)](https://www.apple.com/macos/)

An Apple TV remote for the Mac, built for touch-screen OLED MacBook Pros.

Connect, and a black control panel pours out of the camera island and takes over the screen.
Only the controls are lit; every other pixel stays off. When you're done it drains back into the
island, where a small widget keeps playback controls one tap away.

Drip Remote is a fork of [Itsytv](https://github.com/nickustinov/itsytv-macos) by Nick Ustinov.
The Apple TV protocol work, pairing, keyboard shortcuts and app launcher are his; see
[Acknowledgements](#acknowledgements).

## Features

**Command center** (the main interface)

- Full-screen, pure black: built for OLED, where black pixels are off.
- Pours out of the island with a drip and splash, and drains back into it.
- Square D-pad filling the left half: tap, press and hold, or swipe like the Siri Remote's touch
  surface. Pill-shaped buttons fill the right half.
- Clock at the top. Tap it for a banner of your own text, tap again for nothing at all.
- Tap beside the transport controls for full-screen playback: big buttons, skip 10/20/30 seconds,
  and a scrubber with a large grab circle.
- Long swipe left for your Apple TV's apps.
- Optional red-on-black colours for a dark room.
- Keeps the Mac awake, sits above notification banners, hides the cursor, dims the controls when
  idle and turns the keyboard backlight off until you type.
- Opt-in: double clap to play or pause, or hand gestures seen by the camera (palm or wave left to
  pause, thumbs-up or wave right to play). Both run only while command center is open, and audio
  and video are analysed on the Mac and never recorded.

**Island widget and remote**

- A Live Activity-style widget around the camera island: what's playing, transport, scrubber,
  and buttons to pour out command center or the remote.
- A wide, touch-sized remote that hangs from the island.
- When the Apple TV shows a text field, a text box opens by itself, pre-filled with what's there.
  Dictation works too.

**From Itsytv**

- Pairing with Apple TVs on your network, multiple devices, per-device global hotkeys.
- Keyboard control: arrows, Return, Esc, Delete, Space and more, held like the Siri Remote's
  buttons. Rebind them under Settings → Keyboard shortcuts.
- App launcher, now playing, AppleScript and Shortcuts support.

## Requirements

- macOS 14 or later. The touch and island features are designed for the touch-screen MacBook Pro
  on macOS 27. On other Macs the drip comes out of the notch, or out of a small pill at the top of
  screens without one, and everything works with a mouse or trackpad.
- An Apple TV HD or 4K (4th generation or later) running tvOS 15 or later, on the same network.

## Install

There is no signed download yet; build it yourself:

```bash
brew install xcodegen
git clone https://github.com/<you>/drip-remote.git
cd drip-remote
xcodegen generate
xcodebuild -project DripRemote.xcodeproj -scheme DripRemote -configuration Release \
  -derivedDataPath build/DerivedData build
cp -R "build/DerivedData/Build/Products/Release/Drip Remote.app" /Applications/
```

The build is signed ad hoc, which is enough to run it on the Mac that built it. Opening a copy on
another Mac needs a Developer ID signature and notarization (see [Releasing](#releasing)).

The first time you connect, macOS asks for local network access. Allow it, or Drip Remote can't
find your Apple TV.

## Using it

1. Click the drop in the menu bar and choose your Apple TV. Enter the PIN it shows.
2. Command center pours out. Press ⌘W, pinch in, or tap ✕ to send it back to the island.
3. Tap the island widget for playback controls. Its drop button brings command center back; its
   remote button pours out the smaller remote.
4. Settings live under the gear in command center, on the island widget, or in the menu bar menu.
   To disconnect completely, use the menu bar menu or the remote's ⋯ menu.

### Keyboard

| Key | Action |
|---|---|
| Arrow keys | Navigate |
| Return | Select (hold for the context menu) |
| Esc | Back (hold for the Home screen) |
| Delete | TV / Home |
| Space | Play / pause |
| `=` / `-` | Volume |
| ⇧⌘M | Mute |
| ⌘K | Type on the Apple TV |
| ⌘W | Back to the island |

### AppleScript

```bash
osascript -e 'tell application "Drip Remote" to pause'
osascript -e 'tell application "Drip Remote" to play'
```

## Privacy

- Everything stays on your Mac and your local network. Drip Remote has no analytics and no
  update checks, and makes no internet requests except looking up the Apple TV's app icons with Apple's iTunes Search
  API.
- The microphone and camera are used only if you turn on clap or gesture control, only while
  command center is open, and nothing is recorded or stored.
- Pairing keys are kept in your Keychain.

## Known limitations

- **Not sandboxed.** Dimming the keyboard backlight uses a private macOS service
  (`CoreBrightness`) that a sandboxed app is unlikely to reach. That also rules out the Mac App
  Store. If a future macOS removes the service, dimming silently stops working.
- **The island widget isn't a real Live Activity.** macOS has no public API for drawing in the
  camera island, so the widget is a borderless window positioned over it.
- **No Siri.** The Apple TV accepts the Siri button press, but Drip Remote can't stream your voice
  to it. The mic button uses macOS dictation to type into text fields instead.
- Hand gestures need decent light and work best within a few metres of the camera.

## Development

```bash
xcodegen generate
xcodebuild -project DripRemote.xcodeproj -scheme DripRemote -derivedDataPath build/DerivedData test
```

- `DripRemote/` is the app. Command center is in `UI/CommandMode.swift`, the island widget in
  `UI/IslandWidget.swift`, and the drip shapes in `Island/IslandShapes.swift`.
- `Packages/ItsytvCore/` is a vendored copy of Nick Ustinov's itsytv-core, which implements the
  Apple TV protocols. The changes made to it are listed in
  [Packages/ItsytvCore/VENDORED.md](Packages/ItsytvCore/VENDORED.md).
- Unit tests cover the drip shapes, keyboard shortcuts and onboarding logic. They build without
  a host app, so running them doesn't scan your network.

### Releasing

`scripts/build-release.sh` archives a Release build, signs it and wraps it in a DMG under `dist/`.
Set `DRIP_SIGNING_IDENTITY` to your "Developer ID Application" certificate to sign it for other
Macs, then notarize the DMG with the `notarytool` command the script prints. Without the variable
it signs ad hoc.

## Licence

MIT. See [LICENSE](LICENSE). Itsytv, which Drip Remote is built on, is copyright Nick Ustinov and
also MIT-licensed; its copyright notice is kept in LICENSE as the licence requires.

## Acknowledgements

- [Itsytv](https://github.com/nickustinov/itsytv-macos) and
  [itsytv-core](https://github.com/nickustinov/itsytv-core) by Nick Ustinov, and Itsytv's
  contributors.
- [pyatv](https://github.com/postlund/pyatv), whose documentation of the Apple TV protocols
  informed itsytv-core.
- Swift packages: swift-protobuf, swift-crypto and swift-asn1 (Apple), swift-srp and big-num
  (Adam Fowler).

Full details and licences are in [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).

Apple TV, tvOS, Siri and Dynamic Island are trademarks of Apple Inc. Drip Remote is not affiliated
with or endorsed by Apple or the Itsytv project.
