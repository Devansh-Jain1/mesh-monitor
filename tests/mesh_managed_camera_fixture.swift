import Foundation
import ImageIO
import CoreGraphics

@main struct MeshManagedCameraFixture {
    static func main() throws {
        var checks = 0
        func verify(_ condition: @autoclosure () throws -> Bool, _ message: String) {
            do { let result = try condition(); precondition(result, message); checks += 1 }
            catch { preconditionFailure("Unexpected fixture error: \(error)") }
        }
        func rejects(_ expected: MeshManagedCameraError? = nil, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Invalid managed camera input accepted") }
            catch let error as MeshManagedCameraError {
                if let expected { precondition(error == expected, "Unexpected bounded error: \(error)") }
                checks += 1
            } catch { preconditionFailure("Unexpected error type") }
        }
        let identity = try MeshManagedCameraIdentity(sessionID: "00000000-0000-4000-8000-000000000001",
            generation: "00000000-0000-4000-8000-000000000002", stationEpoch: "epoch-123", cameraID: "EXTERNAL-CAMERA-1")
        let token = String(repeating: "a", count: 64)
        let endpoint = URL(string: "http://127.0.0.1:18495/snapshot.jpg")!
        let connection = try MeshManagedCameraConnection(snapshotURL: endpoint, identity: identity, snapshotToken: token)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func response(url: URL? = nil, status: Int = 200, at: Date = now, length: Int? = nil,
                      changes: [String: String] = [:], missing: String? = nil) -> HTTPURLResponse {
            var headers = ["Content-Type": "image/jpeg", "X-Mesh-Camera-Session": identity.sessionID,
                "X-Mesh-Camera-Generation": identity.generation, "X-Mesh-Station-Epoch": identity.stationEpoch,
                "X-Mesh-Camera-ID": identity.cameraID, "X-Mesh-Captured-At": formatter.string(from: at)]
            if let length { headers["Content-Length"] = String(length) }
            changes.forEach { headers[$0.key] = $0.value }
            if let missing { headers.removeValue(forKey: missing) }
            return HTTPURLResponse(url: url ?? endpoint, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        }
        func verified(_ http: HTTPURLResponse, now time: Date = now, after previous: Date? = nil) throws -> Date {
            try connection.verifySnapshot(response: http, now: time, after: previous)
        }
        for url in ["https://127.0.0.1:18495/snapshot.jpg", "http://localhost:18495/snapshot.jpg",
                    "http://127.0.0.2:18495/snapshot.jpg", "http://127.0.0.1/snapshot.jpg",
                    "http://127.0.0.1:80/snapshot.jpg", "http://127.0.0.1:18495/other.jpg",
                    "http://127.0.0.1:18495/snapshot.jpg?token=x", "http://127.0.0.1:18495/snapshot.jpg#x",
                    "http://name@127.0.0.1:18495/snapshot.jpg", "http://127.0.0.1:18495/%73napshot.jpg"] {
            rejects(.invalidConnection) { _ = try MeshManagedCameraConnection(snapshotURL: URL(string: url)!, identity: identity, snapshotToken: token) }
        }
        for invalidToken in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), token + "a", "Bearer " + token] {
            rejects(.invalidConnection) { _ = try MeshManagedCameraConnection(snapshotURL: endpoint, identity: identity, snapshotToken: invalidToken) }
        }
        for (session, generation, epoch, camera) in [
            ("not-a-uuid", identity.generation, identity.stationEpoch, identity.cameraID),
            (identity.sessionID, "bad", identity.stationEpoch, identity.cameraID),
            (identity.sessionID, identity.generation, "", identity.cameraID),
            (identity.sessionID, identity.generation, "has space", identity.cameraID),
            (identity.sessionID, identity.generation, "a,b", identity.cameraID),
            (identity.sessionID, identity.generation, identity.stationEpoch, "camera\r\nheader"),
            (identity.sessionID, identity.generation, identity.stationEpoch, String(repeating: "x", count: 513))] {
            rejects(.invalidConnection) { _ = try MeshManagedCameraIdentity(sessionID: session, generation: generation, stationEpoch: epoch, cameraID: camera) }
        }
        let request = connection.snapshotRequest(), healthRequest = connection.healthRequest()
        verify(request.url == endpoint && request.httpMethod == "GET", "Snapshot endpoint/method pinned")
        verify(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "Bearer stays in request header")
        verify(request.value(forHTTPHeaderField: "Accept") == "image/jpeg" && !request.httpShouldHandleCookies, "JPEG only/no request cookies")
        verify(healthRequest.url?.absoluteString == "http://127.0.0.1:18495/health" && healthRequest.value(forHTTPHeaderField: "Authorization") == "Bearer " + token, "Health uses same pinned origin/auth")
        verify(!String(describing: connection).contains(token) && !String(reflecting: connection).contains(token), "Descriptions redact credentials")
        verify(!String(describing: Array(Mirror(reflecting: connection).children)).contains(token), "Reflection redacts credentials")
        let configuration = MeshManagedCameraConnection.sessionConfiguration()
        verify(configuration.urlCache == nil && configuration.urlCredentialStorage == nil && configuration.httpCookieStorage == nil && !configuration.httpShouldSetCookies, "No shared cache/cookies/credentials")
        verify(configuration.timeoutIntervalForResource == 6, "Bounded resource timeout")
        verify(configuration.connectionProxyDictionary?.isEmpty == true, "Managed loopback request opts out of proxy routing")
        verify(MeshManagedCameraConnection.sessionConfiguration(managed: false).connectionProxyDictionary == nil, "Manual endpoint proxy policy remains unchanged")

        verify(try verified(response()) == now, "Exact identity and fresh timestamp accepted")
        for header in ["X-Mesh-Camera-Session", "X-Mesh-Camera-Generation", "X-Mesh-Station-Epoch", "X-Mesh-Camera-ID"] {
            rejects(.identityMismatch) { _ = try verified(response(missing: header)) }
            rejects(.identityMismatch) { _ = try verified(response(changes: [header: "wrong"])) }
            let value = response().value(forHTTPHeaderField: header)!
            rejects(.identityMismatch) { _ = try verified(response(changes: [header: value + ", " + value])) }
        }
        rejects { _ = try verified(response(changes: ["x-mesh-camera-id": "conflicting-camera"])) }
        rejects(.invalidTimestamp) { _ = try verified(response(missing: "X-Mesh-Captured-At")) }
        for bad in ["not-a-date", formatter.string(from: now) + ", " + formatter.string(from: now), formatter.string(from: now) + " "] {
            rejects(.invalidTimestamp) { _ = try verified(response(changes: ["X-Mesh-Captured-At": bad])) }
        }
        verify(try verified(response(at: now.addingTimeInterval(-3))) == now.addingTimeInterval(-3), "Maximum capture age allowed")
        verify(try verified(response(at: now.addingTimeInterval(0.5))) == now.addingTimeInterval(0.5), "Clock skew tolerance allowed")
        rejects(.staleFrame) { _ = try verified(response(at: now.addingTimeInterval(-3.001))) }
        rejects(.staleFrame) { _ = try verified(response(at: now.addingTimeInterval(0.501))) }
        rejects(.repeatedFrame) { _ = try verified(response(), after: now) }
        rejects(.repeatedFrame) { _ = try verified(response(), after: now.addingTimeInterval(0.1)) }
        verify(try verified(response(), after: now.addingTimeInterval(-0.1)) == now, "Only advancing frame accepted")
        for invalid in [response(status: 302), response(status: 503), response(url: connection.healthURL),
                        response(changes: ["Content-Type": "image/png"]), response(changes: ["Content-Encoding": "gzip"]),
                        response(changes: ["Content-Length": "10, 10"]), response(changes: ["Content-Length": "-1"]),
                        response(length: MeshManagedCameraConnection.maximumImageBytes + 1),
                        response(changes: ["X-Extra": String(repeating: "x", count: 4097)])] {
            rejects { _ = try verified(invalid) }
        }

        func imageData(type: CFString = "public.jpeg" as CFString, width: Int = 20, height: Int = 12) -> Data {
            let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let data = NSMutableData(), image = context.makeImage()!
            let destination = CGImageDestinationCreateWithData(data, type, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil); precondition(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let jpeg = imageData(), jpegResponse = response(length: jpeg.count)
        let decoded = try connection.decodeSnapshot(data: jpeg, response: jpegResponse, after: nil, now: { now })
        verify(decoded.capturedAt == now && decoded.image.width == 20 && decoded.image.height == 12, "Verified synthetic JPEG decoded")
        let wide = imageData(width: 1200, height: 4)
        let scaled = try connection.decodeSnapshot(data: wide, response: response(length: wide.count), after: nil, now: { now })
        verify(scaled.image.width == 960, "Decode remains bounded to 960 pixels")
        for data in [Data(), Data("not-an-image".utf8), imageData(type: "public.png" as CFString),
                     imageData(width: 8193, height: 1), Data(repeating: 0, count: MeshManagedCameraConnection.maximumImageBytes + 1)] {
            rejects { _ = try connection.decodeSnapshot(data: data, response: response(), after: nil, now: { now }) }
        }
        rejects(.invalidImage) { _ = try connection.decodeSnapshot(data: jpeg, response: response(length: jpeg.count + 1), after: nil, now: { now }) }
        var clockReads = 0
        rejects(.staleFrame) {
            _ = try connection.decodeSnapshot(data: jpeg, response: jpegResponse, after: nil, now: {
                clockReads += 1; return clockReads == 1 ? now : now.addingTimeInterval(3.001)
            })
        }
        verify(clockReads == 2, "Freshness rechecked after actual image decode")
        rejects(.staleFrame) { try MeshManagedCameraConnection.verifyFreshness(capturedAt: decoded.capturedAt, now: now.addingTimeInterval(4), after: nil) }

        let prepared = Data(#"{"ready":true,"captureActive":false,"fresh":false}"#.utf8)
        func health(_ data: Data, changes: [String: String] = [:]) throws -> MeshManagedCameraConnection.Health {
            var headers = changes; headers["Content-Type"] = "application/json"
            return try connection.verifyHealth(response: response(url: connection.healthURL, length: data.count, changes: headers), data: data)
        }
        let initial = try health(prepared)
        verify(initial.ready && !initial.captureActive && !initial.fresh, "Prepared listener never masquerades as capture")
        let active = try health(Data(#"{"ready":true,"captureActive":true,"fresh":true}"#.utf8))
        verify(active.captureActive && active.fresh, "Health exposes typed runtime fields without inventing first-frame receipt")
        for body in [#"{"ready":1,"captureActive":false,"fresh":false}"#,
                     #"{"ready":true,"captureActive":false}"#,
                     #"{"ready":true,"captureActive":false,"fresh":false,"token":"x"}"#,
                     #"{"ready":true,"captureActive":false,"fresh":true}"#,
                     #"{"ready":false,"captureActive":true,"fresh":false}"#,
                     "[]", "not json", String(repeating: "x", count: 1025)] {
            rejects { _ = try health(Data(body.utf8)) }
        }
        rejects(.identityMismatch) { _ = try health(prepared, changes: ["X-Mesh-Camera-Generation": UUID().uuidString]) }
        rejects(.invalidResponse) { _ = try connection.verifyHealth(response: response(), data: prepared) }
        print("PASS: \(checks) managed camera checks; synthetic bytes only; no network, camera, TCC or audio")
    }
}
