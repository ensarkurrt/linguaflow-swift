import Foundation

private struct TelemetryContext: Hashable, Sendable {
  let releaseId: String
  let token: String
}

private struct RuntimeMetricBatch: Sendable {
  let request: RuntimeMetricReportRequestDto
  let context: TelemetryContext
  let attempts: Int
}

actor RuntimeMetricReporter {
  private let config: LinguaFlowConfig
  private let api: DeliveryAPI
  private let enabled: Bool
  private var pending: [TelemetryContext: [String: Int]] = [:]
  private var retries: [RuntimeMetricBatch] = []
  private var scheduledTask: Task<Void, Never>?
  private var stopped = false

  init(config: LinguaFlowConfig, api: DeliveryAPI, enabled: Bool) {
    self.config = config
    self.api = api
    self.enabled = enabled
  }

  func record(
    _ kind: RuntimeMetricItemDto.Kind,
    outcome: RuntimeMetricItemDto.Outcome,
    manifest: LocaleManifest?
  ) {
    guard
      !stopped, enabled, let manifest, manifest.releaseId != "bundled",
      let token = manifest.runtimeTelemetry?.token
    else { return }
    let context = TelemetryContext(releaseId: manifest.releaseId, token: token)
    pending[context, default: [:]]["\(kind.rawValue):\(outcome.rawValue)", default: 0] += 1
    scheduleIfNeeded()
  }

  func flush() async {
    guard !stopped else { return }
    scheduledTask = nil
    var batches = retries
    retries.removeAll()
    for context in pending.keys {
      if let batch = takeBatch(for: context) { batches.append(batch) }
    }
    for batch in batches {
      do {
        try await api.reportRuntimeMetrics(batch.request, token: batch.context.token)
      } catch is CancellationError {
        return
      } catch {
        if batch.attempts < 3 {
          retries.append(
            .init(request: batch.request, context: batch.context, attempts: batch.attempts + 1))
        }
      }
    }
    if !pending.isEmpty || !retries.isEmpty { scheduleIfNeeded() }
  }

  func shutdown() {
    stopped = true
    scheduledTask?.cancel()
    scheduledTask = nil
    pending.removeAll()
    retries.removeAll()
  }

  private func takeBatch(for context: TelemetryContext) -> RuntimeMetricBatch? {
    guard var values = pending[context] else { return nil }
    var remaining = 20_000
    var metrics: [RuntimeMetricItemDto] = []
    for (key, count) in values {
      guard metrics.count < 16, remaining > 0 else { break }
      let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
      guard
        parts.count == 2,
        let kind = RuntimeMetricItemDto.Kind(rawValue: parts[0]),
        let outcome = RuntimeMetricItemDto.Outcome(rawValue: parts[1])
      else {
        values.removeValue(forKey: key)
        continue
      }
      let included = min(count, 10_000, remaining)
      metrics.append(.init(kind: kind, outcome: outcome, count: included))
      if count == included {
        values.removeValue(forKey: key)
      } else {
        values[key] = count - included
      }
      remaining -= included
    }
    if values.isEmpty { pending.removeValue(forKey: context) } else { pending[context] = values }
    guard !metrics.isEmpty else { return nil }
    return RuntimeMetricBatch(
      request: .init(requestId: UUID(), appVersion: config.resolvedAppVersion, metrics: metrics),
      context: context, attempts: 0)
  }

  private func scheduleIfNeeded() {
    guard !stopped, scheduledTask == nil else { return }
    scheduledTask = Task {
      try? await Task.sleep(nanoseconds: 5_000_000_000)
      await flush()
    }
  }
}
