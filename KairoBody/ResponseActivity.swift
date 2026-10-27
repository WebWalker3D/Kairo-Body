import Foundation

/// A description of observed job state, never an estimate of answer completion.
enum ResponseActivity {
    static func shouldShowShared(localJobID: String, sharedJobID: String, localHasStatus: Bool) -> Bool {
        !localHasStatus
    }

    static func headline(status: String, settled: String?) -> String {
        switch settled ?? status {
        case "completed": return "Answer ready"
        case "failed": return "Response failed"
        case "cancelled", "canceled", "stopped": return "Stopped"
        case "waiting_permission": return "Approval needed"
        case "queued": return "Waiting to start"
        case "verifying", "reviewing": return "Checking the answer"
        case "running": return "Kairo is working"
        case "interrupted": return "Response interrupted"
        default: return "Checking response status"
        }
    }

    static func detail(status: String, progress: PromptTokenProgress?, tools: [String]) -> String {
        if status == "waiting_permission" {
            return "This request is paused for an approval. It is not generating an answer."
        }
        if status == "queued" { return "Kairo has received the question and has not started it yet." }
        if status == "verifying" || status == "reviewing" { return "The response is being checked before delivery." }
        if let tool = tools.last { return tool }
        if let progress {
            if let total = progress.total {
                return "Reading context · \(progress.processed.formatted()) of \(total.formatted()) tokens"
            }
            return "Reading context · \(progress.processed.formatted()) tokens"
        }
        return "Waiting for the next reported step."
    }

    static func elapsed(since start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m \(seconds % 60)s"
    }
}
