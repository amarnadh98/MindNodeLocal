import Foundation

/// Single source of truth for app identity (SPEC §11.9). Renaming the app
/// stays a one-file change: edit `Config.xcconfig` for bundle identity and
/// these constants for in-code references.
public enum AppIdentity {
    public static let appName = "Arbor"
    public static let documentUTI = "com.arbor.map"
    public static let documentExtension = "arbor"
    public static let urlScheme = "x-arbor"
    public static let themeExtension = "arbortheme"

    public static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        return (short as? String) ?? "0.1.0"
    }
}
