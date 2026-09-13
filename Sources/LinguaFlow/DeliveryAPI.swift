import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

let linguaFlowAPIOrigin = URL(string: "https://api.linguaflow.dev")!
let linguaFlowRuntimeContractVersion = "1"
let linguaFlowSwiftSDKVersion = "0.1.0"

enum BundleDelivery: Sendable {
  case notModified
  case content([String: JSONValue], etag: String?)
}

struct MissingKeyReport: Encodable, Sendable {
  let requestId: UUID
  let releaseId: String
  let locale: String
  let appVersion: String
  let platform: String
  let keys: [String]
}

struct DeliveryAPI: Sendable {
  private let config: LinguaFlowConfig
  private let session: URLSession
  private let installationId: String
  private let integrityProvider: (any DeviceIntegrityProvider)?

  init(
    config: LinguaFlowConfig,
    session: URLSession,
    installationId: String,
    integrityProvider: (any DeviceIntegrityProvider)?
  ) {
    self.config = config
    self.session = session
    self.installationId = installationId
    self.integrityProvider = integrityProvider
  }

  func manifest(locale: String, explicit: Bool) async throws -> LocaleManifest {
    var request = URLRequest(url: endpoint("v1/bundles/\(config.branchKey)/manifest"))
    try await applyHeaders(&request, locale: locale, explicit: explicit)
    let (data, response) = try await session.data(for: request)
    try requireSuccess(response)
    do {
      return try JSONDecoder().decode(LocaleManifest.self, from: data)
    } catch {
      throw LinguaFlowError.invalidPayload
    }
  }

  func bundle(locale: String, etag: String?) async throws -> BundleDelivery {
    var request = URLRequest(url: endpoint("v1/bundles/\(config.branchKey)"))
    try await applyHeaders(&request, locale: locale, explicit: true)
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (data, response) = try await session.data(for: request)
    if (response as? HTTPURLResponse)?.statusCode == 304 { return .notModified }
    try requireSuccess(response)
    do {
      let body = try JSONDecoder().decode([String: JSONValue].self, from: data)
      return .content(body, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    } catch {
      throw LinguaFlowError.invalidPayload
    }
  }

  func reportMissingKeys(_ report: MissingKeyReport) async throws {
    var request = URLRequest(
      url: endpoint("v1/telemetry/\(config.branchKey)/missing-keys"))
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(report)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try await applyHeaders(&request, locale: report.locale, explicit: true)
    let (_, response) = try await session.data(for: request)
    try requireSuccess(response)
  }

  private func applyHeaders(_ request: inout URLRequest, locale: String, explicit: Bool)
    async throws
  {
    request.setValue(installationId, forHTTPHeaderField: "X-LinguaFlow-Installation-Id")
    request.setValue("swift", forHTTPHeaderField: "X-LinguaFlow-SDK")
    request.setValue(linguaFlowSwiftSDKVersion, forHTTPHeaderField: "X-LinguaFlow-SDK-Version")
    request.setValue(
      linguaFlowRuntimeContractVersion, forHTTPHeaderField: "X-LinguaFlow-Contract-Version")
    request.setValue(
      locale,
      forHTTPHeaderField: explicit ? "X-LinguaFlow-Locale" : "X-LinguaFlow-Device-Locale")
    if let overlay = config.overlay {
      request.setValue(overlay, forHTTPHeaderField: "X-LinguaFlow-Overlay")
    }
    if let integrityProvider {
      let grant = try await integrityProvider.obtainGrant(branchKey: config.branchKey)
      request.setValue(grant, forHTTPHeaderField: "X-LinguaFlow-Integrity")
    }
  }

  private func endpoint(_ path: String) -> URL {
    linguaFlowAPIOrigin.appendingPathComponent(path)
  }

  private func requireSuccess(_ response: URLResponse) throws {
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw LinguaFlowError.delivery((response as? HTTPURLResponse)?.statusCode ?? 0)
    }
  }
}
