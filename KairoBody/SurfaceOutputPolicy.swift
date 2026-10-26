import Foundation

/// The compact settled job carries the server's accepted surface decision.
/// Never turn a missing automatic decision into a second local answer.
enum SurfaceOutputPolicy {
    static func target(job: [String: Any], requested: String?) -> String? {
        guard job["settled_status"] as? String == "completed", requested != "silent" else { return nil }
        let metadata = job["metadata_json"] as? [String: Any]
        if let selected = metadata?["surface_output_target"] as? String {
            return ["ipad_display", "ipad_speech"].contains(selected) ? selected : nil
        }
        return ["ipad_display", "ipad_speech"].contains(requested ?? "") ? requested : nil
    }
}
