import SSHDeskCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView("Đang mở dữ liệu…").frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.windowBackground)
        case .failed(let failure):
            DatabaseErrorView(failure: failure) { model.revealDataFolder() }
        case .ready:
            MainView(model: model)
        }
    }
}

struct DatabaseErrorView: View {
    let failure: DatabaseFailure
    let reveal: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Không mở được dữ liệu SSH Desk", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.red)
        } description: {
            VStack(spacing: 8) {
                Text(failure.message).foregroundStyle(Theme.textPrimary)
                Text(failure.path).font(.callout.monospaced()).textSelection(.enabled)
                    .foregroundStyle(Theme.textPrimary)
                Text(
                    "File được giữ nguyên, app không tạo dữ liệu mới đè lên. Hãy sao lưu hoặc xử lý file rồi mở lại app."
                )
                .foregroundStyle(Theme.textSecondary)
            }
        } actions: {
            Button("Mở thư mục trong Finder", action: reveal).buttonStyle(ProminentButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.windowBackground)
    }
}

struct MainView: View {
    @Bindable var model: AppModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            InventoryChangeBanner(inventory: model.inventory)
            HStack(spacing: 0) {
                SidebarView(model: model)
                Divider().overlay(Theme.divider)
                if model.sidebar.isHostSection { hostsLayout } else { toolsLayout }
            }
            Divider().overlay(Theme.divider)
            statusBar
        }
        .background(Theme.windowBackground)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 8) {
                    LogoView(size: 24)
                    Text("SSH Desk").font(.system(size: 14, weight: .semibold))
                }
            }
            ToolbarItem(placement: .principal) { searchField }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Xuất tất cả máy chủ…") { model.exportHosts(.all) }
                        .disabled(model.hosts.isEmpty)
                    if case .folder(let name) = model.sidebar {
                        Button("Xuất thư mục “\(name)”…") { model.exportHosts(.folder(name)) }
                    }
                    Divider()
                    Button("Nhập từ file…") { model.beginImportFile() }
                    Divider()
                    Button("Nguồn máy chủ (Excel/CSV)…") { model.inventory.openHub() }
                } label: {
                    Label("Xuất / nhập danh sách", systemImage: "arrow.up.arrow.down.square")
                }
                .help("Xuất / nhập danh sách máy chủ (file JSON, không chứa mật khẩu)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showImport = true
                } label: {
                    Label("Import từ SSH config", systemImage: "square.and.arrow.down")
                }
                .help("Import từ SSH config (⇧⌘I)")
            }
        }
        .onChange(of: model.searchFocusTick) { searchFocused = true }
        .sheet(item: $model.form) { target in
            HostFormView(model: model, target: target)
        }
        .sheet(isPresented: $model.showImport) { ImportView(model: model) }
        .sheet(item: $model.assignSetTarget) { target in
            AssignSetSheet(model: model, target: target)
        }
        .sheet(isPresented: $model.inventory.showHub) {
            InventoryHubSheet(model: model, inventory: model.inventory)
        }
        .sheet(item: $model.exchangePreview) { preview in
            HostImportPreviewSheet(model: model, preview: preview)
        }
        .sheet(item: $model.forwardForm) { target in
            PortForwardFormView(model: model, target: target)
        }
        .modifier(KeysDialogs(model: model, keys: model.keys))
        .passwordPromptSheet(model: model, presenter: .root)
        .sheet(item: $model.transferSheet) { target in
            switch target {
            case .download(let h): DownloadSheet(model: model, host: h)
            case .upload(let h): UploadSheet(model: model, host: h)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let prompt = model.activePrompt {
                AuthPromptCard(prompt: prompt)
                    .id(prompt.id)
                    .padding(16)
            }
        }
        .alert(item: $model.alert) { a in
            Alert(title: Text(a.title), message: Text(a.message), dismissButton: .default(Text("Đóng")))
        }
        .confirmationDialog(
            "Xoá “\(model.pendingDelete?.displayName ?? "")”?",
            isPresented: Binding(
                get: { model.pendingDelete != nil },
                set: { if !$0 { model.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Xoá", role: .destructive) { Task { await model.confirmDelete() } }
            Button("Huỷ", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text("Chỉ xoá hồ sơ trong SSH Desk, không đụng tới máy chủ hay ~/.ssh/config của bạn.")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 3)
                    .padding(.bottom, 44)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.textSecondary)
            TextField("Tìm máy chủ…", text: $model.searchText)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { searchFocused = false }
                .onExitCommand {
                    if model.searchText.isEmpty { searchFocused = false } else { model.searchText = "" }
                }
            if model.searchText.isEmpty {
                Text("⌘K").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.rowSelected, in: RoundedRectangle(cornerRadius: 5))
            } else {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain).accessibilityLabel("Xoá nội dung tìm")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 460)
        .background(Theme.control, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.cardStroke))
        .help("Tìm theo tên, host, user, tag (⌘K / ⌘F)")
    }

    private var statusBar: some View {
        HStack {
            Label("Dữ liệu lưu trên máy này", systemImage: "internaldrive")
            Spacer()
            if model.tunnels.activeCount > 0 {
                HStack(spacing: 6) {
                    Circle().fill(Theme.green).frame(width: 8, height: 8)
                    Text("\(model.tunnels.activeCount) tunnel đang chạy")
                }
                .padding(.trailing, 12)
            }
            if model.sidebar == .transfers {
                let sessions = model.browser?.sessionCount ?? 0
                HStack(spacing: 6) {
                    Circle().fill(sessions > 0 ? Theme.green : Theme.textTertiary).frame(width: 8, height: 8)
                    Text(BrowserTabPresentation.sessionsText(sessions))
                }
            } else if model.sidebar == .keys {
                Text("\(model.keys.keys.count) key")
            } else if model.sidebar == .settings {
                Text("Cài đặt")
            } else if model.sidebar == .monitor {
                Text(
                    model.monitor.folder.map { "\(model.monitor.hosts.count) máy chủ trong “\($0)”" }
                        ?? "Monitor")
            } else if model.sidebar == .analyst {
                Text(
                    model.analyst.folder.map { "\(model.analyst.hosts.count) máy chủ trong “\($0)”" }
                        ?? "Project Analyst")
            } else {
                Text("\(model.hosts.count) máy chủ")
            }
        }
        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(Theme.windowBackground)
    }

    private var hostsLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HostListView(model: model)
                    .frame(minWidth: 420, maxWidth: .infinity)
                Divider().overlay(Theme.divider)
                if let host = model.selectedHost {
                    HostDetailView(model: model, host: host)
                } else {
                    ContentUnavailableView(
                        "Chọn một máy chủ", systemImage: "server.rack",
                        description: Text("Chọn máy ở danh sách để xem chi tiết.")
                    )
                    .frame(width: Theme.detailWidth)
                }
            }
            TransfersPanel(model: model)
        }
    }

    @ViewBuilder
    private var toolsLayout: some View {
        if model.sidebar == .keys {
            KeysView(model: model, keys: model.keys)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sidebar == .analyst {
            AnalystView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sidebar == .monitor {
            MonitorView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sidebar == .settings {
            SettingsView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FileTransferView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
