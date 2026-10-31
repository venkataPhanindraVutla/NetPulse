import NetPulseCore
import SwiftUI

struct NetworksSettings: View {
    @Environment(AppModel.self) private var model
    @State private var networks: [StoredNetwork] = []
    @State private var caps: [Cap] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.notificationStatus == .denied {
                    Text("Notifications are off — caps will still show in the popover.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if loaded && networks.isEmpty {
                    Text("No networks recorded yet. They appear here once NetPulse has seen traffic.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(networks) { network in
                    NetworkCard(network: network, caps: caps.filter { $0.networkID == network.id }) {
                        await reload()
                    }
                    .id("\(network.id)-\(network.displayName)-\(network.billingDay)")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.snapshot?.primaryNetwork?.id) {
            await model.refreshNotificationStatus()
            await reload()
        }
    }

    private func reload() async {
        networks = (try? await model.store.networks()) ?? networks
        caps = (try? await model.store.caps()) ?? caps
        loaded = true
    }
}

private struct NetworkCard: View {
    @Environment(AppModel.self) private var model
    let network: StoredNetwork
    let caps: [Cap]
    let didChange: () async -> Void

    @State private var name: String
    @State private var billingDay: Int
    @State private var dailyText: String
    @State private var monthlyText: String
    @State private var dailyOn: Bool
    @State private var monthlyOn: Bool
    @State private var dailyError = false
    @State private var monthlyError = false
    @FocusState private var focus: Field?

    private enum Field { case name, daily, monthly }

    init(network: StoredNetwork, caps: [Cap], didChange: @escaping () async -> Void) {
        self.network = network
        self.caps = caps
        self.didChange = didChange
        let daily = caps.first { $0.period == .daily }, monthly = caps.first { $0.period == .monthly }
        _name = State(initialValue: network.displayName)
        _billingDay = State(initialValue: network.billingDay)
        _dailyText = State(initialValue: CapInput.text(forBytes: daily?.limitBytes ?? 0))
        _monthlyText = State(initialValue: CapInput.text(forBytes: monthly?.limitBytes ?? 0))
        _dailyOn = State(initialValue: daily?.enabled ?? false)
        _monthlyOn = State(initialValue: monthly?.enabled ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onSubmit(commitName)
                    .accessibilityLabel("Network name")
                Text(network.key.kind == .wifi ? "Wi-Fi" : "Ethernet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            capRow("Daily cap", text: $dailyText, on: $dailyOn, error: dailyError, field: .daily, period: .daily)
            capRow("Monthly cap", text: $monthlyText, on: $monthlyOn, error: monthlyError, field: .monthly, period: .monthly)
            Stepper(value: $billingDay, in: 1...28) {
                Text("Billing day  ").foregroundStyle(.secondary) + Text("\(billingDay)").monospacedDigit()
            }
            .font(.system(size: 12))
            .onChange(of: billingDay) { _, _ in commitName() }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .onChange(of: focus) { old, new in
            if old == .name, new != .name { commitName() }
            if old == .daily, new != .daily { commitText(.daily) }
            if old == .monthly, new != .monthly { commitText(.monthly) }
        }
        .onDisappear { commitName() }
    }

    private func capRow(
        _ title: String, text: Binding<String>, on: Binding<Bool>, error: Bool, field: Field, period: CapPeriod
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Toggle(title, isOn: Binding(get: { on.wrappedValue }, set: { toggle(period, $0) }))
                    .toggleStyle(.switch).controlSize(.small)
                Spacer()
                TextField("0", text: text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                    .focused($focus, equals: field)
                    .onSubmit { commitText(period) }
                    .accessibilityLabel("\(title) in gigabytes")
                Text("GB").foregroundStyle(.secondary)
            }
            if error {
                Text("Enter a limit above 0 GB, for example 100 or 0.5.")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .font(.system(size: 12))
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { name = network.displayName }
        let finalName = trimmed.isEmpty ? network.displayName : trimmed
        guard finalName != network.displayName || billingDay != network.billingDay else { return }
        let id = network.id, day = billingDay
        Task {
            await model.saveNetwork(id: id, name: finalName, billingDay: day)
            await didChange()
        }
    }

    private func toggle(_ period: CapPeriod, _ on: Bool) {
        let text = period == .daily ? dailyText : monthlyText
        if on {
            guard let bytes = CapInput.limitBytes(fromGB: text) else {
                setError(period, true)
                return
            }
            setError(period, false)
            if period == .daily { dailyText = CapInput.text(forBytes: bytes) } else { monthlyText = CapInput.text(forBytes: bytes) }
            setOn(period, true)
            save(period, bytes: bytes, enabled: true)
        } else {
            setOn(period, false)
            let bytes = CapInput.limitBytes(fromGB: text) ?? caps.first { $0.period == period }?.limitBytes ?? 0
            save(period, bytes: bytes, enabled: false)
        }
    }

    private func commitText(_ period: CapPeriod) {
        let text = period == .daily ? dailyText : monthlyText
        let enabled = period == .daily ? dailyOn : monthlyOn
        if text.trimmingCharacters(in: .whitespaces).isEmpty, !enabled {
            setError(period, false)
            return
        }
        guard let bytes = CapInput.limitBytes(fromGB: text) else {
            setError(period, true)
            return
        }
        setError(period, false)
        let canonical = CapInput.text(forBytes: bytes)
        if period == .daily { dailyText = canonical } else { monthlyText = canonical }
        guard bytes != caps.first(where: { $0.period == period })?.limitBytes else { return }
        save(period, bytes: bytes, enabled: enabled)
    }

    private func save(_ period: CapPeriod, bytes: UInt64, enabled: Bool) {
        let id = network.id
        Task {
            await model.saveCap(networkID: id, period: period, limitBytes: bytes, enabled: enabled)
            await didChange()
        }
    }

    private func setError(_ period: CapPeriod, _ value: Bool) {
        if period == .daily { dailyError = value } else { monthlyError = value }
    }

    private func setOn(_ period: CapPeriod, _ value: Bool) {
        if period == .daily { dailyOn = value } else { monthlyOn = value }
    }
}
