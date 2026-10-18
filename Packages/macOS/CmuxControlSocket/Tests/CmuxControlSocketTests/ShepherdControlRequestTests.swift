import Foundation
import Testing
@testable import CmuxControlSocket

struct ShepherdControlRequestTests {
    private let workspace = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let surface = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    private let token = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

    private func request(
        _ method: ShepherdControlRequest.Method,
        _ params: [String: JSONValue]
    ) -> ControlRequest {
        ControlRequest(id: .int(7), method: method.rawValue, params: params)
    }

    @Test
    func decodesTheSpecifiedWireNamesThroughTheEnvelopeParser() throws {
        let fixtures: [(String, ShepherdControlRequest)] = [
            (
                #"{"id":1,"method":"surface.shepherd.inspect","params":{"workspace_id":"00000000-0000-0000-0000-000000000001","surface_id":"00000000-0000-0000-0000-000000000002"}}"#,
                .inspect(workspaceID: workspace, surfaceID: surface)
            ),
            (
                #"{"id":2,"method":"surface.shepherd.continue","params":{"request_id":"00000000-0000-0000-0000-000000000003","token":"00000000-0000-0000-0000-000000000004","text":"Continue."}}"#,
                .continueInput(ShepherdContinuationRequest(requestID: requestID, tokenID: token, text: "Continue."))
            ),
            (
                #"{"id":3,"method":"surface.shepherd.receipt","params":{"request_id":"00000000-0000-0000-0000-000000000003"}}"#,
                .receipt(requestID: requestID)
            )
        ]
        for (line, expected) in fixtures {
            let envelope = try ControlRequestParser().request(fromLine: line).get()
            #expect(try ShepherdControlRequest(request: envelope) == expected)
        }
    }

    @Test
    func inspectRequiresExactTargetsAndDoesNotInferFocus() throws {
        let decoded = try ShepherdControlRequest(request: request(.inspect, [
            "workspace_id": .string(workspace.uuidString),
            "surface_id": .string(surface.uuidString)
        ]))
        #expect(decoded == .inspect(workspaceID: workspace, surfaceID: surface))
        #expect(decoded.method == .inspect)
    }

    @Test
    func continuationUsesTokenScopeRatherThanCallerSuppliedHostFacts() throws {
        let decoded = try ShepherdControlRequest(request: request(.continueInput, [
            "request_id": .string(requestID.uuidString),
            "token": .string(token.uuidString),
            "text": .string("Continue the authorized task.")
        ]))
        #expect(decoded == .continueInput(ShepherdContinuationRequest(
            requestID: requestID, tokenID: token, text: "Continue the authorized task."
        )))
        #expect(decoded.method == .continueInput)
    }

    @Test
    func receiptIsAnExactReadWithNoContinuationParameters() throws {
        let decoded = try ShepherdControlRequest(request: request(.receipt, [
            "request_id": .string(requestID.uuidString)
        ]))
        #expect(decoded == .receipt(requestID: requestID))
        #expect(decoded.method == .receipt)
    }

    @Test(arguments: ["workspace_id", "surface_id"])
    func inspectRejectsMissingOrMistypedTargets(key: String) {
        let valid: [String: JSONValue] = [
            "workspace_id": .string(workspace.uuidString),
            "surface_id": .string(surface.uuidString)
        ]
        for replacement: JSONValue? in [nil, .null, .bool(true), .int(1), .string("surface:1"), .string(" ")] {
            var params = valid
            params[key] = replacement
            #expect(throws: ShepherdControlRequest.Error.invalidParameters) {
                try ShepherdControlRequest(request: request(.inspect, params))
            }
        }
    }

    @Test(arguments: ["request_id", "token", "text"])
    func continuationRejectsMissingOrMistypedArguments(key: String) {
        let valid: [String: JSONValue] = [
            "request_id": .string(requestID.uuidString),
            "token": .string(token.uuidString),
            "text": .string("Continue the authorized task.")
        ]
        for replacement: JSONValue? in [nil, .null, .bool(false), .array([]), .object([:])] {
            var params = valid
            params[key] = replacement
            #expect(throws: ShepherdControlRequest.Error.invalidParameters) {
                try ShepherdControlRequest(request: request(.continueInput, params))
            }
        }
    }

    @Test(arguments: [
        "", " ", " leading", "trailing ", "line\nbreak", "tab\tinput",
        "carriage\rreturn", "line\u{2028}break", "paragraph\u{2029}break",
        String(repeating: "x", count: 2001), String(repeating: "\u{1F4A1}", count: 1025)
    ])
    func rejectsUnverifiableOrUnboundedText(text: String) {
        #expect(throws: ShepherdControlRequest.Error.invalidParameters) {
            try ShepherdControlRequest(request: request(.continueInput, [
                "request_id": .string(requestID.uuidString), "token": .string(token.uuidString),
                "text": .string(text)
            ]))
        }
    }

    @Test(arguments: [String(repeating: "x", count: 2000), String(repeating: "\u{1F4A1}", count: 1024)])
    func acceptsExactCharacterAndUTF8ByteLimits(text: String) throws {
        let decoded = try ShepherdControlRequest(request: request(.continueInput, [
            "request_id": .string(requestID.uuidString), "token": .string(token.uuidString),
            "text": .string(text)
        ]))
        #expect(decoded == .continueInput(ShepherdContinuationRequest(
            requestID: requestID, tokenID: token, text: text
        )))
    }

    @Test(arguments: ["background_work", "focused", "approved", "key", "surface_id", "remote_workspace_id"])
    func continuationRejectsExtraStateOrAuthorityClaims(key: String) {
        #expect(throws: ShepherdControlRequest.Error.invalidParameters) {
            try ShepherdControlRequest(request: request(.continueInput, [
                "request_id": .string(requestID.uuidString), "token": .string(token.uuidString),
                "text": .string("Continue."), key: .bool(false)
            ]))
        }
    }

    @Test
    func rejectsUnknownMethodsAndReceiptArguments() {
        #expect(throws: ShepherdControlRequest.Error.unsupportedMethod) {
            try ShepherdControlRequest(request: ControlRequest(id: nil, method: "surface.send_key", params: [:]))
        }
        for params: [String: JSONValue] in [
            [:], ["request_id": .bool(true)],
            ["request_id": .string(requestID.uuidString), "text": .string("Continue.")]
        ] {
            #expect(throws: ShepherdControlRequest.Error.invalidParameters) {
                try ShepherdControlRequest(request: request(.receipt, params))
            }
        }
    }
}
