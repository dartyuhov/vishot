import Foundation
import VishotAgent

/// Local command options never participate in capture transport or its deadlines.
struct AnnotationArguments {
    let input: String
    let inlineJSON: String?
    let jsonFile: String?
    let open: Bool

    init(_ arguments: [String]) throws {
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
