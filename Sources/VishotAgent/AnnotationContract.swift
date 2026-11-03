import Foundation

public struct AgentValidationProblem: Codable, Equatable {
    public let index: Int?
    public let field: String
    public let reason: String
    public init(index: Int? = nil, field: String, reason: String) {
        self.index = index; self.field = field; self.reason = reason
    }
}

public struct AgentAnnotationFile: Codable {
    public let path: String
    public let width: Int
    public let height: Int
    public let style: String
    /// "accepted" means OS acceptance of the request, never proof the user saw the image.
    public let openingStatus: String
    public init(path: String, width: Int, height: Int, style: String, openingStatus: String = "not_requested") {
        self.path = path; self.width = width; self.height = height; self.style = style
        self.openingStatus = openingStatus
    }
}
