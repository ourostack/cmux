import Foundation

struct AgentSessionManagedCommand: Equatable {
    let program: String
    let executableURL: URL
    let arguments: [String]

    init?(program: String, arguments: [String]) {
        guard program.hasPrefix("/"), program.utf8.count <= 4096, !program.utf8.contains(0),
              arguments.count <= 256, !arguments.contains(where: { $0.utf8.contains(0) }),
              arguments.reduce(program.utf8.count, { $0 + $1.utf8.count + 1 }) <= 65_536 else {
            return nil
        }
        self.program = program
        executableURL = URL(fileURLWithPath: program)
        self.arguments = arguments
    }

    init?(toolArguments: Any?) {
        guard let values = toolArguments as? [String: Any],
              Set(values.keys) == ["program", "arguments"],
              let program = values["program"] as? String,
              let arguments = values["arguments"] as? [String] else { return nil }
        self.init(program: program, arguments: arguments)
    }
}
