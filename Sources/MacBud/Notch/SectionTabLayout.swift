import AppKit

/// The tab strip lives in the two bands either side of the notch. A tab that overruns the left band
/// sits under the hardware where you cannot see or click it, so it moves to the right band instead.
/// When neither band can hold the run, the selected tab drops its label rather than hiding a tab.
enum SectionTabLayout {
    struct Plan: Equatable {
        var left: [Section] = []
        var right: [Section] = []
        var showsLabel = true
    }

    static let iconSize: CGFloat = 19
    static let spacing: CGFloat = 4
    static let collapsedPadding: CGFloat = 8
    static let selectedPadding: CGFloat = 10
    static let labelSpacing: CGFloat = 6
    static let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)

    static var collapsedWidth: CGFloat { iconSize + collapsedPadding * 2 }

    static func expandedWidth(_ section: Section, labelWidth: @MainActor (Section) -> CGFloat) -> CGFloat {
        iconSize + labelSpacing + labelWidth(section) + selectedPadding * 2
    }

    static func measuredLabelWidth(_ section: Section) -> CGFloat {
        (section.title as NSString).size(withAttributes: [.font: labelFont]).width.rounded(.up)
    }

    static func width(_ run: [Section], expanding: Section?, labelWidth: @MainActor (Section) -> CGFloat) -> CGFloat {
        guard !run.isEmpty else { return 0 }
        return run.reduce(CGFloat(run.count - 1) * spacing) { total, section in
            total + (section == expanding ? expandedWidth(section, labelWidth: labelWidth) : collapsedWidth)
        }
    }

    /// Worst case for a run: every tab collapsed except the widest, expanded. Planning against the
    /// worst case rather than the current selection is what keeps the strip still — otherwise a tab
    /// would hop across the notch every time you selected a section with a longer name.
    static func worstCaseWidth(_ run: [Section], labelWidth: @MainActor (Section) -> CGFloat) -> CGFloat {
        guard let widest = run.map({ expandedWidth($0, labelWidth: labelWidth) }).max() else { return 0 }
        return CGFloat(run.count - 1) * (spacing + collapsedWidth) + widest
    }

    /// Tries hardest to keep everything on the left with room for a label, then spills the overflow
    /// to the right of the notch, and only gives up labels when neither band can take the overflow.
    static func plan(_ sections: [Section], selected: Section, leftWidth: CGFloat, rightWidth: CGFloat,
                     labelWidth: @escaping @MainActor (Section) -> CGFloat = measuredLabelWidth) -> Plan {
        guard !sections.isEmpty else { return Plan() }
        if worstCaseWidth(sections, labelWidth: labelWidth) <= leftWidth {
            return Plan(left: sections, right: [], showsLabel: true)
        }
        let left = longestRun(sections, within: leftWidth) { worstCaseWidth($0, labelWidth: labelWidth) }
        let right = Array(sections.dropFirst(left.count))
        if !left.isEmpty, worstCaseWidth(right, labelWidth: labelWidth) <= rightWidth {
            return Plan(left: left, right: right, showsLabel: true)
        }
        // Labels off: icons alone are narrow enough that everything usually fits on the left again.
        let iconsWidth: ([Section]) -> CGFloat = { width($0, expanding: nil, labelWidth: labelWidth) }
        if iconsWidth(sections) <= leftWidth { return Plan(left: sections, right: [], showsLabel: false) }
        let iconsLeft = longestRun(sections, within: leftWidth, measure: iconsWidth)
        return Plan(left: iconsLeft, right: Array(sections.dropFirst(iconsLeft.count)), showsLabel: false)
    }

    private static func longestRun(_ sections: [Section], within limit: CGFloat,
                                   measure: ([Section]) -> CGFloat) -> [Section] {
        var run: [Section] = []
        for section in sections {
            guard measure(run + [section]) <= limit else { break }
            run.append(section)
        }
        return run
    }
}
