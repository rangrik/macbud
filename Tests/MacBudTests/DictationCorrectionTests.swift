import Foundation
import Speech
import Testing
@testable import MacBud

@MainActor @Suite struct DictationCorrectionTests {
    @Test func theRecogniserIsAskedForEverythingTheNotchNeeds() {
        // Without these three the notch has nothing to underline, nothing to offer, and words
        // only settle when the whole recording ends — which is what makes pausing to fix one work.
        #expect(DictationEngine.preset.reportingOptions.contains(.frequentFinalization))
        #expect(DictationEngine.preset.reportingOptions.contains(.alternativeTranscriptions))
        #expect(DictationEngine.preset.attributeOptions.contains(.transcriptionConfidence))
    }

    @Test func aCorrectionSurvivesTheWordsThatComeAfterIt() {
        let attempt = UUID()
        let opening = DictationSegment(text: "let's ship the Codex")
        var mine = DictationTranscript(attemptID: attempt, settled: [opening])
        // Editing collapses the chunks into one; the engine's count is remembered separately.
        let (rebuilt, _) = DictationEdit.reconcile(mine.settledWords, with: ["let's", "ship", "the", "Kodex"])
        mine.replaceSettled(with: rebuilt)
        #expect(mine.text == "let's ship the Kodex")
        #expect(mine.settled.count == 1)

        let fromEngine = DictationTranscript(attemptID: attempt,
                                             settled: [opening, DictationSegment(text: "integration today")],
                                             draft: DictationSegment(text: "and tomorrow"))
        #expect(mine.merging(fromEngine).text == "let's ship the Kodex integration today and tomorrow")
    }

    @Test func swappingOneWordIsLearnedAndEverythingElseIsNot() {
        let words = DictationSegment(text: "ship the Codex today").words
        let swap = DictationEdit.reconcile(words, with: ["ship", "the", "Kodex", "today"]).changes
        #expect(swap == [.replaced(from: "Codex", to: "Kodex", wasUncertain: false)])
        #expect(swap.compactMap(\.lesson).count == 1)

        let deleted = DictationEdit.reconcile(words, with: ["ship", "the", "today"]).changes
        #expect(deleted == [.removed("Codex")])
        #expect(deleted.compactMap(\.lesson).isEmpty, "A deletion says nothing about spelling")

        let wholeLine = DictationEdit.reconcile(words, with: []).changes
        #expect(wholeLine.compactMap(\.lesson).isEmpty, "Nor does wiping the line")

        let rewritten = DictationEdit.reconcile(words, with: ["ship", "the", "Kodex", "release", "today"]).changes
        #expect(rewritten.compactMap(\.lesson).isEmpty, "One word becoming two is a rewording, not a fix")
    }

    @Test func editingKeepsTheConfidenceOfWordsYouLeftAlone() {
        var segment = DictationSegment(text: "ship the Codex")
        segment.words[0].confidence = 0.4
        segment.words[2].confidence = 0.3
        let (rebuilt, changes) = DictationEdit.reconcile(segment.words, with: ["ship", "the", "Kodex"])
        #expect(rebuilt[0].isUncertain, "You did not touch it, so it stays flagged")
        #expect(!rebuilt[2].isUncertain, "The word you fixed is yours now")
        #expect(rebuilt[2].isEdited)
        #expect(changes == [.replaced(from: "Codex", to: "Kodex", wasUncertain: true)])
    }

    @Test func startingOverReplacesEverything() {
        let mine = DictationTranscript(settledText: "the words I fixed")
        let restarted = DictationTranscript(settledText: "a completely new attempt")
        #expect(mine.merging(restarted).text == "a completely new attempt")
    }

    @Test func onlyRunnersUpThatLineUpWordForWordOfferAlternatives() {
        let chosen = ["ship", "the", "Codex"]
        let aligned = DictationTranscript.alignedAlternatives(chosen: chosen, runnersUp: [
            ["ship", "the", "codecs"],
            ["ship", "the", "Cortex"],
            ["shipped", "it", "to", "Codex"],
        ])
        #expect(aligned[0].isEmpty)
        #expect(aligned[1].isEmpty)
        #expect(aligned[2] == ["codecs", "Cortex"])
    }

    @Test func lowConfidenceWordsAreTheOnesOfferedForCorrection() {
        var segment = DictationSegment(text: "ship the Codex")
        segment.words[0].confidence = 0.9
        segment.words[2].confidence = 0.3
        let transcript = DictationTranscript(settled: [segment])
        #expect(transcript.uncertainWordCount == 1)
        #expect(segment.words[2].isUncertain)
        #expect(!segment.words[1].isUncertain, "No confidence at all is not the same as low confidence")
    }

    @Test func oneCorrectionOnlyBiasesAndTwoStartRewriting() {
        let store = DictationWordStore()
        #expect(store.record(heard: "Codex", meant: "Kodex", confirmed: false)?.isActive == false)
        #expect(store.apply(to: "ship the Codex") == "ship the Codex", "A candidate must never rewrite text")
        #expect(store.vocabulary == ["Kodex"], "But it should still be offered to the recogniser")

        #expect(store.record(heard: "Codex", meant: "Kodex", confirmed: false)?.isActive == true)
        #expect(store.apply(to: "ship the Codex") == "ship the Kodex")
        #expect(store.rules.count == 1)
    }

    @Test func aCorrectionWeHaveGroundsToTrustRewritesStraightAway() {
        let store = DictationWordStore()
        #expect(store.record(heard: "cloud", meant: "Claude", confirmed: true)?.isActive == true)
        #expect(store.apply(to: "ask cloud about clouds and cloudy skies") == "ask Claude about clouds and cloudy skies")
    }

    @Test func nothingIsLearnedFromNoise() {
        let store = DictationWordStore()
        #expect(store.record(heard: "a", meant: "eh", confirmed: true) == nil, "Single letters are too risky")
        #expect(store.record(heard: "Codex", meant: "", confirmed: true) == nil, "A deletion teaches nothing")
        #expect(store.record(heard: "Codex", meant: "Codex", confirmed: true) == nil, "Nothing changed")
        #expect(store.record(heard: "code x", meant: "Kodex", confirmed: true) == nil, "Rules cover single words")
        #expect(store.rules.isEmpty)
    }

    @Test func fixingHowAWordIsWrittenIsWorthLearning() {
        let store = DictationWordStore()
        #expect(store.record(heard: "kodex", meant: "Kodex", confirmed: true)?.isActive == true)
        #expect(store.apply(to: "the kodex release") == "the Kodex release")
    }
}
