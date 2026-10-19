import Foundation

/// What the bridge tells an AI vision service about one event. Both provider clients send these words; the OpenAI-compatible one adds a
/// request for a bare JSON object (Claude answers through a tool call instead).
public enum DescriptionPrompt {
    /// The standing instructions: one short plain sentence, no guessing who anyone is, and when to rate an event unusual or an alarm.
    public static let system = """
        You describe security camera events for a home owner. You get a few still pictures from one camera, in time order, around the moment an \
        event began. Answer with one short sentence of at most 12 words, present tense, saying what is happening: who or what, and what they are \
        doing. Be plain and specific. Never guess who someone is and never describe faces in detail: say "a person", "a man in a red jacket", \
        "a delivery driver". If nothing worth noting is visible (shadows, trees or plants moving, rain, insects, headlights), use kind "nothing" \
        and summary "Nothing notable". Concern: "alarm" for a likely break-in or forced entry, a weapon, a masked or covered face at a door or \
        window, someone trying door or window handles, or someone tampering with the camera; "unusual" for someone lingering, looking into \
        windows or cars, or anyone near doors at night; otherwise "routine".
        """

    /// What this event is, after its pictures: the camera's name, the kind it reported and the local time.
    public static func userText(_ request: DescriptionRequest) -> String {
        "Camera: \(request.cameraName). The camera reported: \(request.eventKind). Local time: \(request.localTime)."
    }

    /// One piece of the user message.
    enum Part: Equatable {
        case text(String)
        case jpeg(Data)
    }

    /// The user message, in the order both providers get it: each picture after its label (a picture without a label has none; the services
    /// refuse empty text), in time order, then `userText`.
    static func parts(_ request: DescriptionRequest) -> [Part] {
        var parts: [Part] = []
        for picture in request.pictures {
            if !picture.label.isEmpty { parts.append(.text(picture.label)) }
            parts.append(.jpeg(picture.jpeg))
        }
        parts.append(.text(userText(request)))
        return parts
    }
}
