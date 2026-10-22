import Foundation
import Testing

@testable import SSHDeskCore

struct PasswordAutofillPolicyTests {
    private static func managed(
        user: String = "deploy", host: String = "web.example.com", jump: UUID? = nil,
        ref: String? = "ref-1"
    ) -> HostProfile {
        var h = managedHost(hostName: host, user: user, jump: jump)
        h.credentialReference = ref
        return h
    }

    private static func imported(ref: String? = "ref-2") -> HostProfile {
        var h = importedHost()
        h.credentialReference = ref
        return h
    }

    struct Row: Sendable {
        let name: String
        let host: HostProfile
        let prompt: PromptKind
        let alreadyFilled: Bool
        let expected: Bool
    }

    static let rows: [Row] = [
        Row(
            name: "managed khớp user@host", host: managed(),
            prompt: .password("deploy@web.example.com's password:"), alreadyFilled: false,
            expected: true),
        Row(
            name: "managed: host khác hoa thường vẫn khớp", host: managed(),
            prompt: .password("deploy@WEB.Example.COM's password:"), alreadyFilled: false,
            expected: true),
        Row(
            name: "managed: khoảng trắng cuối", host: managed(),
            prompt: .password("deploy@web.example.com's password:  "), alreadyFilled: false,
            expected: true),
        Row(
            name: "managed: prompt của bastion KHÔNG điền", host: managed(),
            prompt: .password("jump@10.0.0.1's password:"), alreadyFilled: false, expected: false),
        Row(
            name: "managed: user khác hoa thường không khớp", host: managed(),
            prompt: .password("Deploy@web.example.com's password:"), alreadyFilled: false,
            expected: false),
        Row(
            name: "managed: Password: trơn không khớp", host: managed(),
            prompt: .password("Password:"), alreadyFilled: false, expected: false),
        Row(
            name: "managed: host là hậu tố của host thật không khớp", host: managed(),
            prompt: .password("deploy@evilweb.example.com's password:"), alreadyFilled: false,
            expected: false),
        Row(
            name: "managed: user chứa @ phía trước không khớp", host: managed(),
            prompt: .password("x@deploy@web.example.com's password:"), alreadyFilled: false,
            expected: false),
        Row(
            name: "managed có bastion → không điền dù khớp", host: managed(jump: UUID()),
            prompt: .password("deploy@web.example.com's password:"), alreadyFilled: false,
            expected: false),
        Row(
            name: "đã điền một lần", host: managed(),
            prompt: .password("deploy@web.example.com's password:"), alreadyFilled: true,
            expected: false),
        Row(
            name: "không có credentialReference", host: managed(ref: nil),
            prompt: .password("deploy@web.example.com's password:"), alreadyFilled: false,
            expected: false),
        Row(
            name: "passphrase không bao giờ điền", host: managed(),
            prompt: .passphrase("Enter passphrase for key 'k':"), alreadyFilled: false,
            expected: false),
        Row(
            name: "mã xác thực không điền", host: managed(),
            prompt: .keyboardInteractive("Verification code:"), alreadyFilled: false,
            expected: false),
        Row(
            name: "imported: lần đầu điền", host: imported(),
            prompt: .password("anyone@somewhere's password:"), alreadyFilled: false,
            expected: true),
        Row(
            name: "imported: lần hai không điền", host: imported(),
            prompt: .password("anyone@somewhere's password:"), alreadyFilled: true,
            expected: false),
        Row(
            name: "imported không có ref", host: imported(ref: nil),
            prompt: .password("a@b's password:"), alreadyFilled: false, expected: false),
        Row(
            name: "user dài hơn 30 ký tự bị ssh cắt", host: managed(user: String(repeating: "u", count: 40)),
            prompt: .password(String(repeating: "u", count: 30) + "@web.example.com's password:"),
            alreadyFilled: false, expected: true),
        Row(
            name: "kbd-int khớp", host: managed(),
            prompt: .password("(deploy@web.example.com) Password: "), alreadyFilled: false, expected: true),
        Row(
            name: "kbd-int host hoa thường + password hoa", host: managed(),
            prompt: .password("(deploy@WEB.example.com) PASSWORD:"), alreadyFilled: false, expected: true),
        Row(
            name: "kbd-int host khác", host: managed(),
            prompt: .password("(deploy@otherhost) Password:"), alreadyFilled: false, expected: false),
        Row(
            name: "kbd-int user khác", host: managed(),
            prompt: .password("(root@web.example.com) Password:"), alreadyFilled: false, expected: false),
        Row(
            name: "kbd-int Verification code", host: managed(),
            prompt: .password("(deploy@web.example.com) Verification code:"), alreadyFilled: false, expected: false),
        Row(
            name: "kbd-int OTP", host: managed(),
            prompt: .password("(deploy@web.example.com) OTP:"), alreadyFilled: false, expected: false),
        Row(
            name: "Password for x", host: managed(),
            prompt: .password("Password for deploy:"), alreadyFilled: false, expected: false),
        Row(
            name: "kbd-int có bastion", host: managed(jump: UUID()),
            prompt: .password("(deploy@web.example.com) Password:"), alreadyFilled: false, expected: false),
        Row(
            name: "kbd-int host là hậu tố", host: managed(),
            prompt: .password("(deploy@evilweb.example.com) Password:"), alreadyFilled: false, expected: false),
        Row(
            name: "kbd-int chữ thừa sau ngoặc", host: managed(),
            prompt: .password("(deploy@web.example.com) New Password:"), alreadyFilled: false, expected: false),
    ]

    @Test(arguments: rows) func table(_ row: Row) {
        #expect(
            PasswordAutofillPolicy.shouldAutofill(
                prompt: row.prompt, host: row.host, alreadyFilled: row.alreadyFilled) == row.expected,
            "\(row.name)")
    }
}
