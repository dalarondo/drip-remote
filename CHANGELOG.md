# Changelog

## 1.0.0

First release of Drip Remote, forked from [Itsytv 1.9.0](https://github.com/nickustinov/itsytv-macos)
by Nick Ustinov. Itsytv's own history is in [docs/ITSYTV-CHANGELOG.md](docs/ITSYTV-CHANGELOG.md).

### Command center

- A full-screen, pure-black control panel for OLED displays: only the controls are lit, every
  other pixel is off. Opens by default when you connect.
- Pours out of the camera island with a drip, wobble and splash, and drains back into it.
- Square, full-height D-pad on the left half (tap, hold, or swipe like the Siri Remote's touch
  surface); pill-shaped buttons filling the right half.
- Clock at the top. Tap it to switch to a banner of your own text, then to nothing.
- Tap beside the transport controls for a full-screen playback page: big transport buttons,
  skip 10 / 20 / 30 seconds, and a scrubber with a large grab circle.
- Long swipe left for the apps grid.
- Optional red-on-black colours.
- Keeps the Mac awake, sits above notification banners, hides the cursor until a mouse or
  trackpad moves, and dims the controls after 30 seconds idle.
- Turns the keyboard backlight off, and back on while you type.
- Opt-in: double clap to play or pause (microphone); raised palm, thumbs-up and waves to pause
  and play (camera). Both run only while command center is open and are analysed on the Mac.

### The island widget

- Command center and the remote retract into a Live Activity-style widget around the camera
  island. Tap it for playback controls, a scrubber, a drip button back to command center and a
  button for the remote.
- Keyboard shortcuts work while it is open, without bringing the app to the front.

### Remote

- Wide, touch-sized layout that pours out of the island and stays attached to it.
- The text box opens by itself when a text field is focused on the Apple TV, pre-filled with
  what is already there, and closes when the field goes away. You can also type from the
  island widget.
- Dictate button: speak into the Apple TV's text fields with macOS dictation.
- Scrubbing like an iOS app: a tall touch target, a thumb, smooth progress and slower
  scrubbing the further your finger moves from the bar.
- Pinch in on command center for the remote; pinch out on the remote for command center.

### Everything else

- One Settings window for every preference, reachable from the menu bar menu, the island
  widget, command center and the remote.
- Touch-screen Macs and Sidecar iPads are detected through gesture recognizers, as Apple's
  touch documentation recommends, so the cursor never triggers the touch layout.
- Removed: update checks against the original project, Mac App Store build paths and promotions
  for the original author's other apps.
