import Foundation

struct CachedBundle: Codable, Sendable {
  let releaseId: String
  let etag: String?
  let data: [String: JSONValue]
}

final class LocalizationStore: @unchecked Sendable {
  private let config: LinguaFlowConfig
  private let defaults: UserDefaults
  private let directory: URL

  init(config: LinguaFlowConfig, defaults: UserDefaults, directory: URL? = nil) {
    self.config = config
    self.defaults = defaults
    self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LinguaFlow", isDirectory: true)
  }

  var selectedLocale: String? {
    get { defaults.string(forKey: key("selected")) }
    set {
      if let newValue {
        defaults.set(newValue, forKey: key("selected"))
      } else {
        defaults.removeObject(forKey: key("selected"))
      }
    }
  }

  var installationId: String {
    let storageKey = key("installation")
    if let existing = defaults.string(forKey: storageKey) { return existing }
    let created = UUID().uuidString
    defaults.set(created, forKey: storageKey)
    return created
  }

  func manifest() -> LocaleManifest? { read("manifest") }
  func saveManifest(_ manifest: LocaleManifest) throws { try write(manifest, "manifest") }
  func bundle(locale: String) -> CachedBundle? {
    guard let bundle: CachedBundle = read("bundle-\(locale)") else { return nil }
    guard (try? validateTranslationBundle(bundle.data)) != nil else { return nil }
    return bundle
  }
  func saveBundle(_ bundle: CachedBundle, locale: String) throws {
    try write(bundle, "bundle-\(locale)")
  }

  private func write<T: Encodable>(_ value: T, _ suffix: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try JSONEncoder().encode(value).write(to: fileURL(suffix), options: .atomic)
  }

  private func read<T: Decodable>(_ suffix: String) -> T? {
    guard let data = try? Data(contentsOf: fileURL(suffix)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  private func fileURL(_ suffix: String) -> URL {
    directory.appendingPathComponent(key(suffix) + ".json")
  }

  private func key(_ suffix: String) -> String {
    "\(config.branchKey)-\(config.overlay ?? "base")-\(suffix)"
      .replacingOccurrences(of: "/", with: "_")
  }
}
