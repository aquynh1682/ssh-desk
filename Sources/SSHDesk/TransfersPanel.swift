import AppKit
import SSHDeskCore
import SwiftUI

/// Khung "Truyền file" dưới cột giữa + phải: job đang chạy và vài job gần nhất.
struct TransfersPanel: View {
    @Bindable var model: AppModel
    @Local private var collapsed = false

    var body: some View {
        let running = TransferPresentation.active(model.jobs).count
        let jobs = TransferPresentation.panelJobs(model.jobs, limit: 4)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { collapsed.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                            .foregroundStyle(Theme.textSecondary)
                        Text("Truyền file").font(.system(size: 15, weight: .semibold))
                        if running > 0 {
                            Text("\(running)").font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.rowSelected, in: Capsule())
                        }
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(collapsed ? "Mở rộng khung Truyền file" : "Thu gọn khung Truyền file")
                Spacer()
                Button("Xem tất cả") { model.sidebar = .transfers }
                    .buttonStyle(.plain).font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            if !collapsed {
                if jobs.isEmpty {
                    Divider().overlay(Theme.divider)
                    Text("Chưa có tác vụ truyền file. Dùng Tải lên / Tải về ở chi tiết máy chủ.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 14)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(jobs) { job in
                                Divider().overlay(Theme.divider)
                                PanelJobRow(model: model, job: job)
                            }
                        }
                    }
                    .frame(maxHeight: 4 * 52)
                }
            }
        }
        .cardStyle()
        .padding(.horizontal, 22).padding(.bottom, 12)
    }
}

private struct PanelJobRow: View {
    @Bindable var model: AppModel
    let job: TransferJob

    var body: some View {
        let route = TransferPresentation.route(for: job)
        HStack(spacing: 12) {
            Image(systemName: job.itemKind == .directory ? "folder" : "doc")
                .font(.system(size: 18)).foregroundStyle(Theme.textSecondary).frame(width: 24)
            Text(TransferPresentation.fileName(for: job))
                .font(.system(size: 13.5)).lineLimit(1).truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            HStack(spacing: 6) {
                Text(route.from).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 9))
                Text(route.to).lineLimit(1)
            }
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            .frame(width: 190, alignment: .leading)
            statusView.frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var statusView: some View {
        switch job.state {
        case .connecting, .transferring, .finalizing:
            HStack(spacing: 10) {
                if let f = TransferPresentation.fraction(for: job) {
                    ProgressView(value: f).tint(Theme.green)
                } else {
                    // Không có fraction thì không bịa phần trăm: thanh không xác định.
                    ProgressView().progressViewStyle(.linear).tint(Theme.green)
                }
                let detail = [TransferPresentation.percentText(for: job), TransferPresentation.speedText(for: job)]
                    .compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize()
                }
            }
        case .completed:
            statusLabel(
                TransferPresentation.isSkipped(job) ? "minus.circle.fill" : "checkmark.circle.fill",
                TransferPresentation.label(for: job),
                TransferPresentation.isSkipped(job) ? Theme.textSecondary : Theme.green)
        case .failed:
            statusLabel("exclamationmark.circle.fill", TransferPresentation.label(for: job), Theme.red)
                .help(job.failureReason ?? "")
        case .awaitingUserInput:
            statusLabel("lock.shield", TransferPresentation.label(for: job), Theme.amber)
        default:
            Text(TransferPresentation.label(for: job)).font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func statusLabel(_ symbol: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text)
        }
        .font(.system(size: 13)).foregroundStyle(color)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            if TransferPresentation.canCancel(job.state) {
                Button("Huỷ") { Task { await model.cancel(job) } }
                    .buttonStyle(OutlineButtonStyle()).controlSize(.small)
            }
            if let p = TransferPresentation.revealPath(for: job) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                } label: {
                    Image(systemName: "folder").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain).help("Mở trong Finder")
                .accessibilityLabel("Mở trong Finder")
            }
            if TransferPresentation.canRetry(job.state) {
                Menu {
                    Button("Thử lại") { Task { await model.retry(job) } }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textSecondary)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Thao tác khác")
            }
        }
        .frame(minWidth: 40, alignment: .trailing)
    }
}
