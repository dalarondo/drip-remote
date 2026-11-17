# Vendored copy of itsytv-core

This directory is a copy of [itsytv-core](https://github.com/nickustinov/itsytv-core) by
Nick Ustinov, taken at upstream commit `0a09f06` ("Merge #2 from Lemelson: real
press-and-hold for buttons"). It is kept inside this repository so Drip Remote builds from a
single checkout.

## Licence

The upstream README states: "MIT License (c) 2026 Nick Ustinov". The upstream repository did
not contain a licence file at that commit, so the `LICENSE` file here was added for this copy
and reproduces the standard MIT text with that copyright line. If upstream publishes its own
licence file, that one takes precedence.

## Changes made for Drip Remote

- `Protocol/AppleTVManager.swift`: track text-field focus on the Apple TV from the Companion
  `_tiStarted` / `_tiStopped` events (and from the reply to `_tiStart` on connect), setting
  `keyboardFocused` and the new `focusedFieldText`. Upstream declares `keyboardFocused` but
  never sets it.
- `Crypto/KeychainStorage.swift`: Keychain service name changed to `com.dripremote.credentials`,
  so Drip Remote keeps its own pairings and does not read Itsytv's.
- `LogConfig.swift`: log subsystem changed to `com.dripremote.app`.
- `Utilities/LastConnectedDeviceStorage.swift`: defaults key changed to
  `com.dripremote.last-connected-device`.
- `MRP/MRPManager.swift`, `AirPlay/AirPlayControlChannel.swift`: the client name the Apple TV
  sees is "Drip Remote".

Everything else is unmodified.
