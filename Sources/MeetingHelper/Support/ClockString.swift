import Foundation

extension TimeInterval {
    /// `mm:ss`, widening to `h:mm:ss` past an hour.
    ///
    /// Used for every duration and offset the interface shows, so a two-hour meeting reads as
    /// `1:30:15` rather than `90:15`.
    var clockString: String {
        let total = Int(self)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}
