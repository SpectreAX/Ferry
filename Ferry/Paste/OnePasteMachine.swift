import Foundation

/// The One ⌘V state machine. Pure logic: it never touches the system; `OnePasteController` performs its effects.
///
/// armed ─⌘V→ [imagesOffered ─image requested→ imagesRequested ─UI shows it→] × each image
///   → textOffered ─text requested→ textRequested ─UI shows text→ armed (repeatable)
///
/// Images go one per paste: every app that takes image attachments takes them one at a time, while some
/// (e.g. Antigravity) keep only the first file of a multi-file paste.
///
/// Every waiting phase has a failure guard. Failures never send anything and never lose content: before the
/// first image the original copy is restored; afterwards the text is left on the clipboard for a manual ⌘V.
struct OnePasteMachine {
    enum Phase: String, CaseIterable {
        case idle, armed, imagesOffered, imagesRequested, textOffered, textRequested

        var isActive: Bool { self != .idle && self != .armed }
    }

    enum Event: Equatable {
        case armed(imageCount: Int)
        case pasteIntercepted
        case imageRequested(Int)
        case textRequested
        case targetUpdated(imagesAdded: Bool, textAdded: Bool)
        case timedOut(Phase)
        case interrupted(String)
        /// The focused field can't take images (password, single-line or unreadable): hand ⌘V back.
        case unsuitableTarget(String)
        case clipboardChangedExternally
        case disarm
    }

    enum Effect: Equatable {
        case takeBaseline
        /// Put image `index` (and only it) on the clipboard.
        case writeImage(Int)
        case writeText
        case postPaste
        case startGuard(Phase)
        case evaluateTarget
        case restoreFallback
        case leaveTextOnClipboard
        case notify(String)
        case log(String)
        /// Teaches `AppPasteRules` whether One ⌘V works in this app.
        case report(AppPasteRules.Outcome)
    }

    static let manualTextMessage = "Images added. Press ⌘V to add the text."

    private(set) var phase: Phase = .idle
    private(set) var imageCount = 0
    /// The image being pasted (0-based).
    private(set) var currentImage = 0

    /// True until the first image has been pasted: the only point where handing ⌘V back is safe.
    var nothingPastedYet: Bool { phase == .imagesOffered && currentImage == 0 }

    mutating func handle(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (_, .disarm):
            phase = .idle
            return [.log("disarmed")]

        case (_, .armed(let count)):
            phase = .armed
            imageCount = count
            currentImage = 0
            return [.log("armed with \(count) image(s)")]

        case (.armed, .pasteIntercepted):
            phase = .imagesOffered
            currentImage = 0
            return [.log("⌘V intercepted")] + offerImage()

        case (.imagesOffered, .imageRequested(let index)) where index == currentImage:
            phase = .imagesRequested
            return [.log("image \(currentImage + 1) of \(imageCount) requested; waiting for the app to show it"),
                    .startGuard(.imagesRequested), .evaluateTarget]

        case (.imagesRequested, .targetUpdated(let imagesAdded, _)) where imagesAdded:
            if currentImage + 1 < imageCount {
                currentImage += 1
                phase = .imagesOffered
                return [.log("image \(currentImage) of \(imageCount) confirmed")] + offerImage()
            }
            phase = .textOffered
            return [.log("image \(imageCount) of \(imageCount) confirmed"), .takeBaseline, .writeText, .postPaste,
                    .startGuard(.textOffered)]

        case (.textOffered, .textRequested):
            phase = .textRequested
            return [.log("text requested; waiting for the app to show it"), .startGuard(.textRequested), .evaluateTarget]

        case (.textRequested, .targetUpdated(_, let textAdded)) where textAdded:
            phase = .armed
            return [.log("text confirmed; done"), .restoreFallback, .report(.worked)]

        // Failure guards (only the guard of the current phase counts).
        case (.imagesOffered, .timedOut(.imagesOffered)) where currentImage == 0:
            phase = .armed
            return [.log("the app never requested the image; nothing was pasted"), .restoreFallback,
                    .notify("Nothing was pasted. Click in the message box and press ⌘V again."), .report(.failed)]
        case (.imagesOffered, .timedOut(.imagesOffered)), (.imagesRequested, .timedOut(.imagesRequested)):
            phase = .idle
            return [.log("image \(currentImage + 1) of \(imageCount) not confirmed"), .leaveTextOnClipboard,
                    .notify(partialImagesMessage), .report(.failed)]
        case (.textOffered, .timedOut(.textOffered)):
            phase = .idle
            return [.log("the app never requested the text"), .leaveTextOnClipboard, .notify(Self.manualTextMessage), .report(.failed)]
        case (.textRequested, .timedOut(.textRequested)):
            phase = .idle
            return [.log("text requested but not confirmed"), .leaveTextOnClipboard,
                    .notify("Check the text; if it's missing, press ⌘V."), .report(.failed)]

        // Decided from the first before-snapshot, before anything was written: the normal copy is still on the
        // clipboard, so re-sending ⌘V gives the app a normal paste.
        case (.imagesOffered, .unsuitableTarget(let reason)) where currentImage == 0:
            phase = .armed
            return [.log("normal paste instead: \(reason)"), .postPaste]

        // Interruptions: focus moved, another key or a click.
        case (.imagesOffered, .interrupted(let reason)) where currentImage == 0:
            phase = .armed
            return [.log("interrupted before the first image: \(reason)"), .restoreFallback]
        case (.imagesOffered, .interrupted(let reason)), (.imagesRequested, .interrupted(let reason)):
            phase = .idle
            return [.log("interrupted at image \(currentImage + 1) of \(imageCount): \(reason)"), .leaveTextOnClipboard,
                    .notify(partialImagesMessage)]
        case (.textOffered, .interrupted(let reason)):
            phase = .idle
            return [.log("interrupted after the images: \(reason)"), .leaveTextOnClipboard, .notify(Self.manualTextMessage)]
        case (.textRequested, .interrupted(let reason)):
            phase = .idle
            return [.log("interrupted after the text was requested: \(reason)"), .leaveTextOnClipboard,
                    .notify("Check the text; if it's missing, press ⌘V.")]

        case (let current, .clipboardChangedExternally) where current != .idle:
            phase = .idle
            return [.log("clipboard changed by another app; stopped without touching it")]

        default:
            return [] // late, repeated or irrelevant events
        }
    }

    /// Only image 1 needs a before-snapshot: later images are counted from it (`AttachmentCounter`).
    private func offerImage() -> [Effect] {
        (currentImage == 0 ? [.takeBaseline] : []) + [.writeImage(currentImage), .postPaste, .startGuard(.imagesOffered)]
    }

    private var partialImagesMessage: String {
        "Check the images (stopped at \(currentImage + 1) of \(imageCount)), then press ⌘V to add the text."
    }
}
