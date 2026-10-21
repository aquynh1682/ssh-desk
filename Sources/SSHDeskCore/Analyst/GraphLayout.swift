import Foundation

public struct GraphPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct GraphSize: Sendable, Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct GraphEdgeInput: Sendable, Equatable {
    public var from: UUID
    public var to: UUID
    public init(from: UUID, to: UUID) {
        self.from = from
        self.to = to
    }
}

public struct GraphEdgeGeometry: Sendable, Equatable {
    /// Chỉ số trong mảng cạnh đầu vào.
    public var index: Int
    public var start: GraphPoint
    public var end: GraphPoint
    /// Trung điểm (đặt nhãn).
    public var mid: GraphPoint { GraphPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2) }
}

public struct GraphLayoutResult: Sendable, Equatable {
    /// Tâm nút, toạ độ tuyệt đối (gốc ở góc trên trái), đơn vị điểm.
    public var centers: [UUID: GraphPoint]
    /// Tâm nút chuẩn hoá về 0...1 theo `size`.
    public var normalized: [UUID: GraphPoint]
    /// Lớp của từng nút (0 = trên cùng).
    public var layerOf: [UUID: Int]
    public var layers: [[UUID]]
    public var size: GraphSize
    public var nodeSize: GraphSize
    public var edges: [GraphEdgeGeometry]
}

/// Bố trí đồ thị theo lớp (Sugiyama rút gọn). Thuần: không phụ thuộc UI.
/// - Nút không có cạnh vào ở lớp trên; lớp = đường dài nhất từ nguồn. Chu trình được phá bằng cách đảo
///   các cạnh ngược khi DFS (không treo).
/// - Giảm giao cắt bằng sắp theo barycenter (2 vòng xuống/lên).
/// - Nút cô lập (không có cạnh) xếp thành hàng cuối.
public enum GraphLayout {
    public static func layout(
        nodes: [UUID], edges: [GraphEdgeInput],
        nodeSize: GraphSize = GraphSize(width: 190, height: 106),
        spacing: GraphSize = GraphSize(width: 80, height: 90), margin: Double = 40
    ) -> GraphLayoutResult {
        let nodeSet = Set(nodes)
        let valid = edges.enumerated().filter {
            $0.element.from != $0.element.to && nodeSet.contains($0.element.from)
                && nodeSet.contains($0.element.to)
        }

        // Hàng xóm theo thứ tự nút đầu vào (kết quả xác định).
        let pos = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($1, $0) })
        var out: [UUID: [UUID]] = [:]
        var connected = Set<UUID>()
        for (_, e) in valid {
            if !(out[e.from] ?? []).contains(e.to) { out[e.from, default: []].append(e.to) }
            connected.insert(e.from)
            connected.insert(e.to)
        }
        for k in out.keys { out[k]?.sort { pos[$0]! < pos[$1]! } }

        // Phá chu trình: DFS lặp; cạnh tới nút đang trên stack là cạnh ngược → bỏ qua khi xếp lớp.
        var state: [UUID: Int] = [:]  // 1 = đang duyệt, 2 = xong
        var dag: [UUID: [UUID]] = [:]
        func visit(_ root: UUID) {
            var stack: [(UUID, Int)] = [(root, 0)]
            state[root] = 1
            while !stack.isEmpty {
                let (n, i) = stack.removeLast()
                let next = out[n] ?? []
                if i < next.count {
                    stack.append((n, i + 1))
                    let m = next[i]
                    switch state[m] {
                    case nil:
                        dag[n, default: []].append(m)
                        state[m] = 1
                        stack.append((m, 0))
                    case 2: dag[n, default: []].append(m)
                    default: break  // cạnh ngược
                    }
                } else {
                    state[n] = 2
                }
            }
        }
        // Ưu tiên bắt đầu từ nút không có cạnh vào (theo cạnh gốc).
        var hasIn = Set<UUID>()
        for (_, e) in valid { hasIn.insert(e.to) }
        let connectedNodes = nodes.filter { connected.contains($0) }
        for n in connectedNodes where !hasIn.contains(n) && state[n] == nil { visit(n) }
        for n in connectedNodes where state[n] == nil { visit(n) }

        // Lớp = đường dài nhất trên DAG (theo thứ tự topo đảo của DFS).
        var layer: [UUID: Int] = [:]
        var indeg: [UUID: Int] = [:]
        for n in connectedNodes { indeg[n] = 0 }
        for (_, tos) in dag { for t in tos { indeg[t, default: 0] += 1 } }
        var queue = connectedNodes.filter { (indeg[$0] ?? 0) == 0 }
        for n in queue { layer[n] = 0 }
        var qi = 0
        while qi < queue.count {
            let n = queue[qi]
            qi += 1
            for m in dag[n] ?? [] {
                layer[m] = max(layer[m] ?? 0, (layer[n] ?? 0) + 1)
                indeg[m, default: 0] -= 1
                if indeg[m] == 0 { queue.append(m) }
            }
        }

        var layers: [[UUID]] = []
        for n in connectedNodes {
            let l = layer[n] ?? 0
            while layers.count <= l { layers.append([]) }
            layers[l].append(n)
        }

        // Barycenter: lượt xuống rồi lượt lên, 2 vòng.
        var preds: [UUID: [UUID]] = [:]
        var succs: [UUID: [UUID]] = [:]
        for (_, e) in valid {
            preds[e.to, default: []].append(e.from)
            succs[e.from, default: []].append(e.to)
        }
        func order(_ li: Int, by neighbors: [UUID: [UUID]]) {
            var index: [UUID: Int] = [:]
            for l in layers { for (i, n) in l.enumerated() { index[n] = i } }
            let current = layers[li]
            var keyed: [(UUID, Double, Int)] = []
            for (i, n) in current.enumerated() {
                let ns = (neighbors[n] ?? []).filter { layer[$0] != layer[n] }
                let bary =
                    ns.isEmpty
                    ? Double(i) : ns.map { Double(index[$0] ?? 0) }.reduce(0, +) / Double(ns.count)
                keyed.append((n, bary, i))
            }
            keyed.sort { ($0.1, $0.2) < ($1.1, $1.2) }
            layers[li] = keyed.map(\.0)
        }
        if layers.count > 1 {
            for _ in 0..<2 {
                for li in 1..<layers.count { order(li, by: preds) }
                for li in stride(from: layers.count - 2, through: 0, by: -1) { order(li, by: succs) }
            }
        }

        // Nút cô lập: hàng cuối.
        let isolated = nodes.filter { !connected.contains($0) }
        if !isolated.isEmpty { layers.append(isolated) }
        for (li, l) in layers.enumerated() { for n in l { layer[n] = li } }

        // Toạ độ.
        let maxCount = max(1, layers.map(\.count).max() ?? 1)
        let innerWidth = Double(maxCount) * nodeSize.width + Double(maxCount - 1) * spacing.width
        let totalWidth = innerWidth + 2 * margin
        let rows = max(1, layers.count)
        let totalHeight =
            Double(rows) * nodeSize.height + Double(rows - 1) * spacing.height + 2 * margin
        var centers: [UUID: GraphPoint] = [:]
        for (li, l) in layers.enumerated() {
            let rowWidth = Double(l.count) * nodeSize.width + Double(max(0, l.count - 1)) * spacing.width
            let startX = margin + (innerWidth - rowWidth) / 2
            let y = margin + Double(li) * (nodeSize.height + spacing.height) + nodeSize.height / 2
            for (i, n) in l.enumerated() {
                let x = startX + Double(i) * (nodeSize.width + spacing.width) + nodeSize.width / 2
                centers[n] = GraphPoint(x: x, y: y)
            }
        }
        let size = GraphSize(width: totalWidth, height: totalHeight)
        let normalized = centers.mapValues {
            GraphPoint(x: $0.x / totalWidth, y: $0.y / totalHeight)
        }

        // Cạnh: cắt đoạn tâm→tâm tại biên hình chữ nhật; cạnh song song/hai chiều lệch sang hai bên.
        var groups: [String: [Int]] = [:]
        for (i, e) in valid {
            let a = e.from.uuidString
            let b = e.to.uuidString
            let key = a < b ? "\(a)|\(b)" : "\(b)|\(a)"
            groups[key, default: []].append(i)
        }
        var geoms: [GraphEdgeGeometry] = []
        for (i, e) in valid {
            guard let c1 = centers[e.from], let c2 = centers[e.to] else { continue }
            let a = e.from.uuidString
            let b = e.to.uuidString
            let key = a < b ? "\(a)|\(b)" : "\(b)|\(a)"
            let group = groups[key] ?? [i]
            let slot = group.firstIndex(of: i) ?? 0
            var offset = (Double(slot) - Double(group.count - 1) / 2) * 22
            if a > b { offset = -offset }  // cùng một phía pháp tuyến cho cả hai chiều của cặp
            let dx = c2.x - c1.x
            let dy = c2.y - c1.y
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            let nx = -dy / len
            let ny = dx / len
            let p1 = GraphPoint(x: c1.x + nx * offset, y: c1.y + ny * offset)
            let p2 = GraphPoint(x: c2.x + nx * offset, y: c2.y + ny * offset)
            let s = clip(from: p1, to: p2, center: c1, size: nodeSize)
            let t = clip(from: p2, to: p1, center: c2, size: nodeSize)
            geoms.append(GraphEdgeGeometry(index: i, start: s, end: t))
        }
        geoms.sort { $0.index < $1.index }
        return GraphLayoutResult(
            centers: centers, normalized: normalized, layerOf: layer, layers: layers, size: size,
            nodeSize: nodeSize, edges: geoms)
    }

    /// Điểm trên biên hình chữ nhật (tâm `center`, kích thước `size`) theo tia từ `from` hướng tới `to`,
    /// với `from` nằm trong hình chữ nhật (hoặc gần tâm).
    static func clip(from: GraphPoint, to: GraphPoint, center: GraphPoint, size: GraphSize)
        -> GraphPoint
    {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let hw = size.width / 2
        let hh = size.height / 2
        var tMax = Double.infinity
        if abs(dx) > 1e-9 {
            let tx = ((dx > 0 ? center.x + hw : center.x - hw) - from.x) / dx
            if tx >= 0 { tMax = min(tMax, tx) }
        }
        if abs(dy) > 1e-9 {
            let ty = ((dy > 0 ? center.y + hh : center.y - hh) - from.y) / dy
            if ty >= 0 { tMax = min(tMax, ty) }
        }
        guard tMax.isFinite else { return from }
        return GraphPoint(x: from.x + dx * tMax, y: from.y + dy * tMax)
    }
}
