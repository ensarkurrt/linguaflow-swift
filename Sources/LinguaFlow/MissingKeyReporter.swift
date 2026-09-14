import Foundation

private struct MissingKeyContext: Hashable, Sendable {
  let releaseId: String
  let locale: String
  let token: String
  let maxBatchSize: Int
}

private struct MissingKeyBatch: Sendable {
  let requestId: UUID
  let context: MissingKeyContext
  let keys: [String]
  let attempts: Int
}

actor MissingKeyReporter {
  private let config: LinguaFlowConfig
  private let api: DeliveryAPI
  private var pending: [MissingKeyContext: Set<String>] = [:]
  private var retries: [MissingKeyBatch] = []
  private var scheduledTask: Task<Void, Never>?
  private var stopped = false

  init(config: LinguaFlowConfig, api: DeliveryAPI) {
    self.config = config
    self.api = api
  }

  func record(_ path: String, manifest: LocaleManifest?) {
    guard
      !stopped, path.count <= 512, config.missingKeyTelemetryEnabled, let manifest,
      manifest.missingKeyTelemetry.enabled, let token = manifest.runtimeTelemetry?.token
    else { return }
    let context = MissingKeyContext(
      releaseId: manifest.releaseId, locale: manifest.resolvedLocale, token: token,
      maxBatchSize: min(manifest.missingKeyTelemetry.maxBatchSize, 100))
    pending[context, default: []].insert(path)
    scheduleIfNeeded(nanoseconds: 500_000_000)
  }

  func flush() async {
    guard !stopped else { return }
    scheduledTask = nil
    var batches = retries
    retries.removeAll()
    for context in pending.keys {
      guard var keys = pending[context], !keys.isEmpty else { continue }
      let selected = Array(keys.prefix(context.maxBatchSize))
      keys.subtract(selected)
      if keys.isEmpty {
        pending.removeValue(forKey: context)
      } else {
        pending[context] = keys
      }
      batches.append(.init(requestId: UUID(), context: context, keys: selected, attempts: 0))
    }
    for batch in batches {
      do {
        try await api.reportMissingKeys(
          MissingKeyReport(
            requestId: batch.requestId, locale: batch.context.locale,
            appVersion: config.resolvedAppVersion, telemetryToken: batch.context.token,
            keys: batch.keys))
      } catch is CancellationError {
        return
      } catch {
        if batch.attempts < 3 {
          retries.append(
            .init(
              requestId: batch.requestId, context: batch.context, keys: batch.keys,
              attempts: batch.attempts + 1))
        }
      }
    }
    if !pending.isEmpty || !retries.isEmpty { scheduleIfNeeded(nanoseconds: 5_000_000_000) }
  }

  func shutdown() {
    stopped = true
    scheduledTask?.cancel()
    scheduledTask = nil
    pending.removeAll()
    retries.removeAll()
  }

  private func scheduleIfNeeded(nanoseconds: UInt64) {
    guard !stopped, scheduledTask == nil else { return }
    scheduledTask = Task {
      try? await Task.sleep(nanoseconds: nanoseconds)
      await flush()
    }
  }
}
