import Foundation

enum AppLocalizer {
  private static let settingsKey = "ios.settings.v1"

  static func string(_ key: String, languageCode: String? = nil) -> String {
    bundle(languageCode: languageCode).localizedString(forKey: key, value: key, table: "Localizable")
  }

  static func format(_ key: String, languageCode: String? = nil, _ arguments: CVarArg...) -> String {
    let formatString = string(key, languageCode: languageCode)
    let locale = locale(languageCode: languageCode)
    return withVaList(arguments) { pointer in
      NSString(format: formatString as NSString, locale: locale, arguments: pointer) as String
    }
  }

  static func locale(languageCode: String? = nil) -> Locale {
    if let resolvedCode = resolvedLanguageCode(explicitLanguageCode: languageCode) {
      return Locale(identifier: resolvedCode)
    }
    return .autoupdatingCurrent
  }

  private static func bundle(languageCode: String? = nil) -> Bundle {
    guard let resolvedCode = resolvedLanguageCode(explicitLanguageCode: languageCode),
          let bundlePath = Bundle.main.path(forResource: resolvedCode, ofType: "lproj"),
          let localizedBundle = Bundle(path: bundlePath) else {
      return .main
    }

    return localizedBundle
  }

  private static func resolvedLanguageCode(explicitLanguageCode: String?) -> String? {
    if let normalizedExplicit = normalizedLanguageCode(explicitLanguageCode) {
      return normalizedExplicit
    }

    guard let data = UserDefaults.standard.data(forKey: settingsKey),
          let settings = try? JSONDecoder().decode(EmulatorSettings.self, from: data) else {
      return nil
    }

    return normalizedLanguageCode(settings.appLanguage)
  }

  private static func normalizedLanguageCode(_ rawValue: String?) -> String? {
    guard let rawValue else {
      return nil
    }

    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != "system" else {
      return nil
    }

    return trimmed
  }
}
