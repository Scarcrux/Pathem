import AppKit

/// How wide a list date column must be for every date to read in full, in the current
/// locale, date format and font. Measured rather than fixed: "28 de set. de 2026, 22:48"
/// and "2026年11月28日 下午10:48" need more room than any one constant chosen in English.
@MainActor
enum DateColumnWidth {
    /// The value cell insets its label 4 pt per side and the label pads its text 2 pt per
    /// side; the rest is slack so a date never sits flush against the truncation point.
    static let cellPadding: CGFloat = 16

    private static var cache: [String: CGFloat] = [:]

    /// The widest of a late-evening, two-digit day in each month of a year, plus padding.
    static func fitting(_ formatter: DateFormatter, fontSize: CGFloat) -> CGFloat {
        let key = [
            formatter.locale.identifier, "\(formatter.dateStyle.rawValue)",
            "\(formatter.timeStyle.rawValue)", "\(fontSize)",
        ].joined(separator: "|")
        if let known = cache[key] { return known }
        let font = NSFont.systemFont(ofSize: fontSize)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = formatter.timeZone ?? .current
        var widest: CGFloat = 0
        for month in 1...12 {
            let parts = DateComponents(year: 2008, month: month, day: 28, hour: 22, minute: 48)
            guard let date = calendar.date(from: parts) else { continue }
            let text = formatter.string(from: date) as NSString
            widest = max(widest, text.size(withAttributes: [.font: font]).width)
        }
        let width = ceil(widest) + cellPadding
        cache[key] = width
        return width
    }
}
