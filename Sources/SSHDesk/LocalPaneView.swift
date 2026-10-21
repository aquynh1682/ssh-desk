import SSHDeskCore
import SwiftUI

/// Khung trái: "Local — Máy Mac này".
struct LocalPaneView: View {
    @Bindable var browser: FileBrowserModel
    @Bindable var local: LocalPaneModel
    @Local private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            PaneNavBar(
                canBack: local.history.canGoBack, canForward: local.history.canGoForward,
                canUp: BrowserPath.parent(local.path) != local.path,
                onBack: { Task { await local.go(.back) } },
                onForward: { Task { await local.go(.forward) } },
                onUp: { Task { await local.goUp() } },
                pathText: $local.pathText,
                onSubmit: { Task { await local.submitPathText() } },
                showSearch: $local.showSearch,
                onRefresh: { Task { await local.refresh() } },
                onNewFolder: { browser.promptNewLocalFolder() }
            ) {
                menuItems
            }
            PaneSearchBar(query: $local.query, visible: $local.showSearch)
            Divider().overlay(Theme.divider)
            if let error = local.error {
                PaneErrorBar(message: error) { local.error = nil }
            }
            table
                .overlay(alignment: .bottom) {
                    if browser.shouldShowDropOverlay(onLocal: targeted) {
                        DropZoneOverlay(
                            symbol: "arrow.down.to.line", title: "Tải về Máy này",
                            detail: BrowserPath.display(local.path, home: local.home))
                    }
                }
            Divider().overlay(Theme.divider)
            PaneFooter(
                text: BrowserFormat.footerText(
                    total: local.rows.count, selected: local.selection.selected.count))
        }
        .cardStyle()
        .onDrop(of: [.browserItems], isTargeted: $targeted) { providers in
            browser.handleDropOnLocal(providers)
            return true
        }
        .task { await local.refresh() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer").font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Local").font(.system(size: 17, weight: .semibold))
                Text("Máy Mac này").font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    private var table: some View {
        FileTable(
            style: .local, rows: local.rows, selection: local.selection.selected, sort: local.sort,
            onSort: { local.sort = local.sort.toggled($0) },
            onClick: { row, modifier in
                local.selection.click(row.id, modifier: modifier, order: local.rows.map(\.id))
            },
            onOpen: { row in Task { await local.open(row) } },
            onClearSelection: { local.selection.clear() },
            makeProvider: { rows in
                browser.provider(for: rows.map(BatchItem.init(row:)), origin: .local)
            },
            menu: { row in rowMenu(row) })
    }

    @ViewBuilder
    private func rowMenu(_ row: BrowserRow) -> some View {
        if row.isDirectory || row.isSymlink {
            Button("Mở") { Task { await local.open(row) } }
        }
        if let tab = browser.selectedTab, tab.isBrowsable {
            Button("Tải lên \(tab.title)") {
                Task {
                    if !local.selection.selected.contains(row.id) {
                        local.selection.click(row.id, modifier: .none, order: local.rows.map(\.id))
                    }
                    await browser.uploadSelectedLocal(to: tab)
                }
            }
        }
        Divider()
        Button("Đổi tên…") { browser.promptRenameLocal(row) }
        Button("Chuyển vào Thùng rác…") {
            let targets =
                local.selection.selected.contains(row.id) ? local.selectedRows : [row]
            browser.confirmTrash(targets)
        }
        Button("Mở trong Finder") { local.reveal([row]) }
    }

    @ViewBuilder
    private var menuItems: some View {
        Toggle("Hiện file ẩn", isOn: $local.showHidden)
        Divider()
        let selected = local.selectedRows
        Button("Đổi tên…") {
            if let row = selected.first { browser.promptRenameLocal(row) }
        }
        .disabled(selected.count != 1)
        Button("Chuyển vào Thùng rác…") { browser.confirmTrash(selected) }
            .disabled(selected.isEmpty)
        Button("Mở trong Finder") { local.reveal(selected) }
    }
}
