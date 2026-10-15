import Foundation
#if os(Windows)
import CRT
#endif

@main
struct BrainMain {
    static func main() throws {
        #if os(Windows)
        _ = _setmode(_fileno(stdin), _O_BINARY)
        _ = _setmode(_fileno(stdout), _O_BINARY)
        #endif
        while let line = readLine() {
            if let response = try BrainRPC.handle(Data(line.utf8)) {
                try FileHandle.standardOutput.write(contentsOf: response + Data([10]))
            }
        }
    }
}
