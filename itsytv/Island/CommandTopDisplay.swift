import Foundation

/// What the top of command center shows. Tapping it cycles through these.
enum CommandTopDisplay: String, CaseIterable {
    case time = "Time"
    case banner = "Banner"
    case nothing = "Nothing"

    static let defaultsKey = "commandModeTopDisplay"

    func next(hasBanner: Bool) -> CommandTopDisplay {
        switch self {
        case .time: hasBanner ? .banner : .nothing
        case .banner: .nothing
        case .nothing: .time
        }
    }
}
