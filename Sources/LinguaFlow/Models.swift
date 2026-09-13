import Foundation

public struct LfKey: Sendable {
  public let path: String
  public init(_ path: String) { self.path = path }
}

public enum LfArgument: Sendable {
  case string(String)
  case number(Double)
  case date(Date)

  var string: String {
    switch self {
    case .string(let value): value
    case .number(let value): value.formatted(.number)
    case .date(let value): value.formatted()
    }
  }
  var number: Double? { if case .number(let value) = self { value } else { nil } }
  var date: Date? { if case .date(let value) = self { value } else { nil } }
}

public struct LfMessage: Sendable {
  public let path: String
  public let arguments: [String: LfArgument]
  public init(_ path: String, _ arguments: [String: LfArgument]) {
    self.path = path
    self.arguments = arguments
  }
}

public enum LinguaFlowBundleSource: Sendable { case remote, downloaded, bundled }
public protocol DeviceIntegrityProvider: Sendable {
  func obtainGrant(branchKey: String) async throws -> String
}
public enum LinguaFlowMissingBehavior: String, Codable, Sendable {
  case fallback, key, empty, `throw`
}

public struct LinguaFlowConfig: Sendable {
  public let branchKey: String
  public let overlay: String?
  public let cacheTTL: TimeInterval
  public let bundledDirectory: String
  public let offlineEnabled: Bool
  public let missingBehavior: LinguaFlowMissingBehavior
  public let missingKeyTelemetryEnabled: Bool
  public let appVersion: String

  public init(
    branchKey: String, overlay: String? = nil, cacheTTL: TimeInterval = 300,
    bundledDirectory: String = "linguaflow", offlineEnabled: Bool = true,
    missingBehavior: LinguaFlowMissingBehavior = .fallback,
    missingKeyTelemetryEnabled: Bool = false, appVersion: String = ""
  ) throws {
    guard branchKey.range(of: #"^br_live_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil
    else {
      throw LinguaFlowError.invalidConfiguration("Invalid branch delivery key")
    }
    if let overlay,
      overlay.range(of: #"^[a-z0-9][a-z0-9-]{1,47}$"#, options: .regularExpression) == nil
    {
      throw LinguaFlowError.invalidConfiguration("Invalid overlay slug")
    }
    guard cacheTTL >= 0 else {
      throw LinguaFlowError.invalidConfiguration("TTL cannot be negative")
    }
    self.branchKey = branchKey
    self.overlay = overlay
    self.cacheTTL = cacheTTL
    self.bundledDirectory = bundledDirectory
    self.offlineEnabled = offlineEnabled
    self.missingBehavior = missingBehavior
    self.missingKeyTelemetryEnabled = missingKeyTelemetryEnabled
    self.appVersion = appVersion
  }
}

public typealias LocaleManifest = DeliveryManifestResponseDto
public typealias RuntimeContractVersion = DeliveryManifestResponseDto.Version
public typealias LocaleResolutionReason = DeliveryManifestResponseDto.Reason
public typealias RolloutSelection = DeliveryRolloutResponseDto
public typealias MissingKeyTelemetryPolicy = MissingKeyTelemetryPolicyResponseDto

public enum LinguaFlowError: Error, Equatable {
  case invalidConfiguration(String)
  case delivery(Int)
  case invalidPayload
  case missingTranslation(String)
  case messageFormat(String)
  case unavailable
}

indirect enum JSONValue: Codable, Sendable {
  case string(String)
  case object([String: JSONValue])
  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let value = try? container.decode(String.self) {
      self = .string(value)
      return
    }
    self = .object(try container.decode([String: JSONValue].self))
  }
  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}
