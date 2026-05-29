import Foundation

/// Intercepts `URLSession.shared` traffic so adapter tests can assert the
/// request that was actually sent and feed back a canned response — no live
/// network. Register/unregister around each test; the static state means the
/// adapter suites run `.serialized`.
final class StubURLProtocol: URLProtocol {
    struct Stub {
        let statusCode: Int
        let data: Data
    }

    /// Canned response returned for the next request. Defaults to 200 + empty.
    nonisolated(unsafe) static var stub: Stub?
    /// The request as URLSession handed it to the loader.
    nonisolated(unsafe) static var lastRequest: URLRequest?
    /// The request body, read from the (possibly streamed) HTTP body.
    nonisolated(unsafe) static var lastBody: Data?

    static func reset() {
        stub = nil
        lastRequest = nil
        lastBody = nil
    }

    /// Only the AI provider hosts are intercepted, so registering the class
    /// globally can never capture another suite's traffic if it happens to run
    /// concurrently (Swift Testing parallelizes across suites).
    private static let interceptedHosts: Set<String> = [
        "api.anthropic.com",
        "api.openai.com",
        "generativelanguage.googleapis.com"
    ]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return interceptedHosts.contains(host)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.capturedBody

        let stub = Self.stub ?? Stub(statusCode: 200, data: Data())
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// URLSession converts `httpBody` to `httpBodyStream` by the time a request
    /// reaches the loader, so read whichever is present.
    var capturedBody: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
