import CoreGraphics
import Foundation
import Testing
@testable import OpenDeviceHubEngine

@Suite struct SimHIDLinesTests {
    @Test func oneContactCarriesItsEdgeOnlyWhenItBegins() throws {
        let down = TouchEvent(phase: .began, points: [CGPoint(x: 0.5, y: 0.999)], edge: .bottom)
        let move = TouchEvent(phase: .moved, points: [CGPoint(x: 0.5, y: 0.6)], edge: .bottom)
        let up = TouchEvent(phase: .ended, points: [CGPoint(x: 0.5, y: 0.2)])
        #expect(try SimHIDConnection.lines(for: down) == ["touch down 0.50000 0.99900 bottom"])
        #expect(try SimHIDConnection.lines(for: move) == ["touch move 0.50000 0.60000"])
        #expect(try SimHIDConnection.lines(for: up) == ["touch up 0.50000 0.20000"])
    }

    @Test func aCancelledContactLifts() throws {
        let cancelled = TouchEvent(phase: .cancelled, points: [CGPoint(x: 0.25, y: 0.75)])
        #expect(try SimHIDConnection.lines(for: cancelled) == ["touch up 0.25000 0.75000"])
    }

    @Test func twoContactsAreOneLine() throws {
        let pinch = TouchEvent(phase: .moved, points: [CGPoint(x: 0.4, y: 0.5), CGPoint(x: 0.6, y: 0.5)])
        #expect(try SimHIDConnection.lines(for: pinch) == ["touch2 move 0.40000 0.50000 0.60000 0.50000"])
    }

    @Test func threeContactsAreRefused() {
        let points = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.3, y: 0.3)]
        #expect(throws: X86SimError.self) { try SimHIDConnection.lines(for: TouchEvent(phase: .began, points: points)) }
    }

    @Test func coordinatesStayOnScreen() {
        #expect(SimHIDConnection.coordinate(-0.2) == "0.00000")
        #expect(SimHIDConnection.coordinate(1.4) == "1.00000")
    }

    @Test func keysAreUsages() {
        #expect(SimHIDConnection.lines(for: KeyEvent(phase: .down, usage: 0x28)) == ["key down 40"])
        #expect(SimHIDConnection.lines(for: KeyEvent(phase: .up, usage: 225)) == ["key up 225"])
    }

    @Test func buttonsUseSimHIDsNames() throws {
        #expect(try SimHIDConnection.lines(for: .home, phase: .down) == ["button home down"])
        #expect(try SimHIDConnection.lines(for: .volumeUp, phase: .up) == ["button volup up"])
        #expect(try SimHIDConnection.lines(for: .actionButton, phase: .down) == ["button action down"])
    }

    @Test func buttonsSimHIDLacksAreRefused() {
        #expect(throws: X86SimError.self) { try SimHIDConnection.lines(for: .cameraControl, phase: .down) }
        #expect(throws: X86SimError.self) { try SimHIDConnection.lines(for: .softwareKeyboard, phase: .down) }
    }

    @Test func orientationNamesAreDeviceOrientations() {
        #expect(X86SimHost.orientation(named: "landscapeLeft\n") == .landscapeLeft)
        #expect(X86SimHost.orientation(named: "portraitUpsideDown") == .portraitUpsideDown)
        #expect(X86SimHost.orientation(named: "unknown") == .portrait)
        #expect(X86SimHost.orientation(named: "faceUp") == nil)
    }
}
