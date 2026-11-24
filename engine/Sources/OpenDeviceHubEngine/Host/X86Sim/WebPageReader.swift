import CoreGraphics
import Foundation

/// The elements of the web pages an app shows, read from stupidsim-webax, which x86Sim loads into
/// WebKit's WebContent processes (guest/stupidsim-webax.m documents the files used here). AXRuntime,
/// which stupidsim-guest reads the app with, stops at the web view.
///
/// Only processes whose `pages-<pid>` names a page of `hostPID` are asked: a WebContent process of
/// an app in the background may be suspended and never answer. One that is asked and does not
/// answer within `budget` is left out rather than failing the whole tree, which still has the
/// app's own elements.
struct WebPageReader {
    let device: X86SimDevice
    /// Covers a page walked for the first time (WebKit builds its tree, then the answer waits half a
    /// second for frames to settle) on a slow device. Answers usually take about 0.1 s.
    var budget: TimeInterval = 4
    var proc = "/proc"

    var directory: URL { device.dataDirectory.appending(path: "tmp/stupidsim-web") }

    struct Answer: Decodable {
        init(request: String, pages: [Page]) {
            self.request = request
            self.pages = pages
        }
        struct Page: Decodable {
            let host: Int32
            let elements: [AccessibilityElement]
        }
        let request: String
        let pages: [Page]
    }

    /// The elements of `hostPID`'s pages whose centres are on `screen`, in the guest's points.
    func elements(hostPID: Int32, screen: CGRect) -> [AccessibilityElement] {
        let candidates = processes(hosting: hostPID)
        guard !candidates.isEmpty else { return [] }
        let live = livePIDs(among: Set(candidates))
        var pending: [Int32: String] = [:]
        for pid in candidates where live.contains(pid) {
            let token = UUID().uuidString
            let request = directory.appending(path: "req-\(pid)")
            let staging = directory.appending(path: ".req-\(pid)")
            guard (try? Data(token.utf8).write(to: staging)) != nil,
                  rename(staging.path, request.path) == 0 else { continue }
            pending[pid] = token
        }
        var answers: [Answer] = []
        let deadline = Date().addingTimeInterval(budget)
        while !pending.isEmpty && Date() < deadline {
            for (pid, token) in pending {
                guard let data = try? Data(contentsOf: directory.appending(path: "web-\(pid).json")),
                      let answer = try? JSONDecoder().decode(Answer.self, from: data),
                      answer.request == token else { continue }
                answers.append(answer)
                pending[pid] = nil
            }
            if !pending.isEmpty { usleep(20_000) }
        }
        for pid in pending.keys { try? FileManager.default.removeItem(at: directory.appending(path: "req-\(pid)")) }
        return Self.merge(answers, hostPID: hostPID, screen: screen)
    }

    /// The pages of `hostPID`, each element once, keeping those whose centre is on the screen.
    static func merge(_ answers: [Answer], hostPID: Int32, screen: CGRect) -> [AccessibilityElement] {
        var seen = Set<String>()
        var out: [AccessibilityElement] = []
        for page in answers.flatMap(\.pages) where page.host == hostPID {
            for element in page.elements where screen.contains(CGPoint(x: element.frame.midX, y: element.frame.midY)) {
                let key = "\(element.label ?? "")|\(element.value ?? "")|\(Int(element.frame.minX))|\(Int(element.frame.minY))"
                if seen.insert(key).inserted { out.append(element) }
            }
        }
        return out
    }

    /// WebContent processes (their pid inside the device) whose `pages-<pid>` lists `hostPID`.
    func processes(hosting hostPID: Int32) -> [Int32] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name -> Int32? in
            guard name.hasPrefix("pages-"), let pid = Int32(name.dropFirst("pages-".count)),
                  let text = try? String(contentsOf: directory.appending(path: name), encoding: .utf8) else { return nil }
            let hosts = text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
            return hosts.contains(hostPID) ? pid : nil
        }.sorted()
    }

    /// Of `pids` (inside the device), those still running as this device's WebContent: `pages-<pid>`
    /// outlives its process, and a device that rebooted reuses pids. Darling runs device processes
    /// in a pid namespace, so /proc/<pid>/status's NSpid line ends with the pid inside it.
    func livePIDs(among pids: Set<Int32>) -> Set<Int32> {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: proc) else { return [] }
        var live = Set<Int32>()
        for entry in entries where Int32(entry) != nil {
            guard let status = try? String(contentsOfFile: "\(proc)/\(entry)/status", encoding: .utf8),
                  let inner = Self.innerPID(status: status), pids.contains(inner),
                  let commandLine = FileManager.default.contents(atPath: "\(proc)/\(entry)/cmdline"),
                  String(decoding: commandLine, as: UTF8.self).contains("com.apple.WebKit.WebContent"),
                  let environment = FileManager.default.contents(atPath: "\(proc)/\(entry)/environ"),
                  String(decoding: environment, as: UTF8.self).contains("SIMULATOR_UDID=\(device.udid)") else {
                continue
            }
            live.insert(inner)
        }
        return live
    }

    static func innerPID(status: String) -> Int32? {
        guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("NSpid:") }) else { return nil }
        return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.flatMap { Int32($0) }
    }
}
