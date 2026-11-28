import ArgumentParser
import Foundation
import OpenDeviceHubEngine

/// `--verify` for the commands that send input. CoreSimulator accepts a message whether or not the
/// guest acts on it, so the only evidence that input landed is the screen changing.
struct Verification: ParsableArguments {
    @Flag(help: "Fail unless the screen changes after the input. Exits 2 when it does not change, and 3 without sending the input when the screen was still changing too much to tell after 5 s.")
    var verify = false

    @Option(help: "Seconds to wait for the screen to change with --verify (default: 3, and 10 for type and button home).")
    var verifyTimeout: Double?

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
    /// How long a screen must have gone without a new frame for one frame to stand in for the
    /// baseline: longer than the baseline frames span, so it never sees less than they would.
    static let stillEnough: TimeInterval = 1.0
    /// How long a screen still moving before the input is watched for it to settle.
    static let settleLimit: TimeInterval = 5
    static let settleRetrySpacing: Duration = .milliseconds(200)
    /// Settled, after the screen was seen moving: fewer than 1 pixel in this many changing across the
    /// baseline. A blinking cursor is far less (about 0.01% of an iPhone 17 Pro's screen).
    static let settledFraction = 100
    /// Between frames after the input, so a host that reads frames instantly is not polled flat out.
    private static let pollSpacing: Duration = .milliseconds(50)

    func validate() throws {
        guard (verifyTimeout ?? 1) > 0 else {
            throw ValidationError("--verify-timeout must be more than zero.")
        }
    }

    /// `defaultTimeout`: how long to wait for the change when `--verify-timeout` is not given.
    func check(_ udid: String, defaultTimeout: Double = 3, _ input: () async throws -> Void) async throws {
        let verifyTimeout = self.verifyTimeout ?? defaultTimeout
        guard verify else {
            try await input()
            return
        }
        let host = try SimulatorHosts.current()
        // A screen moving too much to tell (an on-screen keyboard sliding up after a text field took
        // focus, which took about 4 s, x86Sim 0.5.0, iOS 27.2) is watched again until it has settled,
        // for up to `settleLimit`, rather than given up on at once. Settled means hardly anything
        // still changes, not merely under the first baseline's bar: input sent while an animation
        // was winding down passed --verify on the animation's own frames (a slow drag, x86Sim 0.5.0).
        // Nothing is sent until the baseline holds.
        let settleDeadline = Date().addingTimeInterval(Self.settleLimit)
        var watched: (before: ScreenFrame, noise: [Bool])?
        var problem = ""
        var settling = false
        while true {
            let baseline = try await self.baseline(host, udid)
            if let noise = ScreenChange.noise(in: baseline), let before = baseline.last {
                let noisy = noise.lazy.filter { $0 }.count
                if settling ? noisy * Self.settledFraction < noise.count : noisy * 4 < noise.count {
                    watched = (before, noise)
                    break
                }
                problem = "\(noisy) of \(noise.count) pixels were still changing"
            } else {
                problem = "the screen turned while it was being watched"
            }
            settling = true
            if Date() >= settleDeadline { break }
            try await Task.sleep(for: Self.settleRetrySpacing)
        }
        guard let (before, noise) = watched else {
            FileHandle.standardError.write(Data("""
                could not verify, so nothing was sent: \(problem) for \(Int(Self.settleLimit)) s. \
                Wait for the screen to settle and try again.

                """.utf8))
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

    /// Frames from before the input. A host that publishes frames only when the screen changes
    /// (x86Sim's ring) says how long it has been still; still for longer than the spaced baseline
    /// would watch, one frame is the baseline, since the spaced frames could only have found the
    /// same pixels. The second reading catches a frame published while that one was copied. In a
    /// 4-vCPU cloud session this was 0.8 s of the ~2.5 s a `tap --label --verify` took (x86Sim
    /// 0.5.0, iOS 27.2).
    private func baseline(_ host: any SimulatorHost, _ udid: String) async throws -> [ScreenFrame] {
        if let still = try host.screenStillFor(udid), still >= Self.stillEnough {
            let frame = try host.screenFrame(udid)
            if let stillAfter = try host.screenStillFor(udid), stillAfter >= Self.stillEnough {
                return [frame]
            }
        }
        var frames: [ScreenFrame] = []
        let clock = ContinuousClock()
        for index in 0..<Self.baselineFrames {
            let started = clock.now
            frames.append(try host.screenFrame(udid))
            if index < Self.baselineFrames - 1 {
                try await Task.sleep(until: started + Self.baselineSpacing, clock: clock)
            }
        }
        return frames
    }
}
