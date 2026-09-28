# DeJota

A macOS client for an existing [deej](https://github.com/omriharel/deej) Arduino: master volume,
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

`build.sh` produces `.build/DeJota.app`, a real app bundle, so macOS has an icon to show in System
Settings, Activity Monitor and Finder.

**Quit MonitorControl, BetterDisplay or any similar app first.** Two processes writing the same
monitor over I2C will fight over the value.

It prints live slider values so you can see which physical slider is which index.

## Menu bar

A fader icon sits in the menu bar. While the Arduino is connected its knob sits just above the
middle; when it is not, the knob drops to the bottom. The icon is a template image, so it follows
light and dark menu bars automatically.

The app icon, also shown in the About window, is the same fader in colour. Both are drawn in code
from one shape, `Fader` in [main.swift](Sources/deej-mac/main.swift), so they always match.

Clicking it, with either button, opens a menu: About DeJota first, then the current port and the
live value of every knob, one per line, then Reconnect and Quit.

There is no Dock icon and no window. When run from a terminal it also prints live slider values,
so you can see which physical slider is which index.

## On-screen feedback

Turning a knob shows the same HUD macOS shows for its own brightness and volume keys, on the
display that knob controls. macOS only raises that HUD from its media key handler, so the daemon
asks for it directly over XPC to `com.apple.OSDUIHelper`.

The HUD tracks the knob live. Brightness itself only changes once the knob has been still for a
moment, so a turn lands as one clean change when you let go instead of flickering the panel
through every position on the way. Volume follows the knob immediately. If the HUD ever stops
working it is ignored: the volume or brightness change still happens.

## Jumpy knobs

If a knob's HUD jumps around while you turn it, the pot's track is oxidised. The wiper loses
contact for anywhere from 15ms to a few hundred ms and the Arduino reads a stray value, often near
the ends of travel. It builds up on knobs that rarely move, which is why the volume knob stays
clean.

Sweep the knob slowly from end to end a dozen or so times. Recordings of this board showed a dirty
knob reading clean within about 15 seconds of sweeping. A drop of potentiometer contact cleaner
makes it last. The panel is protected meanwhile: brightness only applies once the knob settles, so
a stray reading shorter than `brightnessSettle` never reaches the display.

## Run at login

```bash
./install.sh
```

Installs a LaunchAgent that starts at login and restarts on crash. Logs to `/tmp/dejota.log`
(quiet: the status line is only printed to a terminal). It also removes the agent from before the
rename (`com.user.deej-mac`), so the two never run at once.

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
- `brightnessSettle`: `0.3` seconds. A brightness knob applies only once it has been still this
  long, and every movement restarts the wait. This is also what hides wiper contact bounce, where a
  moving pot briefly reports its neighbour's value for up to about 0.11s, so keep it well above
  that. Lower it if letting go feels laggy, raise it if a slow turn still applies partway. Volume
  is not affected.
- `osdChiclets`: `100`, the HUD bar resolution. Drop it to `16` for the classic segmented look.
- `osdFadeMsec`: how long the HUD stays up.

Turning a brightness knob fully down sets the backlight to 0 and the panel goes black. The knob is
the way back.

## Not included

Per-app volume. That needs a virtual audio device (BlackHole / Background Music) and process-tap
plumbing; this deliberately only does master.
