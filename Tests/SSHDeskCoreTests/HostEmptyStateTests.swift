import Testing

@testable import SSHDeskCore

@Suite struct HostEmptyStateTests {
    @Test func searchWinsOverEverything() {
        let c = HostEmptyState.content(scope: .favorites, searching: true, hasAnyHosts: false)
        #expect(c.title == "Không tìm thấy máy chủ" && !c.offersAdd)
    }

    @Test func noHostsAtAllOffersAdd() {
        for scope in [HostEmptyState.Scope.all, .favorites, .folder("x")] {
            let c = HostEmptyState.content(scope: scope, searching: false, hasAnyHosts: false)
            #expect(c.title == "Chưa có máy chủ nào" && c.offersAdd)
        }
    }

    @Test func eachScopeHasItsOwnMessage() {
        func c(_ s: HostEmptyState.Scope) -> HostEmptyState.Content {
            HostEmptyState.content(scope: s, searching: false, hasAnyHosts: true)
        }
        #expect(c(.favorites).title.contains("yêu thích"))
        #expect(c(.recent).title.contains("gần đây"))
        #expect(c(.folder("Prod")).title == "Thư mục “Prod” đang trống" && c(.folder("Prod")).offersAdd)
        #expect(c(.environment(.prod)).title.contains("PROD"))
        #expect(c(.uncategorized).title.contains("thư mục"))
        #expect(c(.all).symbol == "line.3.horizontal.decrease.circle")
    }
}
