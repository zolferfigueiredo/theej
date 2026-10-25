#if canImport(AppKit)
import AppKit
import CoreAudio

// A knob sets one app's volume by capturing the app's audio with a Core Audio process tap (macOS 14.2)
// and playing it back at the knob's level. The tap mutes the app's own output, so everything it plays
// comes through here. macOS shows its recording indicator while a tap is read, so a tap is read only
// while its app plays. Taps die with TheeJ, which unmutes.

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
    private(set) var processes: Set<AudioObjectID>  // those left out, for an everyoneBut tap
    let output: AudioDeviceID
    private let tap: AudioObjectID
    private let description: NSObject  // the CATapDescription, changed to change how the tap mutes
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

    private init(processes: Set<AudioObjectID>, output: AudioDeviceID, tap: AudioObjectID, description: NSObject,
                 aggregate: AudioObjectID, proc: AudioDeviceIOProcID, level: UnsafeMutablePointer<Float32>) {
        (self.processes, self.output, self.tap, self.description, self.aggregate, self.proc, self.level) =
            (processes, output, tap, description, aggregate, proc, level)
    }

    // A private tap on the processes, and a private device that joins it to the output device, so one
    // callback can read the tap and write the output. Nothing is read until run(true). Not muted, the app
    // plays by itself until then. everyoneBut taps every process but these, and one that starts later at once.
    static func make(_ processes: Set<AudioObjectID>, everyoneBut: Bool = false, gain: Float32, muted: Bool) -> AppTap? {
        guard #available(macOS 14.2, *), let output = defaultDevice(input: false),
              let uid = readString(output, kAudioDevicePropertyDeviceUID) else { return nil }
        let description = everyoneBut ? CATapDescription(stereoGlobalTapButExcludeProcesses: Array(processes))
            : CATapDescription(stereoMixdownOfProcesses: Array(processes))
        description.name = "TheeJ"
        description.muteBehavior = muted ? .muted : .mutedWhenTapped
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        guard let aggregate = joinTap(description.uuid, to: output, uid: uid) else {
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
        return AppTap(processes: processes, output: output, tap: tap, description: description, aggregate: aggregate,
                      proc: proc, level: level)
    }

    // Reading the tap is what plays the app, and what shows the recording indicator.
    func run(_ on: Bool) {
        guard on != running else { return }
        if on {
            level[1] = level[0]  // at the knob's level from the first sample
            running = AudioDeviceStart(aggregate, proc) == noErr
        } else {
            // Muted while it isn't read, so the app's next sound doesn't start at full volume. Changed once
            // the read has stopped, never while it runs, and the app is quiet now, so it isn't heard.
            AudioDeviceStop(aggregate, proc)
            running = false
            mute(always: true)
        }
    }

    // Muted mutes the app for as long as the tap exists, mutedWhenTapped only while it is read. macOS
    // switches the latter as the read starts or stops, so the app goes between its own output and the
    // tap's with no gap, where making or removing a tap takes long enough to be heard.
    private func mute(always: Bool) {
        guard #available(macOS 14.2, *), let description = description as? CATapDescription else { return }
        let before = description.muteBehavior
        description.muteBehavior = always ? .muted : .mutedWhenTapped
        guard description.muteBehavior != before else { return }
        if !describe(description) { description.muteBehavior = before }
    }

    // Changes who an everyoneBut tap leaves out while it runs, where a new tap would be heard as a cut.
    // False when macOS won't, and then the description no longer matches the tap, which has to be remade.
    func exclude(_ processes: Set<AudioObjectID>) -> Bool {
        guard #available(macOS 14.2, *), let description = description as? CATapDescription else { return false }
        description.processes = Array(processes)
        guard describe(description) else { return false }
        self.processes = processes
        return true
    }

    @available(macOS 14.2, *)
    private func describe(_ description: CATapDescription) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value = Unmanaged.passUnretained(description)
        return AudioObjectSetPropertyData(tap, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value) == noErr
    }

    deinit {
        // The app plays by itself from the moment the read stops, not once the tap is gone.
        mute(always: false)
        if running { AudioDeviceStop(aggregate, proc) }
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
        level.deallocate()
    }
}

// A private device that joins a tap to the output device, so one callback reads the tap on the output's clock.
private func joinTap(_ tap: UUID, to output: AudioDeviceID, uid: String) -> AudioObjectID? {
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
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: !bluetooth, kAudioSubTapUIDKey: tap.uuidString]],
    ]
    var aggregate = AudioObjectID(kAudioObjectUnknown)
    return AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregate) == noErr ? aggregate : nil
}

// MARK: The Mac's sound, for the EQ light patterns

// A tap on every process, unmuted, read while an SMC-Mixer shows an EQ. macOS shows its recording indicator
// meanwhile, and gives silence until TheeJ is allowed to record.
final class SoundTap {
    let output: AudioDeviceID
    private let tap: AudioObjectID
    private let aggregate: AudioObjectID
    private let proc: AudioDeviceIOProcID

    private init(output: AudioDeviceID, tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID) {
        (self.output, self.tap, self.aggregate, self.proc) = (output, tap, aggregate, proc)
    }

    static func make() -> SoundTap? {
        guard #available(macOS 14.2, *), let output = defaultDevice(input: false),
              let uid = readString(output, kAudioDevicePropertyDeviceUID) else { return nil }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "TheeJ EQ"
        description.muteBehavior = .unmuted
        description.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr else { return nil }
        guard let aggregate = joinTap(description.uuid, to: output, uid: uid) else {
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        spectrum.setRate(read(aggregate, kAudioDevicePropertyNominalSampleRate, Float64(48000)) ?? 48000)
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { _, input, _, output, _ in
            // The tap is the last input stream, as in AppTap.
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            if let source = ins.last, let samples = source.mData?.assumingMemoryBound(to: Float32.self) {
                spectrum.add(interleaved: UnsafeBufferPointer(start: samples, count: Int(source.mDataByteSize) / MemoryLayout<Float32>.size),
                             channels: Int(max(1, source.mNumberChannels)))
            }
            // The device plays what is written here, on top of the sound itself, so nothing is.
            for out in UnsafeMutableAudioBufferListPointer(output) {
                if let data = out.mData { memset(data, 0, Int(out.mDataByteSize)) }
            }
        }
        guard status == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        guard AudioDeviceStart(aggregate, proc) == noErr else {
            AudioDeviceDestroyIOProcID(aggregate, proc)
            AudioHardwareDestroyAggregateDevice(aggregate)
            AudioHardwareDestroyProcessTap(tap)
            return nil
        }
        return SoundTap(output: output, tap: tap, aggregate: aggregate, proc: proc)
    }

    deinit {
        AudioDeviceStop(aggregate, proc)
        AudioDeviceDestroyIOProcID(aggregate, proc)
        AudioHardwareDestroyAggregateDevice(aggregate)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(tap) }
    }
}

private var soundTap: SoundTap?  // appQueue only, like everything here
private var following = false
private var watchingOutput = false

// From applyLights. The tap runs on the output device's clock, so a new output device gets a new tap.
func followSound(_ on: Bool) {
    appQueue.async {
        following = on
        if on, !watchingOutput {
            watchingOutput = true
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, appQueue) { _, _ in tendSound() }
        }
        tendSound()
    }
}

private func tendSound() {
    guard following else {
        soundTap = nil
        return
    }
    let output = defaultDevice(input: false)
    if soundTap?.output != output {
        soundTap = nil  // the old one goes first, so two never read at once
        soundTap = SoundTap.make()
    }
}

// MARK: Every app with a knob

// Where Other apps keeps its volume among the apps', since no bundle identifier is empty.
let otherAppsKey = ""

// The frontmost app, unless it is TheeJ, whose sound is every tapped app's played back.
func focusedApp() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return nil }
    return app.bundleIdentifier
}

private var appGains: [String: Float32] = [:]
private var appTaps: [String: AppTap] = [:]
private var lastPlayed: [String: Date] = [:]
private var retryAfter: [String: Date] = [:]
private var appTimer: DispatchSourceTimer?

private var appLevels: [String: Float32] = [:]  // engine queue only, like setAppVolume

// From the engine queue, as a control turns.
func setAppVolume(_ app: String, _ scalar: Float32) {
    appLevels[app] = scalar
    appQueue.async {
        appGains[app] = appGain(scalar)
        tendApps()
    }
}

// Where a control last set the app's volume, or the top when none has. Engine queue only, so it never
// waits for appQueue, which can be busy making a tap.
func appLevel(_ app: String) -> Float32 { appLevels[app] ?? 1 }

// At launch, on Apply and on a profile switch: an app no profile gives a knob any more goes back to its own
// volume, as do the other apps once no profile has Other apps, and the apps Focused app turned once no
// profile has Focused app. An app the profile in use gives a knob is tapped from now, before its knob moves.
func keepAppVolumes(for setup: Setup) {
    let jobs = setup.jobs
    let apps = setup.apps.union(jobs.contains(.otherApps) ? [otherAppsKey] : [])
    let focused = jobs.contains(.focusedApp)
    appQueue.async {
        appGains = appGains.filter { apps.contains($0.key) || focused && $0.key != otherAppsKey }
        tendApps()
    }
}

// The apps a knob of their own is for, in the profiles in use.
private func knobApps() -> Set<String> {
    Set(shared.config().setup.boards.filter(\.enabled).flatMap { $0.profile.jobs.joined() }.compactMap { job -> String? in
        if case .app(let id) = job { return id }
        return nil
    })
}

// The processes of Other apps: those of the apps in the Dock that have no volume of their own, neither a
// knob's nor a job in a profile in use, so no sound is ever tapped twice. Never TheeJ's.
private func otherProcesses(_ processes: [AudioObjectID]) -> Set<AudioObjectID> {
    let own = Set(appGains.keys).subtracting([otherAppsKey]).union(knobApps())
    let docked = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != getpid() }
        .compactMap(\.bundleIdentifier))
    return Set(processes.filter { process in
        let (bundle, owner) = info(process)
        return docked.contains(owner ?? bundle) && !own.contains { belongs(bundle: bundle, owner: owner, to: $0) }
    })
}

// Ten times a second while any app is tapped, and at once when a knob turns. A tapped app that has audio
// processes gets a tap, which is read only while the app plays. The tap's sound comes out a buffer after the
// app's own, so going between the two while the app plays is heard as a cut. So an app with a knob of its own
// is tapped at the top too, from the start, and a knob never cuts it. Focused app and Other apps, which could
// be any app, are tapped once turned down, and back at the top until they go quiet.
// ponytail: a sound loses up to this tick's 0.1 s at its start, since playing is noticed by polling (the
// listener for it doesn't fire on macOS 26). Swapping a tap, when the app's processes or the output
// device change, is a cut and not a crossfade, and so is Focused app's or Other apps' first turn down
// from the top while they play. No watchdog for a tap that goes silent on its own.
private func tendApps() {
    let now = Date()
    var tapped = appGains.filter { $0.value < 1 || appTaps[$0.key]?.running == true }
    for app in knobApps() where tapped[app] == nil { tapped[app] = appGains[app] ?? 1 }
    let output = defaultDevice(input: false)
    let mac = output.map(hasVolume) == false ? macGain : 1
    if tapped.isEmpty && mac == 1 {
        appTimer?.cancel()
        appTimer = nil
    } else if appTimer == nil {
        let timer = DispatchSource.makeTimerSource(queue: appQueue)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { tendApps() }
        timer.resume()
        appTimer = timer
    }
    let allowed = (!tapped.isEmpty || mac < 1) && audioCaptureAllowed()
    let processes = allowed ? readList(system, kAudioHardwarePropertyProcessObjectList) : []
    processInfo = processInfo.filter { processes.contains($0.key) }
    for app in Set(appTaps.keys).union(tapped.keys) {
        guard allowed, let gain = tapped[app], (retryAfter[app] ?? .distantPast) <= now else {
            appTaps[app] = nil
            continue
        }
        let mine = app == otherAppsKey ? otherProcesses(processes)
            : Set(processes.filter { belongs(bundle: info($0).bundle, owner: info($0).owner, to: app) })
        guard !mine.isEmpty else {
            appTaps[app] = nil
            continue
        }
        if mine.contains(where: { read($0, kAudioProcessPropertyIsRunningOutput, UInt32(0)) == 1 }) { lastPlayed[app] = now }
        // Two seconds past the last sound, so a gap between songs isn't clipped.
        let playing = now.timeIntervalSince(lastPlayed[app] ?? .distantPast) < 2
        if appTaps[app]?.processes != mine || appTaps[app]?.output != output {
            // The new tap is made before the old one goes, so the app is muted throughout and nothing
            // gets out at full volume. An app playing by itself, as a knob leaves the top, is muted only
            // once the tap is read, so the time making it takes isn't heard as a gap.
            let fresh = AppTap.make(mine, gain: gain, muted: !playing || appTaps[app] != nil)
            appTaps[app] = fresh
        }
        guard let tap = appTaps[app] else {
            retryAfter[app] = now + 5
            continue
        }
        tap.gain = gain * mac  // its sound isn't in the Mac's tap, so it follows Master volume here
        tap.run(playing)
        // Never muted and unheard: if reading won't start, let the app play by itself and try again later.
        if playing && !tap.running {
            appTaps[app] = nil
            retryAfter[app] = now + 5
        }
    }
    tendMac(mac, output, allowed, now)
}

// MARK: The Mac's volume, on an output with none of its own

// Some USB DACs have no volume macOS can set, so Master volume sets this instead: everything no app tap has
// is tapped at once and played back at it. Muted keeps the level to come back to, as a device's mute does.
private let macLock = NSLock()
private var macLevel: Float32 = 1, macMuted = false  // macLock: set from the engine queue and the main thread
private var macGain: Float32 = 1
private var macTap: AppTap?
private var macRetryAfter = Date.distantPast
private var askedForMac = false

func softVolume() -> Float32 {
    macLock.lock()
    defer { macLock.unlock() }
    return macLevel
}

func softMuted() -> Bool {
    macLock.lock()
    defer { macLock.unlock() }
    return macMuted
}

func setSoftVolume(_ scalar: Float32? = nil, muted: Bool? = nil) {
    macLock.lock()
    macLevel = scalar ?? macLevel
    macMuted = muted ?? macMuted
    let gain = macMuted ? 0 : appGain(macLevel)
    macLock.unlock()
    appQueue.async {
        macGain = gain
        tendApps()
    }
}

// TheeJ's own audio process plays the app taps back, so the Mac's tap leaves it out, or it would hear itself.
private func ownProcess() -> AudioObjectID? {
    var pid = getpid(), process = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process) == noErr,
          process != kAudioObjectUnknown else { return nil }
    return process
}

// After the apps, so it leaves out whatever they tapped. Read for as long as it's turned down, so no sound
// loses its start, and gone at the top, where the output plays by itself.
// ponytail: macOS shows its recording indicator all that time. Reaching the top while sound plays is a cut.
private func tendMac(_ gain: Float32, _ output: AudioDeviceID?, _ allowed: Bool, _ now: Date) {
    if gain < 1, !allowed, !askedForMac {
        askedForMac = true
        requestAudioCapture { _ in }
    }
    guard gain < 1, allowed, macRetryAfter <= now, let own = ownProcess() else {
        macTap = nil
        return
    }
    let mine = Set(appTaps.values.flatMap(\.processes)).union([own])
    if macTap?.output != output || macTap?.processes != mine && macTap?.exclude(mine) != true {
        // As for an app, the new one is made muted while the old one still plays.
        let fresh = AppTap.make(mine, everyoneBut: true, gain: gain, muted: macTap != nil)
        macTap = fresh
    }
    macTap?.gain = gain
    macTap?.run(true)
    if macTap?.running != true {
        macTap = nil
        macRetryAfter = now + 5
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

// An app job's icon at a menu item's size, and nothing for any other job.
func menuIcon(_ target: Target?) -> NSImage? {
    guard case .app(let id)? = target, let icon = appIcon(id)?.copy() as? NSImage else { return nil }
    icon.size = NSSize(width: 16, height: 16)
    return icon
}
#endif
