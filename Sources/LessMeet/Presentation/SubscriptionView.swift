import SwiftUI

struct SubscriptionAccountView: View {
    @ObservedObject var account: AccountSession
    @ObservedObject var billing: BillingStore
    @ObservedObject var subscription: SubscriptionModel
    let configuration: BillingConfiguration?
    @State private var showingPlan = false

    var body: some View {
        VStack(spacing: 0) {
            Button { showingPlan = true } label: {
                Label("Plan & usage", systemImage: "sparkles")
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }.buttonStyle(.plain)
            AccountPanel(session: account, billingBusy: billing.busy)
        }
        .onChange(of: account.sessionIdentifier, initial: true) { _, _ in
            subscription.contextChanged()
        }
        .task(id: account.sessionIdentifier) {
            await billing.prepare(userID: account.sessionIdentifier == nil ? nil : account.userID)
            await subscription.refresh()
        }
        .sheet(isPresented: $showingPlan) {
            SubscriptionView(account: account, billing: billing, subscription: subscription,
                             configuration: configuration)
        }
    }
}

struct SubscriptionView: View {
    @ObservedObject var account: AccountSession
    @ObservedObject var billing: BillingStore
    @ObservedObject var subscription: SubscriptionModel
    let configuration: BillingConfiguration?
    @Environment(\.dismiss) private var dismiss
    @State private var confirming = false
    @State private var acknowledgedInternalTesting = false

    private var canPurchase: Bool {
        account.sessionIdentifier != nil && !account.cloudAccessLocked && billing.activeUserID == account.userID &&
        subscription.status?.userId == account.userID && subscription.status?.enforcement == true &&
        ((configuration?.isInternalTesting == true && acknowledgedInternalTesting) ||
         (configuration?.isInternalTesting != true && configuration?.privacyURL != nil && configuration?.termsURL != nil)) &&
        !billing.busy && !subscription.busy && !confirming
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Plan & usage").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Local recording and playback remain available on every plan.")
                        .foregroundStyle(.secondary)
                    if let status = subscription.status, status.userId == account.userID {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(status.plan == "development" ? "Development access" : status.plan.capitalized)
                                    .font(.headline)
                                if status.enforcement {
                                    Text("\(status.transcriptionSeconds.remaining / 60) transcription minutes remaining")
                                    Text("\(status.questions.remaining) AI questions remaining")
                                    if let end = status.periodEnd {
                                        Text("Current allowance ends \(end.formatted(date: .abbreviated, time: .omitted)).")
                                    } else { Text("Free allowance is one-time, not monthly.") }
                                    Text("In-progress requests reserve allowance until completion.").font(.caption)
                                } else {
                                    Text("Subscription quotas are not active on this environment. Purchases are disabled.")
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                        }
                    } else if !account.isSignedIn {
                        Text("Sign in from Account to view usage or manage purchases.")
                    } else {
                        Text("Refresh your plan before purchasing. Subscription status is not confirmed.")
                    }
                    Divider()
                    if configuration?.isInternalTesting == true {
                        GroupBox("Internal testing only — not for distribution") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Uses the Lessmeet development backend, Clerk and RevenueCat. Use synthetic data only. Public Privacy/Terms are not published yet. Contact Hoang Bang: hoang@2m0r.com.")
                                Text("This build does not force Apple's payment environment. Use your Sandbox Apple Account and cancel any purchase sheet that is not clearly a sandbox test.")
                                Toggle("I will use a Sandbox Apple Account and verify the Apple purchase sheet.", isOn: $acknowledgedInternalTesting)
                            }.font(.caption).padding(6)
                        }
                    }
                    Text("Free").font(.headline)
                    Text("120 transcription minutes + 20 AI questions, once per account.")
                    Text("Pro").font(.headline)
                    Text("1,200 transcription minutes + 200 AI questions each month. Includes transcript chat, summaries and action items; each successful AI request uses one question.")
                    Text("Annual plans also receive monthly allowances. Unused allowance does not roll over. System-failed requests are refunded; previously saved local results remain available after cancellation.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(billing.packages) { package in
                        Button {
                            Task {
                                guard !account.cloudAccessLocked else { return }
                                confirming = true
                                defer { confirming = false }
                                if await billing.purchase(packageID: package.id) {
                                    await subscription.refresh(synchronize: true)
                                }
                            }
                        } label: {
                            HStack {
                                Text(package.period == .monthly ? "Pro monthly" : "Pro annual")
                                Spacer()
                                Text("\(package.localizedPrice) / \(package.period == .monthly ? "month" : "year")")
                            }.padding(6)
                        }.disabled(!canPurchase || subscription.status?.plan == "pro")
                    }
                    if !billing.isConfigured || billing.packages.isEmpty {
                        Text("Store purchases are not available yet.").foregroundStyle(.secondary)
                    }
                    Text("Subscriptions renew automatically unless canceled in your Apple account settings. Payment is charged to your Apple account. Purchase confirmation alone does not unlock AI: the server must verify your subscription.")
                        .font(.caption).foregroundStyle(.secondary)
                    if configuration?.isInternalTesting != true && (configuration?.privacyURL == nil || configuration?.termsURL == nil) {
                        Text("Purchases require published privacy and subscription terms.").font(.caption)
                    }
                    if let error = subscription.error { Text(error).foregroundStyle(.red) }
                    if let error = billing.error { Text(error).foregroundStyle(.red) }
                    HStack {
                        Button("Refresh") {
                            Task {
                                await billing.prepare(userID: account.userID)
                                await subscription.refresh(synchronize: true)
                            }
                        }
                        Button("Restore Purchases") {
                            Task {
                                guard !account.cloudAccessLocked else { return }
                                confirming = true
                                defer { confirming = false }
                                if await billing.restore() { await subscription.refresh(synchronize: true) }
                            }
                        }.disabled(!billing.isConfigured || billing.activeUserID != account.userID)
                        if billing.busy || subscription.busy || confirming { ProgressView().controlSize(.small) }
                    }.disabled(account.sessionIdentifier == nil || account.cloudAccessLocked || billing.busy || subscription.busy || confirming)
                    HStack {
                        if let url = configuration?.privacyURL { Link("Privacy", destination: url) }
                        if let url = configuration?.termsURL { Link("Terms", destination: url) }
                        Link("Manage or cancel with Apple", destination: URL(string: "https://support.apple.com/en-us/118428")!)
                    }.font(.caption)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 540, height: 640)
        .task { await subscription.refresh() }
    }
}
