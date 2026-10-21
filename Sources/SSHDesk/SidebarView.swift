import SSHDeskCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    header("WORKSPACE", first: true)
                    row("Tất cả máy chủ", "server.rack", item: .all)
                    row("Yêu thích", "star", item: .favorites)
                    row(
                        "Truyền file", "arrow.up.arrow.down", item: .transfers,
                        badge: TransferPresentation.active(model.jobs).count)
                    row("Gần đây", "clock", item: .recent)

                    let counts = HostPresentation.environmentCounts(model.hosts)
                    if !counts.isEmpty {
                        header("MÔI TRƯỜNG")
                        ForEach(counts, id: \.environment) { c in
                            row(
                                HostPresentation.title(for: c.environment), "server.rack",
                                item: .environment(c.environment), trailing: "\(c.count)")
                        }
                    }
                    if !model.projects.isEmpty {
                        header("DỰ ÁN")
                        ForEach(model.projects, id: \.self) { p in
                            row(p, "folder", item: .project(p))
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 12)
            }
            Divider().overlay(Theme.divider).padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 2) {
                comingSoon("SSH Keys", "key")
                comingSoon("Cài đặt", "gearshape")
            }
            .padding(10)
        }
        .frame(width: Theme.sidebarWidth)
        .background(Theme.sidebarBackground)
    }

    private func header(_ text: String, first: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10).padding(.top, first ? 4 : 16).padding(.bottom, 4)
    }

    private func row(
        _ title: String, _ symbol: String, item: SidebarItem, trailing: String? = nil,
        badge: Int = 0
    ) -> some View {
        let selected = model.sidebar == item
        return Button {
            model.sidebar = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 20)
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                if badge > 0 {
                    Text("\(badge)").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.rowSelected, in: Capsule())
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .font(.system(size: 13.5))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func comingSoon(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).frame(width: 20)
            Text(title)
            Spacer()
            Text("Sắp có").font(.caption)
        }
        .font(.system(size: 13.5))
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Chưa khả dụng")
    }
}
