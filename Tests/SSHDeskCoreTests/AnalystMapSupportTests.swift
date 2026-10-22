import Foundation
import Testing

@testable import SSHDeskCore

/// G3: gộp cạnh, bố cục khung bản đồ/bảng, dòng LISTEN trên thẻ, đặt nhãn cạnh (cảnh Ping-Identity).
struct AnalystMapSupportTests {
    typealias F = AnalystFixtures
    typealias P = AnalystPresentation

    static let am = UUID()
    static let idm = UUID()
    static let ds = UUID()

    static func ping() -> Topology {
        func snap(_ id: UUID, _ name: String, _ ip: String, _ ss: String) -> ServerSnapshot {
            ServerSnapshot(
                hostID: id, displayName: name, hostName: ip, addresses: F.addrs(ip),
                sockets: F.sockets(ss))
        }
        let base = """
            LISTEN 0 128 0.0.0.0:22 0.0.0.0:*
            LISTEN 0 4096 127.0.0.53:53 0.0.0.0:*
            """
        return TopologyBuilder.build([
            snap(
                am, "Ping-AM", "172.16.50.80",
                base + "\nESTAB 0 0 172.16.50.80:40000 172.16.50.82:1636"),
            snap(
                idm, "Ping-IDM", "172.16.50.81",
                base + "\nESTAB 0 0 172.16.50.81:40001 172.16.50.82:1389"
                    + "\nESTAB 0 0 172.16.50.81:40002 172.16.50.82:1636"),
            snap(
                ds, "Ping-DS", "172.16.50.82",
                base + "\nLISTEN 0 128 0.0.0.0:1389 0.0.0.0:*\nLISTEN 0 128 0.0.0.0:1636 0.0.0.0:*"),
        ])
    }

    static func result(_ f: Flow, _ o: ProbeOutcome) -> FlowTestResult {
        FlowTestResult(flow: f, outcome: o, destinationCheck: .unknown, evidence: [], cause: nil)
    }

    // MARK: Gộp cạnh

    @Test func sameSourceDestinationMergesIntoOneArrow() throws {
        let t = Self.ping()
        #expect(t.flows.count == 3)
        let rs = t.flows.map {
            Self.result($0.flow, .passed(milliseconds: $0.flow.port == 1389 ? 142 : 141))
        }
        let groups = AnalystEdgeGrouping.groups(t.flows, results: rs)
        #expect(groups.count == 2)
        let g = try #require(groups.first { $0.source == Self.idm })
        #expect(g.ports == [1389, 1636])
        #expect(g.label == "TCP :1389, :1636 · 142 ms")
        #expect(g.style == .passed && g.singleFlow == nil)
        let single = try #require(groups.first { $0.source == Self.am })
        #expect(single.label == "TCP :1636 · 141 ms")
        #expect(single.singleFlow == single.flows[0].flow)
    }

    @Test func worstStyleWinsAndFailureIsCounted() throws {
        let t = Self.ping()
        let f1389 = t.flows.first { $0.flow.port == 1389 }!.flow
        let f1636 = t.flows.first { $0.flow.source == Self.idm && $0.flow.port == 1636 }!.flow
        var rs = [Self.result(f1389, .passed(milliseconds: 5)), Self.result(f1636, .failed(.timeout))]
        var g = AnalystEdgeGrouping.groups(t.flows, results: rs).first { $0.source == Self.idm }!
        #expect(g.style == .failed && g.label == "TCP :1389, :1636 · 1/2 lỗi")
        rs = [
            Self.result(f1389, .passed(milliseconds: 5)),
            Self.result(f1636, .untestable(.sessionLost)),
        ]
        g = AnalystEdgeGrouping.groups(t.flows, results: rs).first { $0.source == Self.idm }!
        #expect(g.style == .notTested)
        g = AnalystEdgeGrouping.groups(t.flows, results: []).first { $0.source == Self.idm }!
        #expect(g.style == .notTested && g.label == "TCP :1389, :1636")
        g = AnalystEdgeGrouping.groups(t.flows, results: [], mode: .observed)
            .first { $0.source == Self.idm }!
        #expect(g.style == .observed && g.label == "TCP :1389, :1636 · 2 kết nối")
    }

    // MARK: Khung bản đồ / bảng

    @Test func tableHeightFollowsContentWithBounds() {
        let lay = AnalystPanelLayout.self
        // Ít hàng: tối thiểu 3 hàng, không giãn.
        #expect(lay.tableHeight(rowCount: 1, available: 600) == lay.minTableHeight())
        #expect(lay.tableHeight(rowCount: 3, available: 600) == lay.contentHeight(rowCount: 3))
        // Nhiều hàng: tối đa 40% rồi cuộn.
        #expect(lay.tableHeight(rowCount: 100, available: 600) == 240)
        // Cửa sổ nhỏ: không dưới 3 hàng, bản đồ vẫn còn chỗ.
        let small = lay.tableHeight(rowCount: 100, available: 420)
        #expect(small >= lay.minTableHeight())
        #expect(lay.mapHeight(available: 420, tableHeight: small) >= 420 - lay.splitterHeight - small)
        // Kéo: kẹp, luôn chừa bản đồ tối thiểu.
        #expect(lay.tableHeight(rowCount: 3, available: 600, override: 5000) == 600 - 10 - 200)
        #expect(lay.tableHeight(rowCount: 3, available: 600, override: 1) == lay.minTableHeight())
        #expect(lay.tableHeight(rowCount: 3, available: 600, override: 300) == 300)
    }

    // MARK: LISTEN trên thẻ

    @Test func listenLinesMatchScreenshotCase() throws {
        let t = Self.ping()
        let ds = try #require(t.node(Self.ds))
        let lines = P.listenLines(ds, incoming: P.incomingPorts(t.flows, for: Self.ds))
        // :1389/:1636 có cạnh vào lên đầu, :22 sau; :53 (127.0.0.53) bị bỏ.
        #expect(lines.labels == ["LISTEN :1389", "LISTEN :1636", "LISTEN :22"])
        #expect(lines.hiddenCount == 0 && lines.moreText == nil && lines.internalCount == 1)
        let am = try #require(t.node(Self.am))
        #expect(P.listenLines(am, incoming: []).labels == ["LISTEN :22"])
    }

    @Test func listenLinesCapAtThreeWithMore() {
        let entries = [22, 80, 443, 8080, 9090].map {
            ListenEntry(port: $0, bind: nil, isWildcard: true, processes: nil)
        }
        let node = ServerNode(
            hostID: UUID(), displayName: "x", collected: true, addresses: [], listening: entries,
            externalConnections: 0)
        let lines = P.listenLines(node, incoming: [9090])
        #expect(lines.labels == ["LISTEN :9090", "LISTEN :22", "LISTEN :80"])
        #expect(lines.moreText == "+2")
    }

    @Test func loopbackOnlyPortStaysIfAlsoBoundExternally() {
        let lo = ListenEntry(port: 53, bind: IPLiteral("127.0.0.1"), isWildcard: false, processes: nil)
        let any = ListenEntry(port: 53, bind: nil, isWildcard: true, processes: nil)
        let v6 = ListenEntry(port: 631, bind: IPLiteral("::1"), isWildcard: false, processes: nil)
        let node = ServerNode(
            hostID: UUID(), displayName: "x", collected: true, addresses: [], listening: [lo, any, v6],
            externalConnections: 0)
        #expect(P.listenLines(node, incoming: []).labels == ["LISTEN :53"])
        #expect(P.bindText(lo) == "127.0.0.1 (nội bộ)" && P.bindText(v6) == "::1 (nội bộ)")
        #expect(P.bindText(any) == "*")
    }

    // MARK: Đặt nhãn

    func rects(_ l: GraphLayoutResult) -> [GraphRect] {
        l.centers.values.map { GraphRect(center: $0, size: l.nodeSize) }
    }

    @Test func singleLabelSitsAtMidpoint() {
        let l = GraphLayout.layout(nodes: [F.fe, F.be], edges: [GraphEdgeInput(from: F.fe, to: F.be)])
        let p = GraphLayout.placeLabels(
            edges: l.edges, sizes: [GraphLayout.labelSize(for: "TCP :80 · 4 ms")], nodeRects: rects(l))
        #expect(p == [l.edges[0].mid])
    }

    @Test func convergingEdgesGetNonOverlappingLabelsClearOfNodes() {
        let nodes = [Self.am, Self.idm, Self.ds]
        let edges = [
            GraphEdgeInput(from: Self.am, to: Self.ds), GraphEdgeInput(from: Self.idm, to: Self.ds),
        ]
        let l = GraphLayout.layout(nodes: nodes, edges: edges)
        let texts = ["TCP :1636 · 131 ms", "TCP :1389, :1636 · 142 ms"]
        let sizes = texts.map(GraphLayout.labelSize(for:))
        let pts = GraphLayout.placeLabels(edges: l.edges, sizes: sizes, nodeRects: rects(l))
        let r = zip(pts, sizes).map { GraphRect(center: $0, size: $1) }
        #expect(!r[0].intersects(r[1]))
        for n in rects(l) { for x in r { #expect(!x.intersects(n)) } }
    }

    @Test func manyEdgesSameMidpointAllSeparated() {
        let e = GraphEdgeGeometry(
            index: 0, start: GraphPoint(x: 0, y: 0), end: GraphPoint(x: 0, y: 200))
        let edges = (0..<4).map { i -> GraphEdgeGeometry in
            var c = e
            c.index = i
            return c
        }
        let sizes = Array(repeating: GraphSize(width: 100, height: 22), count: 4)
        let pts = GraphLayout.placeLabels(edges: edges, sizes: sizes, nodeRects: [])
        let r = zip(pts, sizes).map { GraphRect(center: $0, size: $1) }
        for i in 0..<4 { for j in (i + 1)..<4 { #expect(!r[i].intersects(r[j])) } }
    }
}
