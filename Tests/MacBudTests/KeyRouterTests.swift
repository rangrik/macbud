import AppKit
import Testing
@testable import MacBud

@Suite struct KeyRouterTests {
    private func event(_ chars: String, code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    @Test func navigationKeys() {
        #expect(KeyRouter.command(for: event("", code: 126)) == .moveUp)
        #expect(KeyRouter.command(for: event("", code: 125)) == .moveDown)
        #expect(KeyRouter.command(for: event("", code: 123)) == .moveLeft)
        #expect(KeyRouter.command(for: event("n", code: 45, .control)) == .moveDown)
        #expect(KeyRouter.command(for: event("k", code: 40, .control)) == .moveUp)
        #expect(KeyRouter.command(for: event("", code: 53)) == .close)
    }

    @Test func actionsAndModifiers() {
        #expect(KeyRouter.command(for: event("\r", code: 36)) == .primaryAction)
        #expect(KeyRouter.command(for: event("\r", code: 36, .command)) == .secondaryAction)
        #expect(KeyRouter.command(for: event("\u{7F}", code: 51, .command)) == .delete)
        #expect(KeyRouter.command(for: event("\u{7F}", code: 51, [.command, .shift])) == .clearAll)
        #expect(KeyRouter.command(for: event("\u{7F}", code: 51)) == nil, "plain backspace belongs to the text field")
        #expect(KeyRouter.command(for: event("\t", code: 48)) == .nextSection)
        #expect(KeyRouter.command(for: event("\t", code: 48, .shift)) == .previousSection)
        #expect(KeyRouter.command(for: event("2", code: 19, .command)) == .selectSection(.snippets))
        #expect(KeyRouter.command(for: event("p", code: 35, .command)) == .togglePin)
        #expect(KeyRouter.command(for: event(",", code: 43, .command)) == .openSettings)
    }

    @Test func plainTypingFallsThrough() {
        #expect(KeyRouter.command(for: event("a", code: 0)) == nil)
        #expect(KeyRouter.command(for: event("p", code: 35)) == nil)
        #expect(KeyRouter.command(for: event(" ", code: 49)) == nil)
    }
}
