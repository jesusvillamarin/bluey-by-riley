import XCTest
@testable import GooglyMac

final class SentenceSplitterTests: XCTestCase {
    func testEmitsEachSentenceOnceAsItCompletes() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("Hola. Qué"), ["Hola."])
        XCTAssertEqual(splitter.feed("Hola. Qué tal? Bien"), ["Qué tal?"])
        XCTAssertEqual(splitter.finish(), "Bien")
        XCTAssertNil(splitter.finish(), "the rest is handed out once")
    }

    func testNoWhitespaceAfterDotMeansNoSplit() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("3.5 grados"), [])
        XCTAssertEqual(splitter.finish(), "3.5 grados")
    }

    func testTerminatorAtTheEndWaitsForWhitespace() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("¡Listo!"), [])
        XCTAssertEqual(splitter.finish(), "¡Listo!")
    }

    func testEllipsisAndMixedTerminators() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("Hmm… vale?! Sí... ok"), ["Hmm…", "vale?!", "Sí..."])
        XCTAssertEqual(splitter.finish(), "ok")
    }

    func testClosingQuoteStaysWithItsSentence() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("He said \"go!\" Then left"), ["He said \"go!\""])
        XCTAssertEqual(splitter.finish(), "Then left")
    }

    func testSeveralSentencesInOneFeedAndNewlines() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("One. Two!\nThree? "), ["One.", "Two!", "Three?"])
        XCTAssertNil(splitter.finish(), "only whitespace is left")
    }

    func testFinishIsNilWhenBlank() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("   "), [])
        XCTAssertNil(splitter.finish())
    }

    func testFeedingTheSameTextAgainEmitsNothing() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("Hi. There"), ["Hi."])
        XCTAssertEqual(splitter.feed("Hi. There"), [])
        XCTAssertEqual(splitter.feed("Hi. There."), [])
        XCTAssertEqual(splitter.finish(), "There.")
    }

    func testTextThatDisagreesWithWhatWasSpokenIsIgnored() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("Hi. There"), ["Hi."])
        XCTAssertEqual(splitter.feed("Hello. Else"), [], "never speak the same ground twice")
        XCTAssertEqual(splitter.finish(), "There")
    }

    func testReplyAfterNoStreamedText() {
        var splitter = SentenceSplitter()
        XCTAssertEqual(splitter.feed("Done. Bye"), ["Done."])
        XCTAssertEqual(splitter.finish(), "Bye")
    }
}
