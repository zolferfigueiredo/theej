# Installs the DMG of release v<version>. CI keeps version equal to the app's, so a version bump bumps it too.
# The app updates itself, so brew upgrade leaves it alone, and Gatekeeper checks its notarization.
cask "theej" do
  version "2.6.2"
  sha256 :no_check

  url "https://github.com/zolferfigueiredo/theej/releases/download/v#{version}/TheeJ-#{version}.dmg"
  name "TheeJ"
  desc "Client for deej knob boards: volume, app volume, displays and backlights"
  homepage "https://theej.zolfer.com/"

  auto_updates true
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
