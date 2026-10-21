import AppKit
import SSHDeskCore
import SwiftUI

/// "Hàng đợi truyền" ở đáy màn Truyền file: tab Đang chạy / Hoàn tất.
struct TransferQueueView: View {
    @Bindable var model: AppModel
    @Local private var showCompleted = false

    var body: some View {
        let active = TransferPresentation.active(model.jobs)
        let done = TransferPresentation.history(model.jobs)
        let shown = showCompleted ? done : active
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Hàng đợi truyền").font(.system(size: 16, weight: .semibold))
                tabButton("Đang chạy", count: active.count, selected: !showCompleted) { showCompleted = false }
                tabButton("Hoàn tất", count: done.count, selected: showCompleted) { showCompleted = true }
                Spacer()
                Button {
                    Task { await model.clearHistory() }
                } label: {
                    Label("Xoá mục đã xong", systemImage: "trash")
                }
                .buttonStyle(OutlineButtonStyle()).controlSize(.small)
                .disabled(done.isEmpty)
                .help("Chỉ xoá các dòng trong hàng đợi, không xoá file nào")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().overlay(Theme.divider)
            header
            Divider().overlay(Theme.divider)
            if shown.isEmpty {
                Text(showCompleted ? "Chưa có tác vụ nào hoàn tất." : "Không có tác vụ đang chạy.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(shown) { job in
                            QueueRow(model: model, job: job)
                            Divider().overlay(Theme.divider)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    private func tabButton(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Text("\(count)").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 1)
                    .background(Theme.rowSelected, in: Capsule())
            }
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("File").frame(maxWidth: .infinity, alignment: .leading)
            Text("Từ → Đến").frame(width: QueueRow.routeWidth, alignment: .leading)
            Text("Tiến độ").frame(width: QueueRow.progressWidth, alignment: .leading)
            Text("Trạng thái").frame(width: QueueRow.statusWidth, alignment: .leading)
        }
        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

private struct QueueRow: View {
    static let routeWidth: CGFloat = 210
    static let progressWidth: CGFloat = 230
    static let statusWidth: CGFloat = 170

    @Bindable var model: AppModel
    let job: TransferJob

    var body: some View {
        let route = TransferPresentation.route(for: job)
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: job.itemKind == .directory ? "folder" : "doc")
                    .font(.system(size: 16)).foregroundStyle(Theme.textSecondary).frame(width: 22)
                Text(TransferPresentation.fileName(for: job)).font(.system(size: 13.5))
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(route.from).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 9))
                Text(route.to).lineLimit(1)
            }
            .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            .frame(width: Self.routeWidth, alignment: .leading)
            progress.frame(width: Self.progressWidth, alignment: .leading)
            HStack(spacing: 6) {
                status
                Spacer(minLength: 0)
                actions
            }
            .frame(width: Self.statusWidth, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    /// Thanh xanh + "% · tốc độ" chỉ khi có fraction thật; không thì thanh không xác định.
    @ViewBuilder
    private var progress: some View {
        switch job.state {
        case .connecting, .transferring, .finalizing:
            HStack(spacing: 8) {
                if let f = TransferPresentation.fraction(for: job) {
                    ProgressView(value: f).tint(Theme.green)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.green)
                }
                if let detail = BrowserFormat.progressDetail(for: job) {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize()
                }
            }
            .padding(.trailing, 12)
        default:
            if let reason = job.failureReason, job.state != .completed || TransferPresentation.isSkipped(job) {
                Text(reason).font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(job.state == .failed ? Theme.red : Theme.textSecondary)
                    .help(reason).padding(.trailing, 12)
            } else {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch job.state {
        case .completed:
            label(
                TransferPresentation.isSkipped(job) ? "minus.circle.fill" : "checkmark.circle.fill",
                TransferPresentation.isSkipped(job) ? Theme.textSecondary : Theme.green)
        case .failed: label("exclamationmark.circle.fill", Theme.red)
        case .awaitingUserInput: label("lock.shield", Theme.amber)
        default:
            Text(TransferPresentation.label(for: job)).font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
    }

    private func label(_ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(TransferPresentation.label(for: job)).lineLimit(1)
        }
        .font(.system(size: 12.5)).foregroundStyle(color)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if TransferPresentation.canCancel(job.state) {
                iconButton("xmark", "Huỷ") { Task { await model.cancel(job) } }
            }
            if TransferPresentation.canRetry(job.state) {
                iconButton("arrow.clockwise", "Thử lại") { Task { await model.retry(job) } }
            }
            if let p = TransferPresentation.revealPath(for: job) {
                iconButton("folder", "Mở trong Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}
