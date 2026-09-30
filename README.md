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
- Profiles switch every knob's job at once, from the menu bar or a global keyboard shortcut
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
[m1ddc](https://github.com/waydabber/m1ddc), a small standalone binary. Apple Silicon only, so on
an Intel Mac external monitors are not available. Everything else works without it.

```bash
brew install m1ddc
./run.sh
```

`run.sh` quits any running TheeJ, builds with `build.sh` and runs the new build in the terminal. Its first run also
turns on the repository's git hook, which refuses commits made directly on `main`.
`build.sh` runs the tests (`swift test`), then produces `.build/TheeJ.app`, a real app bundle, so macOS has an icon to show in System
Settings, Activity Monitor and Finder. It is a universal app for Apple Silicon and Intel, macOS 14
or later, and signed with your Apple Development certificate when you have one, so Login Items
shows TheeJ by name and icon rather than as an unidentified developer. Without one it is signed ad
hoc.

**Quit MonitorControl, BetterDisplay or any similar app first.** Two processes writing the same
monitor over I2C will fight over the value.

It prints live slider values so you can see which physical slider is which index.

## Menu bar

An icon in the menu bar shows whether the Arduino is connected. Settings offers three looks:

- **Mixer**, the default: the app icon's three faders cut out of a tile. Disconnected, all three
  knobs drop to the bottom.
- **Dial**: a knob in a track, lit up to its pointer. Disconnected, the pointer drops to the minimum
  and the track dims.
- **App icon**: the app icon itself, the same whether connected or not.

Mixer and Dial are template images, so they follow light and dark menu bars automatically.

The app icon, also shown in the About window, is the mixer from
[theej.zolfer.com](https://theej.zolfer.com/): three faders and an orange LED on a cream plate. Both
icons are drawn in code in [Icons.swift](Sources/TheeJ/Icons.swift), the menu bar one by `makeIcon`
and the app icon by `makeAppIcon`.

Clicking it, with either button, opens a menu: the profiles first, with a check by the active one
and each one's shortcut, then Settings and Calibrate, then the current port with Reconnect under
it, then the live value of every knob, one per line, then Launch at login and Keep in
Dock, About TheeJ, Check for updates… with Check automatically (daily, weekly by default, or never),
and Quit TheeJ.

**Check for updates…** asks theej.zolfer.com for `latest.json`, a plain download that sends nothing
about you. When there is a newer version, **Update Now** downloads it, replaces the copy in
Applications and relaunches.

Settings can show the active profile's name beside the icon, or hide the icon altogether. Opening
TheeJ again while it runs, from Finder, Spotlight or `open`, brings up Settings, which is the way
back with the icon hidden. A second copy started directly asks the running one to show Settings and
quits, so two copies never share the serial port. `./run.sh` quits the running one first instead.

TheeJ lives in the menu bar and stays out of the Dock and Cmd+Tab, except while Settings is open. **Keep in Dock** pins a shortcut to it in the Dock, as the Dock's own Keep in Dock does; clicking it opens Settings. When run from a terminal it also prints live slider values, so you can see
which physical slider is which index.

## Settings and calibration

**Settings** lists every knob by the letter on the box with a menu for what it does: nothing, or
one of the jobs under [What a knob can do](#what-a-knob-can-do), grouped as volumes, brightness,
contrast, Night Shift and keyboard backlights. Monitors count left to right by their position in
System Settings. The + and - buttons beside Knobs add or remove the last knob, down to none at all.
A knob that has not been calibrated yet shows "Needs calibration" in red and does nothing until it
is.

Those jobs belong to a **profile**: a name, a job for every knob, and an optional keyboard shortcut.
The menu at the top picks the profile you are editing, + adds one with every knob doing nothing,
and - removes the one shown. Switch profiles from the menu bar, or with a profile's shortcut from
any app. To set one, click Record Shortcut and press it; it needs ⌘ or ⌃, and Escape cancels. The
ⓧ beside a shortcut removes it, as does Delete while recording. Shortcuts need no Accessibility or
Input Monitoring permission.

**Invert knobs** flips every knob's direction, for a board whose pots are wired the other way round.
**Hide menu bar icon** removes the icon, name and all, and greys out the name option and the icon
picker while it is on. **Show profile name in menu bar** puts the active profile's name beside the
icon. **Menu bar icon** picks Mixer, Dial or App icon.

Save applies at once, makes the profile shown the active one, and leaves the window open. A knob
given a new job, by Save or by switching profiles, takes it over the next time you move it, so
neither ever jumps the volume or a panel to wherever that knob happens to sit. With "Calibrate on
save" checked (the default, and remembered), Save also offers to calibrate.
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

The app in Applications turns this on with **Launch at login** in the menu. For a build run from
this folder, use the LaunchAgent instead:

```bash
./install.sh
```

Installs a LaunchAgent that starts at login and restarts on crash. Logs to `/tmp/theej.log`
(quiet: the status line is only printed to a terminal), and shows in Login Items as TheeJ.

Quit from the menu really does quit. The agent uses `KeepAlive` with `SuccessfulExit` set to false,
so a clean exit is left alone while a crash is still restarted.

```bash
./install.sh --uninstall
```

## Release

```bash
./release.sh
```

Builds `dist/TheeJ-<version>.dmg`, taking the version from `appVersion` in
[Version.swift](Sources/TheeJ/Version.swift). The app and the DMG are signed with Developer ID,
notarized and stapled, and the DMG opens on a dark window with an arrow from TheeJ to Applications.
Notarization needs a one-time `xcrun notarytool store-credentials bihan` with an App Store Connect
API key, as the top of `release.sh` shows. BiHan Brightness uses the same profile.
`./release.sh --url` also makes the permanent url.zolfer.com download link.

## Options

```bash
./run.sh /dev/cu.usbserial-1130     # force a specific port
./install.sh /dev/cu.usbserial-1130 # bake the port into the LaunchAgent
swift test                          # run the tests
```

List available ports with `ls /dev/cu.*`.

## Tuning

What each knob does and which input it is on live in Settings, not in source. A fresh install has
no knobs: add yours in Settings and calibrate. They are stored as JSON in the `com.zolfer.theej`
defaults domain: `defaults read com.zolfer.theej` shows them, and `defaults delete
com.zolfer.theej` followed by a restart clears them. Knobs saved by 1.0.2 or earlier become the
Default profile the first time a newer TheeJ starts, and the old `knobs` key is left as it was.

Constants in [Dispatch.swift](Sources/TheeJ/Dispatch.swift) and [HUD.swift](Sources/TheeJ/HUD.swift), then rebuild:

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

## License

MIT, see [LICENSE](LICENSE). TheeJ is an independent client for the
[deej](https://github.com/omriharel/deej) serial protocol and contains no deej code.
