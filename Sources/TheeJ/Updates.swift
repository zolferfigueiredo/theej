import AppKit

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

/// Replaces the running bundle with the one in the DMG for `version`. The caller relaunches.
/// URLSession downloads carry no quarantine flag, so the new copy opens without the Gatekeeper prompt.
func install(_ version: String) async throws {
    let files = FileManager.default
    let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: Bundle.main.bundleURL, create: true)
    defer { try? files.removeItem(at: work) }

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

    try await run("/usr/bin/codesign", "--verify", "--strict", fresh.path)
    let info = Bundle(url: fresh)?.infoDictionary
    guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
          info?["CFBundleShortVersionString"] as? String == version else {
        throw UpdateError(errorDescription: "The download isn't \(appName) \(version).")
    }
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
            guard isNewer(latest, than: appVersion) else {
                if !quiet { alert("You're up to date!", "\(appName) \(appVersion) is currently the newest version available.", "OK") }
                return
            }
            guard alert("\(appName) \(latest) is available", "You have \(appVersion). Update now?", "Update Now", "Later") else { return }
            do {
                guard Bundle.main.bundlePath.hasPrefix("/Applications/") else {
                    throw UpdateError(errorDescription: "\(appName) updates itself only when it runs from the Applications folder.")
                }
                try await install(latest)
                let relaunch = NSWorkspace.OpenConfiguration()
                relaunch.createsNewApplicationInstance = true
                try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: relaunch)
                NSApp.terminate(nil)
            } catch {
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
