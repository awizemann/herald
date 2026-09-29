import Foundation
import HeraldKit
import Testing

@testable import Herald

/// `WorkflowPreferences` (WF3): per-(account, domain) classification settings
/// and the rules WF4's classifier reads.
@Suite("Workflow preferences", .scratchDefaults)
struct WorkflowPreferencesTests {
    private let account = "https://mail.example"
    private let domain = "dom1"
    private let billing = MailLabel(id: "l-billing", name: "Billing", color: .green)
    private let support = MailLabel(id: "l-support", name: "Support", color: .blue)

    @Test("Keys escape dotted account and domain ids under workflow.")
    func keysAreEscaped() {
        #expect(
            WorkflowPreferences.enabledKey(accountID: "https://mail.x", domainID: "domain-name:acme.co")
                == "workflow.https://mail%2Ex.domain-name:acme%2Eco.classify"
        )
    }

    @Test("Classification defaults off with no cutoff and no rules")
    func defaultsOff() {
        let defaults = ScratchDefaults.make()
        #expect(!WorkflowPreferences.isEnabled(accountID: account, domainID: domain, in: defaults))
        #expect(WorkflowPreferences.enabledAt(accountID: account, domainID: domain, in: defaults) == nil)
        #expect(WorkflowPreferences.classificationRules(accountID: account, domainID: domain, labels: [billing], in: defaults) == nil)
    }

    @Test("Enabling stamps enabledAt; re-enabling after off moves it; a repeated on does not")
    func enabledAtLifecycle() {
        let defaults = ScratchDefaults.make()
        let first = Date(timeIntervalSince1970: 1_000)
        let second = Date(timeIntervalSince1970: 2_000)
        WorkflowPreferences.setEnabled(true, accountID: account, domainID: domain, in: defaults, now: first)
        #expect(WorkflowPreferences.enabledAt(accountID: account, domainID: domain, in: defaults) == first)

        WorkflowPreferences.setEnabled(true, accountID: account, domainID: domain, in: defaults, now: second)
        #expect(WorkflowPreferences.enabledAt(accountID: account, domainID: domain, in: defaults) == first)

        WorkflowPreferences.setEnabled(false, accountID: account, domainID: domain, in: defaults, now: second)
        #expect(!WorkflowPreferences.isEnabled(accountID: account, domainID: domain, in: defaults))
        #expect(WorkflowPreferences.enabledAt(accountID: account, domainID: domain, in: defaults) == nil)

        WorkflowPreferences.setEnabled(true, accountID: account, domainID: domain, in: defaults, now: second)
        #expect(WorkflowPreferences.enabledAt(accountID: account, domainID: domain, in: defaults) == second)
    }

    @Test("Label rules round-trip; an empty rule is removed")
    func labelRuleRoundTrip() {
        let defaults = ScratchDefaults.make()
        let rule = WorkflowLabelRule(included: true, description: "Invoices, not receipts")
        WorkflowPreferences.setLabelRule(rule, labelID: billing.id, accountID: account, domainID: domain, in: defaults)
        #expect(WorkflowPreferences.labelRule(labelID: billing.id, accountID: account, domainID: domain, in: defaults) == rule)
        #expect(WorkflowPreferences.labelRule(labelID: support.id, accountID: account, domainID: domain, in: defaults) == .empty)

        WorkflowPreferences.setLabelRule(.empty, labelID: billing.id, accountID: account, domainID: domain, in: defaults)
        #expect(defaults.object(forKey: WorkflowPreferences.labelsKey(accountID: account, domainID: domain)) == nil)
    }

    @Test("Rules: only live, included, described labels, in label order, trimmed")
    func rulesFilter() {
        let defaults = ScratchDefaults.make()
        WorkflowPreferences.setEnabled(true, accountID: account, domainID: domain, in: defaults)
        WorkflowPreferences.setLabelRule(.init(included: true, description: "  Help requests \n"), labelID: support.id, accountID: account, domainID: domain, in: defaults)
        WorkflowPreferences.setLabelRule(.init(included: true, description: "Invoices"), labelID: billing.id, accountID: account, domainID: domain, in: defaults)
        WorkflowPreferences.setLabelRule(.init(included: true, description: "Gone"), labelID: "l-deleted", accountID: account, domainID: domain, in: defaults)
        let excluded = MailLabel(id: "l-ex", name: "Excluded", color: .red)
        WorkflowPreferences.setLabelRule(.init(included: false, description: "Described"), labelID: excluded.id, accountID: account, domainID: domain, in: defaults)
        let blank = MailLabel(id: "l-blank", name: "Blank", color: .red)
        WorkflowPreferences.setLabelRule(.init(included: true, description: "   "), labelID: blank.id, accountID: account, domainID: domain, in: defaults)

        let rules = WorkflowPreferences.classificationRules(
            accountID: account, domainID: domain, labels: [billing, excluded, blank, support], in: defaults
        )
        #expect(rules == [
            ClassificationCandidate(id: billing.id, name: "Billing", description: "Invoices"),
            ClassificationCandidate(id: support.id, name: "Support", description: "Help requests"),
        ])
        #expect(
            WorkflowPreferences.setupWarning(accountID: account, domainID: domain, labels: [billing, blank], in: defaults)
                == .missingDescriptions(["Blank"])
        )
    }

    @Test("Warning: none while off, noLabelsIncluded when on with only a deleted label included, none when complete")
    func warnings() {
        let defaults = ScratchDefaults.make()
        WorkflowPreferences.setLabelRule(.init(included: true, description: "x"), labelID: "l-deleted", accountID: account, domainID: domain, in: defaults)
        #expect(WorkflowPreferences.setupWarning(accountID: account, domainID: domain, labels: [billing], in: defaults) == nil)
        WorkflowPreferences.setEnabled(true, accountID: account, domainID: domain, in: defaults)
        #expect(WorkflowPreferences.setupWarning(accountID: account, domainID: domain, labels: [billing], in: defaults) == .noLabelsIncluded)
        #expect(WorkflowPreferences.classificationRules(accountID: account, domainID: domain, labels: [billing], in: defaults) == [])
        WorkflowPreferences.setLabelRule(.init(included: true, description: "Invoices"), labelID: billing.id, accountID: account, domainID: domain, in: defaults)
        #expect(WorkflowPreferences.setupWarning(accountID: account, domainID: domain, labels: [billing], in: defaults) == nil)
    }

    @Test("Settings are isolated between prefix-sharing accounts and dotted domains, and purge is exact")
    func isolationAndPurge() {
        let defaults = ScratchDefaults.make()
        let longer = "https://mail.example.org"
        WorkflowPreferences.setEnabled(true, accountID: account, domainID: "a.b", in: defaults)
        WorkflowPreferences.setEnabled(true, accountID: longer, domainID: "b", in: defaults)
        #expect(!WorkflowPreferences.isEnabled(accountID: account, domainID: "a", in: defaults))
        #expect(!WorkflowPreferences.isEnabled(accountID: longer, domainID: "a.b", in: defaults))

        PreferenceHygiene.purgeAccount(account, from: defaults)
        #expect(!WorkflowPreferences.isEnabled(accountID: account, domainID: "a.b", in: defaults))
        #expect(WorkflowPreferences.isEnabled(accountID: longer, domainID: "b", in: defaults))
    }

    @Test("Workflows is a real domain page with a route and sidebar key")
    func routeExists() {
        #expect(DomainSettingsPage.allCases.contains(.workflows))
        let route = SettingsRoute.domain("dom1", .workflows)
        #expect(route.title == "Workflows")
        #expect(route.accessibilityKey == "page.workflows")
        #expect(route.resolved(hasAccount: true, visibleDomainIDs: ["dom1"]) == route)
    }

    @Test("Warning wording names the undescribed tags")
    func warningText() {
        #expect(DomainWorkflowsSettingsPage.warningText(.missingDescriptions(["A", "B"])).contains("A, B"))
        #expect(DomainWorkflowsSettingsPage.warningText(.noLabelsIncluded).contains("No tags"))
    }
}
