import Foundation
import Testing
@testable import OpenDeviceHubEngine
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@Suite struct GuestServerTests {
    /// A one-connection server on a Unix socket that records the request line and answers `reply`.
    private final class FakeServer: @unchecked Sendable {
        let path = "/tmp/sg-test-\(UUID().uuidString.prefix(8)).sock"
        private let listener: Int32
        private(set) var request = ""
        private let done = DispatchSemaphore(value: 0)

        init(reply: String) throws {
            #if canImport(Glibc)
            listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
            #else
            listener = socket(AF_UNIX, SOCK_STREAM, 0)
            #endif
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8)
                buffer[path.utf8.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(bound == 0)
            #expect(listen(listener, 1) == 0)
            let listener = listener
            Thread.detachNewThread { [self] in
                let connection = accept(listener, nil, nil)
                var line = Data()
                var byte: UInt8 = 0
                while read(connection, &byte, 1) == 1, byte != 0x0A { line.append(byte) }
                request = String(decoding: line, as: UTF8.self)
                _ = reply.withCString { write(connection, $0, strlen($0)) }
                _ = SimHIDConnection.closeDescriptor(connection)
                done.signal()
            }
        }

        func finish() -> String {
            done.wait()
            _ = SimHIDConnection.closeDescriptor(listener)
            unlink(path)
            return request
        }
    }

    @Test func sendsOneJSONLineAndReadsTheAnswerToTheEnd() throws {
        let server = try FakeServer(reply: #"{"children":[],"role":"AXApplication"}"#)
        let answer = try GuestServer.ask(["tree", "--springboard"], socket: server.path)
        #expect(server.finish() == #"["tree","--springboard"]"#)
        #expect(String(decoding: answer, as: UTF8.self) == #"{"children":[],"role":"AXApplication"}"#)
    }

    @Test func aGuestErrorIsThrown() {
        let answer = Data(#"{"error":"no app is in front"}"#.utf8)
        #expect(throws: X86SimError.self) { try GuestServer.checked(answer, command: "tree") }
        #expect((try? GuestServer.checked(Data(#"{"text":"hi"}"#.utf8), command: "pasteboard-get")) != nil)
    }

    @Test func noServerMeansAConnectError() {
        #expect(throws: X86SimError.self) { try GuestServer.ask(["ping"], socket: "/tmp/sg-test-none.sock") }
    }

    @Test func theBuildIDFollowsTheProgramsBytes() {
        #expect(GuestServer.fnv1a(Data("a".utf8)) == GuestServer.fnv1a(Data("a".utf8)))
        #expect(GuestServer.fnv1a(Data("a".utf8)) != GuestServer.fnv1a(Data("b".utf8)))
        #expect(GuestServer.fnv1a(Data()) == "84222325")
    }
}
