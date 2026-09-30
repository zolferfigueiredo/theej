import Foundation

func isNewer(_ remote: String, than local: String) -> Bool {
    remote.compare(local, options: .numeric) == .orderedDescending
}

/// "1.7.0" gives "1.7.1": the version the test notification offers, so it reads like a real one.
func nextPatch(_ version: String) -> String {
    var parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
    parts[parts.count - 1] += 1
    return parts.map(String.init).joined(separator: ".")
}

/// `every` 0 means never.
func updateCheckIsDue(last: Date?, every: TimeInterval, now: Date) -> Bool {
    every > 0 && now.timeIntervalSince(last ?? .distantPast) >= every
}

#if canImport(AppKit)
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
    let title = NSMutableAttributedString(string: tr("update_available") + "\n", attributes: [.font: bold])
    title.append(NSAttributedString(string: tr("install_now", ["version": version]),
                                    attributes: [.font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                                                 .foregroundColor: NSColor.secondaryLabelColor]))
    return title
}

/// The filled download arrow in the accent color, so the item stands out.
func updateAvailableIcon() -> NSImage? {
    NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: tr("update_available"))?
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
    private let reopen = NSButton(title: tr("reopen"), target: nil, action: nil)
    /// The window outlives the code that started the update, and its Reopen button needs this object
    /// alive: held only by a local variable, it was gone by the time Reopen was clicked.
    private static var open: UpdateProgress?

    /// What the update underway says it is doing, nil when there is none. The window stays up until
    /// Reopen, so an installed update counts too: nothing may start a second install meanwhile.
    static var underway: String? { open?.status.stringValue }

    init(_ title: String) {
        super.init()
        let heading = NSTextField(labelWithString: title)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail  // one line, never wider than the bar
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
        status.widthAnchor.constraint(equalTo: bar.widthAnchor).isActive = true
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown  // fill the 64 pt box whatever size the image says it is
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 16
        row.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        /// The stack only applies its inset on the edge it aligns (the top), so the bottom margin is pinned here.
        row.bottomAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 20).isActive = true
        window.contentView = row
        window.setContentSize(row.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()
        bar.startAnimation(nil)
    }

    func show() {
        Self.open = self
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

    func close() {
        window.close()
        Self.open = nil
    }

    @objc private func relaunch() {
        do {
            try relaunchWhenQuit()
            NSApp.terminate(nil)
        } catch {
            status.stringValue = tr("reopen_failed", ["error": error.localizedDescription])
        }
    }
}

/// An automatic check tells about a new version once, as a notification, instead of interrupting with
/// an alert. False when notifications aren't allowed, so the caller falls back to the alert.
func notifyUpdate(_ version: String) async -> Bool {
    if prefs.string(forKey: "notifiedVersion") == version { return true }
    guard await showUpdateNotification(version) else { return false }
    prefs.set(version, forKey: "notifiedVersion")
    return true
}

/// "… is available", every time. Launch argument `-testNotifications YES` shows it without an update.
func showUpdateNotification(_ version: String) async -> Bool {
    let center = UNUserNotificationCenter.current()
    guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
    let content = UNMutableNotificationContent()
    content.title = tr("available", ["version": version])
    content.body = tr("click_to_update", ["version": appVersion])
    content.sound = .default
    return (try? await center.add(UNNotificationRequest(identifier: "update", content: content, trigger: nil))) != nil
}

/// Replaces the running bundle with the one in the DMG for `version`. The caller relaunches.
/// URLSession downloads carry no quarantine flag, so the new copy opens without the Gatekeeper prompt.
func install(_ version: String, step: @MainActor (String) -> Void) async throws {
    let files = FileManager.default
    let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
    defer { try? files.removeItem(at: work) }

    await step(tr("downloading", ["version": version]))
    let (download, response) = try await URLSession.shared.download(from: dmgURL(version))
    let dmg = work.appending(path: "update.dmg")
    try files.moveItem(at: download, to: dmg)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError(errorDescription: tr("download_failed")) }

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

    await step(tr("checking_signature"))
    do {
        try await run("/usr/bin/codesign", "--verify", "--strict", "-R" + teamRequirement, fresh.path)
    } catch {
        throw UpdateError(errorDescription: tr("not_signed"))
    }
    let info = Bundle(url: fresh)?.infoDictionary
    guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
          info?["CFBundleShortVersionString"] as? String == version else {
        throw UpdateError(errorDescription: tr("wrong_download", ["version": version]))
    }
    await step(tr("installing"))
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
            else { done.resume(throwing: UpdateError(errorDescription: tr("tool_failed", ["tool": (tool as NSString).lastPathComponent, "code": process.terminationStatus]))) }
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
        alert(tr("update_complete"), tr("now_using", ["version": appVersion]), tr("ok"))
    }

    /// Quiet checks only speak up when there is a new version.
    func checkForUpdates(quiet: Bool) {
        guard !checking, UpdateProgress.underway == nil else { return }
        checking = true
        Task { @MainActor in
            defer { checking = false }
            guard let latest = await latestVersion() else {
                print("update check failed")
                if !quiet { alert(tr("check_failed"), tr("check_connection"), tr("ok")) }
                return
            }
            prefs.set(Date.now, forKey: "lastUpdateCheck")
            prefs.set(latest, forKey: "availableVersion")
            guard isNewer(latest, than: appVersion) else {
                if !quiet { alert(tr("up_to_date"), tr("newest", ["version": appVersion]), tr("ok")) }
                return
            }
            if quiet, await notifyUpdate(latest) { return }
            guard alert(tr("available", ["version": latest]), tr("update_question", ["version": appVersion]), tr("update_now"), tr("later")) else { return }
            let progress = UpdateProgress(tr("updating_to", ["version": latest]))
            do {
                guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                    throw UpdateError(errorDescription: tr("applications_only"))
                }
                progress.show()
                try await install(latest) { progress.step($0) }
                prefs.set(latest, forKey: "updatedTo")
                progress.done(tr("installed", ["version": latest]))
            } catch {
                progress.close()
                print("update: \(error.localizedDescription)")
                if alert(tr("update_failed"), error.localizedDescription, tr("download"), tr("cancel")) {
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
#endif
