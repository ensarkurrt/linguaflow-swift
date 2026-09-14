#if canImport(DeviceCheck)
  import CryptoKit
  import DeviceCheck
  import Foundation

  private actor AppAttestServiceClient {
    private let service = DCAppAttestService.shared

    func isSupported() -> Bool { service.isSupported }

    func generateKey() async throws -> String {
      try await withCheckedThrowingContinuation { continuation in
        service.generateKey { keyId, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let keyId {
            continuation.resume(returning: keyId)
          } else {
            continuation.resume(throwing: LinguaFlowError.unavailable)
          }
        }
      }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        service.attestKey(keyId, clientDataHash: clientDataHash) { attestation, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let attestation {
            continuation.resume(returning: attestation)
          } else {
            continuation.resume(throwing: LinguaFlowError.unavailable)
          }
        }
      }
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
      try await withCheckedThrowingContinuation { continuation in
        service.generateAssertion(keyId, clientDataHash: clientDataHash) { assertion, error in
          if let error {
            continuation.resume(throwing: error)
          } else if let assertion {
            continuation.resume(returning: assertion)
          } else {
            continuation.resume(throwing: LinguaFlowError.unavailable)
          }
        }
      }
    }
  }

  public actor AppAttestProvider: DeviceIntegrityProvider {
    public enum Environment: String, Sendable { case development, production }
    private let service = AppAttestServiceClient()
    private let session: URLSession
    private let defaults: UserDefaults
    private var grants: [String: IntegrityGrantResponseDto] = [:]
    private let environment: Environment

    public init(
      session: URLSession = .shared, defaults: UserDefaults = .standard,
      environment: Environment = .production
    ) {
      self.session = session
      self.defaults = defaults
      self.environment = environment
    }

    public func obtainGrant(branchKey: String) async throws -> String {
      try await obtainGrant(branchKey: branchKey, mayRecoverKey: true)
    }

    private func obtainGrant(branchKey: String, mayRecoverKey: Bool) async throws -> String {
      if let grant = grants[branchKey], grant.expiresAt > Date().addingTimeInterval(30) {
        return grant.token
      }
      guard await service.isSupported() else { throw LinguaFlowError.unavailable }
      guard let bundleId = Bundle.main.bundleIdentifier else {
        throw LinguaFlowError.invalidConfiguration("Bundle identifier is unavailable")
      }
      let challenge: AppAttestChallengeResponseDto = try await post(
        "v1/bundles/\(branchKey)/attestation/apple/challenges",
        body: ["bundleId": bundleId, "environment": environment.rawValue])
      let keyStorage = "linguaflow:\(bundleId):\(environment.rawValue):app-attest-key"
      let storedKey = defaults.string(forKey: keyStorage)
      let keyId: String
      if let storedKey { keyId = storedKey } else { keyId = try await service.generateKey() }
      let hash = Data(SHA256.hash(data: Data(challenge.challenge.utf8)))
      let response: IntegrityGrantResponseDto
      if storedKey == nil {
        let attestation = try await service.attestKey(keyId, clientDataHash: hash)
        response = try await post(
          "v1/bundles/\(branchKey)/attestation/apple/keys",
          body: [
            "challengeId": challenge.challengeId.uuidString,
            "challenge": challenge.challenge,
            "bundleId": bundleId,
            "environment": environment.rawValue,
            "keyId": keyId,
            "attestation": attestation.base64EncodedString(),
          ])
        defaults.set(keyId, forKey: keyStorage)
      } else {
        let assertion: Data
        do {
          assertion = try await service.generateAssertion(keyId, clientDataHash: hash)
        } catch let error as CancellationError {
          throw error
        } catch {
          guard mayRecoverKey else { throw error }
          defaults.removeObject(forKey: keyStorage)
          return try await obtainGrant(branchKey: branchKey, mayRecoverKey: false)
        }
        do {
          response = try await post(
            "v1/bundles/\(branchKey)/attestation/apple/assertions",
            body: [
              "challengeId": challenge.challengeId.uuidString,
              "challenge": challenge.challenge,
              "bundleId": bundleId,
              "environment": environment.rawValue,
              "keyId": keyId,
              "assertion": assertion.base64EncodedString(),
            ])
        } catch LinguaFlowError.delivery(401) {
          guard mayRecoverKey else { throw LinguaFlowError.delivery(401) }
          defaults.removeObject(forKey: keyStorage)
          return try await obtainGrant(branchKey: branchKey, mayRecoverKey: false)
        }
      }
      grants[branchKey] = response
      return response.token
    }

    private func post<Response: Decodable>(_ path: String, body: [String: String]? = nil)
      async throws -> Response
    {
      let url = linguaFlowAPIOrigin.appendingPathComponent(path)
      var request = URLRequest(url: url)
      request.httpMethod = "POST"
      request.timeoutInterval = 30
      if let body {
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      }
      request.setValue("swift", forHTTPHeaderField: "X-LinguaFlow-SDK")
      request.setValue(linguaFlowSwiftSDKVersion, forHTTPHeaderField: "X-LinguaFlow-SDK-Version")
      request.setValue(
        linguaFlowRuntimeContractVersion, forHTTPHeaderField: "X-LinguaFlow-Contract-Version")
      let data = try await runtimeData(
        session: session, request: request, maximumBytes: 256 * 1024)
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      do {
        return try decoder.decode(Response.self, from: data)
      } catch let error as CancellationError {
        throw error
      } catch {
        throw LinguaFlowError.invalidPayload
      }
    }
  }

#endif
