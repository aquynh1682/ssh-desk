import Foundation

@testable import SSHDeskCore

/// Kết quả giả cho một request.
enum StubReply {
    case response(status: Int, headers: [String: String] = [:], body: Data = Data())
    case redirect(status: Int, to: URL)
    case failure(URLError.Code)
}

/// Một request đã ghi lại (thân POST đọc từ stream).
struct SeenRequest {
    var url: URL
    var method: String
    var headers: [String: String]
    var body: Data
}

final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func withLock<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// URLProtocol giả, khoá theo `host` của URL nên các test chạy song song không đè nhau.
final class MetricsStubProtocol: URLProtocol, @unchecked Sendable {
    private struct Registry {
        var handlers: [String: @Sendable (SeenRequest) -> StubReply] = [:]
        var seen: [String: [SeenRequest]] = [:]
    }
    private static let registry = Locked(Registry())

    static func register(host: String, _ handler: @escaping @Sendable (SeenRequest) -> StubReply) {
        registry.withLock { $0.handlers[host] = handler }
    }

    static func seen(host: String) -> [SeenRequest] {
        registry.withLock { $0.seen[host] ?? [] }
    }

    static func newHost() -> String { "stub-\(UUID().uuidString.lowercased().prefix(8)).test" }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(buffer, count: n)
            }
            stream.close()
        }
        let seen = SeenRequest(
            url: url, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:],
            body: body)
        let handler = Self.registry.withLock { reg -> (@Sendable (SeenRequest) -> StubReply)? in
            reg.seen[host, default: []].append(seen)
            return reg.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(
                self, didFailWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost))
            return
        }
        switch handler(seen) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code.rawValue))
        case .redirect(let status, let target):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )!
            var next = URLRequest(url: target)
            next.allHTTPHeaderFields = request.allHTTPHeaderFields
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // Nếu client không theo, phản hồi 3xx trở thành phản hồi cuối (giống mạng thật).
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .response(let status, let headers, let data):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

func stubTransport(maxBytes: Int = URLSessionMetricsTransport.maxBytes) -> URLSessionMetricsTransport {
    URLSessionMetricsTransport(protocolClasses: [MetricsStubProtocol.self], maxBytes: maxBytes)
}

func jsonData(_ text: String) -> Data { Data(text.utf8) }

/// Vector Prometheus: mỗi phần tử (nhãn, giá trị chuỗi).
func promVector(_ items: [([String: String], String)]) -> Data {
    let result = items.map { labels, value -> [String: Any] in
        ["metric": labels, "value": [1_700_000_000.5, value]]
    }
    let obj: [String: Any] = ["status": "success", "data": ["resultType": "vector", "result": result]]
    return try! JSONSerialization.data(withJSONObject: obj)
}

func jsonBody(_ r: SeenRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]) ?? [:]
}
