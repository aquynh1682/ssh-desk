import SSHDeskCore
import SwiftUI

/// Kết quả của một hành động trong hộp thoại: đóng, báo lỗi (giữ hộp thoại), hoặc chuyển sang hộp thoại khác.
enum DialogOutcome {
    case done
    case error(String)
    case next(BrowserDialog)
}

struct ConfirmDialog {
    let title: String
    let message: String
    /// Dòng cảnh báo nhấn mạnh (vd máy PRODUCTION).
    var emphasis: String?
    var items: [String] = []
    let confirmTitle: String
    var destructive = false
    let action: @MainActor () async -> DialogOutcome
}

struct NameInputDialog {
    let title: String
    var message: String?
    let initial: String
    let confirmTitle: String
    let submit: @MainActor (String) async -> DialogOutcome
}

struct ConflictDialog {
    let title: String
    let names: [String]
    var note: String?
    let allowAutoRename: Bool
    /// `nil` = Huỷ.
    let choose: @MainActor (BatchConflictChoice?) async -> DialogOutcome
}

struct NoticeDialog {
    let title: String
    let message: String
    var items: [String] = []
    /// Chạy sau khi người dùng bấm OK (vd tiếp tục luồng tải lên).
    var then: (@MainActor () -> DialogOutcome)?
}

/// Xoá thư mục đệ quy: lập kế hoạch → xác nhận (PROD gõ lại tên host) → chạy có tiến độ, huỷ được.
@MainActor @Observable
final class DeleteOperation {
    enum Phase: Equatable {
        case planning
        case confirm(DeletePlanSummary)
        case deleting(done: Int, total: Int)
        case failed(String)
    }

    private(set) var phase = Phase.planning
    var typed = ""
    let rowName: String
    let host: HostProfile
    let confirmation: BrowserSafety.DeleteConfirmation
    private let tab: BrowserTab
    private let row: BrowserRow
    private var plan: RemoteDeletePlan?
    private var task: Task<Void, Never>?
    /// Gọi khi xong/huỷ để đóng hộp thoại.
    var onFinish: (@MainActor () -> Void)?

    init(tab: BrowserTab, row: BrowserRow) {
        self.tab = tab
        self.row = row
        rowName = row.name
        host = tab.host
        confirmation = BrowserSafety.deleteConfirmation(host: tab.host, isDirectory: true)
    }

    var canConfirm: Bool {
        guard case .confirm = phase else { return false }
        return confirmation == .simple || BrowserSafety.isHostNameTyped(typed, host: host)
    }

    var isDeleting: Bool {
        if case .deleting = phase { return true }
        return false
    }

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let plan = try await tab.planDelete(row)
                self.plan = plan
                phase = .confirm(DeletePlanSummary(plan))
            } catch {
                phase = .failed(BrowserErrorText.message(for: error))
            }
        }
    }

    func confirm() {
        guard canConfirm, let plan else { return }
        phase = .deleting(done: 0, total: plan.totalCount)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await tab.executeDelete(plan) { [weak self] done, total in
                    Task { @MainActor in
                        if self?.isDeleting == true { self?.phase = .deleting(done: done, total: total) }
                    }
                }
                onFinish?()
            } catch is CancellationError {
                onFinish?()
            } catch {
                phase = .failed(BrowserErrorText.message(for: error))
            }
        }
    }

    /// Huỷ khi đang xoá: dừng ở mục kế tiếp (các mục đã xoá không khôi phục được).
    func cancel() {
        task?.cancel()
        if !isDeleting { onFinish?() }
    }
}

enum BrowserDialog: Identifiable {
    case notice(NoticeDialog)
    case confirm(ConfirmDialog)
    case nameInput(NameInputDialog)
    case conflicts(ConflictDialog)
    case delete(DeleteOperation)

    var id: String {
        switch self {
        case .notice(let d): return "notice-" + d.title + d.message
        case .confirm(let d): return "confirm-" + d.title + d.message
        case .nameInput(let d): return "name-" + d.title
        case .conflicts(let d): return "conflicts-" + d.title
        case .delete(let o): return "delete-" + o.rowName
        }
    }

    static func error(_ title: String, _ message: String) -> BrowserDialog {
        .notice(NoticeDialog(title: title, message: message))
    }
}

// MARK: - Giao diện

/// Lớp phủ modal tự dựng (không dùng `.sheet`) để chuyển giữa các hộp thoại trong một luồng không bị giật.
struct BrowserDialogHost: View {
    @Bindable var browser: FileBrowserModel

    var body: some View {
        if let dialog = browser.dialog {
            ZStack {
                Color.black.opacity(0.4).ignoresSafeArea().onTapGesture {}
                content(dialog)
                    .id(dialog.id)
                    .frame(width: 460)
                    .padding(18)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.cardStroke))
                    .shadow(radius: 18)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func content(_ dialog: BrowserDialog) -> some View {
        switch dialog {
        case .notice(let d): NoticeView(browser: browser, dialog: d)
        case .confirm(let d): ConfirmView(browser: browser, dialog: d)
        case .nameInput(let d): NameInputView(browser: browser, dialog: d)
        case .conflicts(let d): ConflictsView(browser: browser, dialog: d)
        case .delete(let o): DeleteView(browser: browser, operation: o)
        }
    }
}

private struct DialogTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ItemList: View {
    let items: [String]
    var body: some View {
        if !items.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Text(item).font(.system(size: 12, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 150)
            .background(Theme.rowHover, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

private struct NoticeView: View {
    @Bindable var browser: FileBrowserModel
    let dialog: NoticeDialog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DialogTitle(text: dialog.title)
            Text(dialog.message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ItemList(items: dialog.items)
            HStack {
                Spacer()
                Button("Đóng") {
                    if let then = dialog.then { browser.apply(then()) } else { browser.dialog = nil }
                }
                .buttonStyle(ProminentButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ConfirmView: View {
    @Bindable var browser: FileBrowserModel
    let dialog: ConfirmDialog
    @Local private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DialogTitle(text: dialog.title)
            Text(dialog.message).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let emphasis = dialog.emphasis {
                Text(emphasis).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ItemList(items: dialog.items)
            HStack {
                Spacer()
                Button("Huỷ") { browser.dialog = nil }
                    .buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction).disabled(busy)
                Button(dialog.confirmTitle) {
                    busy = true
                    Task {
                        let outcome = await dialog.action()
                        busy = false
                        browser.apply(outcome)
                    }
                }
                .buttonStyle(ProminentButtonStyle()).disabled(busy)
                .keyboardShortcut(dialog.destructive ? nil : .defaultAction)
            }
        }
    }
}

private struct NameInputView: View {
    @Bindable var browser: FileBrowserModel
    let dialog: NameInputDialog
    @Local private var text = ""
    @Local private var error: String?
    @Local private var busy = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DialogTitle(text: dialog.title)
            if let m = dialog.message {
                Text(m).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            TextField("Tên", text: $text).textFieldStyle(.roundedBorder).focused($focused)
                .onSubmit(submit).disabled(busy)
            if let error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red)
            }
            HStack {
                Spacer()
                Button("Huỷ") { browser.dialog = nil }
                    .buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction).disabled(busy)
                Button(dialog.confirmTitle, action: submit)
                    .buttonStyle(ProminentButtonStyle()).disabled(busy)
            }
        }
        .onAppear {
            text = dialog.initial
            focused = true
        }
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        error = nil
        let value = text
        Task {
            let outcome = await dialog.submit(value)
            busy = false
            if case .error(let message) = outcome { error = message } else { browser.apply(outcome) }
        }
    }
}

private struct ConflictsView: View {
    @Bindable var browser: FileBrowserModel
    let dialog: ConflictDialog

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DialogTitle(text: dialog.title)
            ItemList(items: dialog.names)
            if let note = dialog.note {
                Text(note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Huỷ") { choose(nil) }
                    .buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Bỏ qua mục trùng") { choose(.skipConflicts) }.buttonStyle(OutlineButtonStyle())
                if dialog.allowAutoRename {
                    Button("Đổi tên tự động") { choose(.autoRename) }.buttonStyle(OutlineButtonStyle())
                }
                Button("Ghi đè tất cả") { choose(.overwriteAll) }.buttonStyle(ProminentButtonStyle())
            }
        }
    }

    private func choose(_ choice: BatchConflictChoice?) {
        Task { browser.apply(await dialog.choose(choice)) }
    }
}

private struct DeleteView: View {
    @Bindable var browser: FileBrowserModel
    @Bindable var operation: DeleteOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch operation.phase {
            case .planning:
                DialogTitle(text: "Đang liệt kê “\(operation.rowName)”…")
                ProgressView().progressViewStyle(.linear)
                HStack {
                    Spacer()
                    Button("Huỷ") { operation.cancel() }.buttonStyle(OutlineButtonStyle())
                }
            case .confirm(let summary):
                DialogTitle(text: "Xoá thư mục “\(operation.rowName)” và \(summary.total) mục bên trong?")
                Text(
                    "Xoá vĩnh viễn trên \(operation.host.displayName), không có Thùng rác và không khôi phục được. Quyền theo user SSH, không dùng sudo."
                )
                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                ItemList(items: summary.listed)
                if summary.hiddenCount > 0 {
                    Text("… và \(summary.hiddenCount) mục khác").font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
                if operation.confirmation == .typeHostName {
                    Text("Đây là máy PRODUCTION. Gõ lại tên máy “\(operation.host.displayName)” để xác nhận:")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                    TextField(operation.host.displayName, text: $operation.typed)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Spacer()
                    Button("Huỷ") { operation.cancel() }
                        .buttonStyle(OutlineButtonStyle()).keyboardShortcut(.cancelAction)
                    Button("Xoá \(summary.total) mục") { operation.confirm() }
                        .buttonStyle(ProminentButtonStyle()).disabled(!operation.canConfirm)
                }
            case .deleting(let done, let total):
                DialogTitle(text: "Đang xoá “\(operation.rowName)”…")
                ProgressView(value: Double(done), total: Double(max(1, total))).tint(Theme.green)
                Text("\(done)/\(total) mục").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                HStack {
                    Spacer()
                    Button("Huỷ") { operation.cancel() }.buttonStyle(OutlineButtonStyle())
                }
            case .failed(let message):
                DialogTitle(text: "Không xoá được “\(operation.rowName)”")
                Text(message).font(.system(size: 13)).foregroundStyle(Theme.red)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Đóng") { browser.dialog = nil }.buttonStyle(ProminentButtonStyle())
                }
            }
        }
        .onAppear {
            operation.onFinish = { browser.dialog = nil }
            if case .planning = operation.phase { operation.start() }
        }
    }
}
