import AppKit
import SSHDeskCore
import SwiftUI

/// Nút icon nhỏ trên thanh điều hướng của khung.
struct PaneIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14))
                .foregroundStyle(enabled ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!enabled).help(help).accessibilityLabel(help)
    }
}

/// Thanh điều hướng: lùi/tiến/lên, ô đường dẫn, tìm, làm mới, thư mục mới, menu ≡.
struct PaneNavBar<MenuContent: View>: View {
    let canBack: Bool
    let canForward: Bool
    let canUp: Bool
    let onBack: () -> Void
    let onForward: () -> Void
    let onUp: () -> Void
    @Binding var pathText: String
    let onSubmit: () -> Void
    @Binding var showSearch: Bool
    let onRefresh: () -> Void
    let onNewFolder: () -> Void
    var actionsEnabled = true
    @ViewBuilder let menu: MenuContent

    var body: some View {
        HStack(spacing: 2) {
            PaneIconButton(symbol: "arrow.left", help: "Quay lại", enabled: canBack, action: onBack)
            PaneIconButton(symbol: "arrow.right", help: "Đi tiếp", enabled: canForward, action: onForward)
            PaneIconButton(symbol: "arrow.up", help: "Lên thư mục cha", enabled: canUp, action: onUp)
            TextField("Đường dẫn", text: $pathText)
                .textFieldStyle(.plain).font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
                .onSubmit(onSubmit).padding(.horizontal, 6)
                .disabled(!actionsEnabled)
            PaneIconButton(
                symbol: "magnifyingglass", help: "Tìm trong thư mục này", enabled: actionsEnabled
            ) { showSearch.toggle() }
            PaneIconButton(symbol: "arrow.clockwise", help: "Làm mới", enabled: actionsEnabled, action: onRefresh)
            PaneIconButton(
                symbol: "folder.badge.plus", help: "Thư mục mới", enabled: actionsEnabled, action: onNewFolder)
            Menu {
                menu
            } label: {
                Image(systemName: "line.3.horizontal").font(.system(size: 14))
                    .foregroundStyle(actionsEnabled ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .disabled(!actionsEnabled).help("Thao tác khác").accessibilityLabel("Thao tác khác")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

struct PaneSearchBar: View {
    @Binding var query: String
    @Binding var visible: Bool
    @FocusState private var focused: Bool

    var body: some View {
        if visible {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
                TextField("Lọc theo tên", text: $query).textFieldStyle(.plain).focused($focused)
                    .onExitCommand { close() }
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain).accessibilityLabel("Đóng ô lọc")
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Theme.rowHover)
            .onAppear { focused = true }
        }
    }

    private func close() {
        query = ""
        visible = false
    }
}

/// Bảng file dùng chung: tiêu đề cột sắp xếp, chọn nhiều (⌘/⇧-click), double-click, kéo thả, menu chuột phải.
struct FileTable<RowMenu: View>: View {
    enum Style { case local, remote }

    let style: Style
    let rows: [BrowserRow]
    let selection: Set<String>
    let sort: BrowserSort
    let onSort: (BrowserSort.Key) -> Void
    let onClick: (BrowserRow, BrowserSelection.Modifier) -> Void
    let onOpen: (BrowserRow) -> Void
    let onClearSelection: () -> Void
    let makeProvider: ([BrowserRow]) -> NSItemProvider
    @ViewBuilder let menu: (BrowserRow) -> RowMenu

    private static var sizeWidth: CGFloat { 86 }
    private var thirdWidth: CGFloat { style == .local ? 96 : 110 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.divider)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in rowView(row) }
                }
                .background(
                    Color.clear.contentShape(Rectangle()).onTapGesture { onClearSelection() })
            }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            sortButton("Tên", .name).frame(maxWidth: .infinity, alignment: .leading)
            sortButton("Kích thước", .size).frame(width: Self.sizeWidth, alignment: .leading)
            if style == .local {
                sortButton("Sửa đổi", .modified).frame(width: thirdWidth, alignment: .leading)
            } else {
                Text("Quyền").frame(width: thirdWidth, alignment: .leading)
            }
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func sortButton(_ title: String, _ key: BrowserSort.Key) -> some View {
        Button {
            onSort(key)
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if sort.key == key {
                    Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Sắp xếp theo \(title)")
    }

    private func rowView(_ row: BrowserRow) -> some View {
        let selected = selection.contains(row.id)
        return HStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol(for: row)).font(.system(size: 16))
                    .foregroundStyle(row.isDirectory ? Theme.blue : Theme.textSecondary)
                    .frame(width: 22)
                Text(row.displayName).font(.system(size: 13.5)).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(BrowserFormat.sizeText(row)).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                .frame(width: Self.sizeWidth, alignment: .leading)
            Group {
                if style == .local {
                    Text(BrowserFormat.modifiedText(row.modified)).font(.system(size: 13))
                } else {
                    Text(row.permissions.map { String($0.dropFirst()) } ?? "—")
                        .font(.system(size: 12.5, design: .monospaced))
                }
            }
            .foregroundStyle(Theme.textSecondary).lineLimit(1)
            .frame(width: thirdWidth, alignment: .leading)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(selected ? Theme.rowSelected : .clear)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Theme.green).frame(width: 2) }
        }
        .opacity(row.isSupported ? (row.isHidden ? 0.7 : 1) : 0.4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if row.isSupported { onOpen(row) } }
        .onTapGesture {
            guard row.isSupported else { return }
            onClick(row, currentModifier())
        }
        .contextMenu {
            if row.isSupported { menu(row) }
        }
        .onDrag {
            guard row.isSupported else { return NSItemProvider() }
            if !selection.contains(row.id) { onClick(row, .none) }
            return makeProvider(dragRows(for: row))
        } preview: {
            DragPreviewCard(rows: dragRows(for: row))
        }
        .help(row.isSupported ? "" : "Tên chứa ký tự điều khiển — không hỗ trợ thao tác")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func dragRows(for row: BrowserRow) -> [BrowserRow] {
        guard selection.contains(row.id) else { return [row] }
        return rows.filter { selection.contains($0.id) && $0.isSupported }
    }

    private func symbol(for row: BrowserRow) -> String {
        if row.isDirectory { return "folder.fill" }
        if row.isSymlink { return "link" }
        return "doc"
    }

    private func currentModifier() -> BrowserSelection.Modifier {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .none
    }
}

/// Hình xem trước khi kéo: "N mục" + vài tên đầu.
struct DragPreviewCard: View {
    let rows: [BrowserRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(rows.count == 1 ? rows[0].displayName : "\(rows.count) mục")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if rows.count > 1 {
                ForEach(rows.prefix(2)) { r in
                    Text(r.displayName).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(10).frame(maxWidth: 220, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.cardStroke))
    }
}

/// Vùng thả viền đứt xanh (như mockup): "Tải lên <host>" + thư mục đích.
struct DropZoneOverlay: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 24, weight: .medium))
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
        }
        .foregroundStyle(Theme.green)
        .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 120)
        .background(Theme.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.green, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .padding(10)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }
}

/// Dòng chân khung: "N mục · M đã chọn".
struct PaneFooter: View {
    let text: String
    var warning: String?

    var body: some View {
        HStack(spacing: 10) {
            Text(text)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber).lineLimit(1)
            }
            Spacer()
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// Dòng lỗi nhỏ phía trên bảng.
struct PaneErrorBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).lineLimit(2).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Ẩn thông báo lỗi")
        }
        .font(.system(size: 12.5)).foregroundStyle(Theme.red)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .background(Theme.red.opacity(0.08))
    }
}
