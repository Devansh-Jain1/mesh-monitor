import Foundation
import ImageIO

/// Identity is pinned by the parent-owned control session, never learned from an image response.
struct MeshManagedCameraIdentity: Equatable, Sendable {
    let sessionID: String
    let generation: String
    let stationEpoch: String
    let cameraID: String

    init(sessionID: String, generation: String, stationEpoch: String, cameraID: String) throws {
        func safe(_ value: String, maximum: Int) -> Bool {
            // Commas are deliberately excluded: HTTP stacks can coalesce repeated headers.
            !value.isEmpty && value.utf8.count <= maximum
                && value.utf8.allSatisfy { (33...126).contains($0) && $0 != 44 }
        }
        guard UUID(uuidString: sessionID) != nil, UUID(uuidString: generation) != nil,
              safe(stationEpoch, maximum: 128), safe(cameraID, maximum: 512) else {
            throw MeshManagedCameraError.invalidConnection
        }
        self.sessionID = sessionID; self.generation = generation
        self.stationEpoch = stationEpoch; self.cameraID = cameraID
    }
}

enum MeshManagedCameraError: Error, Equatable, LocalizedError {
    case invalidConnection, invalidResponse, identityMismatch, invalidTimestamp
    case staleFrame, repeatedFrame, invalidImage, invalidHealth

    var errorDescription: String? {
        switch self {
        case .invalidConnection: return "Managed camera connection is invalid; reconnect the selected source."
        case .invalidResponse: return "Managed camera response could not be verified; no image accepted."
        case .identityMismatch: return "Managed camera session changed; reconnect before accepting images."
        case .invalidTimestamp: return "Managed camera capture time is missing or invalid; no image accepted."
        case .staleFrame: return "Managed camera frame expired. Start the input again to reconnect."
        case .repeatedFrame: return "Managed camera repeated an older frame. Start the input again to reconnect."
        case .invalidImage: return "Managed camera did not return a bounded JPEG; no image accepted."
        case .invalidHealth: return "Managed camera endpoint readiness could not be verified."
        }
    }
}

/// In-memory credentials only. This type intentionally has no Codable conformance.
struct MeshManagedCameraConnection: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let maximumImageBytes = 4 * 1_024 * 1_024
    static let maximumHealthBytes = 1_024
    let snapshotURL: URL
    let identity: MeshManagedCameraIdentity
    private let snapshotToken: String

    struct Health: Equatable, Sendable, Decodable {
        let ready: Bool
        let captureActive: Bool
        let fresh: Bool
    }
    struct DecodedSnapshot {
        let image: CGImage
        let capturedAt: Date
    }

    init(snapshotURL: URL, identity: MeshManagedCameraIdentity, snapshotToken: String) throws {
        guard let parts = URLComponents(url: snapshotURL, resolvingAgainstBaseURL: false),
              parts.scheme == "http", parts.host == "127.0.0.1", let port = parts.port,
              (1_024...65_535).contains(port), parts.user == nil, parts.password == nil,
              parts.percentEncodedPath == "/snapshot.jpg", parts.query == nil, parts.fragment == nil,
              snapshotURL.absoluteString == "http://127.0.0.1:\(port)/snapshot.jpg",
              snapshotToken.utf8.count == 64,
              snapshotToken.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MeshManagedCameraError.invalidConnection
        }
        self.snapshotURL = snapshotURL; self.identity = identity; self.snapshotToken = snapshotToken
    }

    var healthURL: URL { snapshotURL.deletingLastPathComponent().appendingPathComponent("health") }
    var description: String { "Managed camera connection (credentials redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["connection": description]) }

    func snapshotRequest() -> URLRequest { request(url: snapshotURL, accept: "image/jpeg") }
    func healthRequest() -> URLRequest { request(url: healthURL, accept: "application/json") }
    private func request(url: URL, accept: String) -> URLRequest {
        var value = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4)
        value.httpShouldHandleCookies = false
        value.setValue("Bearer " + snapshotToken, forHTTPHeaderField: "Authorization")
        value.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        value.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        value.setValue(accept, forHTTPHeaderField: "Accept")
        return value
    }

    /// The same private, cookie-free configuration is used by the image client and runtime health check.
    static func sessionConfiguration(managed: Bool = true) -> URLSessionConfiguration {
        let value = URLSessionConfiguration.ephemeral
        value.urlCache = nil; value.urlCredentialStorage = nil; value.httpCookieStorage = nil
        value.httpShouldSetCookies = false
        if managed { value.connectionProxyDictionary = [:] }
        value.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        value.timeoutIntervalForRequest = 4; value.timeoutIntervalForResource = 6
        return value
    }

    /// Only typed response metadata is inspected here. No network, camera, or filesystem calls.
    func verifySnapshot(response: HTTPURLResponse, now: Date, after previous: Date?) throws -> Date {
        let headers = try verify(response: response, url: snapshotURL, contentType: "image/jpeg", maximumBytes: Self.maximumImageBytes)
        guard let value = headers["x-mesh-captured-at"], value.utf8.count <= 40,
              value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else {
            throw MeshManagedCameraError.invalidTimestamp
        }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = value.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        guard let capturedAt = parser.date(from: value) else { throw MeshManagedCameraError.invalidTimestamp }
        try Self.verifyFreshness(capturedAt: capturedAt, now: now, after: previous)
        return capturedAt
    }

    static func verifyFreshness(capturedAt: Date, now: Date, after previous: Date?) throws {
        let age = now.timeIntervalSince(capturedAt)
        guard age.isFinite, (-0.5...3).contains(age) else { throw MeshManagedCameraError.staleFrame }
        if let previous, capturedAt <= previous { throw MeshManagedCameraError.repeatedFrame }
    }

    /// Rechecks the complete metadata after bounded decode, since decode time consumes frame freshness.
    func decodeSnapshot(data: Data, response: HTTPURLResponse, after previous: Date?,
                        now: () -> Date = Date.init) throws -> DecodedSnapshot {
        _ = try verifySnapshot(response: response, now: now(), after: previous)
        guard !data.isEmpty, data.count <= Self.maximumImageBytes,
              response.expectedContentLength < 0 || response.expectedContentLength == data.count,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 8_192, height <= 8_192, width * height <= 32_000_000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 960,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw MeshManagedCameraError.invalidImage }
        guard CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw MeshManagedCameraError.invalidImage }
        let capturedAt = try verifySnapshot(response: response, now: now(), after: previous)
        return DecodedSnapshot(image: image, capturedAt: capturedAt)
    }

    /// A prepared health result can be ready=true with captureActive=false and fresh=false.
    /// Callers must not label that as a running camera or as evidence of a captured frame.
    func verifyHealth(response: HTTPURLResponse, data: Data) throws -> Health {
        _ = try verify(response: response, url: healthURL, contentType: "application/json", maximumBytes: Self.maximumHealthBytes)
        guard !data.isEmpty, data.count <= Self.maximumHealthBytes,
              response.expectedContentLength < 0 || response.expectedContentLength == data.count,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["ready", "captureActive", "fresh"],
              let value = try? JSONDecoder().decode(Health.self, from: data),
              !value.fresh || (value.ready && value.captureActive),
              !value.captureActive || value.ready else { throw MeshManagedCameraError.invalidHealth }
        return value
    }

    private func verify(response: HTTPURLResponse, url: URL, contentType: String, maximumBytes: Int) throws -> [String: String] {
        guard response.url == url, response.statusCode == 200, response.allHeaderFields.count <= 32,
              response.expectedContentLength <= maximumBytes else { throw MeshManagedCameraError.invalidResponse }
        var headers: [String: String] = [:]
        var total = 0
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = rawKey as? String, let value = rawValue as? String else { throw MeshManagedCameraError.invalidResponse }
            total += key.utf8.count + value.utf8.count
            let name = key.lowercased()
            guard total <= 4_096, headers[name] == nil,
                  !value.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw MeshManagedCameraError.invalidResponse }
            headers[name] = value
        }
        guard headers["content-type"]?.lowercased() == contentType,
              headers["content-encoding"] == nil || headers["content-encoding"]?.lowercased() == "identity" else {
            throw MeshManagedCameraError.invalidResponse
        }
        if let length = headers["content-length"] {
            guard !length.isEmpty, length.utf8.count <= 10,
                  length.utf8.allSatisfy({ (48...57).contains($0) }),
                  let declared = Int64(length), declared == response.expectedContentLength else {
                throw MeshManagedCameraError.invalidResponse
            }
        }
        let expected = ["x-mesh-camera-session": identity.sessionID, "x-mesh-camera-generation": identity.generation,
                        "x-mesh-station-epoch": identity.stationEpoch, "x-mesh-camera-id": identity.cameraID]
        for (key, value) in expected {
            guard headers[key] == value else { throw MeshManagedCameraError.identityMismatch }
        }
        return headers
    }
}
