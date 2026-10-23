import Foundation

/// Lỗi đọc số liệu. Thông điệp hiển thị KHÔNG chứa header, body hay URL (ADR-028).
public enum MetricsError: Error, Equatable, LocalizedError {
    case timeout
    case tooLarge
    case redirectBlocked
    case unauthorized(status: Int)
    case httpStatus(Int)
    case tlsUntrusted
    case cannotConnect
    case network(code: Int)
    case invalidResponse
    /// Prometheus `errorType` hoặc mã lỗi Zabbix — không kèm nội dung do server gửi.
    case apiError(String)
    case noData
    case secretMissing
    case unsupportedVersion

    public var errorDescription: String? {
        switch self {
        case .timeout: return "Hết thời gian chờ (10 giây)."
        case .tooLarge: return "Phản hồi lớn hơn 5 MB — đã bỏ."
        case .redirectBlocked:
            return "Máy chủ chuyển hướng sang địa chỉ khác — app không theo. Dùng đúng URL cuối cùng (vd https)."
        case .unauthorized(let s):
            return s == 200
                ? "Token bị từ chối hoặc hết hạn — kiểm tra token."
                : "Bị từ chối (HTTP \(s)) — kiểm tra token/password."
        case .httpStatus(let s): return "Máy chủ trả HTTP \(s)."
        case .tlsUntrusted:
            return "Chứng chỉ TLS không được tin cậy. Với CA nội bộ, hãy tin cậy CA đó trong Keychain Access của macOS."
        case .cannotConnect: return "Không kết nối được tới máy chủ số liệu."
        case .network(let code): return "Lỗi mạng (mã \(code))."
        case .invalidResponse: return "Phản hồi không đúng định dạng mong đợi."
        case .apiError(let code): return "API trả lỗi (\(code))."
        case .noData: return "Không có số liệu cho máy này — kiểm tra mẫu instance/tên host."
        case .secretMissing: return "Chưa có token/password trong kho — nhập lại ở Cài đặt → Nguồn số liệu."
        case .unsupportedVersion: return "Phiên bản Zabbix không đọc được."
        }
    }

    /// Chuyển lỗi URLSession sang thông điệp an toàn.
    static func from(_ error: Error) -> MetricsError {
        if let e = error as? MetricsError { return e }
        guard let u = error as? URLError else {
            return .network(code: (error as NSError).code)
        }
        switch u.code {
        case .timedOut: return .timeout
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected:
            return .tlsUntrusted
        case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost,
            .dnsLookupFailed:
            return .cannotConnect
        case .httpTooManyRedirects: return .redirectBlocked
        default: return .network(code: u.errorCode)
        }
    }
}

public struct MetricsHTTPResponse: Sendable, Equatable {
    public var status: Int
    public var body: Data
}

/// Gửi một request HTTP và trả phản hồi 2xx (đã giới hạn kích thước). Mọi lỗi là `MetricsError`.
public protocol MetricsTransport: Sendable {
    func send(_ request: URLRequest) async throws -> MetricsHTTPResponse
}

/// Delegate của session: chặn mọi redirect (trả `nil` -> URLSession trả luôn phản hồi 3xx, không gửi tiếp;
/// đặc biệt https -> http hay sang host khác sẽ làm lộ Authorization) và gom body theo chunk với cap cứng.
/// Không cài hook `didReceive challenge`: kiểm TLS mặc định của hệ thống.
final class MetricsSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct Pending {
        var data = Data()
        var status = 0
        var failure: MetricsError?
        var continuation: CheckedContinuation<MetricsHTTPResponse, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private let maxBytes: Int

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func register(_ task: URLSessionTask, _ c: CheckedContinuation<MetricsHTTPResponse, Error>) {
        lock.lock()
        pending[task.taskIdentifier] = Pending(continuation: c)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        var failure: MetricsError?
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 0 {
            failure = .invalidResponse
        } else if (300..<400).contains(status) {
            failure = .redirectBlocked
        } else if status == 401 || status == 403 {
            failure = .unauthorized(status: status)
        } else if !(200..<300).contains(status) {
            failure = .httpStatus(status)
        } else if response.expectedContentLength > Int64(maxBytes) {
            failure = .tooLarge  // Content-Length khai báo quá lớn: bỏ ngay, không đọc body.
        }
        lock.lock()
        pending[dataTask.taskIdentifier]?.status = status
        pending[dataTask.taskIdentifier]?.failure = failure
        lock.unlock()
        completionHandler(failure == nil ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var over = false
        if var p = pending[dataTask.taskIdentifier] {
            p.data.append(data)
            if p.data.count > maxBytes {
                p.failure = .tooLarge
                p.data = Data()
                over = true
            }
            pending[dataTask.taskIdentifier] = p
        }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let p = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let p else { return }
        if let failure = p.failure {
            p.continuation.resume(throwing: failure)
        } else if let error {
            p.continuation.resume(throwing: MetricsError.from(error))
        } else {
            p.continuation.resume(returning: MetricsHTTPResponse(status: p.status, body: p.data))
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func set(_ t: URLSessionTask) {
        lock.lock()
        task = t
        let c = cancelled
        lock.unlock()
        if c { t.cancel() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}

/// Transport thật: URLSession ephemeral riêng, timeout 10 giây, tối đa 5 MB (đọc theo chunk), không cookie/cache.
public final class URLSessionMetricsTransport: MetricsTransport, @unchecked Sendable {
    public static let timeout: TimeInterval = 10
    public static let maxBytes = 5 * 1024 * 1024

    /// Internal để test kiểm cấu hình (TLS tối thiểu).
    let session: URLSession
    private let delegate: MetricsSessionDelegate

    /// `protocolClasses` chỉ để test (URLProtocol giả). `maxBytes` mặc định 5 MB.
    public init(protocolClasses: [AnyClass]? = nil, maxBytes: Int = URLSessionMetricsTransport.maxBytes) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = Self.timeout
        cfg.timeoutIntervalForResource = Self.timeout
        cfg.waitsForConnectivity = false
        // ADR-028b: Info.plist bật NSAllowsArbitraryLoads nên ATS không còn ép TLS tối thiểu -> tự ép ở đây.
        cfg.tlsMinimumSupportedProtocolVersion = .TLSv12
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        if let protocolClasses { cfg.protocolClasses = protocolClasses }
        delegate = MetricsSessionDelegate(maxBytes: maxBytes)
        session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.finishTasksAndInvalidate() }

    public func send(_ request: URLRequest) async throws -> MetricsHTTPResponse {
        var request = request
        request.timeoutInterval = Self.timeout
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<MetricsHTTPResponse, Error>) in
                let task = session.dataTask(with: request)
                delegate.register(task, c)
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Áp xác thực lên request vào lúc gửi. Bí mật chỉ đọc từ `CredentialStore` ở đây và đặt vào header.
enum MetricsAuth {
    static func secret(for source: MetricsSource, credentials: (any CredentialStore)?) throws -> String? {
        guard let ref = source.credentialRef else { return nil }
        guard let secret = credentials?.read(ref: ref), !secret.isEmpty else {
            throw MetricsError.secretMissing
        }
        // Kiểm lại lúc gửi: CR/LF hay ký tự điều khiển trong secret sẽ thành header injection.
        guard (try? MetricSourceService.validateSecret(secret, kind: source.authKind)) != nil else {
            throw MetricsError.secretMissing
        }
        return secret
    }

    /// Bearer/Basic -> header `Authorization`. `includeBearer == false` dùng cho Zabbix cũ (token đi trong body).
    static func apply(
        to request: inout URLRequest, source: MetricsSource, credentials: (any CredentialStore)?,
        includeBearer: Bool = true
    ) throws {
        switch source.authKind {
        case .none:
            return
        case .bearer:
            guard includeBearer else { return }
            guard let token = try secret(for: source, credentials: credentials) else { return }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        case .basic:
            guard let password = try secret(for: source, credentials: credentials) else { return }
            let pair = Data("\(source.basicUser ?? ""):\(password)".utf8).base64EncodedString()
            request.setValue("Basic " + pair, forHTTPHeaderField: "Authorization")
        }
    }
}
