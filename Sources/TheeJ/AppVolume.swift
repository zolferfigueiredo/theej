import AppKit
import CoreAudio

// A knob sets one app's volume by capturing the app's audio with a Core Audio process tap (macOS 14.2)
// and playing it back at the knob's level. The tap mutes the app's own output, so everything it plays
// comes through here. macOS shows its recording indicator while a tap is read, so a tap is read only
// while its app plays, and at full volume there is no tap at all. Taps die with TheeJ, which unmutes.

// Everything here runs on this queue, never on the serial thread: making a tap takes a while.
let appQueue = DispatchQueue(label: "theej.apps")

// ponytail: the knob's position cubed, which is close to how loudness is heard: half way is about
// -18 dB. Square it instead if the bottom of the knob feels too quiet.
func appGain(_ scalar: Float32) -> Float32 { scalar * scalar * scalar }

// MARK: Permission

// With no permission macOS reports no error and asks nothing: the tap just reads silence, and the app,
// being muted, goes quiet. These private TCC calls are the only way to know first and to make it ask.
private let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
private let audioCapture = "kTCCServiceAudioCapture" as CFString

func audioCaptureAllowed() -> Bool {
    typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    guard let symbol = tcc.flatMap({ dlsym($0, "TCCAccessPreflight") }) else { return false }
    return unsafeBitCast(symbol, to: Preflight.self)(audioCapture, nil) == 0
}

// Asks the first time, and answers at once after that. Calls back on the main queue.
func requestAudioCapture(_ done: @escaping (Bool) -> Void) {
    typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void
    guard let symbol = tcc.flatMap({ dlsym($0, "TCCAccessRequest") }) else { return done(false) }
    unsafeBitCast(symbol, to: Request.self)(audioCapture, nil) { granted in DispatchQueue.main.async { done(granted) } }
}

// MARK: Audio processes

private let system = AudioObjectID(kAudioObjectSystemObject)

private func read<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var value = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    let value: Unmanaged<CFString>? = read(object, selector, nil) ?? nil
    return value?.takeRetainedValue() as String?
}

private func readList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr ? list : []
}

// Which app answers for a process: Chrome for its helpers, Safari for its WebKit processes. Private,
// so it may be missing, and then a helper is told by its bundle identifier alone.
private typealias Responsible = @convention(c) (pid_t) -> pid_t
private let responsible = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
    .map { unsafeBitCast($0, to: Responsible.self) }

// FaceTime's calls are played by a system process that no app answers for, as Background Music found.
private let alsoPlays = ["com.apple.FaceTime": ["com.apple.avconferenced"]]

// An audio process is the app's when it is the app, or the app answers for it. With no answer to go
// on, a helper is known by its identifier, as Chrome's is com.google.Chrome.helper.
func belongs(bundle: String, owner: String?, to app: String) -> Bool {
    bundle == app || owner == app || alsoPlays[app]?.contains(bundle) == true
        || (owner == nil && bundle.hasPrefix(app + "."))
}

private var processInfo: [AudioObjectID: (bundle: String, owner: String?)] = [:]

// Looked up once per process: neither changes while it lives.
private func info(_ process: AudioObjectID) -> (bundle: String, owner: String?) {
    if let known = processInfo[process] { return known }
    let pid: pid_t = read(process, kAudioProcessPropertyPID, 0) ?? -1
    let owner = responsible.map { $0(pid) }.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    let found = (readString(process, kAudioProcessPropertyBundleID) ?? "", owner)
    processInfo[process] = found
    return found
}

// MARK: Which apps to offer

// Well-known apps that make sound, offered in Settings while closed if they are installed: players,
// browsers, call and chat apps. Any other app shows up while it plays, or is picked with Other….
let knownAudioApps = [
    "com.apple.Music", "com.spotify.client", "com.apple.podcasts", "com.apple.TV", "com.apple.QuickTimePlayerX",
    "org.videolan.vlc", "com.colliderli.iina", "com.coppertino.Vox", "com.swinsian.Swinsian", "com.tidal.desktop",
    "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "company.thebrowser.Browser", "com.brave.Browser",
    "com.microsoft.edgemac", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.hnc.Discord", "com.tinyspeck.slackmacgap",
    "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop", "com.skype.skype",
    "com.valvesoftware.steam",
]

// The open apps playing sound at this moment. A helper counts as the app that answers for it, and only
// apps with a Dock icon are told: the rest are system services.
func appsPlayingSound() -> Set<String> {
    let playing = appQueue.sync {
        readList(system, kAudioHardwarePropertyProcessObjectList)
            .filter { read($0, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1 }
            .map { info($0).owner ?? info($0).bundle }
    }
    let open = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        .compactMap(\.bundleIdentifier)
    return Set(playing).intersection(open)
}

// MARK: One app's tap

final class AppTap {
    let processes: Set<AudioObjectID>
    let output: AudioDeviceID
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let proc: AudioDeviceIOProcID
    private(set) var running = false
    // [0] is the gain the knob asks for and [1] where the last buffer's ramp ended. Shared with the
    // audio thread with no lock: each is one aligned 32-bit store, which is atomic on arm64 and x86_64.
    private let level: UnsafeMutablePointer<Float32>

    var gain: Float32 {
        get { level[0] }
        set { level[0] = newValue }
    }

    private init(processes: Set<AudioObjectID>, output: AudioDeviceID, tap: AudioObjectID, aggregate: AudioObjectID,
                 proc: AudioDeviceIOProcID, level: UnsafeMutablePointer<Float32>) {
        (self.processes, self.output, self.tap, self.aggregate, self.proc, self.level) = (processes, output, tap, aggregate, proc, level)
    }

    // A private tap on the processes, and a private device that joins it to the output device, so one
    // callback can read the tap and write the output. Nothing is read until run(true).
    static func make(_ processes: Set<AudioObjectID>, gain: Float32) -> AppTap? {
        guard #available(macOS 14.2, *), let output = defaultDevice(input: false),
              let uid = readString(output, kAudioDevicePropertyDeviceUID) else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: Array(processes))
        description.name = "TheeJ"
        description.muteBehavior = .muted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        // Drift compensation crackles on Bluetooth, which is where other tap apps turned it off.
        let transport: UInt32 = read(output, kAudioDevicePropertyTransportType, 0) ?? 0
        let bluetooth = transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        let device: [String: Any] = [
            kAudioAggregateDeviceNameKey: "TheeJ",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: !bluetooth,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate) == noErr else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        let level = UnsafeMutablePointer<Float32>.allocate(capacity: 2)
        level.initialize(repeating: gain, count: 2)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            // The tap is the last input stream: any before it are the output device's own, a headset's mic.
            guard let source = ins.last, let samples = source.mData?.assumingMemoryBound(to: Float32.self) else { return }
            let inChannels = Int(max(1, source.mNumberChannels))
            let frames = Int(source.mDataByteSize) / MemoryLayout<Float32>.size / inChannels
            // Ramped across the buffer: a gain that jumps between buffers clicks.
            let from = level[1], step = frames > 0 ? (level[0] - from) / Float32(frames) : 0
            var channel = 0  // counts across buffers, for a device with one buffer per channel
            for out in UnsafeMutableAudioBufferListPointer(output) {
                let outChannels = Int(max(1, out.mNumberChannels))
                defer { channel += outChannels }
                guard let data = out.mData?.assumingMemoryBound(to: Float32.self) else { continue }
                let count = min(frames, Int(out.mDataByteSize) / MemoryLayout<Float32>.size / outChannels)
                for frame in 0..<count {
                    let gain = from + step * Float32(frame + 1)
                    for c in 0..<outChannels {
                        let sourceChannel = channel + c
                        data[frame * outChannels + c] = sourceChannel < inChannels ? samples[frame * inChannels + sourceChannel] * gain : 0
                    }
                }
            }
            level[1] = from + step * Float32(frames)
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            level.deallocate()
            return nil
        }
        return AppTap(processes: processes, output: output, tap: tap, aggregate: aggregate, proc: proc, level: level)
    }

    // Reading the tap is what plays the app, and what shows the recording indicator.
    func run(_ on: Bool) {
        guard on != running else { return }
        if on {
            level[1] = level[0]  // at the knob's level from the first sample
            running = AudioDeviceStart(aggregate, proc) == noErr
        } else {
            AudioDeviceStop(aggregate, proc)
            running = false
        }
    }

    deinit {
        if running { AudioDeviceStop(aggregate, proc) }
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        level.deallocate()
    }
}

// MARK: Every app with a knob

private var appGains: [String: Float32] = [:]
private var appTaps: [String: AppTap] = [:]
private var lastPlayed: [String: Date] = [:]
private var retryAfter: [String: Date] = [:]
private var appTimer: DispatchSourceTimer?

// From the serial thread, as a knob turns.
func setAppVolume(_ app: String, _ scalar: Float32) {
    appQueue.async {
        appGains[app] = appGain(scalar)
        tendApps()
    }
}

// On Save: an app no profile gives a knob any more goes back to its own volume.
func keepAppVolumes(for apps: Set<String>) {
    appQueue.async {
        appGains = appGains.filter { apps.contains($0.key) }
        tendApps()
    }
}

// Ten times a second while any app is turned down, and at once when a knob turns. An app that is turned
// down and has audio processes gets a tap, which is read only while the app plays.
// ponytail: a sound loses up to this tick's 0.1 s at its start, since playing is noticed by polling (the
// listener for it doesn't fire on macOS 26). Swapping a tap, when the app's processes or the output
// device change, is a cut and not a crossfade. No watchdog for a tap that goes silent on its own.
private func tendApps() {
    let now = Date()
    let turnedDown = appGains.filter { $0.value < 1 }
    if turnedDown.isEmpty {
        appTimer?.cancel()
        appTimer = nil
    } else if appTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: appQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { tendApps() }
        timer.resume()
        appTimer = timer
    }
    let allowed = !turnedDown.isEmpty && audioCaptureAllowed()
    let processes = allowed ? readList(system, kAudioHardwarePropertyProcessObjectList) : []
    processInfo = processInfo.filter { processes.contains($0.key) }
    let output = defaultDevice(input: false)
    for app in Set(appTaps.keys).union(turnedDown.keys) {
        guard allowed, let gain = turnedDown[app], (retryAfter[app] ?? .distantPast) <= now else {
            appTaps[app] = nil
            continue
        }
        let mine = Set(processes.filter { belongs(bundle: info($0).bundle, owner: info($0).owner, to: app) })
        guard !mine.isEmpty else {
            appTaps[app] = nil
            continue
        }
        if mine.contains(where: { read($0, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1 }) { lastPlayed[app] = now }
        if appTaps[app]?.processes != mine || appTaps[app]?.output != output {
            // The new tap is made before the old one goes, so the app is muted throughout and nothing
            // gets out at full volume.
            let fresh = AppTap.make(mine, gain: gain)
            appTaps[app] = fresh
        }
        guard let tap = appTaps[app] else {
            retryAfter[app] = now + 5
            continue
        }
        tap.gain = gain
        // Two seconds past the last sound, so a gap between songs isn't clipped.
        let playing = now.timeIntervalSince(lastPlayed[app] ?? .distantPast) < 2
        tap.run(playing)
        // Never muted and unheard: if reading won't start, let the app play by itself and try again later.
        if playing && !tap.running {
            appTaps[app] = nil
            retryAfter[app] = now + 5
        }
    }
}

// MARK: Names and icons

private let namesLock = NSLock()
private var appNames: [String: String] = [:]

// As the Finder shows it, or the bundle identifier when the app isn't installed. Cached, since the
// serial thread asks on every line for the menu's data.
func appName(_ id: String) -> String {
    namesLock.lock()
    defer { namesLock.unlock() }
    if let name = appNames[id] { return name }
    var name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        .map { FileManager.default.displayName(atPath: $0.path) } ?? id
    if name.hasSuffix(".app") { name.removeLast(4) }
    appNames[id] = name
    return name
}

private var appIcons: [String: NSImage] = [:]  // main thread only

func appIcon(_ id: String) -> NSImage? {
    if let icon = appIcons[id] { return icon }
    let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
    appIcons[id] = icon
    return icon
}
