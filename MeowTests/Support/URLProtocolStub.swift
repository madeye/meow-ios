import Foundation

/// URLProtocol subclass that lets tests inject canned responses for
/// `URLSession` requests. Install before running tests that hit the
/// mihomo REST controller, subscription fetches, or DoH bootstrap.
///
/// Usage:
/// ```
/// let config = URLSessionConfiguration.ephemeral
/// config.protocolClasses = [URLProtocolStub.self]
/// URLProtocolStub.responses[URL(string: "http://127.0.0.1:9090/version")!] =
///     .init(statusCode: 200, body: Data(#"{"version":"test"}"#.utf8))
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

    /// Keyed by URL. Wildcards not supported — populate exact URLs per test.
    nonisolated(unsafe) static var responses: [URL: Response] = [:]

    static func reset() {
        responses.removeAll()
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
        guard let url = request.url, let response = Self.responses[url] else {
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
