import Foundation
import Testing

@testable import SSHDeskCore

struct GraphLayoutTests {
    typealias F = AnalystFixtures

    @Test func mockupHasFourLayersAndNoOverlap() {
        let nodes = [F.fe, F.be, F.api, F.db, F.cache]
        let edges = [
            GraphEdgeInput(from: F.fe, to: F.be), GraphEdgeInput(from: F.be, to: F.api),
            GraphEdgeInput(from: F.api, to: F.db), GraphEdgeInput(from: F.api, to: F.cache),
        ]
        let l = GraphLayout.layout(nodes: nodes, edges: edges)
        #expect(l.layers.count == 4)
        #expect(l.layerOf[F.fe] == 0 && l.layerOf[F.be] == 1 && l.layerOf[F.api] == 2)
        #expect(l.layerOf[F.db] == 3 && l.layerOf[F.cache] == 3)
        assertNoOverlap(l)
        // chuẩn hoá nằm trong 0...1
        for p in l.normalized.values { #expect((0...1).contains(p.x) && (0...1).contains(p.y)) }
        #expect(l.edges.count == 4)
    }

    func assertNoOverlap(_ l: GraphLayoutResult) {
        let ids = Array(l.centers.keys)
        for i in 0..<ids.count {
            for j in (i + 1)..<ids.count {
                let a = l.centers[ids[i]]!
                let b = l.centers[ids[j]]!
                let overlapX = abs(a.x - b.x) < l.nodeSize.width
                let overlapY = abs(a.y - b.y) < l.nodeSize.height
                #expect(!(overlapX && overlapY))
            }
        }
    }

    @Test func edgesStartAndEndOnNodeBoundary() throws {
        let l = GraphLayout.layout(
            nodes: [F.fe, F.be], edges: [GraphEdgeInput(from: F.fe, to: F.be)])
        let e = try #require(l.edges.first)
        let a = try #require(l.centers[F.fe])
        let b = try #require(l.centers[F.be])
        // be nằm dưới fe: cạnh đi từ đáy fe tới đỉnh be
        #expect(abs(e.start.y - (a.y + l.nodeSize.height / 2)) < 0.01)
        #expect(abs(e.end.y - (b.y - l.nodeSize.height / 2)) < 0.01)
    }

    @Test func cycleDoesNotHang() {
        let l = GraphLayout.layout(
            nodes: [F.fe, F.be, F.api],
            edges: [
                GraphEdgeInput(from: F.fe, to: F.be), GraphEdgeInput(from: F.be, to: F.api),
                GraphEdgeInput(from: F.api, to: F.fe),
            ])
        #expect(l.centers.count == 3)
        #expect(l.layers.count == 3)
        assertNoOverlap(l)
    }

    @Test func isolatedNodesGoLast() {
        let l = GraphLayout.layout(
            nodes: [F.cache, F.fe, F.be], edges: [GraphEdgeInput(from: F.fe, to: F.be)])
        #expect(l.layers.last == [F.cache])
        #expect(l.layerOf[F.cache] == 2)
    }

    @Test func onlyIsolatedNodes() {
        let l = GraphLayout.layout(nodes: [F.fe, F.be], edges: [])
        #expect(l.layers.count == 1 && l.layers[0].count == 2)
        assertNoOverlap(l)
    }

    @Test func emptyAndSelfLoopAndUnknownEdges() {
        #expect(GraphLayout.layout(nodes: [], edges: []).centers.isEmpty)
        let l = GraphLayout.layout(
            nodes: [F.fe], edges: [GraphEdgeInput(from: F.fe, to: F.fe), GraphEdgeInput(from: F.fe, to: F.be)])
        #expect(l.edges.isEmpty && l.centers.count == 1)
    }

    @Test func bidirectionalEdgesAreOffset() throws {
        let l = GraphLayout.layout(
            nodes: [F.fe, F.be],
            edges: [GraphEdgeInput(from: F.fe, to: F.be), GraphEdgeInput(from: F.be, to: F.fe)])
        #expect(l.edges.count == 2)
        let d = abs(l.edges[0].start.x - l.edges[1].end.x)
        #expect(d > 5)  // hai chiều không chồng lên nhau
    }

    @Test func barycenterAvoidsCrossing() {
        // a1->b1, a2->b2 khai báo ngược thứ tự ở lớp dưới: barycenter phải sắp lại để không giao cắt.
        let a1 = UUID()
        let a2 = UUID()
        let b1 = UUID()
        let b2 = UUID()
        let l = GraphLayout.layout(
            nodes: [a1, a2, b2, b1],
            edges: [GraphEdgeInput(from: a1, to: b1), GraphEdgeInput(from: a2, to: b2)])
        #expect(l.layers[0] == [a1, a2] && l.layers[1] == [b1, b2])
    }

    @Test func deterministic() {
        let nodes = [F.fe, F.be, F.api, F.db, F.cache]
        let edges = [
            GraphEdgeInput(from: F.fe, to: F.be), GraphEdgeInput(from: F.be, to: F.api),
            GraphEdgeInput(from: F.api, to: F.db),
        ]
        #expect(
            GraphLayout.layout(nodes: nodes, edges: edges)
                == GraphLayout.layout(nodes: nodes, edges: edges))
    }
}
