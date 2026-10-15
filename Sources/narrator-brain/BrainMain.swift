import Foundation
import Dispatch
import NarratorBrain
#if os(Windows)
import CRT
#elseif os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct BrainMain {
    static func main() {
        #if os(Windows)
        _ = _setmode(_fileno(stdin), _O_BINARY)
        _ = _setmode(_fileno(stdout), _O_BINARY)
        #endif
        let input = AsyncThrowingStream<String, any Error>.makeStream()
        DispatchQueue.global().async {
            while let line = readLine() { input.continuation.yield(line) }
            input.continuation.finish()
        }
        Task { @MainActor in
            do {
                let server = BrainRPCServer { line in
                    try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
                }
                try await server.run(lines: input.stream)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("narrator-brain: \(error)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }
}
