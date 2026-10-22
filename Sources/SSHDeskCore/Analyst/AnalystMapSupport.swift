import Foundation

// Logic thuần cho bản đồ Project Analyst (G3): gộp cạnh cùng cặp nút, bố cục khung bản đồ/bảng,
// dòng LISTEN trên thẻ server và đặt nhãn cạnh không chồng nhau.

// MARK: - Gộp cạnh cùng (nguồn, đích)

/// Một mũi tên trên bản đồ = mọi cổng cùng (nguồn, đích).
public struct AnalystEdgeGroup: Sendable, Equatable {
    public var source: UUID
    public var destination: UUID
    /// Sắp theo cổng tăng dần.
    public var flows: [TopologyFlow]
    public var results: [FlowTestResult?]
    public var style: AnalystEdgeStyle
    public var label: String

    public var ports: [Int] { flows.map(\.flow.port) }
    /// Có đúng một cổng: click chọn thẳng kết nối đó.
    public var singleFlow: Flow? { flows.count == 1 ? flows[0].flow : nil }

    public func contains(_ flow: Flow) -> Bool { flows.contains { $0.flow == flow } }
}

public enum AnalystEdgeGrouping {
    /// Gộp theo (nguồn, đích), giữ thứ tự xuất hiện đầu tiên của cặp.
    /// Màu = xấu nhất (lỗi > chưa thử/không kiểm tra được > thông); thời gian = lớn nhất.
    public static func groups(
        _ topology: [TopologyFlow], results: [FlowTestResult], mode: AnalystMapMode = .tests
    ) -> [AnalystEdgeGroup] {
        struct Key: Hashable {
            var s: UUID
            var d: UUID
        }
        var order: [Key] = []
        var byKey: [Key: [TopologyFlow]] = [:]
        for tf in topology {
            let k = Key(s: tf.flow.source, d: tf.flow.destination)
            if byKey[k] == nil { order.append(k) }
            byKey[k, default: []].append(tf)
        }
        return order.map { k in
            let flows = (byKey[k] ?? []).sorted { $0.flow.port < $1.flow.port }
            let rs = flows.map { tf in results.first { $0.flow == tf.flow } }
            return AnalystEdgeGroup(
                source: k.s, destination: k.d, flows: flows, results: rs,
                style: worstStyle(rs, mode: mode), label: label(flows, rs, mode: mode))
        }
    }

    static func worstStyle(_ rs: [FlowTestResult?], mode: AnalystMapMode) -> AnalystEdgeStyle {
        if mode == .observed { return .observed }
        let styles = rs.map { AnalystPresentation.style($0) }
        if styles.contains(.failed) { return .failed }
        if styles.contains(.notTested) { return .notTested }
        return .passed
    }

    /// `TCP :1389, :1636 · 142 ms`; một cổng thì giống `AnalystPresentation.edgeLabel`.
    static func label(_ flows: [TopologyFlow], _ rs: [FlowTestResult?], mode: AnalystMapMode) -> String {
        if flows.count == 1 {
            return AnalystPresentation.edgeLabel(flows[0], result: rs[0], mode: mode)
        }
        let base = "TCP " + flows.map { ":\($0.flow.port)" }.joined(separator: ", ")
        if mode == .observed {
            return base + " · \(flows.reduce(0) { $0 + $1.observedConnections }) kết nối"
        }
        let n = flows.count
        let failed = rs.filter { $0?.outcome.isFailed ?? false }.count
        if failed > 0 { return base + " · \(failed)/\(n) lỗi" }
        let untested = rs.filter { r in
            guard let r else { return true }
            if case .untestable = r.outcome { return true }
            return false
        }.count
        if untested == n, rs.allSatisfy({ $0 == nil }) { return base }
        if untested > 0 { return base + " · \(untested)/\(n) không kiểm tra được" }
        let ms = rs.compactMap { r -> Int? in
            if case .passed(let ms)? = r?.outcome { return ms }
            return nil
        }.max()
        return base + (ms.map { " · " + AnalystPresentation.millisText($0) } ?? "")
    }
}

// MARK: - Bố cục khung bản đồ / bảng

public enum AnalystPanelLayout {
    public static let rowHeight = 28.0
    public static let minRows = 3
    /// Tiêu đề thẻ (~42) + hàng tiêu đề cột (~30) + đường kẻ.
    public static let tableChrome = 73.0
    public static let splitterHeight = 10.0
    public static let minMapHeight = 200.0
    public static let maxAutoFraction = 0.4

    public static func minTableHeight() -> Double { tableChrome + Double(minRows) * rowHeight }

    /// Chiều cao theo nội dung (≥ 3 hàng).
    public static func contentHeight(rowCount: Int) -> Double {
        tableChrome + Double(max(minRows, rowCount)) * rowHeight
    }

    /// Chiều cao khung bảng. `available` = chiều cao cột trái (gồm cả thanh chia).
    /// Không kéo: min(nội dung, 40% `available`) nhưng không dưới 3 hàng. Có kéo (`override`): kẹp trong
    /// [3 hàng, phần còn lại sau khi chừa `minMapHeight`]. Bản đồ luôn nhận phần còn lại.
    public static func tableHeight(rowCount: Int, available: Double, override: Double? = nil) -> Double {
        let lo = minTableHeight()
        let hi = max(lo, available - splitterHeight - minMapHeight)
        let wanted =
            override
            ?? min(contentHeight(rowCount: rowCount), max(lo, available * maxAutoFraction))
        return min(max(wanted, lo), hi)
    }

    public static func mapHeight(available: Double, tableHeight: Double) -> Double {
        max(0, available - splitterHeight - tableHeight)
    }
}

// MARK: - Dòng LISTEN trên thẻ server

public struct NodeListenLines: Sendable, Equatable {
    public var labels: [String]
    /// Số cổng hiển thị được còn lại sau khi cắt (không tính cổng chỉ-loopback).
    public var hiddenCount: Int
    /// Số cổng chỉ bind loopback (bị ẩn khỏi thẻ).
    public var internalCount: Int

    public var moreText: String? { hiddenCount > 0 ? "+\(hiddenCount)" : nil }
}

extension AnalystPresentation {
    /// Cổng có cạnh đi vào `id`.
    public static func incomingPorts(_ flows: [TopologyFlow], for id: UUID) -> Set<Int> {
        Set(flows.filter { $0.flow.destination == id }.map(\.flow.port))
    }

    /// Thứ tự: (a) cổng có cạnh vào, (b) cổng bind ngoài loopback khác, (c) bỏ cổng chỉ-loopback.
    /// Mỗi nhóm sắp theo cổng; khử trùng cổng; tối đa `limit` dòng.
    public static func listenLines(_ node: ServerNode, incoming: Set<Int>, limit: Int = 3)
        -> NodeListenLines
    {
        var externalPorts = Set<Int>()
        var allPorts = Set<Int>()
        for e in node.listening {
            allPorts.insert(e.port)
            if !e.isLoopbackOnly { externalPorts.insert(e.port) }
        }
        let a = externalPorts.filter { incoming.contains($0) }.sorted()
        let b = externalPorts.filter { !incoming.contains($0) }.sorted()
        let ordered = a + b
        return NodeListenLines(
            labels: ordered.prefix(limit).map { "LISTEN :\($0)" },
            hiddenCount: max(0, ordered.count - limit),
            internalCount: allPorts.subtracting(externalPorts).count)
    }

    /// Bind trong panel chi tiết: loopback ghi "(nội bộ)".
    public static func bindText(_ e: ListenEntry) -> String {
        e.isLoopbackOnly ? "\(e.bindDisplay) (nội bộ)" : e.bindDisplay
    }
}

// MARK: - Đặt nhãn cạnh

public struct GraphRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Hình chữ nhật theo tâm.
    public init(center: GraphPoint, size: GraphSize) {
        self.init(
            x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
            height: size.height)
    }

    public func intersects(_ o: GraphRect, padding: Double = 0) -> Bool {
        x - padding < o.x + o.width && o.x - padding < x + width && y - padding < o.y + o.height
            && o.y - padding < y + height
    }
}

extension GraphLayout {
    /// Kích thước nhãn ước lượng (chữ monospaced 11.5 pt + padding).
    public static func labelSize(for text: String) -> GraphSize {
        GraphSize(width: Double(text.count) * 7.0 + 18, height: 22)
    }

    /// Tâm nhãn cho từng cạnh (cùng thứ tự `edges`). Mặc định ở trung điểm; nếu va chạm với nhãn đã đặt
    /// hoặc nút thì thử trượt dọc đoạn rồi dịch vuông góc, lấy ứng viên gần trung điểm nhất không va chạm.
    public static func placeLabels(
        edges: [GraphEdgeGeometry], sizes: [GraphSize], nodeRects: [GraphRect], padding: Double = 3
    ) -> [GraphPoint] {
        var placed: [GraphRect] = []
        var result: [GraphPoint] = []
        for (i, e) in edges.enumerated() {
            let size = i < sizes.count ? sizes[i] : GraphSize(width: 80, height: 22)
            let dx = e.end.x - e.start.x
            let dy = e.end.y - e.start.y
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len
            let ny = dx / len
            var candidates: [(cost: Double, p: GraphPoint)] = []
            for t in [0.5, 0.4, 0.6, 0.3, 0.7, 0.2, 0.8] {
                for k in -8...8 {
                    let perp = Double(k) * 16
                    let cost = abs(t - 0.5) * len * 0.5 + abs(perp)
                    candidates.append(
                        (
                            cost,
                            GraphPoint(
                                x: e.start.x + dx * t + nx * perp, y: e.start.y + dy * t + ny * perp)
                        ))
                }
            }
            candidates.sort { $0.cost < $1.cost }  // ổn định cho cost bằng nhau không cần thiết
            var chosen = e.mid
            for c in candidates {
                let r = GraphRect(center: c.p, size: size)
                if placed.contains(where: { $0.intersects(r, padding: padding) }) { continue }
                if nodeRects.contains(where: { $0.intersects(r, padding: padding) }) { continue }
                chosen = c.p
                break
            }
            placed.append(GraphRect(center: chosen, size: size))
            result.append(chosen)
        }
        return result
    }
}
