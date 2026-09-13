import Foundation

enum LocaleResolver {
  static func resolveOffline(_ manifest: LocaleManifest, input: String) -> String {
    let normalized = input.replacingOccurrences(of: "_", with: "-").lowercased()
    let language = normalized.split(separator: "-").first.map(String.init) ?? normalized
    if let mapped = manifest.localeMappings[normalized] ?? manifest.localeMappings[language] {
      return mapped
    }
    return manifest.translatedLocales.first(where: {
      let candidate = $0.lowercased()
      return candidate == normalized
        || candidate.split(separator: "-").first.map(String.init) == language
    }) ?? manifest.fallbackLocale
  }
}
