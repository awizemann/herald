import HeraldKit
import SwiftUI

/// The Archive / Put Back / Move to Trash trio, in one place.
///
/// It exists because the same three affordances live in the window toolbar and in
/// the reading pane's header, and they had drifted: the toolbar dropped "Move to
/// Trash" in the Trash (a server no-op) while the header kept it, and when
/// upstream 1.3.4's `restore`/`unarchive` arrived only one of the two learned
/// about them. Which verb applies in which folder is a rule about the folder, not
/// about where the button is drawn — so the rule lives here and both call sites
/// read it.
///
/// The server no-ops each of these outside its folder (`conversation-queries.ts`),
/// and a no-op the client mirrors optimistically shows the row leaving a list it
/// never left. Hiding the button is how that is avoided.
struct TriageButtons: View {
    let model: MailViewModel

    var body: some View {
        if model.offersArchiveAction {
            Button { Task { await model.performOnSelection(.archive) } } label: {
                Image(systemName: "archivebox")
                    .iconButtonStyle("Archive")
            }
            .disabled(model.selectedThreadID == nil)
        }

        // Trash and Archive get the put-back verb in the archive button's place.
        if let restore = model.restoreAction {
            Button { Task { await model.performOnSelection(restore) } } label: {
                Image(systemName: "arrow.uturn.backward")
                    .iconButtonStyle(model.restoreActionTitle)
            }
            .disabled(model.selectedThreadID == nil)
        }

        if model.offersTrashAction {
            Button { Task { await model.performOnSelection(.trash) } } label: {
                Image(systemName: "trash")
                    .iconButtonStyle("Move to Trash")
            }
            .disabled(model.selectedThreadID == nil)
        }
    }
}

/// Reply / Reply All / Forward, in the window toolbar (redesign R6, handoff
/// §3.1 order: "reply, reply all, forward | archive, trash, labels | refresh").
///
/// No shortcuts here: ⌘R / ⇧⌘R / ⇧⌘F already live on the Message menu
/// (`MailCommands`), and a second owner of the same key on the toolbar is
/// exactly the ⌘N bug (#10) that `CommandGroup(replacing: .newItem)` fixed.
/// Disabled by the same rule as the Message menu's `hasMessage` — a message,
/// not just a thread, must be selected (matches `MailCommands.hasMessage`).
struct ReplyForwardButtons: View {
    let model: MailViewModel

    var body: some View {
        Button { model.requestCompose(.reply) } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .iconButtonStyle("Reply")
        }
        .disabled(model.selectedMessageID == nil)

        Button { model.requestCompose(.replyAll) } label: {
            Image(systemName: "arrowshape.turn.up.left.2")
                .iconButtonStyle("Reply All")
        }
        .disabled(model.selectedMessageID == nil)

        Button { model.requestCompose(.forward) } label: {
            Image(systemName: "arrowshape.turn.up.right")
                .iconButtonStyle("Forward")
        }
        .disabled(model.selectedMessageID == nil)
    }
}
