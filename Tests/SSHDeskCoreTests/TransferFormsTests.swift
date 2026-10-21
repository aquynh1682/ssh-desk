import Foundation
import Testing

@testable import SSHDeskCore

private func tmp() -> String {
    let u = FileManager.default.temporaryDirectory
        .appendingPathComponent("sshdesk-forms-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u.path
}

private func job(
    _ state: TransferState, direction: TransferDirection = .download,
    policy: OverwritePolicy = .overwrite, reason: String? = nil
) -> TransferJob {
    TransferJob(
        hostID: UUID(), hostDisplayNameSnapshot: "h", targetSnapshot: "u@h:22",
        sshAliasSnapshot: "a", configPathSnapshot: "/c", direction: direction,
        sourcePath: "/r/x", destinationPath: "/l/x", itemKind: .file, overwritePolicy: policy,
        state: state, failureReason: reason)
}

struct DownloadFormTests {
    @Test func finalPathAndName() {
        var f = DownloadForm()
        f.remotePath = "/var/log/app.log"
        f.localDirectory = "/Users/me/Downloads/"
        #expect(f.finalPath == "/Users/me/Downloads/app.log")
        f.remotePath = "/var/log/dir/"
        #expect(f.effectiveName == "dir")
        f.localName = "other"
        #expect(f.finalPath == "/Users/me/Downloads/other")
    }

    @Test func rootRemoteHasNoName() {
        var f = DownloadForm()
        f.remotePath = "/"
        f.localDirectory = "/tmp"
        #expect(f.issues.contains(.remoteNameMissing))
        #expect(!f.canStart)
    }

    @Test func conflictRequiresChoice() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/a.txt", contents: Data("x".utf8))
        var f = DownloadForm()
        f.remotePath = "/srv/a.txt"
        f.localDirectory = dir
        #expect(f.hasConflict)
        #expect(f.issues == [.conflictChoiceRequired])
        #expect(f.suggestedRename == "a (1).txt")

        let host = managedHost()
        f.conflictChoice = .overwrite
        #expect(try f.makeJob(host: host, configPath: "/c").overwritePolicy == .overwrite)
        f.conflictChoice = .skip
        #expect(try f.makeJob(host: host, configPath: "/c").overwritePolicy == .skip)
        f.conflictChoice = .rename
        f.renameTo = "a.txt"  // trùng đích
        #expect(f.issues == [.renameInvalid])
        f.renameTo = "a (1).txt"
        let j = try f.makeJob(host: host, configPath: "/c")
        #expect(j.overwritePolicy == .rename("a (1).txt"))
        #expect(j.destinationPath == dir + "/a.txt")
        #expect(f.resultPath == dir + "/a (1).txt")
    }

    @Test func noConflictUsesExclusiveRename() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var f = DownloadForm()
        f.remotePath = "~/data.bin"
        f.localDirectory = dir
        let j = try f.makeJob(host: managedHost(), configPath: "/c")
        #expect(j.overwritePolicy == .rename("data.bin"))
        #expect(j.direction == .download)
        #expect(j.sourcePath == "~/data.bin")
        #expect(j.sshAliasSnapshot.hasPrefix("sshdesk-"))
        #expect(j.targetSnapshot == "deploy@web.example.com:22")
    }

    @Test func invalidInputsRejected() {
        var f = DownloadForm()
        #expect(f.issues.contains(.remotePathEmpty))
        #expect(f.issues.contains(.localDirectoryInvalid))
        f.remotePath = "/a\nb"
        f.localDirectory = "relative"
        #expect(f.issues.contains(.remotePathInvalid))
        #expect(f.issues.contains(.localDirectoryInvalid))
        #expect(throws: TransferFormError.self) {
            try f.makeJob(host: managedHost(), configPath: "/c")
        }
    }

    @Test func importedTargetIsAlias() {
        #expect(TransferTarget.describe(importedHost()) == "alias web-u")
    }
}

struct UploadFormTests {
    @Test func finalRemotePathAndWarnings() {
        var f = UploadForm()
        f.localPath = "/Users/me/report.pdf"
        f.remoteDirectory = "/srv/in/"
        #expect(f.finalRemotePath == "/srv/in/report.pdf")
        f.remoteName = "r2.pdf"
        #expect(f.finalRemotePath == "/srv/in/r2.pdf")
        f.remoteDirectory = "/"
        #expect(f.finalRemotePath == "/r2.pdf")
        #expect(f.warnings == [UploadForm.overwriteWarning])
        #expect(
            UploadForm.overwriteWarning
                == "scp không kiểm tra được file cùng tên trên server — file cùng tên sẽ bị ghi đè.")
    }

    @Test func directoryWarningAndJob() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let proj = dir + "/proj"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        var f = UploadForm()
        f.localPath = proj
        f.remoteDirectory = "/srv"
        f.refreshLocal()
        #expect(f.kind == .directory)
        #expect(f.warnings.count == 2)
        #expect(
            f.warnings[1]
                == "Nếu thư mục proj đã tồn tại trên server, nội dung sẽ được đặt lồng bên trong.")
        let j = try f.makeJob(host: managedHost(), configPath: "/c")
        #expect(j.direction == .upload)
        #expect(j.itemKind == .directory)
        #expect(j.destinationPath == "/srv/proj")
        #expect(j.sourcePath == proj)
    }

    @Test func symlinksBlockStart() throws {
        let dir = tmp()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let proj = dir + "/proj"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        for i in 0..<25 {
            try FileManager.default.createSymbolicLink(
                atPath: proj + "/l\(i)", withDestinationPath: "/etc/hosts")
        }
        var f = UploadForm()
        f.localPath = proj
        f.remoteDirectory = "/srv"
        f.refreshLocal()
        #expect(!f.canStart)
        guard
            case .symlinks(let l)? = f.issues.first(where: {
                if case .symlinks = $0 { return true } else { return false }
            })
        else {
            Issue.record("thiếu symlinks")
            return
        }
        #expect(l.count == 21)
        let msg = TransferFormIssue.symlinks(l).message
        #expect(msg.contains("l0"))
        #expect(!msg.contains("l9,") || msg.contains("và 1 mục khác"))
        #expect(msg.contains("và 1 mục khác"))
    }

    @Test func missingSourceAndBadName() {
        var f = UploadForm()
        f.localPath = "/nonexistent/\(UUID().uuidString)"
        f.remoteDirectory = "/srv"
        #expect(f.issues.contains(.localSourceMissing))
        f.remoteName = "a/b"
        #expect(f.issues.contains(.nameInvalid))
    }
}

struct PresentationTests {
    @Test func labels() {
        let expected: [TransferState: String] = [
            .queued: "Đang chờ", .connecting: "Đang kết nối", .awaitingUserInput: "Chờ xác thực",
            .transferring: "Đang truyền", .finalizing: "Đang hoàn tất", .completed: "Hoàn tất",
            .failed: "Lỗi", .cancelling: "Đang huỷ", .cancelled: "Đã huỷ",
            .interrupted: "Bị gián đoạn",
        ]
        for s in TransferState.allCases { #expect(TransferPresentation.label(for: s) == expected[s]) }
    }

    @Test func skippedLabel() {
        let j = job(.completed, policy: .skip, reason: TransferJob.skippedReason)
        #expect(TransferPresentation.label(for: j) == "Đã bỏ qua")
        #expect(TransferPresentation.revealPath(for: j) == nil)
        #expect(TransferPresentation.label(for: job(.completed, policy: .skip)) == "Hoàn tất")
    }

    @Test func buttonRules() {
        for s in TransferState.allCases {
            #expect(
                TransferPresentation.canCancel(s)
                    == [.queued, .connecting, .awaitingUserInput, .transferring].contains(s))
            #expect(TransferPresentation.canRetry(s) == [.failed, .cancelled, .interrupted].contains(s))
        }
        #expect(!TransferPresentation.canCancel(.finalizing))
    }

    @Test func revealPath() {
        #expect(TransferPresentation.revealPath(for: job(.completed)) == "/l/x")
        #expect(TransferPresentation.revealPath(for: job(.completed, policy: .rename("y"))) == "/l/y")
        #expect(TransferPresentation.revealPath(for: job(.failed)) == nil)
        #expect(TransferPresentation.revealPath(for: job(.completed, direction: .upload)) == nil)
    }

    @Test func progressNeverInvented() {
        var j = job(.transferring)
        #expect(TransferPresentation.fraction(for: j) == nil)
        #expect(TransferPresentation.speedText(for: j) == nil)
        j.progress = TransferProgress(fraction: 0.4, bytesPerSecond: 2_000_000)
        #expect(TransferPresentation.fraction(for: j) == 0.4)
        #expect(TransferPresentation.speedText(for: j) != nil)
        j.state = .connecting
        #expect(TransferPresentation.fraction(for: j) == nil)
    }

    @Test func activeAndHistorySplit() {
        let a = job(.queued)
        let b = job(.completed)
        let c = job(.interrupted)
        let d = job(.transferring)
        let all = [a, b, c, d]
        #expect(Set(TransferPresentation.active(all).map(\.id)) == [a.id, d.id])
        #expect(Set(TransferPresentation.history(all).map(\.id)) == [b.id, c.id])
    }
}

struct PromptTests {
    @Test func queueOrderAndReplace() {
        var q = AuthPromptQueue()
        let a = UUID()
        let b = UUID()
        q.enqueue(jobID: a, kind: .password("p1"))
        q.enqueue(jobID: b, kind: .password("p2"))
        #expect(q.current?.jobID == a)
        q.enqueue(jobID: a, kind: .password("again"))
        #expect(q.items.count == 2)
        #expect(q.current?.kind == .password("again"))
        q.remove(jobID: a)
        #expect(q.current?.jobID == b)
    }

    @Test func reconcileDropsFinishedJobs() {
        var q = AuthPromptQueue()
        let j = job(.failed)
        q.enqueue(jobID: j.id, kind: .password("p"))
        q.reconcile(j)
        #expect(q.items.isEmpty)
        var waiting = job(.awaitingUserInput)
        q.enqueue(jobID: waiting.id, kind: .password("p"))
        q.reconcile(waiting)
        #expect(q.items.count == 1)
        waiting.state = .connecting
        q.reconcile(waiting)
        #expect(q.items.isEmpty)
    }

    @Test func presentation() {
        #expect(PromptPresentation(.password("x")).input == .secret)
        #expect(PromptPresentation(.passphrase("x")).input == .secret)
        let otp = PromptPresentation(.keyboardInteractive("Code:"))
        #expect(otp.input == .secret)
        #expect(otp.note == "Mã không được lưu")
        let hk = PromptPresentation(.hostKeyConfirm(fingerprint: "SHA256:abc", text: "t"))
        #expect(hk.input == .hostKeyDecision)
        #expect(hk.fingerprint == "SHA256:abc")
        #expect(PromptPresentation.hostKeyTrust.text == "yes")
        #expect(PromptPresentation.hostKeyTrust.isSecret == false)
        #expect(PromptPresentation.hostKeyDecline.text == "no")
        #expect(PromptPresentation(.hostKeyChanged("x")).input == .none)
        #expect(PromptPresentation(.unknown("Foo:")).input == .secret)
    }
}
