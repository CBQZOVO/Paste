import Foundation
import XCTest
@testable import PasteAgent

final class HotkeyParserTests: XCTestCase {
    func testParsesTheDefaultHotkey() {
        let hotkey = HotkeyParser.parse("CmdOrCtrl+Shift+V")
        XCTAssertEqual(hotkey?.keyCode, 9) // kVK_ANSI_V
        XCTAssertEqual(hotkey?.modifiers, [.command, .shift])
    }

    func testParsingIsCaseInsensitiveAndTolerantOfWhitespace() {
        XCTAssertEqual(
            HotkeyParser.parse("  cmd + OPTION + 1 "),
            Hotkey(keyCode: 18, modifiers: [.command, .option])
        )
        XCTAssertEqual(
            HotkeyParser.parse("CTRL+ALT+F5"),
            Hotkey(keyCode: 96, modifiers: [.control, .option])
        )
    }

    func testRejectsInvalidShortcuts() {
        XCTAssertNil(HotkeyParser.parse("V"))
        XCTAssertNil(HotkeyParser.parse("Cmd+"))
        XCTAssertNil(HotkeyParser.parse("Cmd+NotAKey"))
        XCTAssertNil(HotkeyParser.parse("Hyper+V"))
        XCTAssertNil(HotkeyParser.parse(""))
    }

    func testQuickPasteUsesCommandAndDigitKeyCodes() {
        XCTAssertEqual(HotkeyParser.quickPaste(1), Hotkey(keyCode: 18, modifiers: .command))
        XCTAssertEqual(HotkeyParser.quickPaste(9), Hotkey(keyCode: 25, modifiers: .command))
        XCTAssertNil(HotkeyParser.quickPaste(0))
        XCTAssertNil(HotkeyParser.quickPaste(10))
    }
}
