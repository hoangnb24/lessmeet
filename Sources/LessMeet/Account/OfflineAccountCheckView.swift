#if LESSMEET_OFFLINE_CHECK
import SwiftUI

struct OfflineAccountCheckView: View {
    @StateObject private var fixture = OfflineAccountFixture()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Offline account check").font(.title2.bold())
            Text("Synthetic data only. No Keychain, network, billing or recording access.")
                .foregroundStyle(.secondary)
            Text("Account: \(fixture.identity.owner)")
            Picker("Response", selection: $fixture.scenario) {
                ForEach(OfflineAccountFixture.Scenario.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(fixture.hasPendingResponse)
            HStack {
                Button("Complete pending response") { fixture.completePendingResponse() }
                    .disabled(!fixture.hasPendingResponse)
                Button("Switch synthetic account") { fixture.switchAccount() }
            }
            OfflineResultView(model: fixture.model)
            AccountDeletionView(model: fixture.model, sessionID: nil, billingBusy: false,
                                allowsExternalActions: false)
            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

private struct OfflineResultView: View {
    @ObservedObject var model: AccountDeletionModel
    var body: some View {
        Text(model.busy ? "Refresh is waiting" : model.status.map {
            "Applied response: requested=\($0.requested ? "true" : "false")"
        } ?? "No response applied")
        .font(.callout.monospaced())
        .accessibilityIdentifier("offline-refresh-result")
    }
}
#endif
