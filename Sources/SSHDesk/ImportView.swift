import SSHDeskCore
import SwiftUI

struct ImportView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @Local private var result: SSHConfigScanResult?
    @Local private var scanning = false
    @Local private var checked: Set<String> = []
    @Local private var alreadyImported: Set<String> = []

    private let configURL = SSHConfigImporter.defaultUserConfigURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import từ SSH config").font(.title2.bold())
            Text("Chỉ đọc \(configURL.path); không sửa file và không chạy lệnh nào trong đó.")
                .foregroundStyle(.secondary)
            if let result {
                content(result)
            } else {
                Spacer()
                HStack {
                    Spacer()
                    Button(scanning ? "Đang quét…" : "Quét ~/.ssh/config") { scan() }
                        .buttonStyle(.borderedProminent).disabled(scanning)
                    Spacer()
                }
                Spacer()
            }
            Divider()
            HStack {
                Spacer()
                Button("Đóng") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selectedCount) mục") { Task { await doImport() } }
                    .keyboardShortcut(.defaultAction).disabled(selectedCount == 0)
            }
        }
        .padding(16)
        .frame(width: 640, height: 560)
    }

    private var selectedCount: Int { checked.count }

    @ViewBuilder
    private func content(_ r: SSHConfigScanResult) -> some View {
        List {
            Section {
                if r.candidates.isEmpty { Text("Không tìm thấy alias cụ thể nào.").foregroundStyle(.secondary) }
                ForEach(r.candidates, id: \.alias) { c in candidateRow(c) }
            } header: {
                Text("Giá trị đọc trực tiếp từ khối Host, chưa phải cấu hình hiệu lực")
                    .textCase(nil)
            }
            if !r.skippedPatterns.isEmpty {
                Section("Pattern bị bỏ qua (không phải máy cụ thể)") {
                    Text(r.skippedPatterns.joined(separator: ", ")).font(.callout.monospaced())
                }
            }
            if !r.warnings.isEmpty {
                Section("Cảnh báo") {
                    ForEach(Array(r.warnings.enumerated()), id: \.offset) { _, w in
                        Label {
                            Text("\(w.file.lastPathComponent)\(w.line > 0 ? ":\(w.line)" : "") — \(w.message)")
                                .font(.callout)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(
                                    w.kind == .proxyCommand || w.kind == .matchExec
                                        || w.kind == .matchNotEvaluated ? .orange : .secondary)
                        }
                    }
                }
            }
        }
    }

    private func candidateRow(_ c: ImportCandidate) -> some View {
        let done = alreadyImported.contains(c.alias)
        return HStack(alignment: .top) {
            Toggle(
                "",
                isOn: Binding(
                    get: { checked.contains(c.alias) },
                    set: { if $0 { checked.insert(c.alias) } else { checked.remove(c.alias) } })
            )
            .labelsHidden().disabled(done)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(c.alias).font(.body.weight(.medium))
                    if done { Text("đã import").font(.caption).foregroundStyle(.secondary) }
                }
                Text(raw(c)).font(.caption).foregroundStyle(.secondary)
                if c.hasProxyCommand {
                    Text("Có ProxyCommand — app không chạy hay đánh giá lệnh này.")
                        .font(.caption).foregroundStyle(.orange)
                }
                if c.hasMatchOrComplexity {
                    Text("Nằm trong/gần Match, Include hoặc pattern — cấu hình hiệu lực có thể khác.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private func raw(_ c: ImportCandidate) -> String {
        var parts: [String] = []
        if let v = c.hostName { parts.append("HostName \(v)") }
        if let v = c.user { parts.append("User \(v)") }
        if let v = c.port { parts.append("Port \(v)") }
        if let v = c.identityFile { parts.append("IdentityFile \(v)") }
        if let v = c.proxyJump { parts.append("ProxyJump \(v)") }
        return parts.isEmpty ? "(không có giá trị trực tiếp)" : parts.joined(separator: " · ")
    }

    private func scan() {
        scanning = true
        let url = configURL
        let existing = Set(
            model.hosts.filter { $0.sshConfigPath == url.path }.compactMap(\.sshConfigAlias))
        Task {
            let r = await Task.detached { SSHConfigImporter.scan(path: url) }.value
            alreadyImported = existing
            checked = Set(r.candidates.map(\.alias).filter { !existing.contains($0) })
            result = r
            scanning = false
        }
    }

    private func doImport() async {
        guard let result else { return }
        let chosen = result.candidates.filter { checked.contains($0.alias) }
        if await model.importSelected(chosen, sourcePath: configURL.path) { dismiss() }
    }
}
