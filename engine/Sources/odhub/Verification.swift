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
    /// The least time between baseline frames. simctl took about this long for a screenshot, which
    /// is what spread the frames out; the framebuffer and x86Sim's frame ring answer in
    /// milliseconds, and three frames read back to back missed a story ring's animation, so
    /// `--verify` passed on input that had done nothing (x86Sim 0.3.0).
    private static let baselineSpacing: Duration = .milliseconds(400)
    /// Between frames after the input, so a host that reads frames instantly is not polled flat out.
    private static let pollSpacing: Duration = .milliseconds(50)

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
        let host = try SimulatorHosts.current()
        var baseline: [ScreenFrame] = []
        let clock = ContinuousClock()
        for index in 0..<Self.baselineFrames {
            let started = clock.now
            baseline.append(try host.screenFrame(udid))
            if index < Self.baselineFrames - 1 {
                try await Task.sleep(until: started + Self.baselineSpacing, clock: clock)
            }
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
        fflush(nil)

        let deadline = Date().addingTimeInterval(verifyTimeout)
        repeat {
            let after = try host.screenFrame(udid)
            let change = ScreenChange.difference(from: before, to: after, ignoring: noise)
            if change.isChange {
                let box = change.bounds
                print("verified: \(change.pixels) pixels changed in \(Int(box.width))x\(Int(box.height)) at \(Int(box.minX)),\(Int(box.minY))")
                return
            }
            try await Task.sleep(for: Self.pollSpacing)
        } while Date() < deadline
        FileHandle.standardError.write(Data("""
            the screen did not change within \(verifyTimeout) s, so the device may not have acted on the \
            input. If no input works on this simulator, restart it.

            """.utf8))
        throw ExitCode(Self.unchangedExitCode)
    }
}
