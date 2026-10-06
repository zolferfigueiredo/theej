<p align="center">
  <img src="Icon/icon.png" width="128" height="128" alt="TheeJ icon">
</p>

<h1 align="center">TheeJ</h1>

<h3 align="center">Real knobs for your Mac.</h3>

<p align="center">
  The Mac client for <a href="https://github.com/omriharel/deej">deej</a>. Volume for your Mac and your apps, brightness and more,<br>
  straight from the Arduino mixer on your desk.
</p>

<p align="center">
  <a href="https://github.com/zolferfigueiredo/theej/releases/latest"><img src="https://img.shields.io/github/v/release/zolferfigueiredo/theej" alt="Latest release"></a>
  <a href="https://www.swift.org"><img src="https://img.shields.io/badge/Swift-6.0-orange" alt="Swift 6.0"></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-blue" alt="macOS 14 or later">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow" alt="MIT license"></a>
  <a href="https://github.com/zolferfigueiredo/theej/actions/workflows/ci.yml"><img src="https://github.com/zolferfigueiredo/theej/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
</p>

<p align="center">
  <a href="https://github.com/zolferfigueiredo/theej/releases/latest"><b>Download for macOS</b></a>
  &nbsp;·&nbsp;
  <a href="https://theej.zolfer.com">Try the mixer in your browser</a>
</p>

<p align="center">On Windows? Get <a href="https://weej.zolfer.com">WeeJ</a>.</p>

<p align="center">
  <img src="docs/screenshots/theej-menu.png" width="447" alt="The TheeJ menu: each knob's job with its level, Settings, Calibrate, the Language list open, and the port">
</p>
<p align="center"><a href="#screenshots"><b>More screenshots</b></a></p>

## Install

1. [Download the DMG](https://github.com/zolferfigueiredo/theej/releases/latest), open it and drag TheeJ to Applications.
2. Open TheeJ. It's signed and notarized by Apple, so macOS only asks you to confirm the first time. It then asks which language to use, starting from your Mac's.
3. Plug in your deej board. Calibrate opens on its own: move each knob from end to end, and Settings opens to choose what each one does.

Or install it with [Homebrew](https://brew.sh/):

```bash
brew tap zolferfigueiredo/theej https://github.com/zolferfigueiredo/theej
brew install --cask theej
```

You need:

- macOS 14 or later, on Apple silicon or Intel
- Any deej board, over USB. Your Arduino sketch stays as it is.
- For external screens: Apple silicon and [m1ddc](https://github.com/waydabber/m1ddc) (`brew install m1ddc`)
- For one app's volume: macOS 14.2 or later
- TheeJ in Applications, for launch at login and updates

**Quit MonitorControl, BetterDisplay or any similar app first.** Two apps writing the same screen over I2C fight over the value.

## Features

- **One knob, several jobs.** The volume of your Mac, your mic or a single app, a screen's brightness or contrast, Night Shift, a keyboard backlight, screen zoom. Tick several, of any kind, and they all follow the knob.
- **The real macOS HUD.** It shows up on the display the knob controls, or for screen zoom the one with the pointer, with the app's own icon for an app's volume.
- **Finds your knobs by itself.** Calibrate opens when your board first connects, works out how many knobs you have and which input each is on, then sweeps a jumpy pot clean.
- **Profiles on a shortcut.** Switch every knob's jobs at once, from the menu bar or any app.
- **No jumps.** A knob takes up a new job the next time you move it, so switching profiles never jumps the volume or a screen.
- **Every level at a glance.** The menu lists each job with its level, one per line, each app with its icon.
- **Follows your audio device.** Switch outputs or inputs, Bluetooth headphones included, and the knobs follow.
- **Twin screens stay put.** Identical panels stay left and right across sleep and replug.
- **Any number of knobs.** As many as your sketch sends, from A to Z, then A2, B2 and on. One switch inverts them all for pots wired the other way round.
- **Same firmware.** Speaks the deej serial protocol, unchanged.
- **Few permissions.** Shortcuts need no Accessibility or Input Monitoring access. App volume asks macOS for audio recording access, once.
- **Speaks 12 languages.** Deutsch, English, Español, Français, Italiano, Polski, Português, Русский, Українська, 中文, 日本語 and 한국어. **Language** in the menu and at the top of App settings changes it at once, open windows included.
- **Lives in the menu bar.** Out of the Dock and Cmd+Tab unless Settings is open or you keep it in the Dock. Reconnects on its own, can launch at login, and installs updates in one click.

## Screenshots

<p align="center">
  <img src="docs/screenshots/theej-hud-volume.png" width="200" alt="The macOS volume indicator, raised by a knob">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/screenshots/theej-hud-microphone.png" width="200" alt="TheeJ's microphone indicator">
  &nbsp;&nbsp;&nbsp;
  <img src="docs/screenshots/theej-hud-app.png" width="200" alt="An app's volume, with the app's own icon">
</p>
<p align="center"><sub>The indicator on the display a knob controls: the volume, the microphone, and one app's volume with its icon</sub></p>

<p align="center">
  <img src="docs/screenshots/theej-settings-general.png" width="460" alt="Settings, General: a profile's knobs, some doing several jobs, apps with their icons">
</p>
<p align="center"><sub>Settings, General: what each knob does. One knob can do several jobs, an app's volume with its icon</sub></p>

<p align="center">
  <img src="docs/screenshots/theej-settings-language.png" width="460" alt="Settings, App settings: the language, shortcuts, menu bar and sensitivity, with the language list open">
</p>
<p align="center"><sub>Settings, App settings: the language, shortcuts, menu bar and sensitivity</sub></p>

<p align="center">
  <img src="docs/screenshots/theej-calibration.png" width="400" alt="Calibration, knob A found: turn it back and forth for 20 seconds">
</p>
<p align="center"><sub>Calibration finds each knob, then sweeps it clean</sub></p>

## What a knob can do

- **Master volume**: the current output device, through CoreAudio.
- **Microphone volume**: the input volume of the current input device, the same slider as in
  System Settings, Sound.
- **An app's volume** (macOS 14.2 or later): an app picked under Apps, from silent at the bottom of
  the knob to the app's own level at the top. macOS has no volume per app, so TheeJ captures the
  app's sound with a Core Audio process tap and plays it back at the knob's level, about a hundredth
  of a second later. That has three consequences. macOS must allow TheeJ under Screen & System Audio
  Recording, which Apply asks for the first time, and a TheeJ started before the answer needs
  reopening. macOS shows its recording indicator while a turned-down app plays. And a sound can lose
  its first tenth of a second. At the top of the knob there is no capture at all. The app is back to
  its own level when TheeJ quits, or when no profile gives it a knob. It needs a TheeJ signed with a
  certificate, as the release is: macOS gives an ad hoc build silence without asking.
- **Built-in display brightness**: the Retina panel, through DisplayServices.
- **Built-in display contrast**: the Accessibility "Display contrast" setting, normal at the bottom
  of the knob and maximum at the top. External screens ignore it.
- **Night Shift warmth**: off at the bottom of the knob, then from least to most warm, on every
  screen. It is macOS's own Night Shift, so a schedule still switches it on and off at its set
  times.
- **Screen brightness** and **Screen contrast**: each external screen over DDC/CI, through
  m1ddc.
- **Built-in keyboard backlight**: the MacBook keyboard. macOS still turns it off when the keyboard
  sits idle or the room is bright, and brings it back at the knob's level.
- **External keyboard backlight**: a QMK keyboard with VIA, such as a Keychron K8 Pro, on its USB
  cable (not Bluetooth). No permission is needed. Nothing is saved to the keyboard, so unplugging it
  brings back its own level. The knob sets brightness only: a light switched off on the keyboard
  has to be switched back on there.
- **Screen zoom**: 1x at the bottom of the knob, up to 10x at the top, with the pointer kept in the
  middle of the view as it moves. No permission is needed. TheeJ sets the zoom in WindowServer, as
  Accessibility Zoom does, and follows the pointer itself, because Zoom can't be set to a level from
  outside. Several displays zoom as one picture. Quitting TheeJ zooms back out. Use it or
  Accessibility Zoom, not both at once.

The volumes follow the knob as it turns. Everything else waits for the knob to settle, as described
under On-screen feedback.

## How it works

Upstream deej is Windows-only for audio (it uses Windows Core Audio for per-app sessions). TheeJ is a
small Swift app that speaks the same serial protocol and drives macOS instead.

- It reads the deej serial protocol at 9600 baud, however many sliders the sketch sends. It finds the
  serial port by itself and reconnects when the board is unplugged.
- The **output and input volume** go through CoreAudio, in-process, with no `osascript`, and follow
  whichever devices are current.
- **Each app's volume** goes through Core Audio process taps (macOS 14.2).
- **External screens** go over DDC/CI through m1ddc. Screens are identified by their CoreGraphics
  UUID and ordered by on-screen position, so two identical panels stay left and right.
- The **built-in display**, **Night Shift**, the **MacBook keyboard** and **screen zoom** go through
  private macOS frameworks, so a future macOS update could break them. A **VIA keyboard's backlight** goes over USB.
- The HUD is macOS's own, asked for over XPC to `com.apple.OSDUIHelper`.
- **Check for updates…** asks GitHub for the newest release and sends nothing about you, and an update downloads from that release.
  An update installs only if it's signed by the same developer, and only into the copy in
  Applications. While it installs, a window shows each step under a loading bar; **Reopen** then
  starts the new version. When an automatic check finds a new version, a notification says so once;
  clicking it offers Update Now.
- Only one copy runs at a time. Opening TheeJ again while it runs, from Finder, Spotlight or `open`,
  brings up Settings, which is the way back with the menu bar icon hidden.

<details>
<summary><b>The menu bar</b></summary>

An icon in the menu bar shows whether the Arduino is connected. Settings offers three looks:

- **Mixer**, the default: the app icon's three faders cut out of a tile. Disconnected, all three
  knobs drop to the bottom.
- **Dial**: a knob in a track, lit up to its pointer. Disconnected, the pointer drops to the minimum
  and the track dims.
- **App icon**: the app icon itself, the same whether connected or not.

Mixer and Dial follow light and dark menu bars, and on the menu bars of the displays you are not
using they stay as bright as macOS's own icons. Both icons are drawn in code in
[Icons.swift](Sources/TheeJ/Icons.swift), the menu bar one by `makeIcon` and the app icon by
`makeAppIcon`.

Clicking it opens Settings. Right-clicking it, or Control-clicking, opens a menu: Show data below first, on by default, with the live
value of every knob's jobs under it, one job per line in knob order, an app's with its icon, then
the profiles, with a check by the active one and each one's shortcut, then Settings, Calibrate and
Language, then the current port with Reconnect under it, then Launch at login and Keep in Dock,
About TheeJ, which opens the About tab of Settings, Check for updates… with Check automatically
(daily, weekly by default, or never), and Quit TheeJ. Settings can leave the profiles out.

Settings can show the active profile's name beside the icon, or hide the icon altogether. **Keep in
Dock** pins a shortcut to TheeJ in the Dock, as the Dock's own Keep in Dock does; clicking it opens
Settings.

</details>

<details>
<summary><b>Settings and calibration</b></summary>

**Settings** has three tabs, laid out in groups as System Settings is: **General** for the profile
and its knobs, **App settings** for the language, shortcuts, the menu bar and sensitivity, and
**About**. A tab too tall for the screen scrolls. General lists every knob by the letter on the box
with a menu for what it does: any of the jobs under [What a knob can do](#what-a-knob-can-do), each
with the icon its HUD shows. Clicking a job ticks it and clicking it again unticks it, so one knob can do several at once, of any kind: two screens' brightness, or an app's volume and a
keyboard backlight. They all take the knob's position, and the row lists them one under the other,
each with its icon. Clear, at the top of the menu, unticks them all. Each job sits under the header of its section: Volume, Brightness, Contrast,
Night Shift, Keyboard backlight, Zoom or Apps. Apps lists the apps that make sound: the ones playing right
now, the well-known players, browsers and call apps you have installed, open or not, and any app
already on a knob. Other… at its end picks any app from Applications. Brightness and Contrast list one Screen per
external screen plugged in, counted left to right by their position in System Settings, plus any a
knob already uses while it is unplugged. The + and - buttons beside Knobs add or remove the last
knob, down to none at all, and after Z come A2, B2 and on. To reorder, drag a knob by the six dots
before its name onto another knob: its jobs move there and the knobs in between shift along, while
the letters stay where they are, since they stand for the knobs on the box. A knob that has not been calibrated yet shows "Needs calibration" in red under
its name, and does nothing until it is.

Those jobs belong to a **profile**: a name, the jobs of every knob, and an optional keyboard
shortcut. The menu at the top picks the profile you are editing, + adds one with every knob doing
nothing, and - removes the one shown. Switch profiles from the menu bar, or with a profile's
shortcut from any app, and the new profile's name shows on screen, in a square like the HUD's. In App settings, under **Shortcuts**, **Next profile** and **Previous
profile** step through them in order from any app, wrapping round at either end, and every profile
is listed below them with its own shortcut, so you can set them all in one place. To set a shortcut,
click Record Shortcut and press it; it needs ⌘ or ⌃, can't be one already in use, and Escape
cancels. The ✕ after a shortcut removes it, as does Delete while recording. Shortcuts need no
Accessibility or Input Monitoring permission.

**Invert knobs** flips every knob's direction, for a board whose pots are wired the other way round.
In App settings, under **Menu bar**, **Hide menu bar icon** removes the icon, name and all, and
greys out the rest while it is on. **Show profile name** puts the active profile's name beside the
icon, cut short when it is long, **Icon** picks Mixer, Dial or App icon, and **Profile list**, on by
default, puts the profiles in the menu. Under **Sensitivity**, **Speed** sets how long a knob has to
be still before its change lands: Slow (0.3 seconds, recommended), Medium (0.22), Fast (0.18) or
Super fast (0.15). The volumes are not affected; they always follow the knob.

**About** shows the version, with Check for updates…, and links to the website, to zolfer.com, to WeeJ, TheeJ for Windows, and to deej.

**Apply**, at the bottom of every tab with Close, applies at once, makes the profile shown the active
one, and leaves the window open. It stays off until something changes, and goes off again once
applied. A knob given a new job, by Apply or by switching profiles, takes it over the next time you move it, so
neither ever jumps the volume or a panel to wherever that knob happens to sit. When a knob still
needs calibration, as after +, Apply opens Calibration for just the knobs that need it.

**Calibration** finds your knobs by itself. **Calibrate** in the menu runs it any time the board is
connected, as does the Calibrate button under the knobs in Settings, and asks for knob A, then B,
and so on. It also opens on its own when a knob needs it: the first time the board connects, as on a
fresh install, and on Apply after +. Then it asks only for the knobs that need it and keeps the
others as they are. For each knob it asks for:

1. Move it from one end to the other, so TheeJ can tell which knob it is.
2. Turn it back and forth, from one end to the other, for 20 seconds.

Step 2 is the cure for jumpy knobs (below). Its timer only runs while the knob turns, and when it
stops, the window says so in orange and asks you to keep turning. A short sound marks each new step,
so you can watch the knob rather than the screen. Allow about half a minute per knob. While it waits
for a knob, moving one it already found gets an orange reminder of which knob that is. Skip is there
for any knob TheeJ has found: one it found just now skips its turning, and one that was set up
before keeps its input. While the knob it asks for isn't found, the button is Finish, which ends the
run: the knobs found keep their inputs and the others stay as they were. When TheeJ asks for a knob
you don't have, click Finish. Once every value the sketch sends has a knob, it says so, and Finish
is all that's left. Every knob holds still for the whole run, Cancel leaves everything as it was,
and Settings comes to the front at the end to choose what each knob does. Calibration never removes
a knob; - beside Knobs in Settings does.

A knob only shows up once the Arduino sketch sends its value. A knob the sketch does not send is
never found, so click Finish when TheeJ asks for it.

</details>

<details>
<summary><b>On-screen feedback</b></summary>

Turning a knob shows the same HUD macOS shows for its own brightness and volume keys, on the display
that knob controls. A knob with several jobs shows one HUD per display, its first job's there. macOS
only raises that HUD from its media key handler, so TheeJ asks for it directly over XPC to
`com.apple.OSDUIHelper`.

The HUD tracks the knob live. Everything but the volumes only changes once the knob has been still
for a moment, so a turn lands as one clean change when you let go instead of flickering the panel
through every position on the way. The volumes follow the knob immediately. macOS has no icon
for a microphone, contrast, Night Shift, zoom or an app, so for those TheeJ draws the same square
itself, with a microphone, a half-filled circle, a moon and a magnifying glass from SF Symbols, and
the app's own icon. If the
HUD ever stops working it is ignored: the change itself still happens.

</details>

<details>
<summary><b>Jumpy knobs</b></summary>

If a knob's HUD jumps around while you turn it, the pot's track is oxidised. The wiper loses
contact for anywhere from 15ms to a few hundred ms and the Arduino reads a stray value, often near
the ends of travel. It builds up on knobs that rarely move, which is why the volume knob stays
clean.

Sweep the knob slowly from end to end a dozen or so times. **Calibrate** in the menu walks you
through it, one knob at a time. Recordings of this board showed a dirty knob reading clean within
about 15 seconds of sweeping. A drop of potentiometer contact cleaner makes it last. The panel is
protected meanwhile: everything but the volumes only applies once the knob settles, so a stray
reading shorter than the Speed setting's wait never reaches a display or a light. If a panel flashes
on a faster Speed, go back to Slow.

</details>

## Build from source

Needs Xcode command line tools (`xcode-select --install`). External screens also need m1ddc on
Apple silicon; on Apple silicon, the General tab of Settings shows whether it's installed, and its
Install button runs the command below in Terminal.

```bash
brew install m1ddc
./run.sh
```

`run.sh` quits any running TheeJ, builds with `build.sh` and runs the new build in the terminal,
where it prints live slider values so you can see which physical slider is which index. Its first
run also turns on the repository's git hook, which refuses commits made directly on `main`.
`build.sh` runs the tests (`swift test`), then produces `.build/TheeJ.app`, a universal app for
Apple silicon and Intel, signed with your Apple Development certificate when you have one, so Login
Items shows TheeJ by name and icon. Without one it is signed ad hoc.

```bash
./run.sh /dev/cu.usbserial-1130     # force a specific port (list them with ls /dev/cu.*)
./run.sh -testNotifications YES     # show the update notification, offering the next version
swift test                          # run the tests
```

**Run at login.** The app in Applications turns this on with **Launch at login** in the menu. For a
build run from this folder, `./install.sh` installs a LaunchAgent that starts at login and restarts
on crash, logging to `/tmp/theej.log`; `./install.sh /dev/cu.usbserial-1130` bakes a port into it,
and `./install.sh --uninstall` removes it. Quit from the menu really does quit: the agent uses
`KeepAlive` with `SuccessfulExit` set to false, so a clean exit is left alone while a crash is still
restarted.

**Release.** `./release.sh` builds `dist/TheeJ-<version>.dmg`, taking the version from `appVersion`
in [Version.swift](Sources/TheeJ/Version.swift). The app and the DMG are signed with Developer ID,
notarized and stapled, and the DMG is published as a GitHub release of the current commit, which
must be pushed. Notarization needs a one-time `xcrun notarytool store-credentials bihan` with an App
Store Connect API key, as the top of `release.sh` shows; BeeHan Brightness uses the same profile.
`./release.sh --url` also makes the permanent url.zolfer.com download link.

**CI** builds and tests every pull request on macOS, counting any compiler warning as an error. It also runs shellcheck on the scripts, and fails a pull request that changes the app without
raising `appVersion` in `Sources/TheeJ/Version.swift`.

<details>
<summary><b>Tuning</b></summary>

What each knob does and which input it is on live in Settings, not in source. A fresh install has
no knobs, and calibration finds them. They are stored as JSON in the `com.zolfer.theej`
defaults domain: `defaults read com.zolfer.theej` shows them, and `defaults delete
com.zolfer.theej` followed by a restart clears them. Knobs saved by 1.0.2 or earlier become the
Default profile the first time a newer TheeJ starts, and the old `knobs` key is left as it was.

Constants in [Dispatch.swift](Sources/TheeJ/Dispatch.swift), [Setup.swift](Sources/TheeJ/Setup.swift)
and [HUD.swift](Sources/TheeJ/HUD.swift), then rebuild:

- `deadzone`: `0.01` (1%, about 10 ADC counts). Raise it if a value drifts while you aren't
  touching the slider, lower it if the steps feel coarse. It is also how close to an end counts as
  the end, so a knob turned all the way down always reaches 0.
- `Speed.settle`: `0.3`, `0.22`, `0.18` and `0.15` seconds, the waits behind the Speed setting.
  Every knob but the volumes applies only once it has been still this long, and every movement
  restarts the wait. This is also what hides wiper contact bounce, where a moving pot briefly
  reports its neighbour's value for up to about 0.11s, so keep every one above that. The volumes
  are not affected.
- `osdChiclets`: `100`, the HUD bar resolution. Drop it to `16` for the classic segmented look.
- `osdFadeMsec`: how long the HUD stays up.
- `Calibrator.turnSeconds`, in [Calibrator.swift](Sources/TheeJ/Calibrator.swift): `20` seconds of
  turning per knob.

Turning a brightness knob fully down sets the backlight to 0 and the panel goes black, and a screen
contrast knob at 0 leaves it close to black too. The knob is the way back.

</details>

## Disclaimer

Unofficial. An independent client for the [deej](https://github.com/omriharel/deej) serial
protocol, not affiliated with deej or with Apple, and it contains no deej code. It relies on private
macOS frameworks that a future macOS update may change or remove.

## License

[MIT](LICENSE)

---

<p align="center">
  If TheeJ is useful to you, please consider giving it a ⭐<br>
  It helps other deej builders find it. Thank you!
</p>

<p align="center">
  Made with ❤️ for the deej community by <a href="https://zolfer.com">zolfer.com</a>
</p>
