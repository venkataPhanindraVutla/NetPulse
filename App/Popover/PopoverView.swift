import SwiftUI

struct PopoverView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Segmented(selection: $model.tab, options: PopoverTab.allCases.map { ($0, $0.title) })
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Divider().opacity(0.6)
            Group {
                switch model.tab {
                case .now: NowTab()
                case .apps: AppsTab()
                case .history: HistoryTab()
                }
            }
            .transition(.opacity)
            Divider().opacity(0.6)
            PopoverFooter()
        }
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .task(id: model.popoverOpen) {
            guard model.popoverOpen else { return }
            while !Task.isCancelled {
                await model.refreshUsage()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
