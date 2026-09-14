import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

public actor LinguaFlowClient {
  public private(set) var manifest: LocaleManifest?
  public private(set) var source: LinguaFlowBundleSource?
  public private(set) var selectedLocale: String?
  public var supportedLocales: [String] { manifest?.supportedLocales ?? [] }
  public var activeLocale: String? { manifest?.requestedLocale }
  public var resolvedLocale: String? { manifest?.resolvedLocale }

  private let config: LinguaFlowConfig
  private let store: LocalizationStore
  private let api: DeliveryAPI
  private let bundleProvider: @Sendable (String) -> Data?
  private let missingKeys: MissingKeyReporter
  private let runtimeMetrics: RuntimeMetricReporter
  private var values: [String: JSONValue] = [:]
  private var lastChecked = Date.distantPast

  public init(
    config: LinguaFlowConfig,
    session: URLSession = .shared,
    defaults: UserDefaults = .standard,
    integrityProvider: (any DeviceIntegrityProvider)? = nil,
    bundleProvider: @escaping @Sendable (String) -> Data? = LinguaFlowClient.mainBundleFile
  ) {
    self.config = config
    let store = LocalizationStore(config: config, defaults: defaults)
    self.store = store
    let api = DeliveryAPI(
      config: config,
      session: session,
      installationId: store.installationId,
      integrityProvider: integrityProvider)
    self.api = api
    self.missingKeys = MissingKeyReporter(config: config, api: api)
    self.runtimeMetrics = RuntimeMetricReporter(
      config: config, api: api, enabled: integrityProvider != nil)
    self.bundleProvider = bundleProvider
    self.selectedLocale = store.selectedLocale
  }

  public func initialize(
    deviceLocale: String = Locale.current.identifier,
    force: Bool = false
  ) async throws {
    if !force, !values.isEmpty, Date().timeIntervalSince(lastChecked) <= config.cacheTTL { return }
    do {
      try await activateRemote(deviceLocale)
    } catch let error as CancellationError {
      throw error
    } catch {
      guard config.offlineEnabled, activateOffline(deviceLocale) else { throw error }
    }
  }

  public func selectLocale(_ locale: String?) async throws {
    let normalized = locale?.trimmingCharacters(in: .whitespacesAndNewlines)
    selectedLocale = normalized?.isEmpty == false ? normalized : nil
    store.selectedLocale = selectedLocale
    try await initialize(force: true)
  }

  public func text(_ key: LfKey, fallback: String = "") throws -> String {
    try render(key.path, arguments: [:], fallback: fallback)
  }

  public func text(_ message: LfMessage, fallback: String = "") throws -> String {
    try render(message.path, arguments: message.arguments, fallback: fallback)
  }

  public func flushMissingKeys() async {
    await missingKeys.flush()
    await runtimeMetrics.flush()
  }

  public func shutdown() async {
    await missingKeys.shutdown()
    await runtimeMetrics.shutdown()
  }

  private func activateRemote(_ deviceLocale: String) async throws {
    let remoteManifest = try await api.manifest(
      locale: selectedLocale ?? deviceLocale,
      explicit: selectedLocale != nil)
    manifest = remoteManifest
    await runtimeMetrics.record(.deliveryRequest, outcome: .success, manifest: remoteManifest)
    lastChecked = Date()
    try store.saveManifest(remoteManifest)
    if selectedLocale != nil, remoteManifest.reason == .fallback {
      selectedLocale = nil
      store.selectedLocale = nil
    }

    let cached = store.bundle(locale: remoteManifest.resolvedLocale)
    if cached?.releaseId == remoteManifest.releaseId {
      activate(cached!.data, source: .downloaded)
      return
    }
    let delivery: BundleDelivery
    do {
      delivery = try await api.bundle(locale: remoteManifest.resolvedLocale, etag: cached?.etag)
      await runtimeMetrics.record(.deliveryRequest, outcome: .success, manifest: remoteManifest)
    } catch {
      await runtimeMetrics.record(
        .deliveryRequest, outcome: metricOutcome(error), manifest: remoteManifest)
      await runtimeMetrics.record(
        error as? LinguaFlowError == .invalidPayload ? .bundleParse : .bundleDownload,
        outcome: .failure, manifest: remoteManifest)
      throw error
    }
    switch delivery {
    case .notModified:
      guard let cached else { throw LinguaFlowError.invalidPayload }
      activate(cached.data, source: .downloaded)
    case .content(let body, let etag):
      await runtimeMetrics.record(.bundleDownload, outcome: .success, manifest: remoteManifest)
      await runtimeMetrics.record(.bundleParse, outcome: .success, manifest: remoteManifest)
      try store.saveBundle(
        CachedBundle(releaseId: remoteManifest.releaseId, etag: etag, data: body),
        locale: remoteManifest.resolvedLocale)
      activate(body, source: .remote)
    }
  }

  private func activateOffline(_ deviceLocale: String) -> Bool {
    if manifest == nil { manifest = store.manifest() }
    guard let manifest else { return false }
    let locale = LocaleResolver.resolveOffline(manifest, input: selectedLocale ?? deviceLocale)
    if let cached = store.bundle(locale: locale) {
      activate(cached.data, source: .downloaded)
      return true
    }
    guard
      let data = bundleProvider("\(config.bundledDirectory)/\(locale).json"),
      let body = try? JSONDecoder().decode([String: JSONValue].self, from: data),
      (try? validateTranslationBundle(body)) != nil
    else { return false }
    activate(body, source: .bundled)
    return true
  }

  private func activate(_ body: [String: JSONValue], source: LinguaFlowBundleSource) {
    values = body
    self.source = source
  }

  private func render(
    _ path: String,
    arguments: [String: LfArgument],
    fallback: String
  ) throws -> String {
    var cursor: JSONValue = .object(values)
    for segment in path.split(separator: ".").map(String.init) {
      guard case .object(let object) = cursor, let next = object[segment] else {
        return try missing(path, fallback)
      }
      cursor = next
    }
    guard case .string(let pattern) = cursor else { return try missing(path, fallback) }
    do {
      let result = try ICUMessageFormatter.format(
        pattern, arguments: arguments, locale: manifest?.resolvedLocale ?? "en")
      Task { await runtimeMetrics.record(.icuFormat, outcome: .success, manifest: manifest) }
      return result
    } catch {
      Task { await runtimeMetrics.record(.icuFormat, outcome: .failure, manifest: manifest) }
      throw error
    }
  }

  private func missing(_ path: String, _ fallback: String) throws -> String {
    let currentManifest = manifest
    Task { await missingKeys.record(path, manifest: currentManifest) }
    return switch config.missingBehavior {
    case .fallback: fallback
    case .key: path
    case .empty: ""
    case .throw: throw LinguaFlowError.missingTranslation(path)
    }
  }

  public static func mainBundleFile(_ path: String) -> Data? {
    let pieces = path.split(separator: "/")
    guard let last = pieces.last else { return nil }
    let file = String(last).replacingOccurrences(of: ".json", with: "")
    let subdirectory = pieces.dropLast().joined(separator: "/")
    guard
      let url = Bundle.main.url(
        forResource: file,
        withExtension: "json",
        subdirectory: subdirectory)
    else { return nil }
    return try? Data(contentsOf: url)
  }
}

private func metricOutcome(_ error: Error) -> RuntimeMetricItemDto.Outcome {
  if (error as? URLError)?.code == .timedOut { return .timeout }
  if case .delivery(let status) = error as? LinguaFlowError, status >= 500 { return .serverError }
  return .failure
}
