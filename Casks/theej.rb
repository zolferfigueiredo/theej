# Always the latest GitHub release: release.sh uploads a copy of each DMG as TheeJ.dmg, so this file never
# changes with a version. The app updates itself, and Gatekeeper checks its notarization.
cask "theej" do
  version :latest
  sha256 :no_check

  url "https://github.com/zolferfigueiredo/theej/releases/latest/download/TheeJ.dmg"
  name "TheeJ"
  desc "Client for deej knob boards: volume, app volume, displays and backlights"
  homepage "https://theej.zolfer.com/"

  depends_on macos: :sonoma

  app "TheeJ.app"

  uninstall quit: "com.zolfer.theej"

  zap trash: [
    "~/Library/Caches/com.zolfer.theej",
    "~/Library/HTTPStorages/com.zolfer.theej",
    "~/Library/Preferences/com.zolfer.theej.plist",
  ]

  caveats <<~EOS
    External screens need m1ddc, on Apple silicon:
      brew install m1ddc
    Setting one app's volume needs macOS 14.2 or later.
  EOS
end
