import Foundation
import BaseChatFuzz
import BaseChatBackends
import BaseChatInference
import BaseChatTestSupport

@main
@MainActor
struct FuzzChatCLI {

    static func main() async {
        let argv = Array(CommandLine.arguments.dropFirst().filter { $0 != "--" })

        if argv.contains("--help") || argv.contains("-h") {
            printUsage()
            return
        }

        var backend: BackendChoice = .ollama
        var minutes: Int?
        var iterations: Int?
        var seed: UInt64 = UInt64.random(in: 0...UInt64.max)
        var modelHint: String?
        var detectorFilter: Set<String>?
        var quiet = false

        var i = argv.startIndex
        while i < argv.endIndex {
            let arg = argv[i]
            switch arg {
            case "--backend":
                i = argv.index(after: i)
                guard i < argv.endIndex, let b = BackendChoice(rawValue: argv[i]) else {
                    fail("--backend requires one of: \(BackendChoice.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                backend = b
            case "--minutes":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = Int(argv[i]) else { fail("--minutes requires an integer") }
                minutes = n
            case "--iterations":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = Int(argv[i]) else { fail("--iterations requires an integer") }
                iterations = n
            case "--seed":
                i = argv.index(after: i)
                guard i < argv.endIndex, let n = UInt64(argv[i]) else { fail("--seed requires a UInt64") }
                seed = n
            case "--model":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--model requires a value") }
                modelHint = argv[i]
            case "--detector":
                i = argv.index(after: i)
                guard i < argv.endIndex else { fail("--detector requires a value") }
                detectorFilter = Set(argv[i].split(separator: ",").map(String.init))
            case "--quiet":
                quiet = true
            case "--single":
                iterations = 1
            default:
                fail("unknown argument: \(arg)")
            }
            i = argv.index(after: i)
        }

        if backend == .mlx {
            fail("MLX cannot run via `swift run` (needs Xcode-compiled metallib). Use scripts/fuzz.sh or xcodebuild.")
        }

        // Default termination if neither flag passed: 5 minutes.
        if minutes == nil && iterations == nil { minutes = 5 }

        let outputDir = URL(fileURLWithPath: "tmp/fuzz", isDirectory: true)
        let config = FuzzConfig(
            backend: backend,
            minutes: minutes,
            iterations: iterations,
            seed: seed,
            modelHint: modelHint,
            detectorFilter: detectorFilter,
            outputDir: outputDir,
            calibrate: false,
            quiet: quiet
        )

        let factory: any FuzzBackendFactory
        switch backend {
        case .ollama:
            factory = OllamaFuzzFactory(modelHint: modelHint)
        case .llama, .foundation, .mlx, .all:
            fail("\(backend.rawValue) backend not yet wired in v1 (Ollama only).")
        }

        let runner = FuzzRunner(config: config, factory: factory)
        let reporter = TerminalReporter(quiet: quiet)
        _ = await runner.run(reporter: reporter)
    }

    static func printUsage() {
        let lines = [
            "fuzz-chat — chat anomaly fuzzer",
            "",
            "Usage: swift run fuzz-chat [options]",
            "",
            "Options:",
            "  --backend ollama|llama|foundation|mlx|all   default: ollama",
            "  --minutes N         time budget (default 5 if neither flag set)",
            "  --iterations N      iteration budget",
            "  --seed N            RNG seed (default random)",
            "  --model <substr>    model id substring filter",
            "  --detector ids      comma-separated detector ids to run",
            "  --single            shorthand for --iterations 1",
            "  --quiet             suppress live output (still prints findings)",
            "  -h, --help          this help",
        ]
        print(lines.joined(separator: "\n"))
    }
}

struct CLIError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("fuzz-chat: \(message)\n".utf8))
    exit(2)
}
