# Look within Presence

The user approved direct implementation of live front-camera preview, capture, review/retake/cancel, attachment to Presence's existing composer, and continuation in the same conversation.

Look is a sharing action. Both Presence and Conversation open the same sheet and show the same local photo draft. The existing Look rail entry becomes a shortcut to that sheet from Presence. There is no separate question field or separate reply store in this flow.

Opening the camera requests the existing OS permission and reserves camera ownership through BodyClient. It suspends local motion detection and blocks remote camera captures until release. Only the front camera is configured. A live mirrored preview precedes the shutter; the captured image can be reviewed, retaken or attached. Photo-library selection also goes through local review. Cancelling leaves the previously attached photo and written draft intact. Dismissal/backgrounding stops capture, and reservations are identity checked so stale teardown cannot release a newer owner.

Attachment does not upload. On Send, ConversationClient reserves its existing sending slot, resolves the conversation session, uploads the image through the existing vision contract, and sends the returned description attachment with the question. The preview and image remain available after preparation errors. Once a PendingTurn is saved, it owns attachment identity and idempotency across recovery. The local draft is consumed only when the pending turn owns it. A newer local selection must never be removed by an older completion.

Approaches considered: retain a separate Look workspace with navigation back to Presence, or integrate image sharing into the common composer. The user chose integration, addressing the disconnected experience. Use the established native SwiftUI/AVFoundation implementation without dependencies or server changes.

Validation: regression for camera entry/cancel/draft continuity; transport-boundary tests for no eager upload, same-session attachments, failure retention and pending recovery; camera ownership tests; full simulator suite and unsigned device package via GitHub Actions. Simulator screenshots cover sheet layout and portrait/landscape. Physical iPad acceptance remains necessary for exposure, mirroring/rotation, permissions, motion-detector resumption and capture performance.
