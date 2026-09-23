# deej-mac

Master-volume-only macOS client for an existing [deej](https://github.com/omriharel/deej) Arduino.

Upstream deej is Windows-only for audio (it uses Windows Core Audio for per-app sessions). This is a
small Swift daemon that speaks the same serial protocol but drives only the macOS **master output
volume** through CoreAudio. Arduino firmware is unchanged.

- Reads the deej serial protocol at 9600 baud, 5 sliders
- One slider (default index 0) controls system output volume
- Menu bar icon showing connected or disconnected at a glance
- Sets volume in-process via CoreAudio, with no `osascript` and no subprocesses
- Follows whichever output device is current, so Bluetooth headphones just work
- Auto-detects the serial port and reconnects when the board is unplugged
- No Homebrew, no Go, no Background Music, no virtual audio device

## Build and run

Needs Xcode command line tools (`xcode-select --install`).

```bash
./build.sh
./run.sh
```

It prints live slider values so you can see which physical slider is which index.

## Menu bar

A faders icon sits in the menu bar. When the Arduino is not connected it gains a heavy diagonal
slash. The icon is a template image, so it follows light and dark menu bars automatically.

| Action | Result |
|---|---|
| Left click | Reconnect to the device now |
| Right click | Menu with the current port and volume, Reconnect, and Quit |

There is no Dock icon and no window. When run from a terminal it also prints live slider values,
so you can see which physical slider is which index.

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

Both are optional and order doesn't matter:

```bash
./run.sh 2                      # use slider index 2 instead of 0
./run.sh /dev/cu.usbserial-1130 # force a specific port
./install.sh 2                  # bake the slider index into the LaunchAgent
```

List available ports with `ls /dev/cu.*`.

## Tuning

Two constants at the top of [Sources/deej-mac/main.swift](Sources/deej-mac/main.swift), then rebuild:

- `invertSliders`: `true` for boards where sliding down raises the volume. Set to `false` if your
  pots are wired the other way.
- `deadzone`: `0.01` (1%, about 10 ADC counts). Raise it if the volume drifts while you aren't
  touching the slider, lower it if the steps feel coarse.

## Not included

Per-app volume. That needs a virtual audio device (BlackHole / Background Music) and process-tap
plumbing; this deliberately only does master.
