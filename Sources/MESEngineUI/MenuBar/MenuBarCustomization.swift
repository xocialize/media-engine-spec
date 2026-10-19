import AppKit
import DesignScaffold
import SwiftUI

/// The "Customize Menu Bar" menu: the engine's icon, or any mix of CPU, GPU and memory readings. Its rows toggle without
/// closing the menu. The System page's header and the menu-bar item's own menu both show it.
@MainActor
final class MenuBarCustomizationMenu {
    let preferences: MenuBarPreferences
    private var rows: [PersistentMenuActionView] = []
    private static let engineIconID = "engine-icon"
    private static let menuFont = NSFont.menuFont(ofSize: NSFont.systemFontSize)

    init(preferences: MenuBarPreferences) {
        self.preferences = preferences
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        addItems(to: menu)
        return menu
    }

    func addItems(to menu: NSMenu) {
        rows.removeAll()
        menu.addItem(.sectionHeader(title: "Menu Bar"))
        menu.addItem(row(title: "Engine icon", symbol: "app.dashed", id: Self.engineIconID, selected: preferences.showsEngineIcon) {
            [weak self] in
            self?.preferences.useEngineIcon()
            self?.refresh()
        })
        for metric in MenuBarMetric.allCases {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: metric.title))
            for style in metric.styles {
                let item = MenuBarItem(metric: metric, style: style)
                menu.addItem(row(title: style.title, symbol: style.symbol, id: item.id,
                                 selected: preferences.contains(metric, style)) { [weak self] in
                    self?.preferences.toggle(metric, style)
                    self?.refresh()
                })
            }
        }
    }

    func refresh() {
        for row in rows {
            if row.optionID == Self.engineIconID {
                row.isSelected = preferences.showsEngineIcon
            } else if let item = MenuBarItem(id: row.optionID) {
                row.isSelected = preferences.contains(item.metric, item.style)
            }
        }
    }

    private func row(title: String, symbol: String, id: String, selected: Bool, onSelect: @escaping () -> Void) -> NSMenuItem {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize, weight: .regular))
        let view = PersistentMenuActionView(optionID: id, title: NSAttributedString(string: title, attributes: [.font: Self.menuFont]),
                                            image: image, isSelected: selected, onSelect: onSelect)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = view
        item.isEnabled = true
        rows.append(view)
        return item
    }
}

/// The System page's "Customize Menu Bar" button, with a count of the metrics shown.
struct MenuBarCustomizationButton: View {
    let preferences: MenuBarPreferences
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Tokens.Space.s) {
            Image(systemName: "menubar.rectangle").foregroundStyle(Tokens.Color.accent)
            Text("Customize Menu Bar")
            Text("\(max(preferences.orderedItems.count, 1))")
                .font(Tokens.Font.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(minWidth: 18, minHeight: 18)
                .background(Tokens.Color.accent, in: Capsule())
            Image(systemName: "chevron.down").font(Tokens.Font.caption.weight(.bold)).foregroundStyle(Tokens.Color.secondaryLabel)
        }
        .font(Tokens.Font.body.weight(.semibold))
        .padding(.horizontal, 11)
        .frame(height: 30)
        .background(Tokens.Color.accent.opacity(hovered ? 0.14 : 0.07),
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.control + 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Tokens.Radius.control + 2, style: .continuous)
                .stroke(Tokens.Color.accent.opacity(hovered ? 0.65 : 0.32), lineWidth: 1)
        }
        .contentShape(.rect)
        .overlay { MenuOpener(preferences: preferences) }
        .fixedSize()
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { hovered = hovering } }
        .help("Choose which metrics appear in the menu bar")
    }

    /// A transparent button that drops the menu below the control.
    private struct MenuOpener: NSViewRepresentable {
        let preferences: MenuBarPreferences

        func makeCoordinator() -> Coordinator { Coordinator(menu: MenuBarCustomizationMenu(preferences: preferences)) }

        func makeNSView(context: Context) -> NSButton {
            let button = NSButton()
            button.isBordered = false
            button.title = ""
            button.focusRingType = .none
            button.target = context.coordinator
            button.action = #selector(Coordinator.show(_:))
            button.setAccessibilityLabel("Customize Menu Bar")
            return button
        }

        func updateNSView(_ button: NSButton, context: Context) { context.coordinator.menu.refresh() }

        @MainActor final class Coordinator: NSObject {
            let menu: MenuBarCustomizationMenu
            init(menu: MenuBarCustomizationMenu) { self.menu = menu }

            @objc func show(_ sender: NSButton) {
                let menu = menu.makeMenu()
                menu.update()
                menu.popUp(positioning: nil,
                           at: NSPoint(x: -8, y: sender.isFlipped ? sender.bounds.maxY + 4 : sender.bounds.minY - 4), in: sender)
            }
        }
    }
}
