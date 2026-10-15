import Foundation

@MainActor final class RPCPeer {
    private struct Pending {
        let reply: (Result<RPCValue, any Error>) -> Void
        let close: () -> Void
    }
    private var nextID = 0
    private var pending: [String: Pending] = [:]
    private var closed = false
    let writeLine: (String) throws -> Void
    var onFailure: (any Error) -> Void = { _ in }

    init(writeLine: @escaping (String) throws -> Void) { self.writeLine = writeLine }

    func send(_ value: RPCValue) throws { try writeLine(value.line()) }

    private func submit(id: String, method: String, params: RPCValue, pending call: Pending) {
        pending[id] = call
        do {
            try send(.object(["jsonrpc": .string("2.0"), "id": .string(id),
                              "method": .string(method), "params": params]))
        } catch {
            pending.removeValue(forKey: id)?.reply(.failure(error))
            onFailure(error)
        }
    }

    func request<T: Decodable>(_ method: String, _ params: RPCValue = .object([:]), as: T.Type = T.self) async throws -> T {
        nextID += 1
        let id = "brain:\(nextID)"
        let value: RPCValue = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if closed { continuation.resume(throwing: CancellationError()); return }
                submit(id: id, method: method, params: params, pending: Pending(
                    reply: { continuation.resume(with: $0) },
                    close: { continuation.resume(throwing: CancellationError()) }))
            }
        } onCancel: {
            Task { @MainActor in self.pending.removeValue(forKey: id)?.reply(.failure(CancellationError())) }
        }
        return try value.decode(T.self)
    }

    // These ports cannot throw. A failed call ends the session; it must never resume with a fabricated result.
    func required<T: Decodable & Sendable>(_ method: String, _ params: RPCValue = .object([:]), as: T.Type = T.self) async -> T {
        nextID += 1
        let id = "brain:\(nextID)"
        return await withUnsafeContinuation { continuation in
            guard !closed else { return }
            submit(id: id, method: method, params: params, pending: Pending(reply: { result in
                do { continuation.resume(returning: try result.get().decode(T.self)) }
                catch { self.onFailure(error) }
            }, close: {}))
        }
    }

    func receive(_ object: [String: RPCValue]) throws {
        guard let id = object["id"], id.validID,
              (object["result"] != nil) != (object["error"] != nil) else {
            throw BrainRPCError(code: -32600, message: "Invalid response")
        }
        let result: Result<RPCValue, any Error>
        if let error = object["error"] { result = .failure(try error.decode(BrainRPCError.self)) }
        else { result = .success(object["result"]!) }
        guard case .string(let key) = id else { return }
        pending.removeValue(forKey: key)?.reply(result)
    }

    func close() {
        closed = true
        let calls = pending.values
        pending.removeAll()
        for call in calls { call.close() }
    }
}
