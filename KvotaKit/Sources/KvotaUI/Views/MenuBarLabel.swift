import KvotaCore
import SwiftUI

/// What sits in the menu bar.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.settings.menuBarStyle {
        case .iconOnly:
            Image(systemName: Theme.gaugeSymbol(model.highestPercent()))
        case .highest:
            if let used = model.highestPercent() {
                HStack(spacing: 3) {
                    Image(systemName: Theme.gaugeSymbol(used))
                    Text(model.settings.showRemaining ? "\(Format.percent(max(0, 100 - used))) left" : Format.percent(used))
                        .monospacedDigit()
                }
            } else {
                Image(systemName: Theme.gaugeSymbol(nil))
            }
        case .perProvider:
            let parts = model.visibleProviders.compactMap { provider -> String? in
                guard let used = model.state(for: provider).highestPercent(at: model.now) else { return nil }
                let value = model.settings.showRemaining ? max(0, 100 - used) : used
                return "\(provider.shortName) \(Int(value.rounded()))%"
            }
            if parts.isEmpty {
                Image(systemName: Theme.gaugeSymbol(nil))
            } else {
                Text(parts.joined(separator: " · "))
                    .monospacedDigit()
            }
        }
    }
}
