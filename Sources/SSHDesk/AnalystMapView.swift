import SSHDeskCore
import SwiftUI

/// Tab "Bản đồ mạng": cột trái = bản đồ + thanh chia kéo được + bảng kết quả; cột phải = panel chi tiết.
/// Kích thước tính tường minh (không để view tự giãn) nên các khối không bao giờ chồng nhau.
struct AnalystMapTab: View {
    @Bindable var model: AppModel
    @Local private var dragBase: Double? = nil

    var body: some View {
        let a = model.analyst
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 10) {
                AnalystHistoryBanner(analyst: a)
                if let run = a.current, !run.topology.flows.isEmpty || !run.topology.servers.isEmpty,
                    a.emptyState == .hasData
                {
                    split(a, run)
                } else {
                    VStack(spacing: 10) {
                        if let run = a.current, a.emptyState == .noEdges, !run.warnings.isEmpty {
                            Label(
                                "\(run.warnings.count) cảnh báo — xem tab Servers",
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.system(size: 12.5)).foregroundStyle(Theme.amber)
                        }
                        AnalystEmptyView(state: a.emptyState)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cardStyle()
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity)
            AnalystDetailPanel(analyst: a)
                .frame(width: 340).frame(maxHeight: .infinity)
        }
        .padding(16)
    }

    private func split(_ a: AnalystModel, _ run: StoredAnalystRun) -> some View {
        GeometryReader { geo in
            let avail = Double(geo.size.height)
            let table = AnalystPanelLayout.tableHeight(
                rowCount: run.topology.flows.count, available: avail, override: a.tableHeightOverride)
            let map = AnalystPanelLayout.mapHeight(available: avail, tableHeight: table)
            VStack(spacing: 0) {
                AnalystCard(title: "Kết nối giữa các server") {
                    ModeToggle(analyst: a)
                } content: {
                    AnalystCanvas(analyst: a, run: run).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: map)
                .clipped()
                splitter(a, table: table, available: avail)
                AnalystCard(
                    title: "Kết quả kiểm tra", subtitle: AnalystPresentation.summary(run.results)
                ) {
                    AnalystExportMenu(analyst: a)
                } content: {
                    AnalystResultsTable(analyst: a, run: run)
                }
                .frame(height: table)
                .clipped()
            }
        }
    }

    /// Thanh chia: kéo lên/xuống đổi chiều cao bảng; bấm đúp để về tự động.
    private func splitter(_ a: AnalystModel, table: Double, available: Double) -> some View {
        ZStack {
            Capsule().fill(Theme.textTertiary.opacity(0.6)).frame(width: 44, height: 4)
        }
        .frame(maxWidth: .infinity).frame(height: AnalystPanelLayout.splitterHeight)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let base = dragBase ?? table
                    dragBase = base
                    a.tableHeightOverride = AnalystPanelLayout.tableHeight(
                        rowCount: 0, available: available, override: base - Double(v.translation.height))
                }
                .onEnded { _ in dragBase = nil }
        )
        .onTapGesture(count: 2) { a.tableHeightOverride = nil }
        .help("Kéo để đổi chiều cao bảng · bấm đúp để về tự động")
        .accessibilityLabel("Thanh chia bản đồ và bảng kết quả")
    }
}

private struct ModeToggle: View {
    let analyst: AnalystModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AnalystMapMode.allCases, id: \.self) { m in
                let on = analyst.mode == m
                Button {
                    analyst.mode = m
                } label: {
                    Text(m.title).font(.system(size: 12.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(on ? Theme.rowSelected : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }
}

// MARK: - Canvas

struct AnalystCanvas: View {
    let analyst: AnalystModel
    let run: StoredAnalystRun
    @Local private var scale: CGFloat = 1
    @Local private var offset: CGSize = .zero
    @Local private var dragBase: CGSize? = nil
    @Local private var scaleBase: CGFloat? = nil
    @Local private var viewSize: CGSize = .zero

    /// Mỗi cặp (nguồn, đích) là MỘT mũi tên, gộp mọi cổng.
    private var groups: [AnalystEdgeGroup] {
        AnalystEdgeGrouping.groups(run.topology.flows, results: run.results, mode: analyst.mode)
    }

    private func makeLayout(_ groups: [AnalystEdgeGroup]) -> GraphLayoutResult {
        GraphLayout.layout(
            nodes: run.topology.servers.map(\.hostID),
            edges: groups.map { GraphEdgeInput(from: $0.source, to: $0.destination) })
    }

    private var layout: GraphLayoutResult { makeLayout(groups) }

    /// Đổi khi bố cục thay đổi (để tự "Fit").
    private var signature: String {
        run.id.uuidString + "\(run.topology.servers.count)-\(run.topology.flows.count)"
    }

    var body: some View {
        let gs = groups
        let l = makeLayout(gs)
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { analyst.selection = nil }
                world(l, gs)
                    .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
                    .scaleEffect(scale, anchor: .topLeading)
                    .offset(offset)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { v in
                        let base = dragBase ?? offset
                        dragBase = base
                        offset = CGSize(
                            width: base.width + v.translation.width,
                            height: base.height + v.translation.height)
                    }
                    .onEnded { _ in dragBase = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { v in
                        let base = scaleBase ?? scale
                        scaleBase = base
                        zoom(to: base * v.magnification, in: geo.size)
                    }
                    .onEnded { _ in scaleBase = nil }
            )
            .overlay(alignment: .bottomLeading) { legend.padding(10) }
            .overlay(alignment: .bottomTrailing) { controls(l, geo.size).padding(10) }
            .onAppear {
                viewSize = geo.size
                fit(l, geo.size)
            }
            .onChange(of: signature) { fit(layout, geo.size) }
            .onChange(of: geo.size) { _, new in
                let first = viewSize == .zero
                viewSize = new
                if first { fit(layout, new) }
            }
        }
    }

    // MARK: Thế giới

    private func world(_ l: GraphLayoutResult, _ gs: [AnalystEdgeGroup]) -> some View {
        let sizes = gs.map { GraphLayout.labelSize(for: $0.label) }
        let geoms = gs.indices.compactMap { i in l.edges.first { $0.index == i } }
        let nodeRects = l.centers.values.map { GraphRect(center: $0, size: l.nodeSize) }
        let labelPoints = GraphLayout.placeLabels(edges: geoms, sizes: sizes, nodeRects: nodeRects)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(geoms.enumerated()), id: \.offset) { i, g in
                EdgeView(
                    geometry: g, group: gs[i], labelCenter: labelPoints[i], mode: analyst.mode,
                    selected: isSelected(gs[i])
                ) {
                    if let f = gs[i].singleFlow {
                        analyst.selection = .flow(f)
                    } else {
                        analyst.selection = .link(source: gs[i].source, destination: gs[i].destination)
                    }
                }
            }
            ForEach(run.topology.servers, id: \.hostID) { node in
                if let c = l.centers[node.hostID] {
                    NodeCard(
                        node: node, host: analyst.host(node.hostID),
                        incoming: AnalystPresentation.incomingPorts(run.topology.flows, for: node.hostID),
                        selected: analyst.selection == .node(node.hostID)
                    ) { analyst.selection = .node(node.hostID) }
                    .frame(width: l.nodeSize.width, height: l.nodeSize.height)
                    .position(x: c.x, y: c.y)
                }
            }
        }
    }

    private func isSelected(_ g: AnalystEdgeGroup) -> Bool {
        switch analyst.selection {
        case .flow(let f): return g.contains(f)
        case .link(let s, let d): return g.source == s && g.destination == d
        default: return false
        }
    }

    // MARK: Zoom / Fit

    private func fit(_ l: GraphLayoutResult, _ size: CGSize) {
        guard size.width > 0, size.height > 0, l.size.width > 0 else { return }
        let s = min(size.width / l.size.width, size.height / l.size.height, 1.15)
        scale = max(0.2, s)
        offset = CGSize(
            width: (size.width - l.size.width * scale) / 2,
            height: (size.height - l.size.height * scale) / 2)
    }

    /// Phóng/thu quanh tâm khung nhìn.
    private func zoom(to newScale: CGFloat, in size: CGSize) {
        let s = min(3, max(0.2, newScale))
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let k = s / scale
        offset = CGSize(width: c.x - (c.x - offset.width) * k, height: c.y - (c.y - offset.height) * k)
        scale = s
    }

    private func controls(_ l: GraphLayoutResult, _ size: CGSize) -> some View {
        HStack(spacing: 8) {
            ctl("minus", "Thu nhỏ") { zoom(to: scale / 1.25, in: size) }
            ctl("plus", "Phóng to") { zoom(to: scale * 1.25, in: size) }
            Button {
                fit(l, size)
            } label: {
                Text("Fit").font(.system(size: 12.5, weight: .medium)).frame(width: 44, height: 28)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardStroke))
            }
            .buttonStyle(.plain).accessibilityLabel("Vừa khung nhìn")
        }
    }

    private func ctl(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).frame(width: 30, height: 28)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.cardStroke))
        }
        .buttonStyle(.plain).accessibilityLabel(label)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            if analyst.mode == .tests {
                legendItem("Thông", Theme.green, dashed: false)
                legendItem("Lỗi", Theme.red, dashed: false)
                legendItem("Chưa thử / không kiểm tra được", Theme.textTertiary, dashed: true)
            } else {
                legendItem("Kết nối quan sát (chưa thử)", Theme.blue, dashed: false)
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }

    private func legendItem(_ text: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 6) {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 1))
                p.addLine(to: CGPoint(x: 26, y: 1))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [5, 3] : []))
            .frame(width: 26, height: 2)
            Text(text)
        }
    }
}

// MARK: - Nút và cạnh

private struct NodeCard: View {
    let node: ServerNode
    let host: HostProfile?
    let incoming: Set<Int>
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        let ip = node.addresses.first?.address ?? host.map(HostPresentation.addressText) ?? "—"
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack").font(.system(size: 22))
                    .foregroundStyle(node.collected ? Theme.textPrimary : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.displayName).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(ip).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            if node.collected {
                let lines = AnalystPresentation.listenLines(node, incoming: incoming, limit: 3)
                let labels = lines.labels
                ForEach(labels, id: \.self) { l in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.green).frame(width: 7, height: 7)
                        Text(l).font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if let more = lines.moreText {
                    Text("\(more) cổng khác").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                if labels.isEmpty {
                    Text(lines.internalCount > 0 ? "Chỉ cổng nội bộ" : "Không có cổng LISTEN")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
            } else {
                Label("Không thu thập được", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textPrimary)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    selected ? Theme.blue : Theme.textTertiary.opacity(0.5),
                    style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: node.collected ? [] : [4, 3]))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(perform: tap)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct EdgeView: View {
    let geometry: GraphEdgeGeometry
    let group: AnalystEdgeGroup
    let labelCenter: GraphPoint
    let mode: AnalystMapMode
    let selected: Bool
    let tap: () -> Void

    var body: some View {
        let style = group.style
        let color = style.color
        let s = CGPoint(x: geometry.start.x, y: geometry.start.y)
        let e = CGPoint(x: geometry.end.x, y: geometry.end.y)
        let line = Path { p in
            p.move(to: s)
            p.addLine(to: e)
        }
        ZStack {
            line.stroke(
                color,
                style: StrokeStyle(
                    lineWidth: selected ? 3.2 : 2, lineCap: .round, dash: style == .notTested ? [6, 4] : []))
            Arrow(from: s, to: e).fill(color)
            line.stroke(Color.clear, lineWidth: 16).contentShape(line.strokedPath(StrokeStyle(lineWidth: 16)))
                .onTapGesture(perform: tap)
            label(style, color)
                .position(x: labelCenter.x, y: labelCenter.y)
                .onTapGesture(perform: tap)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(group.label)
        .accessibilityAddTraits(.isButton)
    }

    private func label(_ style: AnalystEdgeStyle, _ color: Color) -> some View {
        HStack(spacing: 4) {
            if style == .failed { Image(systemName: "exclamationmark.triangle.fill") }
            Text(group.label).lineLimit(1).fixedSize()
        }
        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
        .foregroundStyle(style == .failed ? color : Theme.textPrimary)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(
                selected ? color : Theme.cardStroke, lineWidth: selected ? 1.5 : 1)
        )
    }
}

private struct Arrow: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in rect: CGRect) -> Path {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len: CGFloat = 11
        let spread: CGFloat = .pi / 7
        var p = Path()
        p.move(to: to)
        p.addLine(to: CGPoint(x: to.x - len * cos(angle - spread), y: to.y - len * sin(angle - spread)))
        p.addLine(to: CGPoint(x: to.x - len * cos(angle + spread), y: to.y - len * sin(angle + spread)))
        p.closeSubpath()
        return p
    }
}

// MARK: - Panel chi tiết

struct AnalystDetailPanel: View {
    let analyst: AnalystModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                switch analyst.selection {
                case .flow(let f): flowDetail(f)
                case .link(let src, let dst): linkDetail(src, dst)
                case .node(let id): nodeDetail(id)
                case nil:
                    Text("Chi tiết kết nối").font(.system(size: 17, weight: .semibold))
                    Text("Chọn một kết nối (mũi tên) hoặc một server trên bản đồ để xem chi tiết.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
        .cardStyle()
    }

    private func name(_ id: UUID) -> String { analyst.current?.topology.node(id)?.displayName ?? "?" }

    private func ip(_ id: UUID) -> String {
        analyst.current?.topology.node(id)?.addresses.first?.address
            ?? analyst.host(id).map(HostPresentation.addressText) ?? "—"
    }

    @ViewBuilder
    private func flowDetail(_ f: Flow) -> some View {
        if let run = analyst.current, let tf = run.topology.flows.first(where: { $0.flow == f }) {
            let result = run.results.first { $0.flow == f }
            let style = AnalystPresentation.style(result)
            HStack {
                Text("Chi tiết kết nối").font(.system(size: 17, weight: .semibold))
                Text(AnalystPresentation.badge(result)).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(style.color)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(style.color.opacity(0.7)))
            }
            Text("\(name(f.source)) → \(name(f.destination))").font(.system(size: 15, weight: .medium))
            VStack(alignment: .leading, spacing: 5) {
                info("Máy nguồn", "\(name(f.source)) (\(ip(f.source)))")
                info(
                    "Đích",
                    "\(name(f.destination)) (\(tf.destinationIPs.first?.address ?? ip(f.destination)):\(f.port))")
                info("Giao thức", "TCP")
                info("Nơi chạy thử", AnalystPresentation.originText(name(f.source)))
                info("Kết nối quan sát", "\(tf.observedConnections)")
                if !tf.sourceProcesses.isEmpty {
                    info("Tiến trình nguồn", tf.sourceProcesses.map(\.name).joined(separator: ", "))
                }
            }
            Divider().overlay(Theme.divider)
            checkBlock(AnalystPresentation.sourceCheck(result))
            Divider().overlay(Theme.divider)
            checkBlock(AnalystPresentation.destinationCheck(result, flow: tf))
            Divider().overlay(Theme.divider)
            let cause = AnalystPresentation.cause(result)
            VStack(alignment: .leading, spacing: 3) {
                Label("NGUYÊN NHÂN", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Text(cause.headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.amber)
                if let hint = cause.hint {
                    Text(hint).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            let ev = AnalystPresentation.evidence(result)
            if !ev.isEmpty {
                Divider().overlay(Theme.divider)
                Label("BẰNG CHỨNG", systemImage: "doc.text").font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                ForEach(Array(ev.enumerated()), id: \.offset) { _, e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 12.5, weight: .medium))
                        Text(e.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 8) {
                Button {
                    analyst.retest(f)
                } label: {
                    Label(
                        analyst.retesting == f ? "Đang thử…" : "Thử lại kết nối",
                        systemImage: "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle(fullWidth: true))
                .disabled(analyst.isRunning || analyst.viewingHistory)
                .help(analyst.viewingHistory ? "Lần chạy cũ chỉ để xem" : "Probe lại đúng kết nối này")
                Button {
                    analyst.openWarp(f.source)
                } label: {
                    Label("Mở Warp", systemImage: "terminal").frame(maxWidth: .infinity)
                }
                .buttonStyle(OutlineButtonStyle(fullWidth: true))
                .help("Mở server nguồn \(name(f.source)) trong Warp")
            }
        } else {
            Text("Kết nối không còn trong lần chạy này.").foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private func linkDetail(_ src: UUID, _ dst: UUID) -> some View {
        if let run = analyst.current {
            let group = AnalystEdgeGrouping.groups(run.topology.flows, results: run.results).first {
                $0.source == src && $0.destination == dst
            }
            if let group {
                Text("Chi tiết kết nối").font(.system(size: 17, weight: .semibold))
                Text("\(name(src)) → \(name(dst))").font(.system(size: 15, weight: .medium))
                Text("\(group.flows.count) cổng giữa hai server. Chọn một cổng để xem chi tiết.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                ForEach(Array(group.flows.enumerated()), id: \.offset) { i, tf in
                    let r = group.results[i]
                    let style = AnalystPresentation.style(r)
                    Button {
                        analyst.selection = .flow(tf.flow)
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(style.color).frame(width: 8, height: 8)
                            Text(":\(tf.flow.port)/TCP").font(.system(size: 12.5, design: .monospaced))
                            Spacer()
                            Text(r.map { AnalystPresentation.resultText($0.outcome) } ?? "Chưa thử")
                                .foregroundStyle(style.color)
                            Text(r.map { AnalystPresentation.timeText($0.outcome) } ?? "—")
                                .font(.system(size: 12.5).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                            Image(systemName: "chevron.right").font(.system(size: 10))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(Theme.control, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Text("Kết nối không còn trong lần chạy này.").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func nodeDetail(_ id: UUID) -> some View {
        if let run = analyst.current, let node = run.topology.node(id) {
            Text("Chi tiết server").font(.system(size: 17, weight: .semibold))
            Text(node.displayName).font(.system(size: 15, weight: .medium))
            VStack(alignment: .leading, spacing: 5) {
                info("Địa chỉ", node.addresses.isEmpty ? ip(id) : node.addresses.map(\.address).joined(separator: ", "))
                info("Thu thập", AnalystPresentation.collectionStatus(node, warnings: run.warnings))
                info("Kết nối ra ngoài project", AnalystPresentation.externalText(node))
            }
            let issues = AnalystPresentation.issues(for: id, in: run.warnings)
            if !issues.isEmpty {
                Divider().overlay(Theme.divider)
                Label("LỖI THU THẬP", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.amber)
                ForEach(issues, id: \.self) { Text($0).font(.system(size: 12.5)) }
            }
            if node.collected {
                Divider().overlay(Theme.divider)
                Text("CỔNG LISTEN").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                if node.listening.isEmpty {
                    Text("Không có").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(Array(node.listening.enumerated()), id: \.offset) { _, e in
                    HStack {
                        Text(":\(e.port)").font(.system(size: 12.5, design: .monospaced))
                        Text(AnalystPresentation.bindText(e)).font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Text(e.processes?.map(\.name).joined(separator: ", ") ?? "không rõ")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            let outgoing = run.topology.flows.filter { $0.flow.source == id }
            let incoming = run.topology.flows.filter { $0.flow.destination == id }
            if !outgoing.isEmpty || !incoming.isEmpty {
                Divider().overlay(Theme.divider)
                Text("KẾT NỐI TRONG PROJECT").font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                ForEach(outgoing, id: \.flow) { tf in
                    flowLink("→ \(name(tf.flow.destination)) :\(tf.flow.port)", tf.flow, run)
                }
                ForEach(incoming, id: \.flow) { tf in
                    flowLink("← \(name(tf.flow.source)) :\(tf.flow.port)", tf.flow, run)
                }
            }
            Button {
                analyst.openWarp(id)
            } label: {
                Label("Mở Warp", systemImage: "terminal").frame(maxWidth: .infinity)
            }
            .buttonStyle(OutlineButtonStyle(fullWidth: true))
        } else {
            Text("Server không còn trong lần chạy này.").foregroundStyle(Theme.textSecondary)
        }
    }

    private func flowLink(_ text: String, _ flow: Flow, _ run: StoredAnalystRun) -> some View {
        let style = AnalystPresentation.style(run.results.first { $0.flow == flow })
        return Button {
            analyst.selection = .flow(flow)
        } label: {
            HStack {
                Circle().fill(style.color).frame(width: 7, height: 7)
                Text(text).font(.system(size: 12.5, design: .monospaced))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func info(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).foregroundStyle(Theme.textSecondary).frame(width: 112, alignment: .leading)
            Text(v).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
    }

    private func checkBlock(_ c: AnalystCheckLine) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(
                systemName: c.tone == .good
                    ? "checkmark.circle.fill" : (c.tone == .bad ? "xmark.circle.fill" : "questionmark.circle")
            )
            .foregroundStyle(c.tone.color).font(.system(size: 17))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                Text(c.headline).font(.system(size: 15, weight: .semibold)).foregroundStyle(c.tone.color)
                if let d = c.detail {
                    Text(d).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }
}
