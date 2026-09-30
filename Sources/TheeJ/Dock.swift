import Foundation

// Keep in Dock pins this copy of the app like the Dock's own menu does. There is no API for it, so this
// edits the Dock's list of pinned apps and restarts the Dock, which reads the list as it starts.
let dockPrefs = UserDefaults(suiteName: "com.apple.dock")!

func isThisApp(_ tile: Any) -> Bool {
    let data = (tile as? [String: Any])?["tile-data"] as? [String: Any]
    let url = (data?["file-data"] as? [String: Any])?["_CFURLString"] as? String
    return url.flatMap(URL.init(string:))?.resolvingSymlinksInPath().path == Bundle.main.bundleURL.resolvingSymlinksInPath().path
}

func inDock() -> Bool { (dockPrefs.array(forKey: "persistent-apps") ?? []).contains(where: isThisApp) }

func toggleDockTile() {
    var tiles = dockPrefs.array(forKey: "persistent-apps") ?? []
    if tiles.contains(where: isThisApp) {
        tiles.removeAll(where: isThisApp)
    } else {
        tiles.append(["GUID": Int.random(in: 1..<Int(Int32.max)), "tile-type": "file-tile",
                      "tile-data": ["file-data": ["_CFURLString": Bundle.main.bundleURL.absoluteString, "_CFURLStringType": 15],
                                    "file-label": Bundle.main.bundleURL.deletingPathExtension().lastPathComponent,
                                    "file-type": 41]])
    }
    dockPrefs.set(tiles, forKey: "persistent-apps")
    dockPrefs.synchronize()  // written through before the Dock restarts and reads it
    _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/killall"), arguments: ["Dock"])
}
