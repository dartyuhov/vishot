import Foundation

/// Public annotation arguments; deliberately separate from capture transport and deadlines.
public struct AgentAnnotationArguments {
    public static let renderArgument = "--vishot-agent-annotate"
    public let input: String
    public let inlineJSON: String?
    public let jsonFile: String?
    public let open: Bool

    public init(_ arguments: [String]) throws {
        let usage = "Usage: vishot annotate --input <PNG> (--annotations <JSON> | --annotations-file <path>) [--open]. Exactly one JSON source is required."
        var options: [String: String] = [:]
        var open = false
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--open" {
                guard !open else { throw AgentFailure(.invalidArguments, usage + " Duplicate --open option.") }
                open = true
                index += 1
                continue
            }
            guard ["--input", "--annotations", "--annotations-file"].contains(flag), options[flag] == nil,
                  index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("--") else {
                throw AgentFailure(.invalidArguments, usage + " Unknown, missing, duplicate, or conflicting option.")
            }
            options[flag] = arguments[index + 1]
            index += 2
        }
        guard let input = options["--input"], (options["--annotations"] != nil) != (options["--annotations-file"] != nil) else {
            throw AgentFailure(.invalidArguments, usage)
        }
        self.input = input
        inlineJSON = options["--annotations"]
        jsonFile = options["--annotations-file"]
        self.open = open
    }
}

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
