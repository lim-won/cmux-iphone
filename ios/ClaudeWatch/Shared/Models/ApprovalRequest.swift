import Foundation

struct ApprovalRequest: Identifiable, Codable {
    let id: UUID
    let permissionId: String?
    let toolName: String
    let actionSummary: String
    let timestamp: Date
    var status: ApprovalStatus
    var question: String?
    var options: [OptionItem]

    // Context for the global approval queue (joined from the session/Mac on receipt).
    var sessionId: String? = nil
    var macName: String? = nil
    var cwd: String? = nil
    var agent: String? = nil
    var reason: String? = nil

    /// Stable identity for de-duplicating re-sent approvals (bridge re-sends
    /// pending permission-requests on every SSE reconnect).
    var dedupeKey: String { permissionId ?? id.uuidString }

    enum ApprovalStatus: String, Codable {
        case pending
        case approved
        case denied
        case expired
    }

    struct OptionItem: Identifiable, Codable {
        let id: UUID
        let label: String
        let description: String?

        init(label: String, description: String? = nil) {
            self.id = UUID()
            self.label = label
            self.description = description
        }
    }

    init(permissionId: String? = nil, toolName: String, actionSummary: String, question: String? = nil, options: [OptionItem] = [],
         sessionId: String? = nil, macName: String? = nil, cwd: String? = nil, agent: String? = nil, reason: String? = nil) {
        self.id = UUID()
        self.permissionId = permissionId
        self.toolName = toolName
        self.actionSummary = actionSummary
        self.timestamp = Date()
        self.status = .pending
        self.question = question
        self.options = options
        self.sessionId = sessionId
        self.macName = macName
        self.cwd = cwd
        self.agent = agent
        self.reason = reason
    }
}
