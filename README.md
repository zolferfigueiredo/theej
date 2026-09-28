# TheeJ

A macOS client for an existing [deej](https://github.com/omriharel/deej) Arduino: each knob turns a
volume, a display's brightness or contrast, Night Shift, or a keyboard backlight, with the native
macOS HUD.

Upstream deej is Windows-only for audio (it uses Windows Core Audio for per-app sessions). This is a
small Swift daemon that speaks the same serial protocol and drives the macOS **output and input
volume** through CoreAudio, **external monitors** over DDC/CI, the **built-in display**, **Night
Shift** and the **MacBook keyboard** through private macOS frameworks, and a **VIA keyboard's
backlight** over USB. Arduino firmware is unchanged.

- Reads the deej serial protocol at 9600 baud, however many sliders the sketch sends
- Settings picks what each knob does: a volume, a display, Night Shift or a keyboard backlight
- Calibrate finds which input each knob is wired to and sweeps its pot clean
- Shows the real macOS HUD on the display each knob controls
- Menu bar icon showing connected or disconnected at a glance
- Sets volume in-process via CoreAudio, with no `osascript`
- Follows whichever output and input devices are current, so Bluetooth headphones just work
- Identifies monitors by their CoreGraphics UUID and orders them by on-screen position, so two
  identical panels stay left and right across sleep and replug
- Auto-detects the serial port and reconnects when the board is unplugged

## Build and run

Needs Xcode command line tools (`xcode-select --install`).

External monitor brightness and contrast additionally need
[m1ddc](https://github.com/waydabber/m1ddc), a small standalone binary. Apple Silicon only.
Everything else works without it.

```bash
brew install m1ddc
./build.sh
./run.sh
```

`build.sh` produces `.build/TheeJ.app`, a real app bundle, so macOS has an icon to show in System
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

Clicking it, with either button, opens a menu: About TheeJ, Settings and Calibrate first, then
the current port and the live value of every knob, one per line, then Reconnect and Quit.

There is no Dock icon. When run from a terminal it also prints live slider values, so you can see
which physical slider is which index.

## Settings and calibration

**Settings** lists every knob by the letter on the box with a menu for what it does: nothing, or
one of the jobs under [What a knob can do](#what-a-knob-can-do). Monitors count left to right by
their position in System Settings. The + and - buttons at the top right add or remove the last
knob, down to none at all. A knob that has not been calibrated yet shows "Needs calibration" in red
and does nothing until it is.

Save applies at once and leaves the window open. A knob given a new job takes it over the next time
you move it, so saving never jumps the volume or a panel to wherever that knob happens to sit. With
"Calibrate on save" checked (the default, and remembered), Save also offers to calibrate.
**Calibrate** in the menu runs it any time the board is connected. For each knob, in letter order:

1. Move it from one end to the other, so TheeJ can tell which knob it is.
2. Turn it slowly, back and forth, for 20 seconds.
3. Turn it fast for 20 seconds.
4. Turn it slowly again for 20 seconds.
5. Sweep it from one end to the other, 10 times.

Steps 2 to 5 are the cure for jumpy knobs (below). The timers only run while the knob turns, and a
short sound marks each new step, so you can watch the knob rather than the screen. Allow a minute or
two per knob. Any knob can be skipped: it keeps the input it had, unless the run found that input on
another knob. Every knob holds still for the whole run, Cancel leaves everything as it was, and
Settings comes to the front at the end to choose what each knob does.

A new knob only shows up once the Arduino sketch sends one more value. A knob the sketch does not
send is never found, so skip it.

## What a knob can do

- **Master volume**: the current output device, through CoreAudio.
- **Microphone volume**: the input volume of the current input device, the same slider as in
  System Settings, Sound.
- **Built-in display brightness**: the Retina panel, through DisplayServices.
- **Built-in display contrast**: the Accessibility "Display contrast" setting, normal at the bottom
  of the knob and maximum at the top. External monitors ignore it.
- **Night Shift warmth**: off at the bottom of the knob, then from least to most warm, on every
  screen. It is macOS's own Night Shift, so a schedule still switches it on and off at its set
  times.
- **Monitor brightness** and **Monitor contrast**: each external monitor over DDC/CI, through
  m1ddc.
- **Built-in keyboard backlight**: the MacBook keyboard. macOS still turns it off when the keyboard
  sits idle or the room is bright, and brings it back at the knob's level.
- **External keyboard backlight**: a QMK keyboard with VIA, such as a Keychron K8 Pro, on its USB
  cable (not Bluetooth). No permission is needed. Nothing is saved to the keyboard, so unplugging it
  brings back its own level. The knob sets brightness only: a light switched off on the keyboard
  has to be switched back on there.

The volumes follow the knob as it turns. Everything else waits for the knob to settle, as described
under On-screen feedback.

## On-screen feedback

Turning a knob shows the same HUD macOS shows for its own brightness and volume keys, on the
display that knob controls. macOS only raises that HUD from its media key handler, so the daemon
asks for it directly over XPC to `com.apple.OSDUIHelper`.

The HUD tracks the knob live. Everything but the volumes only changes once the knob has been still
for a moment, so a turn lands as one clean change when you let go instead of flickering the panel
through every position on the way. The volumes follow the knob immediately. macOS has no icon
for a microphone, contrast or Night Shift, so for those TheeJ draws the same square itself, with a
microphone, a half-filled circle and a moon from SF Symbols. If the HUD ever
stops working it is ignored: the change itself still happens.

## Jumpy knobs

If a knob's HUD jumps around while you turn it, the pot's track is oxidised. The wiper loses
contact for anywhere from 15ms to a few hundred ms and the Arduino reads a stray value, often near
the ends of travel. It builds up on knobs that rarely move, which is why the volume knob stays
clean.

Sweep the knob slowly from end to end a dozen or so times. **Calibrate** in the menu walks you
through it, one knob at a time. Recordings of this board showed a dirty
knob reading clean within about 15 seconds of sweeping. A drop of potentiometer contact cleaner
makes it last. The panel is protected meanwhile: everything but the volumes only applies once the
knob settles, so a stray reading shorter than `brightnessSettle` never reaches a display or a light.

## Run at login

```bash
./install.sh
```

Installs a LaunchAgent that starts at login and restarts on crash. Logs to `/tmp/theej.log`
(quiet: the status line is only printed to a terminal). It also removes the agents from before the
renames (`com.user.deej-mac`, `com.zolfer.dejota`), so they never run at once, and carries knobs
saved under `com.zolfer.dejota` over to the new domain.

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

What each knob does and which input it is on live in Settings, not in source. A fresh install has
no knobs: add yours in Settings and calibrate. They are stored as JSON in the `com.zolfer.theej`
defaults domain: `defaults read com.zolfer.theej` shows them, and `defaults delete
com.zolfer.theej` followed by a restart clears them.

Constants at the top of [Sources/deej-mac/main.swift](Sources/deej-mac/main.swift), then rebuild:

- `invertSliders`: `true` for boards where sliding down raises the value. Set to `false` if your
  pots are wired the other way.
- `deadzone`: `0.01` (1%, about 10 ADC counts). Raise it if a value drifts while you aren't
  touching the slider, lower it if the steps feel coarse. It is also how close to an end counts as
  the end, so a knob turned all the way down always reaches 0.
- `brightnessSettle`: `0.3` seconds. Every knob but the volumes applies only once it has been
  still this long, and every movement restarts the wait. This is also what hides wiper contact
  bounce, where a moving pot briefly reports its neighbour's value for up to about 0.11s, so keep it
  well above that. Lower it if letting go feels laggy, raise it if a slow turn still applies
  partway. The volumes are not affected.
- `osdChiclets`: `100`, the HUD bar resolution. Drop it to `16` for the classic segmented look.
- `osdFadeMsec`: how long the HUD stays up.
- `Calibrator.turnSeconds` and `Calibrator.sweepsNeeded`, further down with the calibration code:
  `20` seconds per turning step and `10` sweeps per knob.

Turning a brightness knob fully down sets the backlight to 0 and the panel goes black, and a monitor
contrast knob at 0 leaves it close to black too. The knob is the way back.

## Not included

Per-app volume. That needs a virtual audio device (BlackHole / Background Music) and process-tap
plumbing; this deliberately only does master.
