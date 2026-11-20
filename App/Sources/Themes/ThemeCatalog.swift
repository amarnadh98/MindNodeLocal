import Foundation
import MapCore
import MapRender

/// F-STY-5's user-theme store: the twelve built-in themes plus the
/// `.arbortheme` JSON files in `~/Library/Application Support/Arbor/Themes`
/// (SPEC §5.8: themes are saved there, importable and exportable). The
/// catalog is the one resolver for "which `Theme` does this document
/// render in": built-ins win over user files with the same id, and an
/// unknown id falls back to the default theme — a document whose theme
/// file went missing still opens, just dressed in Paper.
///
/// ADR-0024. `.arbortheme` is exactly the `Theme` `Codable` schema
/// (ADR-0009): encoding a `Theme` with sorted keys and pretty printing
/// is the whole file format, so the round-trip test is a `JSONDecoder`
/// away.
@MainActor
final class ThemeCatalog {
    static let shared = ThemeCatalog()

    /// The default-theme UserDefaults key (F-STY-6, Settings ▸ General):
    /// a theme id; unknown ids fall back to Paper at read time.
    static let defaultThemeKey = "DefaultThemeID"

    /// Injectable so hosted tests run against a temp directory.
    let directory: URL

    /// The loaded user themes, in file-name order (stable listing).
    private(set) var userThemes: [Theme] = []

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first ?? FileManager.default.temporaryDirectory
            self.directory = support.appending(path: "Arbor/Themes", directoryHint: .isDirectory)
        }
        reload()
    }

    /// Every theme the app knows: built-ins first (SPEC §5.8 order),
    /// then user themes. The default-theme picker and the theme
    /// editor's start list both render this.
    var themes: [Theme] { BuiltInThemes.all + userThemes }

    /// The theme with `id`: a built-in if one matches, else a user
    /// theme, else the default (Paper).
    func theme(id: String) -> Theme {
        themes.first { $0.id == id } ?? theme(id: BuiltInThemes.defaultID)
    }

    /// The theme a document renders in (F-STY-3): its stored selection,
    /// else the default.
    func theme(for model: MapModel) -> Theme {
        theme(id: model.theme?.id ?? BuiltInThemes.defaultID)
    }

    /// The Settings ▸ General default for new documents (F-STY-6):
    /// persisted per user; read back by `MapDocument` when it builds a
    /// fresh empty model. An id that no longer resolves (a deleted
    /// user theme) falls back to the new-document default (Studio).
    static var defaultThemeID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: defaultThemeKey) ?? ""
            guard !stored.isEmpty else { return BuiltInThemes.newDocumentDefaultID }
            let resolves =
                BuiltInThemes.all.contains(where: { $0.id == stored })
                || shared.userThemes.contains(where: { $0.id == stored })
            if resolves {
                return stored
            }
            return BuiltInThemes.newDocumentDefaultID
        }
        set { UserDefaults.standard.set(newValue, forKey: defaultThemeKey) }
    }

    private static let defaultMigrationKey = "arbor.defaultThemeMigratedToStudio"

    /// Once per user: Studio became the new-document default. A stored
    /// "paper" from before that is the old default, not a choice anyone
    /// made, so clear it (a later deliberate pick sticks).
    static func migrateDefaultThemeToStudio() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: defaultMigrationKey) else { return }
        defaults.set(true, forKey: defaultMigrationKey)
        if defaults.string(forKey: defaultThemeKey) == BuiltInThemes.defaultID {
            defaults.removeObject(forKey: defaultThemeKey)
        }
    }

    /// A development build's pre-M2 default-theme key (commit history:
    /// `DocumentPreferences.defaultTheme`), superseded by
    /// `defaultThemeKey`. Nothing at HEAD reads it; cleared once so
    /// `defaults read` stops describing a "paper" default that no
    /// code path ever chose.
    static let legacyDefaultThemeKey = "arbor.defaultThemeID"

    /// Internal (not private) so the hosted test can reset its own
    /// one-shot flag and prove the migration against a stale domain.
    static let stalePaperClearKey = "arbor.defaultThemeStalePaperCleared"

    /// Once more (ADR-0037): the v1 migration's one-shot FLAG made a
    /// stored "paper" immortal — the value was seen back in the
    /// defaults AFTER the flag was set (a pre-Studio build's picker
    /// writing its resolved default), so every new map since opened in
    /// Paper and `migrateDefaultThemeToStudio` will never run again.
    /// Clear the old default and the dead legacy key one more time;
    /// a deliberate "Paper" pick made afterwards sticks (this never
    /// re-runs).
    static func clearStalePaperDefault() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: stalePaperClearKey) else { return }
        defaults.set(true, forKey: stalePaperClearKey)
        defaults.removeObject(forKey: legacyDefaultThemeKey)
        if defaults.string(forKey: defaultThemeKey) == BuiltInThemes.defaultID {
            defaults.removeObject(forKey: defaultThemeKey)
        }
    }

    // MARK: file I/O

    /// Re-reads the themes directory. Undecodable files are skipped
    /// (a user can hand-edit anything); the list never fails.
    @discardableResult
    func reload() -> [Theme] {
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else {
            userThemes = []
            return []
        }
        var loaded: [Theme] = []
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where file.pathExtension.lowercased() == Self.themeFileExtension {
            if let data = try? Data(contentsOf: file), let theme = try? ThemeCatalog.decode(data) {
                loaded.append(theme)
            }
        }
        userThemes = loaded
        return loaded
    }

    /// "Save": writes `theme` as `<name>.arbortheme` into the themes
    /// directory (creating it), overwriting the theme's own previous
    /// save. Returns the written URL.
    @discardableResult
    func save(_ theme: Theme) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = fileURL(for: theme)
        try ThemeCatalog.encode(theme).write(to: target, options: .atomic)
        reload()
        return target
    }

    /// Deletes a user theme's file (built-ins are refused — they are
    /// app data, and documents may reference them).
    func deleteUserTheme(id: String) throws {
        guard let theme = userThemes.first(where: { $0.id == id }) else { return }
        try FileManager.default.removeItem(at: fileURL(for: theme))
        reload()
    }

    /// "Import…": installs a `.arbortheme` from anywhere into the
    /// themes directory under the theme's own name. Returns the
    /// installed theme.
    @discardableResult
    func install(from url: URL) throws -> Theme {
        let data = try Data(contentsOf: url)
        let theme = try ThemeCatalog.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ThemeCatalog.encode(theme).write(to: fileURL(for: theme), options: .atomic)
        reload()
        return theme
    }

    /// "Export…": writes `theme` to an arbitrary location chosen by a
    /// save panel — the same bytes "Save" writes.
    func export(_ theme: Theme, to url: URL) throws {
        try ThemeCatalog.encode(theme).write(to: url, options: .atomic)
    }

    /// Where `theme` lives in the directory: `<slug>.arbortheme`, with
    /// the id appended when a different theme already occupies the
    /// name (two "Sunset Remix" themes coexist as distinct files).
    func fileURL(for theme: Theme) -> URL {
        let base = Self.sanitizedName(theme.name, fallback: theme.id)
        let candidate = directory.appending(path: "\(base).arbortheme")
        if let existing = try? ThemeCatalog.decode(Data(contentsOf: candidate)), existing.id == theme.id {
            return candidate
        }
        if FileManager.default.fileExists(atPath: candidate.path) {
            return directory.appending(path: "\(base)-\(theme.id).arbortheme")
        }
        return candidate
    }

    // MARK: codec (the .arbortheme contract)

    static let themeFileExtension = "arbortheme"
    static let themeUTI = "com.arbor.theme"

    static func encode(_ theme: Theme) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(theme)
    }

    static func decode(_ data: Data) throws -> Theme {
        try JSONDecoder().decode(Theme.self, from: data)
    }

    /// Filename-safe form of a theme name (TemplateStore's rule):
    /// path separators and colons become "-", control characters
    /// dropped, capped at 80 characters.
    static func sanitizedName(_ raw: String, fallback: String) -> String {
        var name = ""
        for scalar in raw.unicodeScalars {
            guard !CharacterSet.controlCharacters.contains(scalar) else { continue }
            if "/:\\".unicodeScalars.contains(scalar) {
                name.unicodeScalars.append("-")
                continue
            }
            name.unicodeScalars.append(scalar)
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(80))
    }
}
