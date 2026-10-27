import ArgumentParser
import Foundation
import OpenDeviceHubEngine

/// `--verify` for the commands that send input. CoreSimulator accepts a message whether or not the
/// guest acts on it, so the only evidence that input landed is the screen changing.
struct Verification: ParsableArguments {
    @Flag(help: "Fail unless the screen changes after the input. Exits 2 when it does not change and 3 when the screen was already changing too much to tell.")
    var verify = false

    @Option(help: "Seconds to wait for the screen to change with --verify.")
    var verifyTimeout: Double = 3

    /// Exit codes an agent can tell apart from a usage error (64) or a failure (1).
    static let unchangedExitCode: Int32 = 2
    static let inconclusiveExitCode: Int32 = 3

    /// Frames taken before the input, spread over about a second so a blinking cursor is caught
    /// both on and off.
    private static let baselineFrames = 3

    func validate() throws {
        guard verifyTimeout > 0 else {
            throw ValidationError("--verify-timeout must be more than zero.")
        }
    }

    func check(_ udid: String, _ input: () async throws -> Void) async throws {
        guard verify else {
            try await input()
            return
        }
        let simctl = SimctlService()
        var baseline: [ScreenFrame] = []
        for _ in 0..<Self.baselineFrames {
            baseline.append(try ScreenFrame(png: simctl.screenshot(udid: udid)))
        }
        guard let noise = ScreenChange.noise(in: baseline), let before = baseline.last else {
            FileHandle.standardError.write(Data("could not verify: the screen turned while it was being watched\n".utf8))
            throw ExitCode(Self.inconclusiveExitCode)
        }
        let noisy = noise.lazy.filter { $0 }.count
        guard noisy * 4 < noise.count else {
            FileHandle.standardError.write(Data("could not verify: \(noisy) of \(noise.count) pixels were already changing\n".utf8))
            throw ExitCode(Self.inconclusiveExitCode)
        }

        try await input()
        // The command's own line comes before the verdict, even when stdout is a pipe.
        fflush(stdout)

        let deadline = Date().addingTimeInterval(verifyTimeout)
        repeat {
            let after = try ScreenFrame(png: simctl.screenshot(udid: udid))
            let change = ScreenChange.difference(from: before, to: after, ignoring: noise)
            if change.isChange {
                let box = change.bounds
                print("verified: \(change.pixels) pixels changed in \(Int(box.width))x\(Int(box.height)) at \(Int(box.minX)),\(Int(box.minY))")
                return
            }
        } while Date() < deadline
        FileHandle.standardError.write(Data("""
            the screen did not change within \(verifyTimeout) s, so the device may not have acted on the \
            input. If no input works on this simulator, restart it.

            """.utf8))
        throw ExitCode(Self.unchangedExitCode)
    }
}
