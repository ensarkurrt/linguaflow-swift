import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

let linguaFlowAPIOrigin = URL(string: "https://api.linguaflow.dev")!
let linguaFlowRuntimeContractVersion = "2"
let linguaFlowSwiftSDKVersion = "0.1.0"
private let maximumManifestBytes = 256 * 1024
private let maximumBundleBytes = 5 * 1024 * 1024
private let maximumTelemetryResponseBytes = 256 * 1024
let linguaFlowNoRedirectDelegate = LinguaFlowNoRedirectDelegate()

final class LinguaFlowNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

enum BundleDelivery: Sendable {
  case notModified
  case content([String: JSONValue], etag: String?)
}

struct MissingKeyReport: Encodable, Sendable {
  let requestId: UUID
  let locale: String
  let appVersion: String
  let telemetryToken: String
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
    request.timeoutInterval = 30
    try await applyHeaders(&request, locale: locale, explicit: explicit)
    let data = try await runtimeData(
      session: session, request: request, maximumBytes: maximumManifestBytes)
    do {
      return try JSONDecoder().decode(LocaleManifest.self, from: data)
    } catch {
      throw LinguaFlowError.invalidPayload
    }
  }

  func bundle(locale: String, etag: String?) async throws -> BundleDelivery {
    var request = URLRequest(url: endpoint("v1/bundles/\(config.branchKey)"))
    request.timeoutInterval = 30
    try await applyHeaders(&request, locale: locale, explicit: true)
    if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    let (data, response) = try await runtimeDataWithResponse(
      session: session, request: request, maximumBytes: maximumBundleBytes,
      allowNotModified: true)
    if (response as? HTTPURLResponse)?.statusCode == 304 { return .notModified }
    do {
      let body = try JSONDecoder().decode([String: JSONValue].self, from: data)
      try validateTranslationBundle(body)
      return .content(body, etag: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    } catch {
      throw LinguaFlowError.invalidPayload
    }
  }

  func reportMissingKeys(_ report: MissingKeyReport) async throws {
    var request = URLRequest(
      url: endpoint("v1/telemetry/\(config.branchKey)/missing-keys"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.httpBody = try JSONEncoder().encode(report)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try await applyHeaders(&request, locale: report.locale, explicit: true)
    request.setValue(report.telemetryToken, forHTTPHeaderField: "X-LinguaFlow-Telemetry-Token")
    _ = try await runtimeData(
      session: session, request: request, maximumBytes: maximumTelemetryResponseBytes)
  }

  func reportRuntimeMetrics(_ report: RuntimeMetricReportRequestDto, token: String) async throws {
    var request = URLRequest(url: endpoint("v1/telemetry/\(config.branchKey)/runtime-metrics"))
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.httpBody = try JSONEncoder().encode(report)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    try await applyHeaders(&request, locale: "en", explicit: true)
    request.setValue(token, forHTTPHeaderField: "X-LinguaFlow-Telemetry-Token")
    _ = try await runtimeData(
      session: session, request: request, maximumBytes: maximumTelemetryResponseBytes)
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

}

func runtimeData(session: URLSession, request: URLRequest, maximumBytes: Int) async throws -> Data {
  let (data, _) = try await runtimeDataWithResponse(
    session: session, request: request, maximumBytes: maximumBytes)
  return data
}

func runtimeDataWithResponse(
  session: URLSession, request: URLRequest, maximumBytes: Int,
  allowNotModified: Bool = false
) async throws -> (Data, URLResponse) {
  let (bytes, response) = try await session.bytes(
    for: request, delegate: linguaFlowNoRedirectDelegate)
  try validateRuntimeResponse(
    response, maximumBytes: maximumBytes, allowNotModified: allowNotModified)
  let data = try await collectRuntimeBytes(bytes, maximumBytes: maximumBytes)
  return (data, response)
}

func collectRuntimeBytes<Bytes: AsyncSequence>(_ bytes: Bytes, maximumBytes: Int) async throws
  -> Data where Bytes.Element == UInt8
{
  var data = Data()
  data.reserveCapacity(min(maximumBytes, 64 * 1024))
  for try await byte in bytes {
    guard data.count < maximumBytes else { throw LinguaFlowError.invalidPayload }
    data.append(byte)
  }
  return data
}

func validateRuntimeResponse(
  _ response: URLResponse, maximumBytes: Int, allowNotModified: Bool = false
) throws {
  guard let http = response as? HTTPURLResponse else { throw LinguaFlowError.invalidPayload }
  guard
    http.url?.scheme == linguaFlowAPIOrigin.scheme,
    http.url?.host == linguaFlowAPIOrigin.host,
    http.url?.port == linguaFlowAPIOrigin.port
  else { throw LinguaFlowError.invalidPayload }
  guard (200..<300).contains(http.statusCode) || (allowNotModified && http.statusCode == 304) else {
    throw LinguaFlowError.delivery(http.statusCode)
  }
  guard response.expectedContentLength <= Int64(maximumBytes) else {
    throw LinguaFlowError.invalidPayload
  }
  guard
    http.value(forHTTPHeaderField: "X-LinguaFlow-Contract-Version")
      == linguaFlowRuntimeContractVersion
  else { throw LinguaFlowError.invalidPayload }
}
