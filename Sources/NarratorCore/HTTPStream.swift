import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum HTTPStream {
    public static func bytes(for request: URLRequest, configuration: URLSessionConfiguration = .default) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamDelegate(continuation: continuation)
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in task.cancel(); session.invalidateAndCancel() }
            task.resume()
        }
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    var status = 0
    var errorBody = Data()

    init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) { self.continuation = continuation }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as! HTTPURLResponse).statusCode
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if (200..<300).contains(status) { continuation.yield(data) }
        else { errorBody.append(data) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { continuation.finish(throwing: error) }
        else if !(200..<300).contains(status) {
            continuation.finish(throwing: HTTPClientError.status(status, String(decoding: errorBody, as: UTF8.self)))
        } else { continuation.finish() }
        session.finishTasksAndInvalidate()
    }
}

struct SSEParser {
    private var buffer = Data()
    private var lines: [String] = []
    private(set) var done = false

    mutating func feed(_ data: Data) -> [String] {
        guard !done else { return [] }
        buffer.append(data)
        var events: [String] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self).trimmingCharacters(in: .newlines)
            buffer.removeSubrange(...newline)
            if let event = consume(line) { events.append(event) }
            if done { break }
        }
        return events
    }

    mutating func finish() -> [String] {
        guard !done else { return [] }
        var events: [String] = []
        if !buffer.isEmpty, let event = consume(String(decoding: buffer, as: UTF8.self)) { events.append(event) }
        buffer.removeAll()
        if let event = consume("") { events.append(event) }
        return events
    }

    private mutating func consume(_ line: String) -> String? {
        if line.isEmpty {
            guard !lines.isEmpty else { return nil }
            let event = lines.joined(separator: "\n")
            lines.removeAll()
            if event == "[DONE]" { done = true; return nil }
            return event
        }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.first == " " { value.removeFirst() }
            lines.append(value)
        }
        return nil
    }
}

func generatedJSON(_ text: String) -> String {
    var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if result == "`" || result == "``" { return "" }
    if result.hasPrefix("```") {
        guard let newline = result.firstIndex(of: "\n") else { return "" }
        result = String(result[result.index(after: newline)...])
        while result.last == "`" { result.removeLast() }
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
