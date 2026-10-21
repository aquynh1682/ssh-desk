import Foundation
import Testing

@testable import SSHDeskCore

private func row(
    _ name: String, dir: Bool = false, size: Int64? = 1, modified: TimeInterval? = nil,
    hidden: Bool = false, kind: RemoteEntryKind? = nil
) -> BrowserRow {
    BrowserRow(
        id: "/d/" + name, name: name, kind: kind ?? (dir ? .directory : .file),
        size: dir ? nil : size, modified: modified.map { Date(timeIntervalSince1970: $0) },
        permissions: nil, isHidden: hidden,
        isSupported: !name.unicodeScalars.contains { $0.value < 0x20 })
}

struct BrowserPathTests {
    @Test func joinParentLast() {
        #expect(BrowserPath.join("/a", "b") == "/a/b")
        #expect(BrowserPath.join("/", "b") == "/b")
        #expect(BrowserPath.parent("/a/b") == "/a")
        #expect(BrowserPath.parent("/a") == "/")
        #expect(BrowserPath.parent("/") == "/")
        #expect(BrowserPath.parent("/a/b/") == "/a")
        #expect(BrowserPath.lastComponent("/a/b/") == "b")
    }

    @Test func normalizeAndResolve() {
        #expect(BrowserPath.normalize("/a//b/./c/../d") == "/a/b/d")
        #expect(BrowserPath.normalize("/../..") == "/")
        #expect(BrowserPath.normalize("rel") == nil)
        #expect(BrowserPath.resolve("~", home: "/Users/me") == "/Users/me")
        #expect(BrowserPath.resolve("~/Downloads/", home: "/Users/me") == "/Users/me/Downloads")
        #expect(BrowserPath.resolve("  /var/log  ", home: "/Users/me") == "/var/log")
        #expect(BrowserPath.resolve("relative", home: "/Users/me") == nil)
        #expect(BrowserPath.resolve("", home: "/Users/me") == nil)
        #expect(BrowserPath.resolve("/a\nb", home: "/Users/me") == nil)
    }

    @Test func displayUsesTildeForHome() {
        #expect(BrowserPath.display("/Users/me", home: "/Users/me") == "~")
        #expect(BrowserPath.display("/Users/me/Downloads", home: "/Users/me") == "~/Downloads")
        #expect(BrowserPath.display("/Users/mellow", home: "/Users/me") == "/Users/mellow")
        #expect(BrowserPath.display("/etc", home: "/Users/me") == "/etc")
        #expect(BrowserPath.display("/etc", home: "/") == "/etc")
    }

    @Test func nameRules() {
        #expect(EntryNameRules.validate("ok name.txt") == nil)
        #expect(EntryNameRules.validate("") == .empty)
        #expect(EntryNameRules.validate("   ") == .empty)
        #expect(EntryNameRules.validate("..") == .reserved)
        #expect(EntryNameRules.validate("a/b") == .containsSlash)
        #expect(EntryNameRules.validate("a\nb") == .containsControl)
    }
}

struct BrowserRowsTests {
    @Test func directoriesFirstThenByName() {
        let rows = [row("b.txt"), row("zdir", dir: true), row("a.txt"), row("adir", dir: true)]
        let out = BrowserRows.arranged(rows).map(\.name)
        #expect(out == ["adir", "zdir", "a.txt", "b.txt"])
        let desc = BrowserRows.arranged(rows, sort: BrowserSort(key: .name, ascending: false)).map(
            \.name)
        #expect(desc == ["zdir", "adir", "b.txt", "a.txt"])
    }

    @Test func naturalNameOrder() {
        let rows = [row("f10"), row("f2"), row("f1")]
        #expect(BrowserRows.arranged(rows).map(\.name) == ["f1", "f2", "f10"])
    }

    @Test func sortBySizeAndModified() {
        let rows = [
            row("big", size: 900, modified: 10), row("small", size: 5, modified: 30),
            row("mid", size: 50, modified: 20),
        ]
        #expect(
            BrowserRows.arranged(rows, sort: BrowserSort(key: .size)).map(\.name)
                == ["small", "mid", "big"])
        #expect(
            BrowserRows.arranged(rows, sort: BrowserSort(key: .modified, ascending: false)).map(
                \.name) == ["small", "mid", "big"])
    }

    @Test func filterIsCaseAndDiacriticInsensitive() {
        let rows = [row("Báo cáo.pdf"), row("readme.md"), row("notes.txt")]
        #expect(BrowserRows.arranged(rows, query: "bao").map(\.name) == ["Báo cáo.pdf"])
        #expect(BrowserRows.arranged(rows, query: "README").map(\.name) == ["readme.md"])
        #expect(BrowserRows.arranged(rows, query: "zzz").isEmpty)
    }

    @Test func hiddenFiles() {
        let rows = [row(".env", hidden: true), row("a")]
        #expect(BrowserRows.arranged(rows, showHidden: false).map(\.name) == ["a"])
        #expect(BrowserRows.arranged(rows, showHidden: true).count == 2)
    }

    @Test func sortToggle() {
        let s = BrowserSort()
        #expect(s.toggled(.name) == BrowserSort(key: .name, ascending: false))
        #expect(s.toggled(.size) == BrowserSort(key: .size, ascending: true))
    }

    @Test func remoteRowMapping() {
        let e = RemoteEntry(
            name: "bad\nname", kind: .symlink, size: 5, permissions: "lrwxrwxrwx", owner: "u",
            group: "g", modified: nil, rawDate: "")
        let r = BrowserRow(remote: e, directory: "/srv")
        #expect(r.id == "/srv/bad\nname")
        #expect(!r.isSupported)
        #expect(r.displayName == "bad\u{FFFD}name")
        #expect(r.isSymlink)
        let d = RemoteEntry(
            name: ".cfg", kind: .directory, size: 4096, permissions: "drwx------", owner: "u",
            group: "g", modified: nil, rawDate: "")
        let dr = BrowserRow(remote: d, directory: "/")
        #expect(dr.id == "/.cfg" && dr.isHidden && dr.size == nil)
    }
}

struct BrowserFormatTests {
    private static var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func sizeText() {
        #expect(BrowserFormat.sizeText(row("d", dir: true)) == "—")
        #expect(BrowserFormat.sizeText(row("f", size: 2000)) == "2 KB")
        #expect(BrowserFormat.sizeText(bytes: 128_000_000) == "128 MB")
    }

    @Test func modifiedText() {
        let cal = Self.cal
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 15))!
        func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 9) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: day, hour: h))!
        }
        #expect(BrowserFormat.modifiedText(d(2026, 10, 21, 1), now: now, calendar: cal) == "Hôm nay")
        #expect(BrowserFormat.modifiedText(d(2026, 10, 20, 23), now: now, calendar: cal) == "Hôm qua")
        #expect(BrowserFormat.modifiedText(d(2026, 3, 5), now: now, calendar: cal) == "05/03")
        #expect(BrowserFormat.modifiedText(d(2025, 12, 31), now: now, calendar: cal) == "31/12/2025")
        #expect(BrowserFormat.modifiedText(nil, now: now, calendar: cal) == "—")
    }

    @Test func footer() {
        #expect(BrowserFormat.footerText(total: 6, selected: 2) == "6 mục · 2 đã chọn")
        #expect(BrowserFormat.footerText(total: 6, selected: 0) == "6 mục")
    }

    @Test func progressDetailOnlyWithRealData() {
        var job = sampleJob(direction: .upload, state: .transferring)
        #expect(BrowserFormat.progressDetail(for: job) == nil)
        job.progress = TransferProgress(bytes: 1, fraction: 0.64, bytesPerSecond: 38_000_000)
        #expect(BrowserFormat.progressDetail(for: job) == "64% · 38 MB/s")
        job.progress = TransferProgress(bytesPerSecond: 1_000_000)  // thư mục: không có fraction
        #expect(BrowserFormat.progressDetail(for: job) == "1 MB/s")
    }
}

struct BrowserSelectionTests {
    private let order = ["a", "b", "c", "d", "e"]

    @Test func plainAndCommandClick() {
        var s = BrowserSelection()
        s.click("b", modifier: .none, order: order)
        #expect(s.selected == ["b"])
        s.click("d", modifier: .command, order: order)
        #expect(s.selected == ["b", "d"])
        s.click("b", modifier: .command, order: order)
        #expect(s.selected == ["d"])
        s.click("e", modifier: .none, order: order)
        #expect(s.selected == ["e"])
    }

    @Test func shiftSelectsRangeFromAnchor() {
        var s = BrowserSelection()
        s.click("b", modifier: .none, order: order)
        s.click("d", modifier: .shift, order: order)
        #expect(s.selected == ["b", "c", "d"])
        s.click("a", modifier: .shift, order: order)  // mốc vẫn là b
        #expect(s.selected == ["a", "b"])
    }

    @Test func shiftWithoutAnchorSelectsOne() {
        var s = BrowserSelection()
        s.click("c", modifier: .shift, order: order)
        #expect(s.selected == ["c"])
    }

    @Test func retainDropsMissing() {
        var s = BrowserSelection()
        s.selectAll(order)
        s.retain(["a", "x"])
        #expect(s.selected == ["a"])
    }

    @Test func dragIDs() {
        var s = BrowserSelection()
        s.click("d", modifier: .none, order: order)
        s.click("b", modifier: .command, order: order)
        #expect(s.dragIDs(from: "d", order: order) == ["b", "d"])
        #expect(s.dragIDs(from: "a", order: order) == ["a"])  // kéo dòng chưa chọn → chỉ dòng đó
    }
}

struct NavigationHistoryTests {
    @Test func backForward() {
        var h = NavigationHistory(start: "/a")
        h.commitVisit("/a/b")
        h.commitVisit("/a/b/c")
        #expect(h.current == "/a/b/c" && h.canGoBack && !h.canGoForward)
        #expect(h.backTarget == "/a/b")
        h.commitBack()
        #expect(h.current == "/a/b" && h.forwardTarget == "/a/b/c")
        h.commitForward()
        #expect(h.current == "/a/b/c")
        h.commitBack()
        h.commitVisit("/x")  // đi nhánh mới xoá tiến
        #expect(!h.canGoForward && h.backTarget == "/a/b")
    }

    @Test func sameDirectoryDoesNotGrowHistory() {
        var h = NavigationHistory(start: "/a")
        h.commitVisit("/a")
        #expect(!h.canGoBack)
    }
}

struct BrowserTabStateTests {
    @Test func happyPath() {
        var s = BrowserTabState.connecting
        s = BrowserTabReducer.reduce(s, .session(.authPrompt(.password("x"))))
        #expect(s == .awaitingAuth)
        s = BrowserTabReducer.reduce(s, .answered)
        #expect(s == .connecting)
        s = BrowserTabReducer.reduce(s, .session(.connected))
        #expect(s == .connected)
    }

    @Test func lossAndReconnect() {
        var s = BrowserTabState.connected
        s = BrowserTabReducer.reduce(s, .session(.disconnected("Master ssh đã thoát")))
        #expect(s == .disconnected("Master ssh đã thoát"))
        // Sự kiện mất kết nối thứ hai không ghi đè lý do đầu.
        s = BrowserTabReducer.reduce(s, .sessionLost)
        #expect(s == .disconnected("Master ssh đã thoát"))
        s = BrowserTabReducer.reduce(s, .reconnecting)
        #expect(s == .connecting)
        s = BrowserTabReducer.reduce(s, .startFailed("socket đang dùng"))
        #expect(s == .disconnected("socket đang dùng"))
    }

    @Test func fileOpSessionLostMarksDisconnected() {
        #expect(
            BrowserTabReducer.reduce(.connected, .sessionLost)
                == .disconnected("Mất kết nối tới máy chủ."))
    }

    @Test func connectedIgnoredWhenDisconnected() {
        #expect(
            BrowserTabReducer.reduce(.disconnected("x"), .session(.connected)) == .disconnected("x"))
    }

    @Test func presentation() {
        #expect(BrowserTabPresentation.dot(.connected) == .green)
        #expect(BrowserTabPresentation.dot(.connecting) == .yellow)
        #expect(BrowserTabPresentation.dot(.awaitingAuth) == .yellow)
        #expect(BrowserTabPresentation.dot(.disconnected("")) == .red)
        #expect(BrowserTabPresentation.statusText(.connected) == "Đã kết nối SFTP")
        #expect(BrowserTabPresentation.statusText(.connecting) == "Đang kết nối…")
        #expect(BrowserTabPresentation.statusText(.disconnected("x")) == "Mất kết nối")
        #expect(BrowserTabPresentation.canReconnect(.disconnected("")))
        #expect(!BrowserTabPresentation.canReconnect(.connected))
        #expect(BrowserTabPresentation.sessionCount([.connected, .connecting, .connected]) == 2)
        #expect(BrowserTabPresentation.sessionsText(3) == "3 phiên đang kết nối")
        #expect(BrowserTabPresentation.identity(managedHost(hostName: "10.0.0.1", user: "ubuntu")) == "ubuntu@10.0.0.1")
        #expect(BrowserTabPresentation.identity(importedHost(alias: "web-u")) == "web-u")
    }
}

struct HostPickerTests {
    @Test func groupsByEnvironmentAndFilters() {
        var prod = managedHost("zeta", hostName: "p.example.com")
        prod.environment = .prod
        var dev = managedHost("alpha", hostName: "d.example.com")
        dev.environment = .dev
        var dev2 = managedHost("Beta", hostName: "b.example.com", user: "root")
        dev2.environment = .dev
        let groups = HostPicker.groups([dev, prod, dev2], query: "")
        #expect(groups.map(\.environment) == [.prod, .dev])
        #expect(groups[1].hosts.map(\.displayName) == ["alpha", "Beta"])
        #expect(HostPicker.groups([dev, prod, dev2], query: "ROOT").flatMap(\.hosts).map(\.displayName) == ["Beta"])
        #expect(HostPicker.groups([dev, prod, dev2], query: "nope").isEmpty)
    }

    @Test func selectable() {
        #expect(HostPicker.isSelectable(managedHost()))
        var h = importedHost()
        h.sshConfigAlias = nil
        #expect(!HostPicker.isSelectable(h))
    }
}

struct BrowserTransferPlannerTests {
    private func item(_ n: String, _ k: BatchItemKind = .file, base: String = "/src") -> BatchItem {
        BatchItem(name: n, path: base + "/" + n, kind: k)
    }

    @Test func uploadConflictDetectionUsesRemoteListing() {
        let plan = BrowserTransferPlanner.planUpload(
            items: [item("a.txt"), item("b.txt"), item("dir", .directory)],
            remoteDirectory: "/home/u", remoteNames: ["b.txt", "dir", "other"])
        #expect(plan.conflicts == ["b.txt", "dir"])
        #expect(plan.hasConflicts && plan.unsupported.isEmpty)
    }

    @Test func uploadDestinationsFilesAndDirectories() {
        let plan = BrowserTransferPlanner.planUpload(
            items: [item("a.txt"), item("proj", .directory)], remoteDirectory: "/home/u",
            remoteNames: ["proj"])
        let jobs = BrowserTransferPlanner.uploadJobs(plan, choice: .overwriteAll)
        #expect(jobs.count == 2)
        #expect(jobs[0].destination == "/home/u/a.txt" && jobs[0].kind == .file)
        // Thư mục: đích là thư mục cha (gộp), KHÔNG lồng thêm một cấp.
        #expect(jobs[1].destination == "/home/u" && jobs[1].kind == .directory)
        #expect(jobs.allSatisfy { $0.policy == .overwrite && $0.direction == .upload })
    }

    @Test func uploadSkipConflictsDropsOnlyConflicting() {
        let plan = BrowserTransferPlanner.planUpload(
            items: [item("a.txt"), item("b.txt")], remoteDirectory: "/r", remoteNames: ["b.txt"])
        let jobs = BrowserTransferPlanner.uploadJobs(plan, choice: .skipConflicts)
        #expect(jobs.map(\.source) == ["/src/a.txt"])
    }

    @Test func unsupportedNamesAreSeparated() {
        let plan = BrowserTransferPlanner.planUpload(
            items: [item("ok"), BatchItem(name: "bad\nname", path: "/src/bad\nname", kind: .file)],
            remoteDirectory: "/r", remoteNames: [])
        #expect(plan.items.map(\.name) == ["ok"])
        #expect(plan.unsupported == ["bad\nname"])
    }

    @Test func downloadConflictsAndPolicies() {
        let plan = BrowserTransferPlanner.planDownload(
            items: [
                item("a.txt", base: "/srv"), item("b.txt", base: "/srv"),
                item("d", .directory, base: "/srv"),
            ], localDirectory: "/Users/me/Downloads",
            exists: { $0 == "/Users/me/Downloads/b.txt" })
        #expect(plan.conflicts == ["b.txt"])

        let over = BrowserTransferPlanner.downloadJobs(plan, choice: .overwriteAll)
        #expect(over.map(\.policy) == [.rename("a.txt"), .overwrite, .rename("d")])
        #expect(over[2].kind == .directory)
        #expect(over[0].destination == "/Users/me/Downloads/a.txt")

        let skip = BrowserTransferPlanner.downloadJobs(plan, choice: .skipConflicts)
        #expect(skip.map(\.source) == ["/srv/a.txt", "/srv/d"])

        let auto = BrowserTransferPlanner.downloadJobs(
            plan, choice: .autoRename, suggest: { name, _ in "unique-" + name })
        #expect(auto.map(\.policy) == [.rename("a.txt"), .rename("unique-b.txt"), .rename("d")])
        #expect(auto[1].destination == "/Users/me/Downloads/b.txt")
    }

    @Test func symlinkRemoteItemDownloadsAsFile() {
        let plan = BrowserTransferPlanner.planDownload(
            items: [item("lnk", .symlink, base: "/srv")], localDirectory: "/tmp/x", exists: { _ in false })
        #expect(BrowserTransferPlanner.downloadJobs(plan, choice: .overwriteAll)[0].kind == .file)
    }

    @Test func makeJobsUsesHostSnapshots() throws {
        let host = managedHost("Web", hostName: "h.example.com", user: "deploy")
        let plan = BrowserTransferPlanner.planUpload(
            items: [item("a.txt")], remoteDirectory: "/r", remoteNames: [])
        let jobs = try BrowserTransferPlanner.makeJobs(
            BrowserTransferPlanner.uploadJobs(plan, choice: .overwriteAll), host: host,
            configPath: "/cfg")
        #expect(jobs.count == 1)
        #expect(jobs[0].hostID == host.id && jobs[0].sshAliasSnapshot == host.sshAlias)
        #expect(jobs[0].targetSnapshot == "deploy@h.example.com:22")
        #expect(jobs[0].configPathSnapshot == "/cfg")
        var noAlias = importedHost()
        noAlias.sshConfigAlias = nil
        #expect(throws: BrowserTransferPlanner.JobBuildError.hostMissingAlias) {
            try BrowserTransferPlanner.makeJobs([], host: noAlias, configPath: "/cfg")
        }
    }

    @Test func inspectLocalSourcesRejectsSymlinks() throws {
        let dir = HostTempDir()
        defer { dir.cleanup() }
        let fm = FileManager.default
        let base = dir.url.path
        fm.createFile(atPath: base + "/file.txt", contents: Data("x".utf8))
        try fm.createDirectory(atPath: base + "/plain/sub", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: base + "/withlink", withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: base + "/withlink/l", withDestinationPath: "/etc")
        try fm.createSymbolicLink(atPath: base + "/toplink", withDestinationPath: base + "/file.txt")
        let r = BrowserTransferPlanner.inspectLocalSources(
            ["file.txt", "plain", "withlink", "toplink", "missing"].map { base + "/" + $0 })
        #expect(r.items.map(\.name) == ["file.txt", "plain"])
        #expect(r.items.map(\.kind) == [.file, .directory])
        #expect(
            r.rejections == [
                .containsSymlinks(name: "withlink", links: ["l"]), .symlink("toplink"),
                .missing("missing"),
            ])
        #expect(r.rejections[0].message.contains("withlink"))
    }
}

struct BrowserDragPayloadTests {
    @Test func roundTrip() throws {
        let p = BrowserDragPayload(
            origin: .remote(hostID: UUID()),
            items: [BatchItem(name: "a b", path: "/x/a b", kind: .file)])
        let data = try #require(p.encoded())
        #expect(BrowserDragPayload.decode(data) == p)
    }

    @Test func rejectsHostileData() throws {
        #expect(BrowserDragPayload.decode(Data("not json".utf8)) == nil)
        let empty = try #require(BrowserDragPayload(origin: .local, items: []).encoded())
        #expect(BrowserDragPayload.decode(empty) == nil)
        let slash = try #require(
            BrowserDragPayload(origin: .local, items: [BatchItem(name: "a/b", path: "/a/b", kind: .file)])
                .encoded())
        #expect(BrowserDragPayload.decode(slash) == nil)
        let ctrl = try #require(
            BrowserDragPayload(origin: .local, items: [BatchItem(name: "a", path: "/a\nb", kind: .file)])
                .encoded())
        #expect(BrowserDragPayload.decode(ctrl) == nil)
    }
}

struct BrowserSafetyTests {
    @Test func prodRules() {
        var prod = managedHost("Prod DB")
        prod.environment = .prod
        let dev = managedHost("dev box")
        #expect(BrowserSafety.requiresUploadConfirmation(prod))
        #expect(!BrowserSafety.requiresUploadConfirmation(dev))
        #expect(BrowserSafety.uploadConfirmationTitle(prod) == "Tải lên máy PROD Prod DB?")
        #expect(BrowserSafety.deleteConfirmation(host: prod, isDirectory: true) == .typeHostName)
        #expect(BrowserSafety.deleteConfirmation(host: prod, isDirectory: false) == .simple)
        #expect(BrowserSafety.deleteConfirmation(host: dev, isDirectory: true) == .simple)
        #expect(BrowserSafety.isHostNameTyped(" Prod DB ", host: prod))
        #expect(!BrowserSafety.isHostNameTyped("prod db", host: prod))
        #expect(!BrowserSafety.isHostNameTyped("", host: prod))
    }

    @Test func deleteSummaryCapsList() {
        var items: [RemoteDeleteItem] = []
        for i in 0..<60 { items.append(RemoteDeleteItem(path: "/srv/tree/a/f\(i)", kind: .file)) }
        items.append(RemoteDeleteItem(path: "/srv/tree/a", kind: .directory))
        items.append(RemoteDeleteItem(path: "/srv/tree", kind: .directory))
        let s = DeletePlanSummary(RemoteDeletePlan(root: "/srv/tree", items: items))
        #expect(s.total == 62)
        #expect(s.listed.count == 50)
        #expect(s.hiddenCount == 12)
        #expect(s.listed[0] == "tree/a/f0")
        let small = DeletePlanSummary(
            RemoteDeletePlan(
                root: "/srv/tree/",
                items: [
                    RemoteDeleteItem(path: "/srv/tree/a", kind: .directory),
                    RemoteDeleteItem(path: "/srv/tree", kind: .directory),
                ]))
        #expect(small.listed == ["tree/a/", "tree/"])
    }
}

struct BrowserRefreshRuleTests {
    private func job(
        _ dir: TransferDirection, dest: String, state: TransferState = .completed, host: UUID
    ) -> TransferJob {
        var j = sampleJob(direction: dir, source: "/x", destination: dest, state: state)
        j.hostID = host
        return j
    }

    @Test func remote() {
        let host = UUID()
        #expect(
            BrowserRefreshRule.shouldRefreshRemote(
                job: job(.upload, dest: "/home/u/a.txt", host: host), hostID: host, currentPath: "/home/u"))
        // Thư mục gộp: đích là chính thư mục đang xem.
        #expect(
            BrowserRefreshRule.shouldRefreshRemote(
                job: job(.upload, dest: "/home/u", host: host), hostID: host, currentPath: "/home/u"))
        #expect(
            !BrowserRefreshRule.shouldRefreshRemote(
                job: job(.upload, dest: "/home/u/a.txt", host: host), hostID: host, currentPath: "/home"))
        #expect(
            !BrowserRefreshRule.shouldRefreshRemote(
                job: job(.upload, dest: "/home/u/a.txt", host: UUID()), hostID: host, currentPath: "/home/u"))
        #expect(
            !BrowserRefreshRule.shouldRefreshRemote(
                job: job(.upload, dest: "/home/u/a.txt", state: .failed, host: host), hostID: host,
                currentPath: "/home/u"))
        #expect(
            !BrowserRefreshRule.shouldRefreshRemote(
                job: job(.download, dest: "/home/u/a.txt", host: host), hostID: host, currentPath: "/home/u"))
    }

    @Test func local() {
        let h = UUID()
        #expect(
            BrowserRefreshRule.shouldRefreshLocal(
                job: job(.download, dest: "/Users/me/Downloads/a", host: h),
                currentDirectory: "/Users/me/Downloads"))
        #expect(
            !BrowserRefreshRule.shouldRefreshLocal(
                job: job(.download, dest: "/Users/me/Downloads/a", host: h), currentDirectory: "/Users/me"))
        #expect(
            !BrowserRefreshRule.shouldRefreshLocal(
                job: job(.upload, dest: "/Users/me/Downloads/a", host: h),
                currentDirectory: "/Users/me/Downloads"))
    }
}

struct BrowserErrorTextTests {
    @Test func everyRemoteErrorHasText() {
        let all: [RemoteFileError] = [
            .invalidPath("x"), .unsupportedName("x"), .destinationExists("x"), .permissionDenied("/r"),
            .notFound("x"), .directoryNotEmpty("x"), .commandFailed("boom"), .sessionLost,
            .connectionFailed("c"), .timeout, .tooManyEntries(limit: 5000),
            .unparsedEntries(directory: "/d", count: 2),
            .deleteInterrupted(deleted: 3, failedPath: "/p", message: "m"),
        ]
        for e in all { #expect(!BrowserErrorText.message(for: e).isEmpty) }
        #expect(BrowserErrorText.message(for: RemoteFileError.permissionDenied("/r")).contains("sudo"))
        #expect(BrowserErrorText.message(for: RemoteFileError.commandFailed("boom")) == "boom")
    }
}
