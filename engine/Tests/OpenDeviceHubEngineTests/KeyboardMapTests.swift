import XCTest
@testable import OpenDeviceHubEngine

final class KeyboardMapTests: XCTestCase {
    func testTheLettersFollowTheHIDKeyboardPage() {
        // kVK_ANSI_A is 0x00 and HID usage 0x04 is "a"; the rest of the alphabet follows.
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x00), 0x04)
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x06), 0x1D, "z")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x08), 0x06, "c")
    }

    func testDigitsMapOneThroughNineThenZero() {
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x12), 0x1E, "1")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x1D), 0x27, "0")
    }

    func testCommonControlKeys() {
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x24), 0x28, "return")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x35), 0x29, "escape")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x33), 0x2A, "delete")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x31), 0x2C, "space")
    }

    func testArrowKeys() {
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x7B), 0x50, "left")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x7C), 0x4F, "right")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x7D), 0x51, "down")
        XCTAssertEqual(KeyboardMap.usage(forVirtualKeyCode: 0x7E), 0x52, "up")
    }

    func testAnUnknownKeyCodeHasNoUsage() {
        XCTAssertNil(KeyboardMap.usage(forVirtualKeyCode: 0xFF))
    }

    func testEveryUsageIsDistinct() {
        let usages = Array(KeyboardMap.usageByVirtualKeyCode.values)
        XCTAssertEqual(Set(usages).count, usages.count, "two key codes map to the same usage")
    }

    func testEveryUsageIsOnTheKeyboardPage() {
        for usage in KeyboardMap.usageByVirtualKeyCode.values {
            XCTAssertTrue((0x04...0x73).contains(usage), "usage \(usage) is outside the keyboard page")
        }
    }

    func testTypingASimpleString() throws {
        let keys = try XCTUnwrap(KeyboardMap.keys(forTyping: "abc 12"))
        XCTAssertEqual(keys.map(\.usage), [0x04, 0x05, 0x06, 0x2C, 0x1E, 0x1F])
        XCTAssertFalse(keys.contains(where: \.shifted))
    }

    func testCapitalsAreTheirLetterWithShift() throws {
        let keys = try XCTUnwrap(KeyboardMap.keys(forTyping: "aZ"))
        XCTAssertEqual(keys, [
            KeyboardMap.TypedKey(usage: 0x04, shifted: false),
            KeyboardMap.TypedKey(usage: 0x1D, shifted: true),
        ])
    }

    func testSymbolsAreTheUpperCharacterOfTheirKey() throws {
        let keys = try XCTUnwrap(KeyboardMap.keys(forTyping: "a@b.com #1!"))
        XCTAssertEqual(keys.map(\.usage), [0x04, 0x1F, 0x05, 0x37, 0x06, 0x12, 0x10, 0x2C, 0x20, 0x1E, 0x1E])
        XCTAssertEqual(keys.map(\.shifted), [false, true, false, false, false, false, false, false, true, false, true])
    }

    func testEveryShiftedCharacterSharesAKeyWithAnUnshiftedOne() {
        let unshifted = Set(KeyboardMap.usageByCharacter.values)
        for (character, usage) in KeyboardMap.shiftedUsageByCharacter {
            XCTAssertTrue(unshifted.contains(usage), "\(character) has a key nothing unshifted uses")
        }
        XCTAssertEqual(KeyboardMap.shiftedUsageByCharacter.count, 47, "26 capitals and 21 symbols")
    }

    func testTypingRefusesCharactersWithNoKey() {
        XCTAssertNil(KeyboardMap.keys(forTyping: "caf\u{e9}"))
        XCTAssertNil(KeyboardMap.keys(forTyping: "\u{1F600}"))
    }

    func testTypingAnEmptyStringProducesNoKeys() {
        XCTAssertEqual(KeyboardMap.keys(forTyping: ""), [])
    }

    func testModifiersReadWhetherThatKeyIsDownFromItsOwnFlag() throws {
        // Left Shift pressed: the device flag 0x02 is set alongside the generic Shift flag.
        let down = try XCTUnwrap(KeyboardMap.modifier(forVirtualKeyCode: 0x38, flags: 0x20102))
        XCTAssertEqual(down.usage, 0xE1)
        XCTAssertTrue(down.isDown)
        // Left Shift released while right Shift is still held: Shift stays set, 0x02 does not.
        let up = try XCTUnwrap(KeyboardMap.modifier(forVirtualKeyCode: 0x38, flags: 0x20104))
        XCTAssertFalse(up.isDown)
        XCTAssertNil(KeyboardMap.modifier(forVirtualKeyCode: 0x37, flags: 0x100108), "Command stays with the Mac")
    }
}
