import Foundation

public enum RDPRenderError: Error, Equatable {
    /// Giá trị chứa ký tự điều khiển (CR/LF...): không sinh file.
    case controlCharacter(field: String)
    case notWindowsHost
}

/// Sinh nội dung file `.rdp` (UTF-8, mỗi dòng `name:type:value`, kết thúc `\r\n`). Thuần logic.
/// Không bao giờ ghi password (ADR-017).
public enum RDPFileRenderer {
    /// Có ghi `username:s:` không. Đặt `false` nếu bản Windows App trên Mac bỏ qua/gây lỗi.
    public static let includeUsername = true

    public static func render(_ host: HostProfile, includeUsername: Bool = includeUsername) throws
        -> String
    {
        guard host.kind == .windowsRDP else { throw RDPRenderError.notWindowsHost }
        let user = host.rdpUsername
        let domain = host.rdpDomain ?? ""
        let gateway = host.rdpGateway ?? ""
        for (field, value) in [
            ("hostName", host.hostName), ("rdpUsername", user), ("rdpDomain", domain),
            ("rdpGateway", gateway),
        ] {
            let bad = value.unicodeScalars.contains {
                $0.value < 0x20 || $0.value == 0x7F || (0x80...0x9F).contains($0.value)
                    || $0.value == 0x2028 || $0.value == 0x2029
            }
            if bad { throw RDPRenderError.controlCharacter(field: field) }
        }

        var lines = ["full address:s:\(address(host.hostName, host.port))"]
        if includeUsername && !user.isEmpty { lines.append("username:s:\(user)") }
        if !domain.isEmpty { lines.append("domain:s:\(domain)") }
        lines.append("screen mode id:i:\(host.rdpScreenMode == .fullScreen ? 2 : 1)")
        lines.append("use multimon:i:\(host.rdpMultiMonitor ? 1 : 0)")
        lines.append("dynamic resolution:i:1")
        lines.append("redirectclipboard:i:\(host.rdpRedirectClipboard ? 1 : 0)")
        lines.append("audiomode:i:0")
        lines.append("enablecredsspsupport:i:1")
        if host.rdpAdminSession { lines.append("administrative session:i:1") }
        if !gateway.isEmpty {
            lines.append("gatewayhostname:s:\(gateway)")
            lines.append("gatewayusagemethod:i:1")
        }
        return lines.map { $0 + "\r\n" }.joined()
    }

    /// Port mặc định 3389 thì bỏ; IPv6 bọc `[ ]` khi có port.
    static func address(_ host: String, _ port: Int) -> String {
        if port == HostProfile.defaultRDPPort { return host }
        return (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }
}
