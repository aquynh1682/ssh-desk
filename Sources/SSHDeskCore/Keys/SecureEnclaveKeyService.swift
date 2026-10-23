import Darwin
import Foundation

/// Một identity Secure Enclave (CryptoTokenKit) trong keychain, từ `sc_auth list-ctk-identities`.
public struct SecureEnclaveIdentity: Sendable, Equatable, Identifiable {
    public var label: String
    /// SHA1 (40 hex, chữ hoa) của public key: dùng cho `delete-ctk-identity -h`.
    public var sha1: String
    /// `p-256-ne`...
    public var keyType: String
    /// `none` / `bio`...
    public var protection: String
    public var id: String { sha1 }

    /// Identity do app tạo/quản lý được: p-256-ne và nhãn hợp lệ. Còn lại chỉ xem (tạo ngoài app).
    public var isManageable: Bool {
        keyType == "p-256-ne" && (try? SecureEnclaveKeyService.validateLabel(label)) != nil
    }
}

public enum SecureEnclaveProtection: String, Sendable, CaseIterable {
    case biometric = "bio"
    case none
}

public enum SecureEnclaveError: Error, Equatable, CustomStringConvertible {
    case unavailable
    case invalidLabel
    case labelInUse(String)
    case notFound(String)
    case fileExists(String)
    case commandFailed(String)
    /// Identity đã tạo nhưng bước xuất file handle lỗi: KHÔNG tự xoá, UI đề nghị xoá.
    case handleExportFailed(label: String, reason: String)
    /// `sc_auth delete-ctk-identity` báo xong nhưng identity vẫn còn (exit code không đáng tin).
    case deleteNotConfirmed(String)
    /// Nhiều identity cùng nhãn: không đoán xoá cái nào.
    case ambiguousLabel(label: String, count: Int)

    public var description: String {
        switch self {
        case .unavailable: return "Máy này không có Secure Enclave SSH (thiếu ssh-keychain.dylib hoặc sc_auth)."
        case .invalidLabel: return "Nhãn chỉ gồm chữ, số, `.`, `_`, `-` (1–64 ký tự)."
        case .labelInUse(let l): return "Đã có identity Secure Enclave tên “\(l)”."
        case .notFound(let l): return "Không thấy identity Secure Enclave “\(l)”."
        case .fileExists(let p): return "File đã tồn tại, app không ghi đè: \(p)"
        case .commandFailed(let r): return r
        case .handleExportFailed(let label, let reason):
            return
                "Đã tạo identity “\(label)” nhưng không xuất được file handle: \(reason) Có thể xoá identity này rồi tạo lại."
        case .ambiguousLabel(let l, let n):
            return "Có \(n) khoá cùng nhãn “\(l)” — hãy xoá bằng sc_auth (theo hash)."
        case .deleteNotConfirmed(let l):
            return "sc_auth không xoá được identity “\(l)” (vẫn còn trong danh sách)."
        }
    }
}

/// Nhận diện khoá Secure Enclave: `.pub` cạnh identityFile có loại `sk-ecdsa-sha2-nistp256@openssh.com`.
/// Chỉ đọc file `.pub`; không bao giờ đọc private key / file handle.
public enum SecureEnclaveKeyDetector {
    public static let keyType = "sk-ecdsa-sha2-nistp256@openssh.com"
    static let maxPublicBytes = 16 * 1024

    public static func isSecureEnclaveKey(identityFile: String, home: String = NSHomeDirectory()) -> Bool {
        let path = CredentialResolution.expandTilde(identityFile, home: home)
        guard path.hasPrefix("/"), !path.hasSuffix(".pub") else { return false }
        return isSecurityKeyPublicFile(path + ".pub")
    }

    /// `.pub` là file thường, ≤ 16 KB, từ đầu tiên của dòng đầu là loại sk-ecdsa.
    public static func isSecurityKeyPublicFile(_ pubPath: String) -> Bool {
        guard let st = SSHKeyInventory.lstatInfo(pubPath), st.isRegular, st.size <= maxPublicBytes,
            let data = FileManager.default.contents(atPath: pubPath)
        else { return false }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first else { return false }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) == keyType
    }
}

/// Tạo/liệt kê/xoá khoá SSH trong Secure Enclave qua `sc_auth` + `ssh-keychain.dylib` (ADR-027).
/// Không có shell; không đụng `~/.ssh/config`. Thư mục đích và đường dẫn công cụ tham số hoá để test.
public struct SecureEnclaveKeyService: Sendable {
    public static let dylibPath = "/usr/lib/ssh-keychain.dylib"
    public static let scAuthPath = "/usr/sbin/sc_auth"
    public static let handlePrefix = "id_ecdsa_sk_rk_"

    public let directory: URL
    private let dylib: String
    private let scAuth: String
    private let keygen: String
    private let helper: URL?
    private let environment: [String: String]
    private let tempBase: URL
    private let keygenTimeout: TimeInterval

    public init(
        directory: URL = SSHKeyInventory.defaultDirectory, dylibPath: String = dylibPath,
        scAuthPath: String = scAuthPath, keygenPath: String = SSHKeyInventory.keygenPath,
        helper: URL? = nil, environment: [String: String] = ProcessEnvironment.inherited(),
        tempBase: URL = FileManager.default.temporaryDirectory, keygenTimeout: TimeInterval = 90
    ) {
        self.directory = directory
        self.dylib = dylibPath
        self.scAuth = scAuthPath
        self.keygen = keygenPath
        self.helper = helper
        self.environment = environment
        self.tempBase = tempBase
        self.keygenTimeout = keygenTimeout
    }

    public var isAvailable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: dylib) && fm.isExecutableFile(atPath: scAuth)
    }

    // MARK: - Thuần

    public static func validateLabel(_ label: String) throws {
        guard label.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
            throw SecureEnclaveError.invalidLabel
        }
    }

    public static func handleName(label: String) -> String { handlePrefix + label }

    public func handlePath(label: String) -> String {
        directory.appendingPathComponent(Self.handleName(label: label)).path
    }

    /// Cả hai file (`handle` thường và `.pub` thường) có trong thư mục đích.
    public func hasHandleFiles(label: String) -> Bool {
        guard (try? Self.validateLabel(label)) != nil else { return false }
        let p = handlePath(label: label)
        return SSHKeyInventory.lstatInfo(p)?.isRegular == true
            && SSHKeyInventory.lstatInfo(p + ".pub")?.isRegular == true
    }

    /// Parse output `list-ctk-identities`. Dùng vị trí cột theo dòng tiêu đề (nhãn có thể chứa dấu cách);
    /// bỏ dòng lạ (SHA1 không phải 40 hex, thiếu cột).
    public static func parseList(_ output: String) -> [SecureEnclaveIdentity] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let header = lines.first(where: { $0.hasPrefix("Key Type") }),
            let labelStart = header.range(of: "Label")?.lowerBound,
            let labelEnd = header.range(of: "Common Name")?.lowerBound
        else { return [] }
        let labelFrom = header.distance(from: header.startIndex, to: labelStart)
        let labelTo = header.distance(from: header.startIndex, to: labelEnd)
        var result: [SecureEnclaveIdentity] = []
        for line in lines where !line.hasPrefix("Key Type") {
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 4, tokens[1].range(of: #"^[0-9A-Fa-f]{40}$"#, options: .regularExpression) != nil
            else { continue }
            let chars = Array(line)
            guard chars.count > labelFrom else { continue }
            let label = String(chars[labelFrom..<min(labelTo, chars.count)])
                .trimmingCharacters(in: .whitespaces)
            guard !label.isEmpty else { continue }
            result.append(
                SecureEnclaveIdentity(
                    label: label, sha1: tokens[1].uppercased(), keyType: tokens[0], protection: tokens[2]))
        }
        return result
    }

    // MARK: - Liệt kê

    public func list() async throws -> [SecureEnclaveIdentity] {
        guard isAvailable else { throw SecureEnclaveError.unavailable }
        let out = try await runSCAuth(["list-ctk-identities"])
        return Self.parseList(out.stdout)
    }

    // MARK: - Tạo

    /// Trả đường dẫn file handle trong thư mục đích.
    @discardableResult
    public func create(label: String, protection: SecureEnclaveProtection) async throws -> String {
        guard isAvailable else { throw SecureEnclaveError.unavailable }
        try Self.validateLabel(label)
        let handle = handlePath(label: label)
        for p in [handle, handle + ".pub"] where SSHKeyInventory.lstatInfo(p) != nil {
            throw SecureEnclaveError.fileExists(p)
        }
        if try await list().contains(where: { $0.label == label }) {
            throw SecureEnclaveError.labelInUse(label)
        }
        let out = try await runSCAuth([
            "create-ctk-identity", "-l", label, "-k", "p-256-ne", "-t", protection.rawValue, "-N", label,
        ])
        guard out.status == 0 else {
            throw SecureEnclaveError.commandFailed("sc_auth create-ctk-identity lỗi: \(Self.brief(out))")
        }
        guard try await list().contains(where: { $0.label == label }) else {
            throw SecureEnclaveError.commandFailed("sc_auth không tạo identity: \(Self.brief(out))")
        }
        do {
            try await exportHandle(label: label)
        } catch {
            throw SecureEnclaveError.handleExportFailed(label: label, reason: "\(error)")
        }
        return handle
    }

    private func exportHandle(label: String) async throws {
        let fm = FileManager.default
        let tmp = tempBase.appendingPathComponent("sshdesk-se-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: tmp) }

        try await runKeygenExport(in: tmp)

        let name = Self.handleName(label: label)
        let srcPriv = tmp.appendingPathComponent(name).path
        let srcPub = srcPriv + ".pub"
        guard SSHKeyInventory.lstatInfo(srcPriv)?.isRegular == true,
            SSHKeyInventory.lstatInfo(srcPub)?.isRegular == true
        else { throw SecureEnclaveError.commandFailed("ssh-keygen -K không xuất file \(name).") }
        guard SecureEnclaveKeyDetector.isSecurityKeyPublicFile(srcPub) else {
            throw SecureEnclaveError.commandFailed("File .pub xuất ra không phải khoá sk-ecdsa.")
        }

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: directory.path, isDirectory: &isDir) {
            guard isDir.boolValue else { throw SSHKeyError.directoryNotUsable(directory.path) }
        } else {
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let dstPriv = handlePath(label: label)
        let dstPub = dstPriv + ".pub"
        // link() không bao giờ ghi đè (EEXIST); sau đó xoá bản trong thư mục tạm.
        guard link(srcPriv, dstPriv) == 0 else {
            throw errno == EEXIST ? SecureEnclaveError.fileExists(dstPriv) : posixError("link")
        }
        guard link(srcPub, dstPub) == 0 else {
            let code = errno
            unlink(dstPriv)
            throw code == EEXIST ? SecureEnclaveError.fileExists(dstPub) : posixError("link")
        }
        chmod(dstPriv, 0o600)
        chmod(dstPub, 0o644)
    }

    private func posixError(_ what: String) -> SecureEnclaveError {
        .commandFailed("\(what) lỗi: \(String(cString: strerror(errno)))")
    }

    /// `ssh-keygen -w <dylib> -K` trong `cwd`, trả lời PIN/passphrase bằng Enter trống.
    private func runKeygenExport(in cwd: URL) async throws {
        let proc: PTYProcess
        do {
            proc = try PTYProcess.start(
                executable: URL(fileURLWithPath: keygen), arguments: ["-w", dylib, "-K"],
                environment: environment, helper: helper, currentDirectory: cwd)
        } catch {
            throw SecureEnclaveError.commandFailed("Không chạy được ssh-keygen: \(error)")
        }
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: UInt64(keygenTimeout * 1_000_000_000))
            if !Task.isCancelled { proc.cancel() }
        }
        defer { watchdog.cancel() }
        var detector = PromptDetector()
        var tail = ""
        var exit: ProcessExit = .cancelled
        var failure: String?
        for await event in proc.events {
            switch event {
            case .output(let text):
                tail = String((tail + text).suffix(600))
                guard failure == nil, let kind = detector.feed(text) else { continue }
                switch kind {
                case .passphrase:
                    proc.send("", redact: false)  // file handle không phải secret: passphrase trống
                case .unknown(let t) where t.lowercased().contains("pin"):
                    proc.send("", redact: false)
                case .hostKeyChanged, .hostKeyConfirm, .password, .keyboardInteractive, .unknown:
                    failure = "ssh-keygen hỏi điều app không xử lý được."
                    proc.cancel()
                }
            case .exit(let e): exit = e
            }
        }
        if let failure { throw SecureEnclaveError.commandFailed(failure) }
        guard case .exited(0) = exit else {
            let detail = PromptDetector.clip(String(tail.suffix(200)))
            throw SecureEnclaveError.commandFailed("ssh-keygen -K không thành công (\(exit)). \(detail)")
        }
    }

    // MARK: - Xoá

    /// Xoá identity (kiểm lại bằng list vì exit code không đáng tin) rồi xoá cặp file handle đúng tên.
    /// Trả danh sách file handle đã xoá.
    @discardableResult
    public func delete(label: String) async throws -> [String] {
        guard isAvailable else { throw SecureEnclaveError.unavailable }
        try Self.validateLabel(label)
        let matches = try await list().filter { $0.label == label }
        guard let identity = matches.first else { throw SecureEnclaveError.notFound(label) }
        guard matches.count == 1 else {
            throw SecureEnclaveError.ambiguousLabel(label: label, count: matches.count)
        }
        _ = try await runSCAuth(["delete-ctk-identity", "-h", identity.sha1])
        if try await list().contains(where: { $0.sha1 == identity.sha1 }) {
            throw SecureEnclaveError.deleteNotConfirmed(label)
        }
        return removeHandleFiles(label: label)
    }

    /// Chỉ xoá `id_ecdsa_sk_rk_<label>` và `.pub` là file thường (không symlink/thư mục).
    func removeHandleFiles(label: String) -> [String] {
        guard (try? Self.validateLabel(label)) != nil else { return [] }
        var removed: [String] = []
        let p = handlePath(label: label)
        for path in [p, p + ".pub"] {
            guard let st = SSHKeyInventory.lstatInfo(path), st.isRegular else { continue }
            if unlink(path) == 0 { removed.append(path) }
        }
        return removed
    }

    // MARK: - Nội bộ

    private func runSCAuth(_ args: [String]) async throws -> SimpleProcessOutput {
        do {
            let out = try await SimpleProcess.run(
                executable: scAuth, arguments: args, environment: environment, timeout: 30)
            if out.timedOut { throw SecureEnclaveError.commandFailed("sc_auth quá thời gian chờ.") }
            return out
        } catch let e as SecureEnclaveError {
            throw e
        } catch {
            throw SecureEnclaveError.commandFailed("Không chạy được sc_auth: \(error)")
        }
    }

    static func brief(_ out: SimpleProcessOutput) -> String {
        PromptDetector.clip(String((out.stderr + " " + out.stdout).suffix(300)))
    }
}
