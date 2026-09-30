import AppKit
import UserNotifications

// Launch argument `-updateSite http://localhost:8022/` tests against the website's run.sh.
let site = URL(string: prefs.string(forKey: "updateSite") ?? "https://theej.zolfer.com/")!

/// The site names the DMG after the version, the same rule its deploy.sh uses.
func dmgURL(_ version: String) -> URL { site.appending(path: "\(appName)-\(version).dmg") }

/// The version the site offers, or nil when it can't be reached.
func latestVersion() async -> String? {
    let request = URLRequest(url: site.appending(path: "latest.json"), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["version"] as? String
}

func isNewer(_ remote: String, than local: String) -> Bool {
    remote.compare(local, options: .numeric) == .orderedDescending
}

/// `every` 0 means never.
func updateCheckIsDue(last: Date?, every: TimeInterval, now: Date) -> Bool {
    every > 0 && now.timeIntervalSince(last ?? .distantPast) >= every
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
}

/// Only builds signed by this team install. A valid signature alone would accept anyone's app.
let teamRequirement = #"=anchor apple generic and certificate leaf[subject.OU] = "497V6MCDS8""#

/// Opens this app again once this process has quit. A copy started while this one still runs would
/// find it running, hand over to it and quit, leaving no TheeJ at all.
func relaunchWhenQuit() throws {
    // The PID and the app path go in as $0 and $1, never spliced into the script.
    _ = try Process.run(URL(fileURLWithPath: "/bin/sh"),
                        arguments: ["-c", #"while kill -0 "$0" 2>/dev/null; do sleep 0.2; done; open "$1""#,
                                    "\(getpid())", Bundle.main.bundlePath])
}

/// "Update available!" over "Install version 1.2.1 now", for the menu item that replaces Check for updates.
func updateAvailableTitle(_ version: String) -> NSAttributedString {
    let bold = NSFontManager.shared.convert(NSFont.menuFont(ofSize: 0), toHaveTrait: .boldFontMask)
    let title = NSMutableAttributedString(string: "Update available!\n", attributes: [.font: bold])
    title.append(NSAttributedString(string: "Install version \(version) now",
                                    attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                 .foregroundColor: NSColor.secondaryLabelColor]))
    return title
}

/// The filled download arrow in the accent color, so the item stands out.
func updateAvailableIcon() -> NSImage? {
    NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update available")?
        .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
}

/// The newer version a check found, while this one is still older.
func availableUpdate() -> String? {
    prefs.string(forKey: "availableVersion").flatMap { isNewer($0, than: appVersion) ? $0 : nil }
}

/// While an update installs: what it's doing, a loading bar, and Reopen once the new version is in place.
final class UpdateProgress: NSObject {
    private let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let reopen = NSButton(title: "Reopen", target: nil, action: nil)

    init(_ title: String) {
        super.init()
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        status.textColor = .secondaryLabelColor
        bar.style = .bar
        bar.isIndeterminate = true
        bar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        reopen.target = self
        reopen.action = #selector(relaunch)
        reopen.keyEquivalent = "\r"
        reopen.isEnabled = false  // until the new version is in place
        let buttons = NSStackView()
        buttons.setViews([reopen], in: .trailing)
        let text = NSStackView(views: [heading, status, bar, buttons])
        text.orientation = .vertical
        text.alignment = .leading
        text.setCustomSpacing(16, after: bar)
        buttons.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = row
        window.setContentSize(row.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()
        bar.startAnimation(nil)
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func step(_ text: String) { status.stringValue = text }

    /// The new version is in place: the bar fills and Reopen starts it.
    func done(_ text: String) {
        status.stringValue = text
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = bar.maxValue
        reopen.isEnabled = true
    }

    func close() { window.close() }

    @objc private func relaunch() {
        do {
            try relaunchWhenQuit()
            NSApp.terminate(nil)
        } catch {
            status.stringValue = "Couldn't reopen: \(error.localizedDescription) Quit and open it yourself."
        }
    }
}

/// An automatic check tells about a new version once, as a notification, instead of interrupting with
/// an alert. False when notifications aren't allowed, so the caller falls back to the alert.
func notifyUpdate(_ version: String) async -> Bool {
    if prefs.string(forKey: "notifiedVersion") == version { return true }
    let center = UNUserNotificationCenter.current()
    guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
    let content = UNMutableNotificationContent()
    content.title = "\(appName) \(version) is available"
    content.body = "You have \(appVersion). Click to update."
    content.sound = .default
    guard (try? await center.add(UNNotificationRequest(identifier: "update", content: content, trigger: nil))) != nil else { return false }
    prefs.set(version, forKey: "notifiedVersion")
    return true
}

/// Replaces the running bundle with the one in the DMG for `version`. The caller relaunches.
/// URLSession downloads carry no quarantine flag, so the new copy opens without the Gatekeeper prompt.
func install(_ version: String, step: @MainActor (String) -> Void) async throws {
    let files = FileManager.default
    let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
    defer { try? files.removeItem(at: work) }

    await step("Downloading version \(version)…")
    let (download, response) = try await URLSession.shared.download(from: dmgURL(version))
    let dmg = work.appending(path: "update.dmg")
    try files.moveItem(at: download, to: dmg)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(errorDescription: "The download failed.") }

    let mount = work.appending(path: "mount")
    try files.createDirectory(at: mount, withIntermediateDirectories: true)
    try await run("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
    let fresh = work.appending(path: "\(appName).app")
    do {
        try await run("/usr/bin/ditto", mount.appending(path: "\(appName).app").path, fresh.path)
    } catch {
        try? await run("/usr/bin/hdiutil", "detach", mount.path, "-force")
        throw error
    }
    try? await run("/usr/bin/hdiutil", "detach", mount.path, "-force")

    await step("Checking the signature…")
    do {
        try await run("/usr/bin/codesign", "--verify", "--strict", "-R" + teamRequirement, fresh.path)
    } catch {
        throw UpdateError(errorDescription: "The download isn't signed by Zolfer Figueiredo.")
    }
    let info = Bundle(url: fresh)?.infoDictionary
    guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
          info?["CFBundleShortVersionString"] as? String == version else {
        throw UpdateError(errorDescription: "The download isn't \(appName) \(version).")
    }
    await step("Installing…")
    _ = try files.replaceItemAt(Bundle.main.bundleURL, withItemAt: fresh)
}

private func run(_ tool: String, _ arguments: String...) async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { process in
            if process.terminationStatus == 0 { done.resume() }
            else { done.resume(throwing: UpdateError(errorDescription: "\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus)).")) }
        }
        do { try process.run() } catch { done.resume(throwing: error) }
    }
}

// Everything Settings saves. columns[i] is the serial field knob i (A = 0) arrives on, which
// calibration finds: nil until it has.

extension MenuBar {
    @objc func autoCheck() {
        let every = TimeInterval(prefs.integer(forKey: "updateEvery"))
        guard updateCheckIsDue(last: prefs.object(forKey: "lastUpdateCheck") as? Date, every: every, now: .now) else { return }
        checkForUpdates(quiet: true)
    }

    @objc func checkNow() { checkForUpdates(quiet: false) }

    /// Once, right after a self-update relaunched into this version.
    func showUpdateComplete() {
        guard let version = prefs.string(forKey: "updatedTo") else { return }
        prefs.removeObject(forKey: "updatedTo")
        guard version == appVersion else { return }
        alert("Update complete!", "You're now using \(appName) \(appVersion), the newest version available.", "OK")
    }

    /// Quiet checks only speak up when there is a new version.
    func checkForUpdates(quiet: Bool) {
        guard !checking else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            guard let latest = await latestVersion() else {
                print("update check failed")
                if !quiet { alert("Couldn't check for updates", "Check your connection and try again.") }
                return
            }
            prefs.set(Date.now, forKey: "lastUpdateCheck")
            prefs.set(latest, forKey: "availableVersion")
            guard isNewer(latest, than: appVersion) else {
                if !quiet { alert("You're up to date!", "\(appName) \(appVersion) is currently the newest version available.", "OK") }
                return
            }
            if quiet, await notifyUpdate(latest) { return }
            guard alert("\(appName) \(latest) is available", "You have \(appVersion). Update now?", "Update Now", "Later") else { return }
            let progress = UpdateProgress("Updating \(appName) to \(latest)")
            do {
                guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                    throw UpdateError(errorDescription: "\(appName) updates itself only when it runs from the Applications folder.")
                }
                progress.show()
                try await install(latest) { progress.step($0) }
                prefs.set(latest, forKey: "updatedTo")
                progress.done("Version \(latest) is installed. Reopen \(appName) to start using it.")
            } catch {
                progress.close()
                print("update: \(error.localizedDescription)")
                if alert("Couldn't install the update", error.localizedDescription, "Download", "Cancel") {
                    NSWorkspace.shared.open(dmgURL(latest))
                }
            }
        }
    }

    /// True when the first button was clicked.
    @discardableResult
    func alert(_ title: String, _ text: String, _ buttons: String...) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

extension MenuBar: UNUserNotificationCenterDelegate {
    /// Clicking "… is available" checks again, which offers Update Now.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if response.notification.request.identifier == "update" { DispatchQueue.main.async { self.checkNow() } }
        done()
    }

    /// Shown even while the app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}
