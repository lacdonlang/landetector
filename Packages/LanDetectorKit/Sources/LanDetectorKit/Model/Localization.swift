import Foundation

/// The package's translation of `key`, an English text in Localizable.xcstrings – for text kept in tables, which the
/// compiler cannot extract. Literal text uses `String(localized:bundle: .module)` instead.
func localized(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
