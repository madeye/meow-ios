import Foundation
import os

/// URLProtocol subclass that lets tests inject canned responses for
/// `URLSession` requests. Install before running tests that hit the
/// meow REST controller, subscription fetches, or DoH bootstrap.
///
/// Usage:
/// ```
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [URLProtocolStub.self]
/// let url = URL(string: "http://127.0.0.1:<port>/version")!
/// URLProtocolStub.stub(url, with: .init(statusCode: 200, body: Data(#"{"version":"test"}"#.utf8)))
/// defer { URLProtocolStub.removeStub(url) }
/// let session = URLSession(configuration: config)
/// ```
final class URLProtocolStub: URLProtocol {
    struct Response {
        var statusCode: Int
        var headers: [String: String]
        var body: Data
        var error: Error?

        init(statusCode: Int = 200,
             headers: [String: String] = ["Content-Type": "application/json"],
             body: Data = Data(),
             error: Error? = nil)
        {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
            self.error = error
        }
    }

    /// Keyed by exact URL — wildcards not supported. Lock-protected because
    /// Swift Testing runs tests concurrently in one process: each test must
    /// register unique URLs via `stub(_:with:)` and remove exactly those in
    /// a `defer` via `removeStub(_:)`. There is deliberately no global
    /// reset — the old `reset()`/`removeAll()` yanked stubs out from under
    /// unrelated in-flight tests, and tests sharing one URL raced each
    /// other's bodies (the DeepLinkImportConfirmation "# refreshed" flake).
    private static let responses = OSAllocatedUnfairLock<[URL: Response]>(initialState: [:])

    static func stub(_ url: URL, with response: Response) {
        responses.withLock { $0[url] = response }
    }

    static func removeStub(_ url: URL) {
        responses.withLock { $0[url] = nil }
    }

    private static func response(for url: URL) -> Response? {
        responses.withLock { $0[url] }
    }

    // swiftlint:disable static_over_final_class
    // NSURLProtocol's canInit/canonicalRequest are class methods; overrides can't switch to static.
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    // swiftlint:enable static_over_final_class

    override func startLoading() {
        guard let url = request.url, let response = Self.response(for: url) else {
            let message = "No stub for \(request.url?.absoluteString ?? "nil")"
            let err = NSError(domain: "URLProtocolStub", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: message])
            client?.urlProtocol(self, didFailWithError: err)
            return
        }

        if let error = response.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let httpResponse = HTTPURLResponse(url: url,
                                           statusCode: response.statusCode,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: response.headers)!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
