import XCTest
@testable import Dictation

/// "Dispatch, …" navigation: the words of each command form, and how spoken names find spaces and tabs.
final class VoiceCommandTests: XCTestCase {
    private func command(_ transcript: String, file: StaticString = #filePath, line: UInt = #line) -> VoiceCommand? {
        guard case .command(let command) = VoiceCommand.read(transcript) else {
            XCTFail("“\(transcript)” is not a command: \(VoiceCommand.read(transcript))", file: file, line: line)
            return nil
        }
        return command
    }

    func testOnlyTranscriptsStartingWithDispatchAreCommands() {
        XCTAssertEqual(VoiceCommand.read("Go to billing"), .text)
        XCTAssertEqual(VoiceCommand.read("Please dispatch the job"), .text)
        XCTAssertEqual(VoiceCommand.read(""), .text)
        XCTAssertEqual(VoiceCommand.read("Dispatch, space"), .unrecognized("space"))
        XCTAssertEqual(VoiceCommand.read("Dispatch."), .unrecognized(""))
        XCTAssertEqual(command("Hey Dispatch, back"), .back)
        XCTAssertEqual(command("Captain, back."), .back)
        XCTAssertEqual(command("Captain, billing tab 2"), .go(space: .name("billing"), tab: .number(2)))
        XCTAssertEqual(command("OK captain, send"), .send)
        XCTAssertEqual(VoiceCommand.read("The captain said hi"), .text)
        XCTAssertTrue(VoiceCommand.addressed("Captain, bill"))
        XCTAssertFalse(VoiceCommand.addressed("Capture the logs"))
    }

    func testBackAndSteps() {
        XCTAssertEqual(command("Dispatch, back."), .back)
        XCTAssertEqual(command("Dispatch go back"), .back)
        XCTAssertEqual(command("Dispatch, next space."), .step(.space, 1))
        XCTAssertEqual(command("Dispatch, previous tab"), .step(.tab, -1))
        XCTAssertEqual(command("Dispatch, go to the next tab please"), .step(.tab, 1))
    }

    func testSidebar() {
        XCTAssertEqual(command("Dispatch, open sidebar."), .sidebar(true))
        XCTAssertEqual(command("Dispatch, show the side bar"), .sidebar(true))
        XCTAssertEqual(command("Dispatch close sidebar"), .sidebar(false))
        XCTAssertEqual(command("Dispatch, hide the sidebar please"), .sidebar(false))
        XCTAssertEqual(command("Dispatch, toggle sidebar"), .sidebar(nil))
        XCTAssertEqual(command("Dispatch, sidebar"), .sidebar(nil))
        XCTAssertEqual(command("Dispatch, sidebar off"), .sidebar(false))
        XCTAssertEqual(command("Dispatch, paint the sidebar blue"), .named("paint sidebar blue"),
                       "not a sidebar command: a name, which finds no place")
    }

    func testChosenWakeWords() {
        XCTAssertEqual(VoiceCommand.read("Jarvis, send", wakeWords: ["jarvis"]), .command(.send))
        XCTAssertEqual(VoiceCommand.read("Dispatch, send", wakeWords: ["jarvis"]), .text, "only the chosen words")
        XCTAssertTrue(VoiceCommand.addressed("Hey Jarvis", wakeWords: ["jarvis"]))
        XCTAssertEqual(VoiceCommand.trailing("Fix it. Jarvis, send.", wakeWords: ["jarvis"])?.command, .send)
        XCTAssertNil(VoiceCommand.trailing("Fix it. Dispatch, send.", wakeWords: ["jarvis"]))
    }

    func testWakeWordsAreCheckedBeforeUse() {
        let checked = WakeWords.check("Jarvis, Captain;  hey there, send, the, 42, jarvis, Dash")
        XCTAssertEqual(checked.words, ["jarvis", "captain", "dash"])
        XCTAssertEqual(checked.problems, ["“hey there” is more than one word", "“send” is a command word",
                                          "“the” starts too many sentences", "“42” is a number"])
        XCTAssertEqual(checked.warnings, ["“Dash” is short: recognizers often drop or mishear one syllable"])
        XCTAssertEqual(WakeWords.check("").words, [])
        XCTAssertEqual(WakeWords.syllables("dispatch"), 2)
        XCTAssertEqual(WakeWords.syllables("captain"), 2)
        XCTAssertEqual(WakeWords.syllables("computer"), 3)
        XCTAssertEqual(WakeWords.syllables("helm"), 1)
        XCTAssertEqual(WakeWords.syllables("drake"), 1)
        XCTAssertEqual(WakeWords.syllables("marble"), 2)
    }

    func testChatCommands() {
        XCTAssertEqual(command("Dispatch, send."), .send)
        XCTAssertEqual(command("Dispatch, send it"), .send)
        XCTAssertEqual(command("Dispatch, steer"), .steer)
        XCTAssertEqual(command("Dispatch, new line."), .newLine)
        XCTAssertEqual(command("Dispatch, scratch that."), .scratch)
        XCTAssertEqual(command("Dispatch, clear the draft"), .clear)
        XCTAssertEqual(command("Dispatch, stop."), .interrupt)
        XCTAssertEqual(command("Dispatch, stop the agent"), .interrupt)
        XCTAssertEqual(command("Dispatch, stop listening."), .stopListening)
        XCTAssertEqual(command("Dispatch, deny."), .deny)
        XCTAssertEqual(command("Dispatch, don't allow"), .deny)
        XCTAssertEqual(command("Dispatch, option 2"), .option(2))
        XCTAssertEqual(command("Dispatch, answer two."), .option(2))
        XCTAssertEqual(command("Dispatch, choose the second option"), .option(2))
        XCTAssertEqual(command("Dispatch, third option"), .option(3))
        XCTAssertEqual(command("Dispatch, listen"), .listen)
        XCTAssertEqual(command("Dispatch, read that again"), .readAgain)
        XCTAssertEqual(command("Dispatch, be quiet"), .quiet)
        XCTAssertEqual(command("Dispatch, go to billing"), .named("billing"), "navigation still reads as before")
    }

    func testTrailingCommands() {
        XCTAssertEqual(VoiceCommand.trailing("Fix the login bug. Dispatch, send.")?.text, "Fix the login bug.")
        XCTAssertEqual(VoiceCommand.trailing("Fix the login bug. Dispatch, send.")?.command, .send)
        XCTAssertEqual(VoiceCommand.trailing("Rename it dispatch steer")?.command, .steer)
        XCTAssertNil(VoiceCommand.trailing("Dispatch, send."), "a whole-utterance command is not trailing")
        XCTAssertNil(VoiceCommand.trailing("Then dispatch the job to the worker."), "not a command")
        XCTAssertNil(VoiceCommand.trailing("Look at it. Dispatch, deny."), "answering the agent must be said on its own")
        XCTAssertNil(VoiceCommand.trailing("Check the redispatch, send logic"), "only the word itself")
        XCTAssertEqual(VoiceCommand.trailing("Dispatch the build. Dispatch, send")?.text, "Dispatch the build.")
        XCTAssertEqual(VoiceCommand.trailing("Fix it. Captain, send.")?.command, .send)
        XCTAssertEqual(VoiceCommand.trailing("Ask the captain. Dispatch, steer")?.text, "Ask the captain.")
        XCTAssertEqual(VoiceCommand.trailing("Dispatch it. Captain, send")?.text, "Dispatch it.", "the last wake word")
    }

    func testSpaces() {
        XCTAssertEqual(command("Dispatch, space 3"), .go(space: .number(3), tab: nil))
        XCTAssertEqual(command("Dispatch, switch to the third space."), .go(space: .number(3), tab: nil))
        XCTAssertEqual(command("Dispatch, last space"), .go(space: .last, tab: nil))
        XCTAssertEqual(command("Dispatch, space number two"), .go(space: .number(2), tab: nil))
        XCTAssertEqual(command("Dispatch, go to space Billing"), .go(space: .name("billing"), tab: nil))
        XCTAssertEqual(command("Dispatch, the api-server space"), .go(space: .name("api server"), tab: nil))
    }

    func testTabs() {
        XCTAssertEqual(command("Dispatch, tab 2."), .go(space: nil, tab: .number(2)))
        XCTAssertEqual(command("Dispatch, tab to"), .go(space: nil, tab: .number(2)), "how recognizers hear “two”")
        XCTAssertEqual(command("Dispatch, tap four"), .go(space: nil, tab: .number(4)))
        XCTAssertEqual(command("Dispatch, billing tattoo."), .go(space: .name("billing"), tab: .number(2)),
                       "how Apple's engine and Whisper both hear “billing tab two”")
        XCTAssertEqual(command("Dispatch, second tab"), .go(space: nil, tab: .number(2)))
        XCTAssertEqual(command("Dispatch, 3rd tab"), .go(space: nil, tab: .number(3)))
        XCTAssertEqual(command("Dispatch, last tab"), .go(space: nil, tab: .last))
        XCTAssertEqual(command("Dispatch, tab Claude"), .go(space: nil, tab: .name("claude")))
        XCTAssertEqual(command("Dispatch, open the vim tab"), .go(space: nil, tab: .name("vim")))
    }

    func testSpaceAndTab() {
        XCTAssertEqual(command("Dispatch, billing tab 2"), .go(space: .name("billing"), tab: .number(2)))
        XCTAssertEqual(command("Dispatch, billing, second tab"), .go(space: .name("billing"), tab: .number(2)))
        XCTAssertEqual(command("Dispatch, space 3 tab 1"), .go(space: .number(3), tab: .number(1)))
        XCTAssertEqual(command("Dispatch, tab 2 in billing"), .go(space: .name("billing"), tab: .number(2)))
        XCTAssertEqual(command("Dispatch, Claude in Billing"), .go(space: .name("billing"), tab: .name("claude")))
        XCTAssertEqual(command("Dispatch, the last tab in space 2"), .go(space: .number(2), tab: .last))
    }

    func testBareNamesAndWhatIsNoCommand() {
        XCTAssertEqual(command("Dispatch, billing."), .named("billing"))
        XCTAssertEqual(command("Dispatch, go to billing"), .named("billing"))
        XCTAssertEqual(command("Dispatch the job to the worker"), .named("job to worker"),
                       "read as a name; the app finds no such place and keeps it as text")
        XCTAssertEqual(VoiceCommand.read("Dispatch, three"), .unrecognized("three"), "a bare number says neither space nor tab")
        XCTAssertEqual(VoiceCommand.read("Dispatch, tab"), .unrecognized("tab"))
        XCTAssertEqual(VoiceCommand.read("Dispatch, space tab 2"), .unrecognized("space tab 2"))
    }

    func testMatchingPrefersExactThenSqueezedThenPrefixThenWordsThenSpelling() {
        let names: [(id: Int, name: String)] = [(1, "billing"), (2, "billing-api"), (3, "api-server"), (4, "Docs site"),
                                                (5, "herdr")]
        XCTAssertEqual(VoiceMatch.best("Billing", among: names), .one(1), "exact beats prefix of billing-api")
        XCTAssertEqual(VoiceMatch.best("api server", among: names), .one(3))
        XCTAssertEqual(VoiceMatch.best("apiserver", among: names), .one(3))
        XCTAssertEqual(VoiceMatch.best("bill", among: names), .several([1, 2]))
        XCTAssertEqual(VoiceMatch.best("billing api", among: names), .one(2))
        XCTAssertEqual(VoiceMatch.best("site", among: names), .one(4))
        XCTAssertEqual(VoiceMatch.best("herder", among: names), .one(5), "a letter off")
        XCTAssertEqual(VoiceMatch.best("job to worker", among: names), .none)
        XCTAssertEqual(VoiceMatch.best("ab", among: [(1, "ac")]), .none, "short names must match exactly")
    }

    func testEqualNamesAreAmbiguous() {
        XCTAssertEqual(VoiceMatch.best("zsh", among: [(1, "zsh"), (2, "vim"), (3, "zsh")]), .several([1, 3]))
    }
}
