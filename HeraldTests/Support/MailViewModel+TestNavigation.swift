@testable import Herald
import HeraldKit

extension MailViewModel {
    /// Test shorthand for "show this mailbox's (or every mailbox's) folder, no
    /// label" — ONE navigation, exactly what the pre-redesign
    /// `selection = FolderSelection(mailboxID:folder:)` assignment did (it also
    /// closed any open label), so the many tests written against that keep
    /// asserting the same behaviour.
    func showListing(mailboxID: String?, folder: ConversationFolder) {
        navigate(to: Location(
            scope: mailboxID.map(Scope.mailbox) ?? .allDomains,
            folder: .conversation(folder),
            labelID: nil
        ))
    }

    /// The conversation folder on screen, or `nil` on Drafts.
    var listFolder: ConversationFolder? { folder.conversationFolder }
}
