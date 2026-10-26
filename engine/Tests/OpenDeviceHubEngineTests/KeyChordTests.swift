import Testing
@testable import OpenDeviceHubEngine

@Suite struct KeyChordTests {
    @Test func aNamedKeyHasNoModifiers() {
        #expect(KeyboardMap.chord(named: "delete") == .init(modifiers: [], usage: 0x2A))
        #expect(KeyboardMap.chord(named: "Backspace") == .init(modifiers: [], usage: 0x2A))
        #expect(KeyboardMap.chord(named: "forward-delete") == .init(modifiers: [], usage: 0x4C))
        #expect(KeyboardMap.chord(named: "left") == .init(modifiers: [], usage: 0x50))
    }

    @Test func modifiersAreHeldInTheOrderGiven() {
        #expect(KeyboardMap.chord(named: "cmd+a") == .init(modifiers: [0xE3], usage: 0x04))
        #expect(KeyboardMap.chord(named: "shift+option+left") == .init(modifiers: [0xE1, 0xE2], usage: 0x50))
    }

    @Test func anUpperCharacterHoldsShift() {
        #expect(KeyboardMap.chord(named: "A") == .init(modifiers: [0xE1], usage: 0x04))
        #expect(KeyboardMap.chord(named: "cmd+Z") == .init(modifiers: [0xE3, 0xE1], usage: 0x1D))
        #expect(KeyboardMap.chord(named: "shift+A") == .init(modifiers: [0xE1], usage: 0x04))
    }

    @Test func thePlusKeyCanBeNamed() {
        #expect(KeyboardMap.chord(named: "+") == .init(modifiers: [0xE1], usage: 0x2E))
        #expect(KeyboardMap.chord(named: "cmd++") == .init(modifiers: [0xE3, 0xE1], usage: 0x2E))
    }

    @Test func anythingUnknownIsRefused() {
        #expect(KeyboardMap.chord(named: "") == nil)
        #expect(KeyboardMap.chord(named: "backspac") == nil)
        #expect(KeyboardMap.chord(named: "hyper+a") == nil)
        #expect(KeyboardMap.chord(named: "cmd+") == nil)
        #expect(KeyboardMap.chord(named: "é") == nil)
    }
}
