import Foundation

/// The error object (§12): the body of every error response, and a failed job's `error`.
public struct MESError: Error, Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var reason: String?
    public var param: String?
    public var job: String?
    public var requestID: String?
    public var supportedVersions: [String]?

    enum CodingKeys: String, CodingKey {
        case code, message, reason, param, job
        case requestID = "request_id", supportedVersions = "supported_versions"
    }

    public init(_ code: MESErrorCode, _ message: String, reason: String? = nil, param: String? = nil, job: String? = nil) {
        self.code = code.rawValue; self.message = message; self.reason = reason; self.param = param; self.job = job
    }

    public init(code: String, message: String) { self.code = code; self.message = message }

    /// The HTTP status for this error's code; unknown codes are 500.
    public var status: Int { MESErrorCode(rawValue: code)?.status ?? 500 }
}

/// `{"error": {...}}`
public struct ErrorBody: Codable, Sendable, Equatable {
    public var error: MESError
    public init(error: MESError) { self.error = error }
}

/// The error-code registry (§12) with each code's HTTP status.
public enum MESErrorCode: String, Sendable, CaseIterable {
    case invalidRequest = "invalid_request", unsupportedVersion = "unsupported_version"
    case unauthorized
    case forbidden, originNotAllowed = "origin_not_allowed", pairingRejected = "pairing_rejected"
    case notFound = "not_found", unknownOperation = "unknown_operation"
    case conflict, alreadyConfirmed = "already_confirmed"
    case gone
    case tooLarge = "too_large"
    case unsupportedMediaType = "unsupported_media_type"
    case outOfLimits = "out_of_limits", unsupportedParameter = "unsupported_parameter", policyUnmet = "policy_unmet"
    case inputInvalid = "input_invalid", modelUnavailable = "model_unavailable"
    case busy
    case engineError = "engine_error"
    case inputFetchFailed = "input_fetch_failed", remoteProviderFailed = "remote_provider_failed"
    case noCapacity = "no_capacity"

    public var status: Int {
        switch self {
        case .invalidRequest, .unsupportedVersion: 400
        case .unauthorized: 401
        case .forbidden, .originNotAllowed, .pairingRejected: 403
        case .notFound, .unknownOperation: 404
        case .conflict, .alreadyConfirmed: 409
        case .gone: 410
        case .tooLarge: 413
        case .unsupportedMediaType: 415
        case .outOfLimits, .unsupportedParameter, .policyUnmet, .inputInvalid, .modelUnavailable: 422
        case .busy: 429
        case .engineError: 500
        case .inputFetchFailed, .remoteProviderFailed: 502
        case .noCapacity: 503
        }
    }
}
