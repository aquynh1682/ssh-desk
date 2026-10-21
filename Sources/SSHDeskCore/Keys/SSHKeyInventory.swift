import Darwin
import Foundation

/// Một cặp key trong thư mục SSH (mặc định `~/.ssh`). Không bao giờ chứa nội dung private key.
public struct SSHKeyInfo: Sendable, Equatable, Identifiable {
    /// Tên file không có `.pub`.
    public var name: String
    public var publicKeyPath: String
    /// Đường dẫn file private nếu tồn tại (chỉ kiểm tra tồn tại, không đọc).
    public var privateKeyPath: String?
    /// Loại key theo `ssh-keygen -l` (ED25519, RSA, ECDSA...). nil nếu không đọc được (vd symlink).
    public var type: String?
    public var bits: Int?
    public var fingerprint: String?
    public var comment: String?
    /// File `.pub` hoặc private là symbolic link: app không đi theo link.
    public var isSymlink: Bool
    /// Cảnh báo hiển thị (quyền private rộng, thiếu private...). Rỗng = không có.
    public var warnings: [String]

    public var id: String { name }
    public var hasPrivateKey: Bool { privateKeyPath != nil }

    /// "ED25519 256" hoặc "—".
    public var typeText: String {
        guard let type else { return "—" }
        return bits.map { "\(type) \($0)" } ?? type
    }
}

/// Kết quả parse một dòng `ssh-keygen -l`.
public struct SSHKeygenFingerprint: Sendable, Equatable {
    public var bits: Int
    public var fingerprint: String
    public var comment: String?
    public var type: String
}

/// Liệt kê key trong một thư mục (inject để test). Chỉ đọc file `*.pub` (qua `ssh-keygen -l`);
/// private key chỉ được kiểm tra tồn tại + quyền, KHÔNG đọc nội dung (ADR-014).
public struct SSHKeyInventory: Sendable {
    public static let keygenPath = "/usr/bin/ssh-keygen"
    public static let maxPublicKeyBytes = 16 * 1024

    public let directory: URL
    private let keygen: String
    private let timeout: TimeInterval

    public init(
        directory: URL = SSHKeyInventory.defaultDirectory, keygenPath: String = keygenPath,
        timeout: TimeInterval = 10
    ) {
        self.directory = directory
        self.keygen = keygenPath
        self.timeout = timeout
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
    }

    /// `256 SHA256:abc... comment (ED25519)`. Chỉ dòng đầu. Comment "no comment" → nil.
    public static func parseKeygenLine(_ output: String) -> SSHKeygenFingerprint? {
        guard let line = output.split(whereSeparator: \.isNewline).first.map(String.init) else {
            return nil
        }
        let pattern = #"^(\d+) (SHA256:\S+|MD5:\S+) (.*) \(([A-Za-z0-9-]+)\)$"#
        guard let re = try? NSRegularExpression(pattern: pattern),
            let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
            m.numberOfRanges == 5,
            let r1 = Range(m.range(at: 1), in: line), let r2 = Range(m.range(at: 2), in: line),
            let r3 = Range(m.range(at: 3), in: line), let r4 = Range(m.range(at: 4), in: line),
            let bits = Int(line[r1])
        else { return nil }
        let comment = String(line[r3]).trimmingCharacters(in: .whitespaces)
        return SSHKeygenFingerprint(
            bits: bits, fingerprint: String(line[r2]),
            comment: (comment.isEmpty || comment == "no comment") ? nil : comment,
            type: String(line[r4]))
    }

    /// Mọi cặp key (có `.pub` hợp lệ), sắp theo tên. Thư mục không tồn tại → rỗng.
    public func list() async -> [SSHKeyInfo] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [SSHKeyInfo] = []
        for file in names.sorted() {
            guard file.hasSuffix(".pub"), file != ".pub", !file.hasSuffix("-cert.pub") else { continue }
            let name = String(file.dropLast(4))
            let pubPath = directory.appendingPathComponent(file).path
            let privPath = directory.appendingPathComponent(name).path
            guard let pubStat = Self.lstatInfo(pubPath) else { continue }
            let pubIsLink = pubStat.isSymlink
            // Chỉ nhận file thường (hoặc symlink, ghi nhận là link).
            guard pubIsLink || pubStat.isRegular else { continue }

            let privStat = Self.lstatInfo(privPath)
            let privIsLink = privStat?.isSymlink ?? false
            var info = SSHKeyInfo(
                name: name, publicKeyPath: pubPath,
                privateKeyPath: (privStat != nil && (privStat!.isRegular || privIsLink)) ? privPath : nil,
                type: nil, bits: nil, fingerprint: nil, comment: nil,
                isSymlink: pubIsLink || privIsLink, warnings: [])

            if pubIsLink {
                info.warnings.append("Là symbolic link — app không đi theo link")
            } else {
                guard pubStat.size <= Self.maxPublicKeyBytes, let fp = await fingerprint(ofPublicKey: pubPath)
                else { continue }  // không phải key
                info.type = fp.type
                info.bits = fp.bits
                info.fingerprint = fp.fingerprint
                info.comment = fp.comment
            }
            if let privStat {
                if privIsLink {
                    info.warnings.append("Private key là symbolic link — không kiểm tra quyền")
                } else if privStat.isRegular, let w = Self.permissionWarning(mode: privStat.mode) {
                    info.warnings.append(w)
                }
            } else {
                info.warnings.append("Không có private key cùng tên")
            }
            result.append(info)
        }
        return result
    }

    /// `ssh-keygen -l -f <pub>`; nil nếu không phải key / lỗi / quá thời gian.
    func fingerprint(ofPublicKey path: String) async -> SSHKeygenFingerprint? {
        guard
            let out = try? await SimpleProcess.run(
                executable: keygen, arguments: ["-l", "-f", path],
                environment: ProcessEnvironment.inherited(), timeout: timeout),
            out.status == 0, !out.timedOut
        else { return nil }
        return Self.parseKeygenLine(out.stdout)
    }

    /// Cảnh báo nếu quyền rộng hơn 0600 (có bit nào ngoài rw của chủ).
    public static func permissionWarning(mode: UInt16) -> String? {
        let perm = mode & 0o7777
        guard perm & ~UInt16(0o600) != 0 else { return nil }
        return "Quyền private key \(String(perm, radix: 8)) rộng hơn 0600"
    }

    /// Nội dung public key (một dòng) để copy. Từ chối symlink, file không phải `.pub` trong thư mục
    /// này, file quá lớn. Public key không phải bí mật; hàm này không bao giờ đọc private key.
    public func publicKeyText(_ key: SSHKeyInfo) -> String? {
        let url = URL(fileURLWithPath: key.publicKeyPath)
        guard url.pathExtension == "pub",
            url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path,
            let st = Self.lstatInfo(url.path), st.isRegular, st.size <= Self.maxPublicKeyBytes,
            let data = try? Data(contentsOf: url)
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).first else { return nil }
        return line.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - lstat

    struct StatInfo {
        var mode: UInt16
        var size: Int
        var isSymlink: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFLNK) }
        var isRegular: Bool { mode & UInt16(S_IFMT) == UInt16(S_IFREG) }
    }

    static func lstatInfo(_ path: String) -> StatInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return StatInfo(mode: UInt16(st.st_mode), size: Int(st.st_size))
    }
}
