# deej-mac

macOS client for an existing [deej](https://github.com/omriharel/deej) Arduino: master volume,
external monitor brightness, and built-in display brightness, with the native macOS HUD.

Upstream deej is Windows-only for audio (it uses Windows Core Audio for per-app sessions). This is a
small Swift daemon that speaks the same serial protocol and drives the macOS **master output
volume** through CoreAudio, **external monitor backlights** over DDC/CI, and the **built-in Retina
panel** through DisplayServices. Arduino firmware is unchanged.

- Reads the deej serial protocol at 9600 baud, 5 sliders
- Four knobs by default: volume, built-in display, left monitor, right monitor
- Shows the real macOS HUD on the display each knob controls
- Menu bar icon showing connected or disconnected at a glance
- Sets volume in-process via CoreAudio, with no `osascript`
- Follows whichever output device is current, so Bluetooth headphones just work
- Identifies monitors by their CoreGraphics UUID and orders them by on-screen position, so two
  identical panels stay left and right across sleep and replug
- Auto-detects the serial port and reconnects when the board is unplugged

## Build and run

Needs Xcode command line tools (`xcode-select --install`).

External monitor brightness additionally needs [m1ddc](https://github.com/waydabber/m1ddc), a small
standalone binary. Apple Silicon only. Volume and built-in brightness work without it.

```bash
brew install m1ddc
./build.sh
./run.sh
```

**Quit MonitorControl, BetterDisplay or any similar app first.** Two processes writing the same
monitor over I2C will fight over the value.

It prints live slider values so you can see which physical slider is which index.

## Menu bar

A faders icon sits in the menu bar. When the Arduino is not connected it gains a heavy diagonal
slash. The icon is a template image, so it follows light and dark menu bars automatically.

Clicking it, with either button, opens a menu showing the current port and the live value of every
knob, plus Reconnect and Quit.

There is no Dock icon and no window. When run from a terminal it also prints live slider values,
so you can see which physical slider is which index.

## On-screen feedback

Turning a knob shows the same HUD macOS shows for its own brightness and volume keys, on the
display that knob controls. macOS only raises that HUD from its media key handler, so the daemon
asks for it directly over XPC to `com.apple.OSDUIHelper`.

The HUD is not rate limited, so it tracks the knob smoothly even while an external panel is still
stepping toward the value at its slower DDC pace. If the HUD ever stops working it is ignored: the
volume or brightness change still happens.

## Run at login

```bash
./install.sh
```

Installs a LaunchAgent that starts at login and restarts on crash. Logs to `/tmp/deej-mac.log`
(quiet: the status line is only printed to a terminal).

Quit from the menu really does quit. The agent uses `KeepAlive` with `SuccessfulExit` set to false,
so a clean exit is left alone while a crash is still restarted.

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
  `[0: .master, 1: .builtinBrightness, 3: .brightness(0), 2: .brightness(1)]`, meaning slider 0 is
  volume, slider 1 is the built-in display, slider 3 is the leftmost external monitor and slider 2
  is the one to its right. Brightness indices count external displays left to right by their
  position in System Settings. Column 4 is unused. Swap the two monitor indices if yours are the
  other way round.
- `invertSliders`: `true` for boards where sliding down raises the value. Set to `false` if your
  pots are wired the other way.
- `deadzone`: `0.01` (1%, about 10 ADC counts). Raise it if a value drifts while you aren't
  touching the slider, lower it if the steps feel coarse.
- `brightnessInterval`: `0.25` seconds between DDC writes to external monitors. One write takes
  about 77ms and DDC/CI is slow, so a fast sweep drops intermediate positions and applies the final
  one. The built-in display is not affected: it is an in-process call and applies immediately.
- `osdChiclets`: `100`, the HUD bar resolution. Drop it to `16` for the classic segmented look.
- `osdFadeMsec`: how long the HUD stays up.

Turning a brightness knob fully down sets the backlight to 0 and the panel goes black. The knob is
the way back.

## Not included

Per-app volume. That needs a virtual audio device (BlackHole / Background Music) and process-tap
plumbing; this deliberately only does master.
