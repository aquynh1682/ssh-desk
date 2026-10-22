import SSHDeskCore
import SwiftUI

/// Prompt xác thực đang chờ, từ một job truyền file HOẶC từ phiên của một tab duyệt file.
struct ActivePrompt: Identifiable {
    let id: String
    let kind: PromptKind
    /// Dòng mô tả nguồn (tên máy · địa chỉ).
    let context: String
    /// Số prompt khác đang xếp hàng.
    let waiting: Int
    let cancelTitle: String
    let send: (String, Bool) -> Void
    let cancel: () -> Void
}

extension AppModel {
    /// Prompt của job (xếp hàng theo thứ tự) trước, rồi tới prompt của các tab.
    var activePrompt: ActivePrompt? {
        if let kind = keys.pendingPrompt, let task = keys.task {
            return ActivePrompt(
                id: "key-" + task.context, kind: kind, context: task.context, waiting: 0,
                cancelTitle: "Huỷ tác vụ",
                send: { [weak self] text, secret in self?.keys.respond(text: text, isSecret: secret) },
                cancel: { [weak self] in self?.keys.cancelTask() })
        }
        if let ap = analyst.activePrompt {
            return ap
        }
        if let mp = monitor.activePrompt {
            return mp
        }
        if let tp = tunnels.activePrompt {
            return tp
        }
        let tabPrompts = (browser?.tabs ?? []).filter { $0.pendingPrompt != nil }
        let total = prompts.items.count + tabPrompts.count
        if let p = prompts.current {
            let job = jobs.first { $0.id == p.jobID }
            return ActivePrompt(
                id: "job-" + p.jobID.uuidString, kind: p.kind,
                context: job.map { "\($0.hostDisplayNameSnapshot) · \($0.targetSnapshot)" } ?? "",
                waiting: total - 1, cancelTitle: "Huỷ tác vụ",
                send: { [weak self] text, secret in
                    self?.respond(jobID: p.jobID, text: text, isSecret: secret)
                },
                cancel: { [weak self] in Task { await self?.cancelJob(id: p.jobID) } })
        }
        if let tab = tabPrompts.first, let kind = tab.pendingPrompt, let browser {
            return ActivePrompt(
                id: "tab-" + tab.id.uuidString, kind: kind,
                context: "\(tab.title) · \(BrowserTabPresentation.identity(tab.host)) (Truyền file)",
                waiting: total - 1, cancelTitle: "Huỷ kết nối",
                send: { text, secret in tab.respond(text: text, isSecret: secret) },
                cancel: { Task { await browser.closeTab(tab) } })
        }
        return nil
    }
}

/// Thẻ nổi (không modal) hỏi xác thực; nhiều prompt thì xếp hàng.
struct AuthPromptCard: View {
    let prompt: ActivePrompt
    @Local private var secret = ""

    var body: some View {
        let p = PromptPresentation(prompt.kind)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield").foregroundStyle(Theme.textSecondary)
                Text(p.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if prompt.waiting > 0 {
                    Text("còn \(prompt.waiting) đang chờ").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            if !prompt.context.isEmpty {
                Text(prompt.context).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
            }
            Text(p.text).font(.callout.monospaced()).textSelection(.enabled)
            if let fp = p.fingerprint {
                Text("Fingerprint: \(fp)").font(.callout.monospaced()).textSelection(.enabled)
            }
            switch p.input {
            case .secret:
                SecureField("Nhập rồi nhấn Gửi", text: $secret)
                    .textFieldStyle(.roundedBorder).onSubmit(send)
                if let note = p.note { Text(note).font(.caption).foregroundStyle(Theme.textSecondary) }
            case .hostKeyDecision, .none: EmptyView()
            }
            HStack {
                Button(prompt.cancelTitle) {
                    secret = ""
                    prompt.cancel()
                }
                .buttonStyle(OutlineButtonStyle())
                .foregroundStyle(Theme.red)
                Spacer()
                switch p.input {
                case .secret:
                    Button("Gửi", action: send).buttonStyle(ProminentButtonStyle())
                case .hostKeyDecision:
                    Button("Huỷ") {
                        prompt.send(PromptPresentation.hostKeyDecline.text, false)
                    }
                    .buttonStyle(OutlineButtonStyle())
                    Button("Tin cậy và tiếp tục") {
                        prompt.send(PromptPresentation.hostKeyTrust.text, false)
                    }
                    .buttonStyle(ProminentButtonStyle())
                case .none: EmptyView()
                }
            }
        }
        .padding(14)
        .frame(width: 440)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardCorner))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardCorner).strokeBorder(Theme.cardStroke))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private func send() {
        let value = secret
        secret = ""  // xoá khỏi state ngay
        prompt.send(value, true)
    }
}
