import AppKit
import Combine
import CryptoKit
import NarratorCore
import Security

@MainActor
public final class Updater: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public enum State {
        case idle, checking, upToDate, available(AppRelease), downloading(Double), failed(String)
    }
    @Published public private(set) var state: State = .idle
    private var schedule: Task<Void, Never>?
    private let session = URLSession(configuration: .ephemeral)

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading: true
        default: false
        }
    }

    public func configure(automatic: Bool) {
        schedule?.cancel()
        schedule = nil
        if automatic {
            schedule = Task {
                while !Task.isCancelled {
                    await check()
                    do { try await Task.sleep(for: .seconds(24 * 60 * 60)) }
                    catch { return }
                }
            }
        }
    }

    public func check() async {
        guard !isBusy else { return }
        state = .checking
        do {
            let (data, response) = try await session.data(from: AppRelease.latestVersionURL)
            try Self.checkResponse(response)
            guard let text = String(data: data, encoding: .utf8) else { throw Self.failure("version.txt is not UTF-8.") }
            let release = try AppRelease(versionText: text)
            state = try SemanticVersion(release.tag) > SemanticVersion(NarratorCore.version) ? .available(release) : .upToDate
        } catch { state = .failed(String(describing: error)) }
    }

    public func install(_ release: AppRelease) async {
        state = .downloading(0)
        var staging: URL?
        do {
            let current = Bundle.main.bundleURL
            guard current.pathExtension == "app" else { throw Self.failure("Run the installed LifeNarrator.app to update it.") }
            let parent = current.deletingLastPathComponent()
            let work = parent.appendingPathComponent(".LifeNarrator-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false)
            staging = work
            let (checksums, checksumResponse) = try await session.data(from: release.assetURL(named: "checksums.txt"))
            try Self.checkResponse(checksumResponse)
            guard let text = String(data: checksums, encoding: .utf8) else { throw Self.failure("checksums.txt is not UTF-8.") }
            let expected = try ReleaseChecksums.sha256(for: "LifeNarrator.zip", in: text)
            let (download, response) = try await session.download(from: release.assetURL(named: "LifeNarrator.zip"), delegate: self)
            try Self.checkResponse(response)
            let archive = work.appendingPathComponent("LifeNarrator.zip")
            try FileManager.default.moveItem(at: download, to: archive)
            try await Task.detached {
                try Self.prepare(archive: archive, expected: expected, work: work)
            }.value
            let script = work.appendingPathComponent("install.sh")
            try Self.replacementScript.write(to: script, atomically: true, encoding: .utf8)
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            helper.arguments = ["/bin/sh", script.path, String(ProcessInfo.processInfo.processIdentifier), current.path, work.path]
            helper.standardInput = FileHandle.nullDevice
            helper.standardOutput = FileHandle.nullDevice
            helper.standardError = FileHandle.nullDevice
            try helper.run()
            staging = nil // The detached helper now owns cleanup, including rollback on failure.
            NSApp.terminate(nil)
        } catch {
            let failure = error
            do {
                if let staging { try FileManager.default.removeItem(at: staging) }
                state = .failed(String(describing: failure))
            } catch { state = .failed("\(failure)\n\(error)") }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                      didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                      totalBytesExpectedToWrite: Int64) {
        let progress = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        Task { @MainActor in
            if case .downloading = self.state { self.state = .downloading(progress) }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                      didFinishDownloadingTo location: URL) {}

    nonisolated private static func checkResponse(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse else { throw failure("Expected an HTTP response.") }
        guard (200..<300).contains(response.statusCode) else {
            throw failure("HTTP \(response.statusCode): \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))")
        }
    }

    nonisolated private static func failure(_ message: String) -> NSError {
        NSError(domain: "LifeNarrator.Updater", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    nonisolated private static func prepare(archive: URL, expected: String, work: URL) throws {
        let handle = try FileHandle(forReadingFrom: archive)
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        try handle.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw failure("SHA-256 mismatch: expected \(expected), received \(digest)") }
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, work.path])
        let app = work.appendingPathComponent("LifeNarrator.app")
        var current: SecCode?
        try checkStatus(SecCodeCopySelf([], &current))
        var currentStatic: SecStaticCode?
        try checkStatus(SecCodeCopyStaticCode(current!, [], &currentStatic))
        var requirement: SecRequirement?
        try checkStatus(SecCodeCopyDesignatedRequirement(currentStatic!, [], &requirement))
        var candidate: SecStaticCode?
        try checkStatus(SecStaticCodeCreateWithPath(app as CFURL, [], &candidate))
        try checkStatus(SecStaticCodeCheckValidity(candidate!, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), requirement!))
        try run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    }

    nonisolated private static func checkStatus(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    nonisolated private static func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw failure("\(path) (exit \(process.terminationStatus)): \(String(decoding: data, as: UTF8.self))")
        }
    }

    nonisolated static let replacementScript = #"""
    #!/bin/sh
    set -eu
    pid=$1
    app=$2
    work=$3
    committed=false
    exec 2>"$work/error.txt"
    cleanup() {
      status=$?
      trap - EXIT
      if [ "$committed" = false ] && [ -e "$work/previous.app" ]; then
        rm -rf "$app"
        mv "$work/previous.app" "$app"
      fi
      if [ "$status" -ne 0 ]; then
        /usr/bin/osascript -e 'on run argv' -e 'display alert "LifeNarrator update failed" message (item 1 of argv) as critical' -e 'end run' "$(cat "$work/error.txt")"
      fi
      rm -rf "$work"
      exit "$status"
    }
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    elapsed=0
    while kill -0 "$pid" 2>/dev/null; do
      if [ "$elapsed" -ge 60 ]; then
        echo 'LifeNarrator did not quit within 60 seconds. Please try the update again.' >&2
        exit 1
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    mv "$app" "$work/previous.app"
    mv "$work/LifeNarrator.app" "$app"
    /usr/bin/open "$app"
    committed=true
    """#
}
