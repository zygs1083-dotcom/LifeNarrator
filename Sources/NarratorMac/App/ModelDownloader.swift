import Combine
import CryptoKit
import Foundation

public struct DownloadableModel: Sendable {
    public let name: String
    public let url: URL
    public let size: Int64
    public let sha256: String
    public var filename: String { url.lastPathComponent }
}

public enum ModelCatalog {
    public static let models = [DownloadableModel(
        name: "Qwen3.5-4B-Q4_K_M",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!,
        size: 2_740_937_888,
        sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"
    ), DownloadableModel(
        name: "Qwen3.5-2B-Q4_K_M",
        url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf")!,
        size: 1_280_835_840,
        sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223"
    )]
}

public enum ModelDownloadSource: String, CaseIterable {
    case huggingFace = "huggingface.co", mirror = "hf-mirror.com"
}

@MainActor
public final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    public enum State { case notDownloaded, downloading(Double), verifying, ready }
    @Published public private(set) var state: State
    @Published public var error: String?
    public var progressHandler: (@MainActor (Double) -> Void)?
    public let model: DownloadableModel
    public let destination: URL
    private let resumeDirectory: URL
    private var resumeURL: URL
    private var task: URLSessionDownloadTask?
    private var paused = false
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Otherwise an unused Cache.db is created under ~/Library/Caches.
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public init(directory: AppDataDirectory, model: DownloadableModel = ModelCatalog.models[0]) {
        self.model = model
        destination = directory.models.appendingPathComponent(model.filename)
        resumeDirectory = directory.root
        resumeURL = directory.root.appendingPathComponent("\(model.name)-huggingface.co.resume")
        state = FileManager.default.fileExists(atPath: destination.path) ? .ready : .notDownloaded
        super.init()
    }

    public func start(source: ModelDownloadSource) throws {
        error = nil
        paused = false
        resumeURL = resumeDirectory.appendingPathComponent("\(model.name)-\(source.rawValue).resume")
        let staging = destination.appendingPathExtension("download")
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        if FileManager.default.fileExists(atPath: resumeURL.path) {
            task = session.downloadTask(withResumeData: try Data(contentsOf: resumeURL))
        } else {
            var components = URLComponents(url: model.url, resolvingAgainstBaseURL: false)!
            components.host = source.rawValue
            task = session.downloadTask(with: components.url!)
        }
        state = .downloading(0)
        task!.resume()
    }

    public func pause() async throws {
        paused = true
        let data = await withCheckedContinuation { continuation in
            task!.cancel { continuation.resume(returning: $0) }
        }
        task = nil
        state = .notDownloaded
        if let data { try data.write(to: resumeURL, options: .atomic) }
    }

    public func delete() throws {
        try FileManager.default.removeItem(at: destination)
        state = .notDownloaded
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                      didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                      totalBytesExpectedToWrite: Int64) {
        let progress = Double(totalBytesWritten) / Double(model.size)
        Task { @MainActor in
            if self.paused { return }
            self.state = .downloading(progress)
            self.progressHandler?(progress)
        }
    }

    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                      didFinishDownloadingTo location: URL) {
        let staging = destination.appendingPathExtension("download")
        do {
            let response = downloadTask.response as! HTTPURLResponse
            guard (200..<300).contains(response.statusCode) else {
                throw NSError(domain: "ModelDownloader.HTTP", code: response.statusCode)
            }
            try FileManager.default.moveItem(at: location, to: staging)
            Task { @MainActor in
                self.state = .verifying
                do {
                    try await Task.detached {
                        try Self.verify(file: staging, model: self.model)
                    }.value
                    try FileManager.default.moveItem(at: staging, to: self.destination)
                    if FileManager.default.fileExists(atPath: self.resumeURL.path) {
                        try FileManager.default.removeItem(at: self.resumeURL)
                    }
                    self.task = nil
                    self.state = .ready
                } catch {
                    let failure = error
                    do {
                        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
                        self.error = String(describing: failure)
                    } catch { self.error = String(describing: error) }
                    self.task = nil
                    self.state = .notDownloaded
                }
            }
        } catch {
            Task { @MainActor in
                self.task = nil
                self.state = .notDownloaded
                self.error = String(describing: error)
            }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask,
                                      didCompleteWithError error: (any Error)?) {
        guard let error else { return }
        Task { @MainActor in
            if self.paused { return }
            do {
                if let data = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data {
                    try data.write(to: self.resumeURL, options: .atomic)
                }
                self.error = String(describing: error)
            } catch { self.error = String(describing: error) }
            self.task = nil
            self.state = .notDownloaded
        }
    }

    nonisolated public static func verify(file: URL, model: DownloadableModel) throws {
        let handle = try FileHandle(forReadingFrom: file)
        var hash = SHA256()
        var size: Int64 = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hash.update(data: data)
            size += Int64(data.count)
        }
        try handle.close()
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard size == model.size, digest == model.sha256 else {
            try FileManager.default.removeItem(at: file)
            throw NSError(domain: "ModelDownloader.SHA256", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SHA-256 mismatch: \(digest) (\(size) bytes)"
            ])
        }
    }
}
