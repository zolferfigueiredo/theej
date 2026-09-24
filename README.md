# deej-mac

macOS client for an existing [deej](https://github.com/omriharel/deej) Arduino: master volume
plus external monitor brightness.

Upstream deej is Windows-only for audio (it uses Windows Core Audio for per-app sessions). This is a
small Swift daemon that speaks the same serial protocol and drives the macOS **master output
volume** through CoreAudio, and **external monitor backlights** over DDC/CI. Arduino firmware is
unchanged.

- Reads the deej serial protocol at 9600 baud, 5 sliders
- Three knobs by default: volume, left monitor brightness, right monitor brightness
- Sets volume in-process via CoreAudio, with no `osascript`
- Follows whichever output device is current, so Bluetooth headphones just work
- Identifies monitors by their CoreGraphics UUID and orders them by on-screen position, so two
  identical panels stay left and right across sleep and replug
- Auto-detects the serial port and reconnects when the board is unplugged
- No menu bar app, nothing resident besides the daemon itself

## Build and run

Needs Xcode command line tools (`xcode-select --install`).

Brightness additionally needs [m1ddc](https://github.com/waydabber/m1ddc), a small standalone
binary. Apple Silicon only; volume works without it.

```bash
brew install m1ddc
./build.sh
./run.sh
```

**Quit MonitorControl, BetterDisplay or any similar app first.** Two processes writing the same
monitor over I2C will fight over the value.

It prints live slider values so you can see which physical slider is which index.

## Run at login

```bash
./install.sh
```

Installs a LaunchAgent that starts at login and restarts on crash. Logs to `/tmp/deej-mac.log`
(quiet: the status line is only printed to a terminal).

```bash
./install.sh --uninstall
```

## Options

```bash
./run.sh /dev/cu.usbserial-1130     # force a specific port
./install.sh /dev/cu.usbserial-1130 # bake the port into the LaunchAgent
./run.sh --selftest                 # run the built-in assertions and exit
```

List available ports with `ls /dev/cu.*`.

## Tuning

Constants at the top of [Sources/deej-mac/main.swift](Sources/deej-mac/main.swift), then rebuild:

- `mapping`: which knob drives what. Defaults to
  `[0: .master, 3: .brightness(0), 2: .brightness(1)]`, meaning slider 0 is volume, slider 3 is the
  leftmost external monitor and slider 2 is the one to its right. Brightness indices count external
  displays left to right by their position in System Settings; the built-in display is never a
  target. Swap the two indices if your monitors are the other way round.
- `invertSliders`: `true` for boards where sliding down raises the value. Set to `false` if your
  pots are wired the other way.
- `deadzone`: `0.01` (1%, about 10 ADC counts). Raise it if a value drifts while you aren't
  touching the slider, lower it if the steps feel coarse.
- `brightnessInterval`: `0.25` seconds between DDC writes. One write takes about 77ms and DDC/CI is
  slow, so a fast sweep drops intermediate positions and applies the final one. Lower it if
  brightness feels laggy, raise it if the panel struggles.

Turning a brightness knob fully down sets the backlight to 0 and the panel goes black. The knob is
the way back.

## Not included

Per-app volume. That needs a virtual audio device (BlackHole / Background Music) and process-tap
plumbing; this deliberately only does master.

Brightness of the built-in display. It is not a DDC device and needs a separate API.
