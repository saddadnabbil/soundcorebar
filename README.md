# SoundcoreBar

A small macOS menu bar app for the **soundcore R50i NC** earbuds (model A3959).

I use these earbuds every day, mostly at my Mac. Changing noise cancelling or checking the
battery meant picking up my phone and opening the Soundcore app, every time. I'm too lazy for
that, so this app puts the controls I actually use in the menu bar, one click away.

## What it does

- Battery level for the left and right earbud, with a charging indicator
- Sound mode: ANC, Transparency or Normal
- Noise cancelling type: Manual (strength 1–5), Adaptive, or Scene (Transport / Outdoor / Indoor)
- Wind noise reduction on or off
- Dual connection: turn it on or off, see which devices the earbuds remember, and connect or
  disconnect another device (for example your phone) from the Mac
- Firmware version of each earbud

The menu bar icon changes with the current mode, and the panel updates by itself when you
change the mode with a tap on the earbuds.

Everything happens over Bluetooth between the Mac and the earbuds. There is no account, no
cloud and no network access.

## Requirements

- macOS 13 or later
- Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not needed.
- The earbuds paired and connected to the Mac in System Settings → Bluetooth

Only the R50i NC (A3959) is supported. Write controls are switched off automatically if the
connected earbuds don't identify as an A3959.

## Build and run

```sh
./build.sh
open build/SoundcoreBar.app
```

The first time, macOS asks for Bluetooth permission. To start it at login, add
`SoundcoreBar.app` under System Settings → General → Login Items.

If the panel says the control channel is unavailable, close the Soundcore app on your phone
(it can hold the same channel) and press **Refresh**.

## Tests

```sh
Tests/run_parse.sh   # offline protocol/parser tests, no earbuds needed
Tests/run_e2e.sh     # against real earbuds: switches through the sound modes, then restores your settings
```

`run_e2e.sh` quits a running SoundcoreBar first, because only one program can hold the control
channel at a time.

## How it works

The earbuds expose a vendor serial channel (RFCOMM) next to the normal audio profiles. The
app opens that channel with IOBluetooth and exchanges small framed commands:

| Command | What it does |
|---|---|
| `01 01` | Read the full state (battery, firmware, sound modes, dual connection flag) |
| `06 81` | Set the sound mode block (ANC / Transparency / Normal and ANC options) |
| `06 01` | Pushed by the earbuds when the sound mode changes |
| `0b 01` | Read the dual connection device list |
| `0b 84` | Turn dual connection on or off |
| `0b 81` / `0b 82` | Disconnect / connect one remembered device |

The command set comes from [OpenSCQ30](https://github.com/Oppzippy/OpenSCQ30), which
documents the Soundcore protocol for many models. This app is a separate Swift implementation
for macOS and doesn't include OpenSCQ30 code.

Logs go to `~/Library/Logs/SoundcoreBar.log`.

## Known limits

- The dual connection on/off switch and the Connect/Disconnect buttons follow OpenSCQ30's
  commands. Reading the device list has been checked on real earbuds, but the switching
  commands haven't been fully tested yet.
- The earbuds can have at most two devices connected at the same time.
- Turning dual connection off leaves only one device connected, and that may be the Mac or
  the phone.
- EQ, button remapping and firmware updates are not included. Use the Soundcore app for those.

## Disclaimer

Not affiliated with or endorsed by Anker or Soundcore. "soundcore" is a trademark of Anker
Innovations.
