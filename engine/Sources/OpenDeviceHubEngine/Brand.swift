import Foundation

public enum Brand {
    public static let productName = "stupid simulator"
    public static let commandName = "stupidsim"
    public static let viewerExecutableName = "stupidsim-viewer"
    public static let bundledViewerExecutableName = "StupidSimulator"
    public static let identifierPrefix = "stupidsimulator"

    /// This app's own URL scheme, for links that name a simulator to open.
    public static let urlScheme = "stupidsim"

    /// Distinct from upstream OpenDeviceHub's, so both can be installed side by side. Changing it
    /// after a release makes macOS treat the app as a different one, orphaning every copy already
    /// installed.
    public static let bundleIdentifier = "net.stupidtech.stupidsimulator"

    /// Read from the bundle that is running, which is where the release build writes it. A source
    /// build has no bundle and says so, so a development copy is never mistaken for a release.
    public static let version: String = {
        guard let version = runningBundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            return developmentVersion
        }
        return version
    }()

    public static let developmentVersion = "0.0.0-dev"

    /// The app this executable ships in. Run through a symlink, which is how Install Command Line
    /// Tool puts the CLI on the PATH, `Bundle.main` is the link's own folder and has no Info.plist,
    /// so the bundle is found again from the resolved executable: `<app>/Contents/MacOS/<name>`.
    static let runningBundle: Bundle = {
        if Bundle.main.infoDictionary?["CFBundleShortVersionString"] != nil { return Bundle.main }
        guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return Bundle.main }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard app.pathExtension == "app", let bundle = Bundle(url: app) else { return Bundle.main }
        return bundle
    }()

    public static var isDevelopmentBuild: Bool { version == developmentVersion }

    /// Sparkle compares this, not the marketing version, so it has to increase with every release
    /// or an update stays invisible to everyone.
    public static let buildNumber: String = {
        guard let build = runningBundle.infoDictionary?["CFBundleVersion"] as? String,
              !build.isEmpty else {
            return "0"
        }
        return build
    }()
}
