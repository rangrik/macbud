import Foundation
import Testing
@testable import MacBud

/// The seam: a tab that overruns the left band lands under the notch hardware, where it is both
/// invisible and unclickable. Nothing may ever end up there.
@Suite @MainActor struct SectionTabLayoutTests {
    /// Fixed label widths so the expectations do not move with the system font.
    private func label(_ section: Section) -> CGFloat {
        switch section {
        case .clipboard: 60
        case .snippets: 52
        case .screenshots: 75
        case .dictationHistory: 44
        case .apps: 30
        }
    }

    private func plan(_ sections: [Section], selected: Section, left: CGFloat, right: CGFloat) -> SectionTabLayout.Plan {
        SectionTabLayout.plan(sections, selected: selected, leftWidth: left, rightWidth: right, labelWidth: label)
    }

    private func width(_ run: [Section], expanding: Section?) -> CGFloat {
        SectionTabLayout.width(run, expanding: expanding, labelWidth: label)
    }

    private func worstCase(_ run: [Section]) -> CGFloat {
        SectionTabLayout.worstCaseWidth(run, labelWidth: label)
    }

    @Test func everythingStaysLeftWhenItFits() {
        let p = plan(Section.allCases, selected: .apps, left: 400, right: 100)
        #expect(p.left == Section.allCases)
        #expect(p.right.isEmpty)
        #expect(p.showsLabel)
    }

    @Test func overflowMovesToTheRightOfTheNotchRatherThanUnderIt() {
        // The real bands on a 220pt notch: 256pt left of it, 118pt right of it once the status
        // area has taken its share. Four tabs fit on the left, the fifth would sit under the notch.
        let p = plan(Section.allCases, selected: .screenshots, left: 256, right: 118)
        #expect(p.left.count < Section.allCases.count)
        #expect(p.left + p.right == Section.allCases, "every tab is still on screen somewhere")
        #expect(worstCase(p.left) <= 256)
        #expect(worstCase(p.right) <= 118)
        #expect(p.showsLabel)
    }

    @Test func labelIsDroppedWhenTheRightBandIsTooNarrowToTakeTheOverflow() {
        // A wide status area leaves almost nothing on the right, so labels go instead of tabs.
        let p = plan(Section.allCases, selected: .screenshots, left: 208, right: 10)
        #expect(worstCase(Section.allCases) > 208, "the label would not have fitted anyway")
        #expect(p.left == Section.allCases)
        #expect(p.right.isEmpty)
        #expect(!p.showsLabel)
        #expect(width(p.left, expanding: nil) <= 208)
    }

    @Test func aVeryNarrowBandStillSplitsInsteadOfHiding() {
        let p = plan(Section.allCases, selected: .clipboard, left: 80, right: 10)
        #expect(!p.showsLabel)
        #expect(p.left + p.right == Section.allCases)
        #expect(width(p.left, expanding: nil) <= 80)
    }

    @Test func theStripDoesNotRearrangeWhenYouSwitchSections() {
        let reference = plan(Section.allCases, selected: .clipboard, left: 256, right: 118)
        #expect(!reference.right.isEmpty, "this case must exercise a real split")
        for selected in Section.allCases {
            let p = plan(Section.allCases, selected: selected, left: 256, right: 118)
            #expect(p == reference, "selecting \(selected) moved a tab across the notch")
            #expect(Set(p.left + p.right) == Set(Section.allCases), "\(selected) stranded a tab")
        }
    }

    @Test func noSectionsIsSafe() {
        #expect(plan([], selected: .clipboard, left: 200, right: 90) == SectionTabLayout.Plan())
    }
}
