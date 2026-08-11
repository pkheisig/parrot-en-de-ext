import Foundation
import XCTest
@testable import parrot

final class CorrectionDictionaryTests: XCTestCase {
    func testUpsertKeepsOneMappingPerAliasAndBuildsDeduplicatedPrompt() {
        let store = CorrectionDictionaryStore(persistent: false)
        store.upsert(alias: "spectra easy", canonical: "Spectreasy")
        store.upsert(alias: "spectr easy", canonical: "Spectreasy")
        store.upsert(alias: "SPECTRA EASY", canonical: "Spectreasy 2")

        XCTAssertEqual(store.entries.count, 2)
        let prompt = store.promptText()
        XCTAssertTrue(prompt?.contains("Spectreasy 2") == true)
        XCTAssertTrue(prompt?.contains("Spectreasy") == true)
    }

    func testPromptPlacesNewestVocabularyAtTheDecoderKeptSuffix() {
        let older = Date(timeIntervalSince1970: 1)
        let newer = Date(timeIntervalSince1970: 2)
        let store = CorrectionDictionaryStore(
            persistent: false,
            initialEntries: [
                CorrectionEntry(
                    alias: "older",
                    canonical: "OlderTerm",
                    createdAt: older,
                    updatedAt: older
                ),
                CorrectionEntry(
                    alias: "newer",
                    canonical: "NewestTerm",
                    createdAt: newer,
                    updatedAt: newer
                ),
            ]
        )

        XCTAssertEqual(
            store.promptText(),
            "Technical vocabulary includes OlderTerm. "
                + "Technical vocabulary includes NewestTerm."
        )
    }

    func testFocusedPromptOnlyIncludesAliasesRenderedInThisTranscript() {
        let store = CorrectionDictionaryStore(persistent: false)
        store.upsert(alias: "spectrizy", canonical: "Spectreasy")
        store.upsert(alias: "omelet", canonical: "OMIP")

        XCTAssertEqual(
            store.promptText(matching: "We opened spectrizy for the analysis."),
            "Technical vocabulary includes Spectreasy."
        )
        XCTAssertNil(
            store.promptText(matching: "This sentence contains neither learned rendering.")
        )
    }

    func testPersistsAndReloadsEntries() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("parrot-dictionary-\(UUID().uuidString)")
        let file = directory.appendingPathComponent("corrections.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let writer = CorrectionDictionaryStore(fileURL: file)
        writer.upsert(alias: "oh mip", canonical: "OMIP")

        let reader = CorrectionDictionaryStore(fileURL: file)
        XCTAssertEqual(reader.entries.count, 1)
        XCTAssertEqual(reader.entries.first?.alias, "oh mip")
        XCTAssertEqual(reader.entries.first?.canonical, "OMIP")
    }

    func testExtractsOneOrMultipleWordLevelCorrections() {
        XCTAssertEqual(
            CorrectionDiff.proposals(
                original: "This uses spectra easy today.",
                corrected: "This uses Spectreasy today."
            ),
            [CorrectionProposal(alias: "spectra easy", canonical: "Spectreasy")]
        )
        XCTAssertEqual(
            CorrectionDiff.proposals(
                original: "Use spectra easy with O M I P today.",
                corrected: "Use Spectreasy with OMIP today."
            ),
            [
                CorrectionProposal(alias: "spectra easy", canonical: "Spectreasy"),
                CorrectionProposal(alias: "O M I P", canonical: "OMIP"),
            ]
        )
    }

    func testFindsLikelyOriginalAliasForSelectedCorrection() {
        XCTAssertEqual(
            CorrectionDiff.bestAlias(
                in: "We analyzed it in spectra easy yesterday",
                for: "Spectreasy"
            ),
            "spectra easy"
        )
        XCTAssertEqual(
            CorrectionDiff.bestAlias(
                in: "This is the O M I P panel",
                for: "OMIP"
            ),
            "O M I P"
        )
    }

    func testExtractsCorrectionFromShortOrWholeSelection() {
        XCTAssertEqual(
            CorrectionDiff.proposalsFromSelection(
                original: "My package is called spectra easy.",
                selected: "Spectreasy"
            ),
            [CorrectionProposal(alias: "spectra easy", canonical: "Spectreasy")]
        )
        XCTAssertEqual(
            CorrectionDiff.proposalsFromSelection(
                original: "My package is called spectra easy.",
                selected: "My package is called Spectreasy."
            ),
            [CorrectionProposal(alias: "spectra easy", canonical: "Spectreasy")]
        )
    }

    func testFindsEditedTranscriptInsideLargerFocusedEditor() {
        let field = """
        Earlier unrelated text.
        My package is called Spectreasy.
        Some following text.
        """
        XCTAssertEqual(
            CorrectionDiff.bestCorrectedTranscript(
                in: field,
                for: "My package is called spectra easy."
            ),
            "My package is called Spectreasy"
        )
    }
}
