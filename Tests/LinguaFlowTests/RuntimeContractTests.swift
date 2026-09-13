import Foundation
import Testing

@testable import LinguaFlow

@Test func decodesTypedManifestReason() throws {
  let data = Data(
    #"{"version":1,"releaseId":"r1","sequence":1,"requestedLocale":"tr-TR","resolvedLocale":"tr","reason":"device","supportedLocales":["en","tr"],"translatedLocales":["en","tr"],"fallbackLocale":"en","localeMappings":{},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/tr.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100}}"#
      .utf8)

  let manifest = try JSONDecoder().decode(LocaleManifest.self, from: data)

  #expect(manifest.reason == .device)
}

@Test func rejectsUnknownManifestReason() {
  let data = Data(
    #"{"version":1,"releaseId":"r1","sequence":1,"requestedLocale":"tr","resolvedLocale":"tr","reason":"guessed","supportedLocales":["tr"],"translatedLocales":["tr"],"fallbackLocale":"tr","localeMappings":{},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/tr.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100}}"#
      .utf8)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(LocaleManifest.self, from: data)
  }
}

@Test func rejectsUnknownRuntimeContractVersion() {
  let data = Data(
    #"{"version":2,"releaseId":"r1","sequence":1,"requestedLocale":"tr","resolvedLocale":"tr","reason":"selected","supportedLocales":["tr"],"translatedLocales":["tr"],"fallbackLocale":"tr","localeMappings":{},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/tr.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100}}"#.utf8)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(LocaleManifest.self, from: data)
  }
}

@Test func resolvesMappedOfflineLocaleBeforeFallback() throws {
  let data = Data(
    #"{"version":1,"releaseId":"r1","sequence":1,"requestedLocale":"ar","resolvedLocale":"he","reason":"mapped","supportedLocales":["en","he","ar"],"translatedLocales":["en","he"],"fallbackLocale":"en","localeMappings":{"ar":"he"},"rollout":{"candidateReleaseId":"r1","percentage":100,"selection":"stable"},"bundlePath":"releases/r1/he.json","overlays":[],"overlay":null,"missingKeyTelemetry":{"enabled":false,"maxBatchSize":100}}"#
      .utf8)
  let manifest = try JSONDecoder().decode(LocaleManifest.self, from: data)

  #expect(LocaleResolver.resolveOffline(manifest, input: "ar-SA") == "he")
}
