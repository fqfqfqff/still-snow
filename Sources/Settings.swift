import SwiftUI
import AppKit

enum SnowStyle: String, CaseIterable, Identifiable {
    case minimal, crystal, frost, retro
    var id: Self { self }

    func title(_ ru: Bool) -> String {
        switch self {
        case .minimal: ru ? "Минимализм" : "Minimal"
        case .crystal: ru ? "Объёмный лёд" : "Crystal"
        case .frost: ru ? "Матовое стекло" : "Frosted"
        case .retro: ru ? "Пиксельный снег" : "Pixel Snow"
        }
    }

    var iconName: String {
        switch self {
        case .minimal: "IconMinimal"
        case .crystal: "StillSnow"
        case .frost: "IconFrostLight"
        case .retro: "IconRetro"
        }
    }

    private static let icons = Dictionary(uniqueKeysWithValues:
        (allCases.map(\.iconName) + ["IconFrostDark"]).compactMap { name -> (String, NSImage)? in
            guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
                  let icon = NSImage(contentsOf: url) else { return nil }
            return (name, icon)
        }
    )

    func appIcon(dark: Bool) -> NSImage? { Self.icons[resourceName(dark: dark)] }

    private func resourceName(dark: Bool) -> String {
        self == .frost && dark ? "IconFrostDark" : iconName
    }

    var palette: [Color] {
        switch self {
        case .minimal: [Color(red: 0.09, green: 0.18, blue: 0.22), Color(red: 0.14, green: 0.28, blue: 0.32)]
        case .crystal: [Color(red: 0.04, green: 0.11, blue: 0.26), Color(red: 0.10, green: 0.32, blue: 0.58)]
        case .frost: [Color(red: 0.21, green: 0.21, blue: 0.44), Color(red: 0.13, green: 0.45, blue: 0.52)]
        case .retro: [Color(red: 0.19, green: 0.09, blue: 0.28), Color(red: 0.34, green: 0.16, blue: 0.39)]
        }
    }
}

enum SnowAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    func title(_ ru: Bool) -> String {
        switch self {
        case .system: ru ? "Как в системе" : "System"
        case .light: ru ? "Светлая" : "Light"
        case .dark: ru ? "Тёмная" : "Dark"
        }
    }

    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum SnowLanguage: String, CaseIterable, Identifiable {
    case system, russian, english
    var id: Self { self }

    var usesRussian: Bool {
        switch self {
        case .system: Locale.preferredLanguages.first?.hasPrefix("ru") == true
        case .russian: true
        case .english: false
        }
    }

    func title(_ ru: Bool) -> String {
        switch self {
        case .system: ru ? "Как в системе" : "System"
        case .russian: "Русский"
        case .english: "English"
        }
    }
}

final class SnowPreferences: ObservableObject {
    private let defaults: UserDefaults
    var changed: (() -> Void)?
    @Published var paused = false
    @Published var garlands: Bool {
        didSet { defaults.set(garlands, forKey: "garlands"); changed?() }
    }
    @Published var weather: Int {
        didSet { defaults.set(weather, forKey: "weather") }
    }
    @Published var wind: Int {
        didSet {
            defaults.set(wind % 3 - 1, forKey: "windX")
            defaults.set(wind / 3 - 1, forKey: "windY")
        }
    }
    @Published var language: SnowLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language"); changed?() }
    }
    @Published var appearance: SnowAppearance {
        didSet { defaults.set(appearance.rawValue, forKey: "appearance"); changed?() }
    }
    @Published var theme: SnowStyle {
        didSet { defaults.set(theme.rawValue, forKey: "theme"); changed?() }
    }
    @Published var icon: SnowStyle {
        didSet { defaults.set(icon.rawValue, forKey: "icon"); changed?() }
    }
    @Published var opacity: Double {
        didSet { defaults.set(opacity, forKey: "snowOpacity"); changed?() }
    }
    @Published var size: Double {
        didSet { defaults.set(size, forKey: "snowSize"); changed?() }
    }
    @Published var accumulate: Bool {
        didSet { defaults.set(accumulate, forKey: "accumulate"); changed?() }
    }
    @Published var tint: String {
        didSet { defaults.set(tint, forKey: "snowTint"); changed?() }
    }
    @Published var glass: Bool {
        didSet { defaults.set(glass, forKey: "glass"); changed?() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        garlands = defaults.bool(forKey: "garlands")
        weather = min(2, max(0, defaults.object(forKey: "weather") as? Int ?? 1))
        let x = min(1, max(-1, defaults.integer(forKey: "windX")))
        let y = min(1, max(-1, defaults.integer(forKey: "windY")))
        wind = (y + 1) * 3 + x + 1
        language = SnowLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        appearance = SnowAppearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        theme = SnowStyle(rawValue: defaults.string(forKey: "theme") ?? "") ?? .frost
        icon = SnowStyle(rawValue: defaults.string(forKey: "icon") ?? "") ?? .frost
        opacity = min(1, max(0.2, defaults.object(forKey: "snowOpacity") as? Double ?? 0.92))
        size = min(1.8, max(0.6, defaults.object(forKey: "snowSize") as? Double ?? 1))
        accumulate = defaults.object(forKey: "accumulate") as? Bool ?? true
        tint = defaults.string(forKey: "snowTint") ?? "ice"
        glass = defaults.object(forKey: "glass") as? Bool ?? true
    }

    var color: NSColor {
        switch tint {
        case "white": .white
        case "lavender": NSColor(srgbRed: 0.93, green: 0.85, blue: 1, alpha: 1)
        case "mint": NSColor(srgbRed: 0.82, green: 0.98, blue: 0.95, alpha: 1)
        default: NSColor(srgbRed: 0.88, green: 0.94, blue: 1, alpha: 1)
        }
    }

    func reset() {
        appearance = .system
        theme = .frost
        icon = .frost
        opacity = 0.92
        size = 1
        accumulate = true
        tint = "ice"
        glass = true
    }
}

struct SnowSettingsView: View {
    @ObservedObject var preferences: SnowPreferences
    private var russian: Bool { preferences.language.usesRussian }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private func tr(_ en: String, _ ru: String) -> String { russian ? ru : en }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                preview
                section(tr("Interface theme", "Тема интерфейса")) {
                    Picker(tr("Language", "Язык"), selection: $preferences.language) {
                        ForEach(SnowLanguage.allCases) { language in
                            Text(language.title(russian)).tag(language)
                        }
                    }
                    .pickerStyle(.menu)
                    Picker(tr("Appearance", "Оформление"), selection: $preferences.appearance) {
                        ForEach(SnowAppearance.allCases) { appearance in
                            Text(appearance.title(russian)).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 9) {
                        ForEach(SnowStyle.allCases) { style in
                            choice(style, selection: $preferences.theme, icon: false)
                        }
                    }
                    Toggle(tr("Translucent controls", "Прозрачные элементы управления"), isOn: $preferences.glass)
                }
                section(tr("Application icon", "Иконка приложения")) {
                    HStack(spacing: 9) {
                        ForEach(SnowStyle.allCases) { style in
                            choice(style, selection: $preferences.icon, icon: true)
                        }
                    }
                }
                section(tr("Snow", "Снег")) {
                    slider(tr("Opacity", "Прозрачность"), $preferences.opacity, 0.2...1)
                    slider(tr("Flake size", "Размер снежинок"), $preferences.size, 0.6...1.8)
                    Picker(tr("Tint", "Оттенок"), selection: $preferences.tint) {
                        Text(tr("Ice blue", "Ледяной")).tag("ice")
                        Text(tr("White", "Белый")).tag("white")
                        Text(tr("Lavender", "Лавандовый")).tag("lavender")
                        Text(tr("Mint", "Мятный")).tag("mint")
                    }
                    Toggle(tr("Accumulate on windows", "Накапливать снег на окнах"), isOn: $preferences.accumulate)
                }
                Button(tr("Reset appearance", "Сбросить оформление")) { preferences.reset() }
                    .buttonStyle(.link)
            }
            .padding(16)
        }

        .tint(preferences.theme == .retro ? .purple : preferences.theme == .minimal ? .teal : .blue)
        .background {
            if preferences.theme != .minimal {
                LinearGradient(colors: preferences.theme.palette.map { $0.opacity(0.12) },
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }

    private var dark: Bool { colorScheme == .dark }

    private var preview: some View {
        let frostedLight = preferences.theme == .frost && !dark
        let palette: [Color] = frostedLight
            ? [Color(red: 0.78, green: 0.82, blue: 0.97), Color(red: 0.64, green: 0.88, blue: 0.96)]
            : preferences.theme.palette
        return ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, geometry in
                let color = Color(nsColor: preferences.color).opacity(preferences.opacity)
                let width = Int(max(1, geometry.width))
                let height = Int(max(1, geometry.height))
                for index in 0..<62 {
                    let x = CGFloat((index * 71 + 43) % width)
                    let y = CGFloat((index * 29 + 37) % height)
                    let size = CGFloat(1 + index % 4) * preferences.size
                    let rect = CGRect(x: x, y: y, width: size, height: size)
                    let path = preferences.theme == .retro ? Path(rect) : Path(ellipseIn: rect)
                    context.fill(path, with: .color(color.opacity(0.5 + Double(index % 4) / 7)))
                }
            }
            HStack(spacing: 10) {
                if let icon = preferences.icon.appIcon(dark: dark) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 48, height: 48)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Still Snow").font(.headline)
                    Text(preferences.theme.title(russian)).font(.caption).opacity(0.87)
                }
            }
            .foregroundStyle(frostedLight ? Color(red: 0.06, green: 0.17, blue: 0.32) : .white)
            .padding(.horizontal, 13).padding(.vertical, 6)
            .modifier(PreviewGlass(enabled: preferences.glass && !reduceTransparency, light: frostedLight))
            .padding(14)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: preferences.theme == .retro ? 8 : 22))
        .accessibilityHidden(true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
    }

    private func choice(_ style: SnowStyle, selection: Binding<SnowStyle>, icon: Bool) -> some View {
        let selected = selection.wrappedValue == style
        return Button {
            selection.wrappedValue = style
        } label: {
            VStack(spacing: 5) {
                if icon, let art = style.appIcon(dark: dark) {
                    Image(nsImage: art).resizable().interpolation(.high).frame(width: 50, height: 50)
                } else {
                    RoundedRectangle(cornerRadius: style == .retro ? 4 : 10)
                        .fill(LinearGradient(colors: style.palette, startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            Image(systemName: style == .retro ? "square.grid.3x3.fill" : "snowflake")
                                .font(.system(size: 20, weight: .medium)).foregroundStyle(.white)
                        }
                        .frame(height: 43)
                }
                Text(style.title(russian)).font(.caption).lineLimit(1).minimumScaleFactor(0.75)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ bounds: ClosedRange<Double>) -> some View {
        HStack {
            Slider(value: value, in: bounds, step: 0.05) { Text(title) }
            Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
        }
    }
}

private struct PreviewGlass: ViewModifier {
    let enabled: Bool
    let light: Bool

    private var tint: Color { light ? .white : .black }

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            if #available(macOS 26.0, *) {
                content.glassEffect(.regular.tint(tint.opacity(0.32)), in: Capsule())
            } else {
                content.background(tint.opacity(0.48), in: Capsule())
            }
        } else {
            content.background(tint.opacity(0.75), in: Capsule())
        }
    }
}

struct SnowControlPanel: View {
    @ObservedObject var preferences: SnowPreferences
    @ObservedObject var updates: AppUpdates
    let togglePause: () -> Void
    let clearSnow: () -> Void
    let checkUpdates: () -> Void
    let quit: () -> Void
    @State private var page = 0

    private func tr(_ en: String, _ ru: String) -> String { preferences.language.usesRussian ? ru : en }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Still Snow", systemImage: "snowflake")
                    .font(.headline)
                Spacer()
                Button(action: togglePause) {
                    Image(systemName: preferences.paused ? "play.fill" : "pause.fill")
                }
                .help(preferences.paused ? tr("Resume snowfall", "Продолжить снег") : tr("Pause snowfall", "Пауза"))
                .accessibilityLabel(preferences.paused ? tr("Resume snowfall", "Продолжить снег") : tr("Pause snowfall", "Пауза"))
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Picker(tr("Section", "Раздел"), selection: $page) {
                Text(tr("Snow", "Снег")).tag(0)
                Text(tr("Settings", "Настройки")).tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16).padding(.bottom, 12)

            Divider()
            if page == 0 {
                controls
            } else {
                SnowSettingsView(preferences: preferences)
            }
        }
        .frame(width: 395, height: 495)
        .preferredColorScheme(preferences.appearance == .system ? nil : preferences.appearance == .dark ? .dark : .light)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(tr("Snowfall", "Снегопад")).font(.headline)
                    Picker(tr("Snowfall", "Снегопад"), selection: $preferences.weather) {
                        Text(tr("Light", "Лёгкий")).tag(0)
                        Text(tr("Steady", "Ровный")).tag(1)
                        Text(tr("Flurry", "Метель")).tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Picker(tr("Wind", "Ветер"), selection: $preferences.wind) {
                        ForEach(Array(zip(0...8, ["↙", "↓", "↘", "←", tr("Calm", "Штиль"), "→", "↖", "↑", "↗"])), id: \.0) { tag, label in
                            Text(label).tag(tag)
                        }
                    }
                }
                Text(tr("Move the pointer through snow to sweep it. Click to scatter it, or drag from a drift to roll a ball.",
                        "Проведи курсором, чтобы сдвинуть снег. Клик разбросает его, а зажатие и перетаскивание слепит шар."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(tr("Garlands on windows", "Гирлянды на окнах"), isOn: $preferences.garlands)
                Button(tr("Clear snow", "Очистить снег"), action: clearSnow)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Updates", "Обновления")).font(.headline)
                    if updates.requiresInstallation {
                        Text(tr("This copy is read-only. Quit it and open Still Snow from Applications in Finder.",
                                "Эта копия только для чтения. Выйди из неё и открой Still Snow из «Программ» в Finder."))
                            .font(.caption).foregroundStyle(.secondary)
                        Button(tr("Open Applications", "Открыть «Программы»")) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                        }
                    } else if updates.available {
                        Button(tr("Check for updates…", "Проверить обновления…"), action: checkUpdates)
                            .disabled(!updates.canCheck)
                        Toggle(tr("Check automatically", "Проверять автоматически"), isOn: Binding(
                            get: { updates.automaticChecks }, set: { updates.automaticChecks = $0 }
                        ))
                        Toggle(tr("Install automatically", "Устанавливать автоматически"), isOn: Binding(
                            get: { updates.automaticInstallation }, set: { updates.automaticInstallation = $0 }
                        )).disabled(!updates.automaticChecks)
                    } else {
                        Link(tr("Download a release build", "Скачать сборку с GitHub"),
                             destination: URL(string: "https://github.com/fqfqfqff/still-snow/releases/latest")!)
                    }
                }
                Divider()
                Button(tr("Quit Still Snow", "Выйти из Still Snow"), action: quit)
                    .buttonStyle(.link)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }
}
