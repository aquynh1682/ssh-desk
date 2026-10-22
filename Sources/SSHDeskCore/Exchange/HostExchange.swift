import Darwin
import Foundation

/// Lỗi đọc/ghi file xuất-nhập (ADR-020). Thông điệp tiếng Việt, không chứa nội dung file.
public enum HostExchangeError: Error, Equatable, CustomStringConvertible {
    case fileTooLarge(limit: Int)
    case notRegularFile
    case unreadable(String)
    case notJSON
    case wrongFormat
    case unsupportedVersion(Int)
    case tooManyHosts(limit: Int)
    case writeFailed(String)

    public var description: String {
        switch self {
        case .fileTooLarge(let limit): return "File quá lớn (tối đa \(limit / 1_048_576) MB)."
        case .notRegularFile: return "Đường dẫn không phải file thường."
        case .unreadable(let s): return "Không đọc được file: \(s)"
        case .notJSON: return "File không phải JSON hợp lệ của SSH Desk."
        case .wrongFormat: return "File không phải danh sách máy chủ của SSH Desk."
        case .unsupportedVersion(let v):
            return "File thuộc phiên bản định dạng \(v), app này chỉ hiểu phiên bản \(HostExchange.version)."
        case .tooManyHosts(let limit): return "File có quá nhiều máy chủ (tối đa \(limit))."
        case .writeFailed(let s): return "Không ghi được file: \(s)"
        }
    }
}

/// Cách xử lý máy trùng (cùng loại + host + port + user).
public enum DuplicateHandling: String, Sendable, CaseIterable {
    /// Bỏ qua (mặc định).
    case skip
    /// Nhập thành bản sao (tên thêm “(bản sao)”).
    case copy
}

/// Một máy chủ trong file. Mọi giá trị enum là chuỗi để một giá trị lạ chỉ làm hỏng đúng máy đó.
/// Không có trường nào cho password / credentialReference.
struct ExchangeHost: Codable, Equatable {
    struct Bookmark: Codable, Equatable {
        var name: String
        var path: String
    }
    struct RDP: Codable, Equatable {
        var username: String
        var domain: String?
        var gateway: String?
        var screenMode: String
        var multiMonitor: Bool
        var redirectClipboard: Bool
        var adminSession: Bool
    }
    struct Forward: Codable, Equatable {
        var name: String
        var localPort: Int
        var remoteHost: String
        var remotePort: Int
    }

    var id: String
    var displayName: String
    var folder: String
    var environment: String
    var tags: [String]
    var notes: String
    var isFavorite: Bool
    var kind: String
    var connectionMode: String
    var hostName: String
    var port: Int
    var user: String
    var authMethod: String
    var identityFile: String?
    var jumpHostId: String?
    var sshConfigPath: String?
    var sshConfigAlias: String?
    var bookmarks: [Bookmark]
    var defaultLocalDirectory: String
    var defaultRemoteDirectory: String
    var rdp: RDP?
    /// Máy này có mật khẩu lưu ở nơi xuất → sau khi nhập phải nhập lại (mật khẩu không nằm trong file).
    var needsReauth: Bool
    var portForwards: [Forward]

    init(
        id: String, displayName: String, folder: String, environment: String, tags: [String],
        notes: String, isFavorite: Bool, kind: String, connectionMode: String, hostName: String,
        port: Int, user: String, authMethod: String, identityFile: String?, jumpHostId: String?,
        sshConfigPath: String?, sshConfigAlias: String?, bookmarks: [Bookmark],
        defaultLocalDirectory: String, defaultRemoteDirectory: String, rdp: RDP?,
        needsReauth: Bool, portForwards: [Forward]
    ) {
        self.id = id
        self.displayName = displayName
        self.folder = folder
        self.environment = environment
        self.tags = tags
        self.notes = notes
        self.isFavorite = isFavorite
        self.kind = kind
        self.connectionMode = connectionMode
        self.hostName = hostName
        self.port = port
        self.user = user
        self.authMethod = authMethod
        self.identityFile = identityFile
        self.jumpHostId = jumpHostId
        self.sshConfigPath = sshConfigPath
        self.sshConfigAlias = sshConfigAlias
        self.bookmarks = bookmarks
        self.defaultLocalDirectory = defaultLocalDirectory
        self.defaultRemoteDirectory = defaultRemoteDirectory
        self.rdp = rdp
        self.needsReauth = needsReauth
        self.portForwards = portForwards
    }

    // Trường không bắt buộc có mặc định, để file viết tay/ít trường vẫn đọc được.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? ""
        environment = try c.decodeIfPresent(String.self, forKey: .environment) ?? "OTHER"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "ssh"
        connectionMode = try c.decodeIfPresent(String.self, forKey: .connectionMode) ?? "managed"
        hostName = try c.decodeIfPresent(String.self, forKey: .hostName) ?? ""
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 22
        user = try c.decodeIfPresent(String.self, forKey: .user) ?? ""
        authMethod = try c.decodeIfPresent(String.self, forKey: .authMethod) ?? "agent"
        identityFile = try c.decodeIfPresent(String.self, forKey: .identityFile)
        jumpHostId = try c.decodeIfPresent(String.self, forKey: .jumpHostId)
        sshConfigPath = try c.decodeIfPresent(String.self, forKey: .sshConfigPath)
        sshConfigAlias = try c.decodeIfPresent(String.self, forKey: .sshConfigAlias)
        bookmarks = try c.decodeIfPresent([Bookmark].self, forKey: .bookmarks) ?? []
        defaultLocalDirectory = try c.decodeIfPresent(String.self, forKey: .defaultLocalDirectory) ?? ""
        defaultRemoteDirectory = try c.decodeIfPresent(String.self, forKey: .defaultRemoteDirectory) ?? ""
        rdp = try c.decodeIfPresent(RDP.self, forKey: .rdp)
        needsReauth = try c.decodeIfPresent(Bool.self, forKey: .needsReauth) ?? false
        portForwards = try c.decodeIfPresent([Forward].self, forKey: .portForwards) ?? []
    }

    private enum Key: String, CodingKey {
        case id, displayName, folder, environment, tags, notes, isFavorite, kind, connectionMode
        case hostName, port, user, authMethod, identityFile, jumpHostId, sshConfigPath
        case sshConfigAlias, bookmarks, defaultLocalDirectory, defaultRemoteDirectory, rdp
        case needsReauth, portForwards
    }
}

/// Nội dung file đã giải mã (chưa kiểm hợp lệ từng máy).
public struct ExchangeFile: Sendable, Equatable {
    var folders: [String]
    var hosts: [ExchangeHost]
    public var exportedAt: String

    public var hostCount: Int { hosts.count }
}

struct ExchangeEnvelope: Codable {
    var format: String
    var version: Int
    var exportedAt: String
    var folders: [String]
    var hosts: [ExchangeHost]
}

/// Xuất / nhập danh sách máy chủ (ADR-020). Thuần: không chạm DB, Keychain hay mạng.
public enum HostExchange {
    public static let formatName = "sshdesk-hosts"
    public static let version = 1
    public static let maxFileBytes = 5 * 1_048_576
    public static let maxHosts = 5000
    public static let maxForwardsPerHost = 100
    public static let fileExtension = "sshdesk.json"

    // MARK: - Xuất

    /// Máy được xuất = `selected` + mọi bastion (jump host) mà chúng cần (bắc cầu), để quan hệ bastion không mất.
    public static func exportSet(selected: [HostProfile], all: [HostProfile]) -> [HostProfile] {
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var ids = Set<UUID>()
        var order: [UUID] = []
        func add(_ h: HostProfile) {
            var cur: HostProfile? = h
            while let c = cur, ids.insert(c.id).inserted {
                order.append(c.id)
                cur = c.jumpHostID.flatMap { byID[$0] }
            }
        }
        for h in selected { add(h) }
        return order.compactMap { byID[$0] }
    }

    /// Dựng JSON. `needsReauth`: id các máy đang có mật khẩu lưu (chỉ để đánh dấu, không kèm mật khẩu).
    /// KHÔNG BAO GIỜ ghi `credentialReference`/mật khẩu: DTO không có trường đó.
    public static func export(
        hosts: [HostProfile], forwards: [PortForward], folders: [String],
        needsReauth: Set<UUID> = [], now: Date = Date()
    ) throws -> Data {
        let ids = Set(hosts.map(\.id))
        let byHost = Dictionary(grouping: forwards.filter { ids.contains($0.hostID) }, by: \.hostID)
        let rows = hosts.map { h -> ExchangeHost in
            var rdp: ExchangeHost.RDP?
            if h.kind == .windowsRDP {
                rdp = ExchangeHost.RDP(
                    username: h.rdpUsername, domain: h.rdpDomain, gateway: h.rdpGateway,
                    screenMode: h.rdpScreenMode.rawValue, multiMonitor: h.rdpMultiMonitor,
                    redirectClipboard: h.rdpRedirectClipboard, adminSession: h.rdpAdminSession)
            }
            return ExchangeHost(
                id: h.id.uuidString.lowercased(), displayName: h.displayName, folder: h.project,
                environment: h.environment.rawValue, tags: h.tags, notes: h.notes,
                isFavorite: h.isFavorite, kind: h.kind.rawValue,
                connectionMode: h.connectionMode.rawValue, hostName: h.hostName, port: h.port,
                user: h.user, authMethod: h.authMethod.rawValue, identityFile: h.identityFile,
                // Bastion ngoài tập xuất: bỏ liên kết (người gọi nên dùng exportSet để kèm bastion).
                jumpHostId: h.jumpHostID.flatMap { ids.contains($0) ? $0.uuidString.lowercased() : nil },
                sshConfigPath: h.sshConfigPath, sshConfigAlias: h.sshConfigAlias,
                bookmarks: h.remoteBookmarks.map { .init(name: $0.name, path: $0.path) },
                defaultLocalDirectory: h.defaultLocalDirectory,
                defaultRemoteDirectory: h.defaultRemoteDirectory, rdp: rdp,
                needsReauth: needsReauth.contains(h.id),
                portForwards: (byHost[h.id] ?? []).sorted { $0.localPort < $1.localPort }.map {
                    .init(
                        name: $0.name, localPort: $0.localPort, remoteHost: $0.remoteHost,
                        remotePort: $0.remotePort)
                })
        }
        let folderNames = HostFolders.sortedUnique(folders + hosts.map(\.project))
        let envelope = ExchangeEnvelope(
            format: formatName, version: version, exportedAt: isoString(now), folders: folderNames,
            hosts: rows)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(envelope)
    }

    private static func isoString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    // MARK: - Đọc

    /// Giải mã dữ liệu. Từ chối file > 5 MB, không phải JSON, sai `format`, `version` lạ, quá nhiều máy.
    public static func decode(_ data: Data) throws -> ExchangeFile {
        guard data.count <= maxFileBytes else { throw HostExchangeError.fileTooLarge(limit: maxFileBytes) }
        struct Probe: Decodable {
            var format: String?
            var version: Int?
        }
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(Probe.self, from: data) else {
            throw HostExchangeError.notJSON
        }
        guard probe.format == formatName else { throw HostExchangeError.wrongFormat }
        guard let v = probe.version else { throw HostExchangeError.wrongFormat }
        guard v == version else { throw HostExchangeError.unsupportedVersion(v) }
        guard let env = try? decoder.decode(ExchangeEnvelope.self, from: data) else {
            throw HostExchangeError.notJSON
        }
        guard env.hosts.count <= maxHosts else { throw HostExchangeError.tooManyHosts(limit: maxHosts) }
        return ExchangeFile(folders: env.folders, hosts: env.hosts, exportedAt: env.exportedAt)
    }

    /// Đọc file: phải là file thường, ≤ 5 MB (kiểm cả lúc đọc, không tin kích thước khai báo).
    public static func read(from url: URL) throws -> ExchangeFile {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw HostExchangeError.unreadable("không thấy file") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw HostExchangeError.notRegularFile }
        guard st.st_size <= maxFileBytes else { throw HostExchangeError.fileTooLarge(limit: maxFileBytes) }
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            throw HostExchangeError.unreadable("không mở được")
        }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxFileBytes + 1)) ?? Data()
        return try decode(data)
    }

    // MARK: - Ghi file

    /// Ghi nguyên tử, quyền 0600: file tạm 0600 cùng thư mục rồi `rename`. Lỗi → không để file tạm lại.
    public static func write(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".sshdesk-export-\(UUID().uuidString).tmp")
        let fm = FileManager.default
        guard fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw HostExchangeError.writeFailed("không tạo được file tạm trong thư mục đích") }
        do {
            let fh = try FileHandle(forWritingTo: temp)
            defer { try? fh.close() }
            try fh.write(contentsOf: data)
            try fh.synchronize()
            chmod(temp.path, 0o600)
            guard rename(temp.path, url.path) == 0 else {
                throw HostExchangeError.writeFailed(String(cString: strerror(errno)))
            }
        } catch {
            try? fm.removeItem(at: temp)
            if let e = error as? HostExchangeError { throw e }
            throw HostExchangeError.writeFailed("\(error)")
        }
    }

    // MARK: - Xem trước / kế hoạch nhập

    public enum Outcome: Sendable, Equatable {
        /// Sẽ được thêm.
        case new
        /// Trùng máy đã có (hoặc trùng máy trước đó trong file). `existingID`: máy đã có trong app, nil nếu trùng trong file.
        case duplicate(existingID: UUID?)
        /// Không nhập được (lý do tiếng Việt).
        case invalid(String)
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public var id: String
        public var displayName: String
        public var subtitle: String
        public var outcome: Outcome
        /// Cảnh báo (bastion thiếu, forward bị bỏ, cần nhập lại mật khẩu...).
        public var warnings: [String]
        /// true nếu máy sẽ được ghi (mới, hoặc trùng + chế độ bản sao).
        public var willImport: Bool
    }

    public struct Plan: Sendable, Equatable {
        public var entries: [Entry]
        /// Máy sẽ ghi, theo thứ tự bastion trước máy dùng nó. Id là UUID MỚI.
        public var hosts: [HostProfile]
        public var forwards: [PortForward]
        public var foldersToCreate: [String]
        public var fileWarnings: [String]

        public var newCount: Int { entries.filter { $0.outcome == .new }.count }
        public var duplicateCount: Int {
            entries.filter { if case .duplicate = $0.outcome { return true } else { return false } }.count
        }
        public var invalidCount: Int {
            entries.filter { if case .invalid = $0.outcome { return true } else { return false } }.count
        }
        public var importCount: Int { hosts.count }
    }

    /// Khoá nhận biết trùng: cùng loại + host + port + user (RDP: user + domain); alias import: alias + file config.
    static func duplicateKey(_ h: HostProfile) -> String {
        func norm(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        if h.connectionMode == .existingSSHConfigAlias {
            return "alias|" + (h.sshConfigPath ?? "") + "|" + (h.sshConfigAlias ?? "")
        }
        let who = h.kind == .windowsRDP ? norm(h.rdpUsername) + "|" + norm(h.rdpDomain ?? "") : norm(h.user)
        return [h.kind.rawValue, norm(h.hostName), String(h.port), who].joined(separator: "|")
    }

    /// Chuyển một dòng trong file thành `HostProfile` (id mới) và kiểm bằng validator của form
    /// (`HostDraft`) + `HostProfile.validate()` + cấm ký tự điều khiển ở các trường tên/đường dẫn.
    static func convert(_ x: ExchangeHost, newID: UUID, now: Date) -> Result<HostProfile, ConvertError> {
        guard let env = HostEnvironment(rawValue: x.environment) else {
            return .failure(.init("Môi trường “\(clip(x.environment))” không hợp lệ."))
        }
        guard let kind = HostKind(rawValue: x.kind) else {
            return .failure(.init("Loại máy “\(clip(x.kind))” không hợp lệ."))
        }
        guard let mode = HostConnectionMode(rawValue: x.connectionMode) else {
            return .failure(.init("Kiểu kết nối “\(clip(x.connectionMode))” không hợp lệ."))
        }
        guard let auth = HostAuthMethod(rawValue: x.authMethod) else {
            return .failure(.init("Kiểu xác thực “\(clip(x.authMethod))” không hợp lệ."))
        }
        var screen = RDPScreenMode.fullScreen
        if let r = x.rdp {
            guard let s = RDPScreenMode(rawValue: r.screenMode) else {
                return .failure(.init("Chế độ màn hình RDP không hợp lệ."))
            }
            screen = s
        }
        if kind == .windowsRDP && mode == .existingSSHConfigAlias {
            return .failure(.init("Máy Windows không thể là alias SSH config."))
        }
        // Newline / ký tự điều khiển trong các trường một dòng (notes được phép xuống dòng).
        let singleLine: [(String, String)] =
            [
                ("tên", x.displayName), ("thư mục", x.folder), ("host", x.hostName), ("user", x.user),
                ("đường dẫn key", x.identityFile ?? ""), ("alias", x.sshConfigAlias ?? ""),
                ("đường dẫn SSH config", x.sshConfigPath ?? ""),
                ("thư mục local mặc định", x.defaultLocalDirectory),
                ("thư mục remote mặc định", x.defaultRemoteDirectory),
            ] + x.tags.map { ("tag", $0) }
            + x.bookmarks.flatMap { [("tên bookmark", $0.name), ("đường dẫn bookmark", $0.path)] }
        for (label, value) in singleLine where hasControl(value) {
            return .failure(.init("Trường \(label) chứa ký tự điều khiển hoặc xuống dòng."))
        }
        if x.notes.unicodeScalars.contains(where: { isControl($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }) {
            return .failure(.init("Ghi chú chứa ký tự điều khiển."))
        }
        if x.displayName.count > 200 || x.notes.count > 20_000 || x.tags.count > 100 || x.bookmarks.count > 200 {
            return .failure(.init("Dữ liệu quá dài."))
        }
        if !x.folder.isEmpty {
            do { _ = try HostFolders.normalize(x.folder) } catch {
                return .failure(.init("Tên thư mục không hợp lệ."))
            }
        }

        let profile = HostProfile(
            id: newID, displayName: x.displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            project: x.folder.trimmingCharacters(in: .whitespacesAndNewlines), environment: env,
            tags: HostDraft.parseTags(x.tags.joined(separator: ",")), notes: x.notes,
            isFavorite: x.isFavorite, connectionMode: mode, kind: kind,
            rdpUsername: x.rdp?.username ?? "", rdpDomain: x.rdp?.domain, rdpGateway: x.rdp?.gateway,
            rdpScreenMode: screen, rdpMultiMonitor: x.rdp?.multiMonitor ?? false,
            rdpRedirectClipboard: x.rdp?.redirectClipboard ?? true,
            rdpAdminSession: x.rdp?.adminSession ?? false, hostName: x.hostName, port: x.port,
            user: x.user, authMethod: auth, identityFile: x.identityFile, jumpHostID: nil,
            sshConfigPath: x.sshConfigPath, sshConfigAlias: x.sshConfigAlias, credentialReference: nil,
            remoteBookmarks: x.bookmarks.map { RemoteBookmark(name: $0.name, path: $0.path) },
            defaultLocalDirectory: x.defaultLocalDirectory,
            defaultRemoteDirectory: x.defaultRemoteDirectory, createdAt: now, updatedAt: now)

        // Validator của form: tin nhắn lỗi theo trường.
        let draft = HostDraft(host: profile)
        let base: HostProfile? = mode == .existingSSHConfigAlias ? profile : nil
        let problems = draft.errors(basedOn: base)
        if let first = problems.values.sorted().first { return .failure(.init(first)) }
        do { try profile.validate() } catch let e as HostValidationError {
            return .failure(.init(HostDraft.describe(e).1))
        } catch { return .failure(.init("Dữ liệu không hợp lệ.")) }
        return .success(profile)
    }

    struct ConvertError: Error, Equatable {
        var message: String
        init(_ m: String) { message = m }
    }

    /// Lập kế hoạch nhập (thuần). Trùng + `.skip` → bỏ qua; `.copy` → thêm bản sao đổi tên.
    /// Id luôn mới; jump host ánh xạ lại (thiếu/không hợp lệ → bỏ trống + cảnh báo);
    /// forward chỉ giữ khi hợp lệ và cổng local không đụng forward đã có / forward khác trong file.
    public static func plan(
        file: ExchangeFile, existingHosts: [HostProfile], existingFolders: [String],
        existingForwards: [PortForward], duplicates: DuplicateHandling = .skip,
        now: Date = Date(), makeID: () -> UUID = { UUID() }
    ) -> Plan {
        struct Row {
            var x: ExchangeHost
            var profile: HostProfile?
            var invalid: String?
            var duplicateOf: UUID??  // .some(nil) = trùng trong file
            var warnings: [String] = []
            var willImport = false
        }
        var rows: [Row] = []
        var fileWarnings: [String] = []

        // 1) Chuyển + kiểm hợp lệ + nhận biết trùng.
        var existingByKey: [String: UUID] = [:]
        for h in existingHosts { existingByKey[duplicateKey(h)] = existingByKey[duplicateKey(h)] ?? h.id }
        var seenInFile: [String: Int] = [:]
        var seenFileIDs = Set<String>()
        for x in file.hosts {
            var row = Row(x: x)
            if !seenFileIDs.insert(x.id.lowercased()).inserted {
                row.invalid = "Trùng id với một máy khác trong file."
            } else {
                switch convert(x, newID: makeID(), now: now) {
                case .failure(let e): row.invalid = e.message
                case .success(let p):
                    row.profile = p
                    let key = duplicateKey(p)
                    if let existing = existingByKey[key] {
                        row.duplicateOf = .some(existing)
                    } else if seenInFile[key] != nil {
                        row.duplicateOf = .some(nil)
                    }
                    if seenInFile[key] == nil { seenInFile[key] = rows.count }
                }
            }
            rows.append(row)
        }

        // 2) Quyết định ghi. Tên bản sao tránh trùng tên đã có / đã thêm.
        var names = existingHosts.map(\.displayName)
        for i in rows.indices {
            guard var p = rows[i].profile else { continue }
            if rows[i].duplicateOf != nil {
                guard duplicates == .copy else { continue }
                p.displayName = HostProfile.duplicateName(of: p.displayName, existingNames: names)
                rows[i].profile = p
            }
            rows[i].willImport = true
            names.append(p.displayName)
        }

        // 3) Ánh xạ jump host: id trong file → id mới (máy sẽ ghi) hoặc máy đã có (khi bỏ qua bản trùng).
        var fileIDToHost: [String: UUID] = [:]  // máy sẽ ghi
        var fileIDToExisting: [String: UUID] = [:]  // máy trùng bị bỏ qua → máy đã có
        for row in rows {
            guard let p = row.profile else { continue }
            let key = row.x.id.lowercased()
            if row.willImport {
                fileIDToHost[key] = p.id
            } else if case .some(.some(let e)) = row.duplicateOf {
                fileIDToExisting[key] = e
            }
        }
        let existingByID = Dictionary(existingHosts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var jumpOf: [UUID: UUID] = [:]
        for i in rows.indices where rows[i].willImport {
            guard var p = rows[i].profile, let ref = rows[i].x.jumpHostId, !ref.isEmpty else { continue }
            let key = ref.lowercased()
            if p.connectionMode == .existingSSHConfigAlias || p.kind != .ssh {
                rows[i].warnings.append("Bỏ qua bastion: loại máy này không dùng bastion của app.")
                continue
            }
            if let new = fileIDToHost[key] {
                jumpOf[p.id] = new
            } else if let old = fileIDToExisting[key], existingByID[old]?.kind == .ssh {
                jumpOf[p.id] = old
            } else {
                rows[i].warnings.append("Bastion không có trong file (hoặc không nhập được): để trống.")
                continue
            }
            p.jumpHostID = jumpOf[p.id]
            rows[i].profile = p
        }
        // Vòng lặp bastion → bỏ trống (cập nhật dần để chỉ cắt đúng chỗ cần).
        var writing = Dictionary(
            rows.compactMap { r in r.willImport ? r.profile.map { ($0.id, $0) } : nil },
            uniquingKeysWith: { a, _ in a })
        for i in rows.indices where rows[i].willImport {
            guard var p = rows[i].profile, let j = p.jumpHostID else { continue }
            var seen: Set<UUID> = [p.id]
            var cur: UUID? = j
            var cyclic = false
            while let c = cur {
                if !seen.insert(c).inserted {
                    cyclic = true
                    break
                }
                cur = writing[c]?.jumpHostID ?? existingByID[c]?.jumpHostID
            }
            if cyclic {
                p.jumpHostID = nil
                rows[i].profile = p
                writing[p.id] = p
                rows[i].warnings.append("Bastion tạo vòng lặp: để trống.")
            }
        }
        // Sắp xếp: bastion (trong tập ghi) trước máy dùng nó. Vòng lặp đã bị loại ở trên.
        var finalByID: [UUID: HostProfile] = [:]
        for r in rows where r.willImport { if let p = r.profile { finalByID[p.id] = p } }
        var ordered: [HostProfile] = []
        var placed = Set<UUID>()
        func place(_ id: UUID) {
            guard placed.insert(id).inserted, let p = finalByID[id] else { return }
            if let j = p.jumpHostID { place(j) }
            ordered.append(p)
        }
        for r in rows where r.willImport { if let p = r.profile { place(p.id) } }

        // 4) Port forward.
        var usedPorts = Set(existingForwards.map(\.localPort))
        var forwards: [PortForward] = []
        for i in rows.indices where rows[i].willImport {
            guard let p = rows[i].profile else { continue }
            let list = rows[i].x.portForwards
            if list.isEmpty { continue }
            if p.kind != .ssh {
                rows[i].warnings.append("Bỏ \(list.count) port forward: máy Windows không có forward.")
                continue
            }
            for f in list.prefix(maxForwardsPerHost) {
                let candidate = PortForward(
                    hostID: p.id, name: f.name, localPort: f.localPort, remoteHost: f.remoteHost,
                    remotePort: f.remotePort, createdAt: now)
                guard let v = try? candidate.validated() else {
                    rows[i].warnings.append("Bỏ port forward cổng \(f.localPort): giá trị không hợp lệ.")
                    continue
                }
                guard usedPorts.insert(v.localPort).inserted else {
                    rows[i].warnings.append(
                        "Bỏ port forward cổng \(v.localPort): cổng local đã được forward khác dùng.")
                    continue
                }
                forwards.append(v)
            }
            if list.count > maxForwardsPerHost {
                rows[i].warnings.append("Bỏ \(list.count - maxForwardsPerHost) port forward vượt giới hạn.")
            }
        }

        // 5) Cảnh báo mật khẩu + tổng hợp.
        for i in rows.indices where rows[i].willImport && rows[i].x.needsReauth {
            rows[i].warnings.append("Cần nhập lại mật khẩu (mật khẩu không nằm trong file).")
        }
        var entries: [Entry] = []
        for r in rows {
            let outcome: Outcome
            if let m = r.invalid {
                outcome = .invalid(m)
            } else if let d = r.duplicateOf {
                outcome = .duplicate(existingID: d)
            } else {
                outcome = .new
            }
            let name = r.profile?.displayName ?? r.x.displayName
            let sub = r.profile.map { HostPresentation.subtitle($0) } ?? ""
            entries.append(
                Entry(
                    id: r.x.id, displayName: name.isEmpty ? "(không tên)" : name, subtitle: sub,
                    outcome: outcome, warnings: r.warnings, willImport: r.willImport))
        }

        // 6) Thư mục cần tạo (khớp thư mục sẵn có không phân biệt hoa thường/dấu).
        var toCreate: [String] = []
        func want(_ raw: String) {
            guard let n = try? HostFolders.normalize(raw) else { return }
            if existingFolders.contains(where: { HostFolders.sameFolder($0, n) }) { return }
            if toCreate.contains(where: { HostFolders.sameFolder($0, n) }) { return }
            toCreate.append(n)
        }
        for f in file.folders where !f.isEmpty {
            if (try? HostFolders.normalize(f)) == nil {
                fileWarnings.append("Bỏ qua tên thư mục không hợp lệ.")
            } else {
                want(f)
            }
        }
        for h in ordered where !h.project.isEmpty { want(h.project) }
        // Dùng đúng cách viết của thư mục đã có.
        let canonical = existingFolders + toCreate
        let fixed = ordered.map { h -> HostProfile in
            var c = h
            if let m = canonical.first(where: { !h.project.isEmpty && HostFolders.sameFolder($0, h.project) }) {
                c.project = m
            }
            return c
        }
        return Plan(
            entries: entries, hosts: fixed, forwards: forwards,
            foldersToCreate: HostFolders.sortedUnique(toCreate), fileWarnings: fileWarnings)
    }

    // MARK: - Tiện ích

    private static func isControl(_ s: Unicode.Scalar) -> Bool { PortForward.isControl(s) }

    private static func hasControl(_ s: String) -> Bool { s.unicodeScalars.contains(where: isControl) }

    private static func clip(_ s: String) -> String {
        String(s.unicodeScalars.filter { !isControl($0) }.prefix(40).map(Character.init))
    }
}
