import Foundation

actor MissingKeyReporter {
  private let config: LinguaFlowConfig
  private let api: DeliveryAPI
  private var pending: Set<String> = []
  private var scheduledTask: Task<Void, Never>?
  private var manifest: LocaleManifest?

  init(config: LinguaFlowConfig, api: DeliveryAPI) {
    self.config = config
    self.api = api
  }

  func record(_ path: String, manifest: LocaleManifest?) {
    guard config.missingKeyTelemetryEnabled, manifest?.missingKeyTelemetry.enabled == true else {
      return
    }
    self.manifest = manifest
    pending.insert(path)
    guard scheduledTask == nil else { return }
    scheduledTask = Task {
      try? await Task.sleep(nanoseconds: 500_000_000)
      await flush()
    }
  }

  func flush() async {
    scheduledTask = nil
    guard let manifest, !pending.isEmpty else { return }
    let limit = min(manifest.missingKeyTelemetry.maxBatchSize, 100)
    let keys = Array(pending.prefix(limit))
    pending.subtract(keys)
    do {
      try await api.reportMissingKeys(
        MissingKeyReport(
          requestId: UUID(),
          releaseId: manifest.releaseId,
          locale: manifest.resolvedLocale,
          appVersion: config.appVersion,
          platform: "ios",
          keys: keys))
    } catch {
      pending.formUnion(keys)
    }
    scheduleRetryIfNeeded()
  }

  private func scheduleRetryIfNeeded() {
    guard !pending.isEmpty, scheduledTask == nil else { return }
    scheduledTask = Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      await flush()
    }
  }
}
