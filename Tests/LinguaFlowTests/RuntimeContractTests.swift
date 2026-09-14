import Foundation
import Testing

@testable import LinguaFlow

@Test func decodesTypedManifestReason() throws {
  let data = Data(
    #"{"version":2,"releaseId":"r1","sequence":1,"requestedLocale":"tr-TR","resolvedLocale":"tr","reason":"device","supportedLocales":["en","tr"],"translatedLocales":["en","tr"],"fallbackLocale":"en","localeMappings":{},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/tr.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100},"runtimeTelemetry":null}"#
      .utf8)

  let manifest = try JSONDecoder().decode(LocaleManifest.self, from: data)

  #expect(manifest.reason == .device)
}

@Test func rejectsUnknownManifestReason() {
  let data = Data(
    #"{"version":2,"releaseId":"r1","sequence":1,"requestedLocale":"tr","resolvedLocale":"tr","reason":"guessed","supportedLocales":["tr"],"translatedLocales":["tr"],"fallbackLocale":"tr","localeMappings":{},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/tr.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100},"runtimeTelemetry":null}"#
      .utf8)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(LocaleManifest.self, from: data)
  }
}

@Test func rejectsUnknownRuntimeContractVersion() {
  let data = Data(
    #"{"version":1,"releaseId":"r1","sequence":1,"requestedLocale":"tr","resolvedLocale":"tr","reason":"selected","supportedLocales":["tr"],"translatedLocales":["tr"],"fallbackLocale":"tr","localeMappings":{},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/tr.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100},"runtimeTelemetry":null}"#
      .utf8)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(LocaleManifest.self, from: data)
  }
}

@Test func resolvesMappedOfflineLocaleBeforeFallback() throws {
  let data = Data(
    #"{"version":2,"releaseId":"r1","sequence":1,"requestedLocale":"ar","resolvedLocale":"he","reason":"mapped","supportedLocales":["en","he","ar"],"translatedLocales":["en","he"],"fallbackLocale":"en","localeMappings":{"ar":"he"},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/he.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100},"runtimeTelemetry":null}"#
      .utf8)
  let manifest = try JSONDecoder().decode(LocaleManifest.self, from: data)

  #expect(LocaleResolver.resolveOffline(manifest, input: "ar-SA") == "he")
}

@Test func rejectsUnsafeOrInvalidBundleLeaves() {
  #expect(throws: LinguaFlowError.invalidPayload) {
    try validateTranslationBundle([
      "home": .object(["title": .object(["constructor": .string("x")])])
    ])
  }
}

@Test func rejectsUnsafeBundledDirectory() {
  #expect(
    throws: LinguaFlowError.invalidConfiguration(
      "Bundled directory must be an application-relative resource path")
  ) {
    try LinguaFlowConfig(branchKey: "br_live_test", bundledDirectory: "../private")
  }
}

@Test func validatesRuntimeResponseOriginVersionAndSize() throws {
  let valid = try #require(
    HTTPURLResponse(
      url: linguaFlowAPIOrigin, statusCode: 200, httpVersion: nil,
      headerFields: ["X-LinguaFlow-Contract-Version": "2", "Content-Length": "10"]))
  try validateRuntimeResponse(valid, maximumBytes: 10)

  let stale = try #require(
    HTTPURLResponse(
      url: linguaFlowAPIOrigin, statusCode: 200, httpVersion: nil,
      headerFields: ["X-LinguaFlow-Contract-Version": "1"]))
  #expect(throws: LinguaFlowError.invalidPayload) {
    try validateRuntimeResponse(stale, maximumBytes: 10)
  }

  let oversized = try #require(
    HTTPURLResponse(
      url: linguaFlowAPIOrigin, statusCode: 200, httpVersion: nil,
      headerFields: ["X-LinguaFlow-Contract-Version": "2", "Content-Length": "11"]))
  #expect(throws: LinguaFlowError.invalidPayload) {
    try validateRuntimeResponse(oversized, maximumBytes: 10)
  }
}

@Test func rejectsTruncatedAndOversizedRuntimeStreams() async {
  struct Truncated: Error {}
  let truncated = AsyncThrowingStream<UInt8, Error> { continuation in
    continuation.yield(123)
    continuation.yield(34)
    continuation.finish(throwing: Truncated())
  }
  await #expect(throws: Truncated.self) {
    try await collectRuntimeBytes(truncated, maximumBytes: 10)
  }

  let oversized = AsyncStream<UInt8>(bufferingPolicy: .unbounded) { continuation in
    continuation.yield(1)
    continuation.yield(2)
    continuation.yield(3)
    continuation.finish()
  }
  await #expect(throws: LinguaFlowError.invalidPayload) {
    try await collectRuntimeBytes(oversized, maximumBytes: 2)
  }
}

@Test func corruptedOfflineBundleIsNeverActivated() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let suite = "linguaflow-tests-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let config = try LinguaFlowConfig(branchKey: "br_live_fault_test")
  let store = LocalizationStore(config: config, defaults: defaults, directory: directory)
  try store.saveBundle(
    CachedBundle(releaseId: "r1", etag: nil, data: ["home": .string("valid")]),
    locale: "en")
  let file = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
  try Data(#"{"releaseId":"r1","data":{"home":42}}"#.utf8).write(to: file, options: .atomic)

  #expect(store.bundle(locale: "en") == nil)
}
