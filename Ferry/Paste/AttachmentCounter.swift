import Foundation

/// Confirms "k images are in" against the snapshot taken once, before the first image of a session.
/// Measuring each image against a snapshot taken just before its own paste is fooled by redraws: in
/// Antigravity, image 1's chip briefly dropped a button right then, and its return looked like image 2.
///
/// Thumbnails count first. Apps that show none (ChatGPT) are counted by buttons, at the number of buttons one
/// attachment added for image 1 (Antigravity adds two per image, ChatGPT one).
struct AttachmentCounter {
    let start: TargetSnapshot
    private(set) var buttonsPerImage: Int?

    init(start: TargetSnapshot) {
        self.start = start
    }

    /// True when at least `expected` attachments have appeared since `start`.
    mutating func confirms(_ expected: Int, now: TargetSnapshot) -> Bool {
        let pairs = Array(zip(now.levels, start.levels))
        let imageGain = pairs.map { $0.0.images - $0.1.images }.max() ?? 0
        if imageGain > 0 { return imageGain >= expected }
        let buttonGain = pairs.map { $0.0.buttons - $0.1.buttons }.max() ?? 0
        guard let perImage = buttonsPerImage else {
            // Image 1 in an app without thumbnails: any new button(s) confirm it and set the rate.
            guard expected == 1, buttonGain > 0 else { return false }
            buttonsPerImage = buttonGain
            return true
        }
        return buttonGain >= perImage * expected
    }
}
