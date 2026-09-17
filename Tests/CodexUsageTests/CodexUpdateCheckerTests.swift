import Foundation
import Testing
@testable import CodexUsageCore

@Suite(.serialized)
struct CodexUpdateCheckerTests {
    @Test func checksLatestRelease() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let checker = CodexUpdateChecker(session: URLSession(configuration: configuration))

        StubURLProtocol.configure(
            statusCode: 200,
            data: Data(#"[{"tag_name":"v0.2.0","html_url":"https://github.com/zouzonghua/codex-usage/releases/tag/v0.2.0","prerelease":false}]"#.utf8))
        let update = try await checker.check(currentVersion: "v0.1.0-beta.9")
        #expect(update.isUpdateAvailable)
        #expect(update.latestVersion == "v0.2.0")
        #expect(update.releaseURL.absoluteString == "https://github.com/zouzonghua/codex-usage/releases/tag/v0.2.0")
    }

    @Test func reportsNoUpdateForTheLatestVersion() async throws {
        let checker = Self.makeChecker()
        StubURLProtocol.configure(
            statusCode: 200,
            data: Data(#"[{"tag_name":"v0.2.0","html_url":"https://github.com/zouzonghua/codex-usage/releases/tag/v0.2.0","prerelease":false}]"#.utf8))

        let update = try await checker.check(currentVersion: "0.2.0")
        #expect(!update.isUpdateAvailable)
    }

    @Test func checksLatestBetaRelease() async throws {
        let checker = Self.makeChecker()
        StubURLProtocol.configure(
            statusCode: 200,
            data: Data(#"[{"tag_name":"v0.1.0-beta.9","html_url":"https://github.com/zouzonghua/codex-usage/releases/tag/v0.1.0-beta.9","prerelease":true}]"#.utf8))

        let update = try await checker.check(currentVersion: "v0.1.0-beta.8")
        #expect(update.isUpdateAvailable)
        #expect(update.latestVersion == "v0.1.0-beta.9")
    }

    @Test func stableReleaseIsNewerThanPrerelease() async throws {
        let checker = Self.makeChecker()
        StubURLProtocol.configure(
            statusCode: 200,
            data: Data(#"[{"tag_name":"v0.1.0-beta.9","html_url":"https://github.com/zouzonghua/codex-usage/releases/tag/v0.1.0-beta.9","prerelease":true},{"tag_name":"v0.1.0","html_url":"https://github.com/zouzonghua/codex-usage/releases/tag/v0.1.0","prerelease":false}]"#.utf8))

        let update = try await checker.check(currentVersion: "v0.1.0-beta.9")
        #expect(update.isUpdateAvailable)
        #expect(update.latestVersion == "v0.1.0")
    }

    @Test func rejectsMalformedReleaseResponse() async throws {
        let checker = Self.makeChecker()

        StubURLProtocol.configure(statusCode: 200, data: Data("not-json".utf8))
        do {
            _ = try await checker.check(currentVersion: "0.1.0")
            Issue.record("Malformed release data should fail")
        } catch let error as CodexUpdateError {
            #expect(error == .invalidResponse)
        }

    }

    @Test func reportsReleaseServerError() async throws {
        let checker = Self.makeChecker()
        StubURLProtocol.configure(statusCode: 503, data: Data())
        do {
            _ = try await checker.check(currentVersion: "0.1.0")
            Issue.record("A server error should fail")
        } catch let error as CodexUpdateError {
            #expect(error == .server(503))
        }
    }

    @Test func reportsNetworkError() async throws {
        let checker = Self.makeChecker()
        StubURLProtocol.configure(
            statusCode: 200,
            data: Data(),
            error: URLError(.notConnectedToInternet))
        do {
            _ = try await checker.check(currentVersion: "0.1.0")
            Issue.record("A network error should fail")
        } catch let error as CodexUpdateError {
            if case .network = error {} else { Issue.record("Expected a network error") }
        }
    }

    @Test func treatsCancellationAsCancellation() async throws {
        let checker = Self.makeChecker()
        StubURLProtocol.configure(statusCode: 200, data: Data(), error: URLError(.cancelled))
        do {
            _ = try await checker.check(currentVersion: "0.1.0")
            Issue.record("A cancelled request should fail with cancellation")
        } catch is CancellationError {
            return
        } catch {
            Issue.record("Expected CancellationError")
        }
    }

    @Test func rejectsInvalidCurrentVersion() async throws {
        let checker = Self.makeChecker()
        do {
            _ = try await checker.check(currentVersion: "development")
            Issue.record("An invalid current version should fail")
        } catch let error as CodexUpdateError {
            #expect(error == .invalidVersion)
        }
    }

    private static func makeChecker() -> CodexUpdateChecker {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return CodexUpdateChecker(session: URLSession(configuration: configuration))
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var responseData = Data()
    nonisolated(unsafe) private static var responseError: Error?
    private static let lock = NSLock()

    static func configure(statusCode: Int, data: Data, error: Error? = nil) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.statusCode = statusCode
        self.responseData = data
        self.responseError = error
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let statusCode = Self.statusCode
        let data = Self.responseData
        let error = Self.responseError
        Self.lock.unlock()

        if let error {
            self.client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: self.request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
