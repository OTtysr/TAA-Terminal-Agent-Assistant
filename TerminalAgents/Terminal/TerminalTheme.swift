import AppKit
import SwiftTerm

enum TerminalThemeMode: String, Codable, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    func label(language: AppLanguage) -> String {
        switch (language, self) {
        case (.chinese, .light): return "亮色"
        case (.chinese, .dark): return "暗色"
        case (.english, .light): return "Light"
        case (.english, .dark): return "Dark"
        }
    }
}

/// Ghostty-inspired terminal presentation defaults.
///
/// Ghostty's useful lesson here is not "force everything dark"; it is a fast,
/// native terminal with carefully tuned themes and chrome. Keep this layer
/// separate from PTY lifecycle so the terminal can evolve without disturbing
/// session recovery or transcript capture.
enum TerminalTheme {
    struct Style {
        let background: NSColor
        let elevatedBackground: NSColor
        let selectedTabBackground: NSColor
        let tabBorder: NSColor
        let selectedTabBorder: NSColor
        let foreground: NSColor
        let mutedForeground: NSColor
        let accent: NSColor
        let cursorText: NSColor
        let selection: NSColor
        let palette16: [SwiftTerm.Color]

        var palette256: [SwiftTerm.Color] {
            TerminalTheme.makePalette256(from: palette16)
        }
    }

    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let cornerRadius: CGFloat = 9

    static func style(for mode: TerminalThemeMode) -> Style {
        switch mode {
        case .light:
            return Style(
                background: ns(0xfaf8f3),
                elevatedBackground: ns(0xeeeae1),
                selectedTabBackground: ns(0xfffcf6),
                tabBorder: ns(0xd9d2c5),
                selectedTabBorder: ns(0x9ab8da),
                foreground: ns(0x2d333b),
                mutedForeground: ns(0x68707d),
                accent: ns(0x1264b0),
                cursorText: ns(0xffffff),
                selection: ns(0x9fc4ee, alpha: 0.42),
                palette16: [
                    color(0x2d333b), color(0xcf222e), color(0x1a7f37), color(0x9a6700),
                    color(0x0969da), color(0x8250df), color(0x1b7c83), color(0xd0d7de),
                    color(0x57606a), color(0xa40e26), color(0x2da44e), color(0xbf8700),
                    color(0x218bff), color(0xa475f9), color(0x3192aa), color(0xf6f8fa)
                ]
            )
        case .dark:
            return Style(
                background: ns(0x171a21),
                elevatedBackground: ns(0x20242d),
                selectedTabBackground: ns(0x2a303b),
                tabBorder: ns(0x343b47),
                selectedTabBorder: ns(0x5d7fa7),
                foreground: ns(0xc7ced8),
                mutedForeground: ns(0x8a93a3),
                accent: ns(0x80b7e8),
                cursorText: ns(0x171a21),
                selection: ns(0x5d7fa7, alpha: 0.34),
                palette16: [
                    color(0x252a33), color(0xe06c75), color(0x98c379), color(0xd19a66),
                    color(0x80b7e8), color(0xc678dd), color(0x56b6c2), color(0xc7ced8),
                    color(0x6f7787), color(0xef858c), color(0xa8d08d), color(0xe0b478),
                    color(0xa0c8f2), color(0xd69aed), color(0x76cbd3), color(0xe3e8ef)
                ]
            )
        }
    }

    static func apply(to view: TranscriptCapturingTerminalView, mode: TerminalThemeMode) {
        let theme = style(for: mode)
        view.wantsLayer = true
        view.layer?.backgroundColor = theme.background.cgColor
        view.layer?.cornerRadius = cornerRadius
        if #available(macOS 14.0, *) {
            view.clipsToBounds = true
        }

        view.nativeForegroundColor = theme.foreground
        view.nativeBackgroundColor = theme.background
        view.caretColor = theme.accent
        view.caretTextColor = theme.cursorText
        view.selectedTextBackgroundColor = theme.selection
        view.font = preferredFont(size: 14)
        view.useBrightColors = true
        view.customBlockGlyphs = true
        view.antiAliasCustomBlockGlyphs = true
        view.optionAsMetaKey = true
        view.allowMouseReporting = true
        view.linkReporting = .implicit
        view.getTerminal().installPalette(colors: theme.palette256)
        view.needsDisplay = true
    }

    static func enableMetalIfAvailable(on view: TranscriptCapturingTerminalView) {
        #if canImport(MetalKit)
        if !view.isUsingMetalRenderer {
            view.metalBufferingMode = .perFrameAggregated
            try? view.setUseMetal(true)
        }
        #endif
    }

    private static func preferredFont(size: CGFloat) -> NSFont {
        for name in ["SFMono-Regular", "SF Mono", "Menlo-Regular", "Menlo"] {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func makePalette256(from palette16: [SwiftTerm.Color]) -> [SwiftTerm.Color] {
        var colors = palette16
        let cube: [UInt32] = [0x00, 0x5f, 0x87, 0xaf, 0xd7, 0xff]
        for r in cube {
            for g in cube {
                for b in cube {
                    colors.append(color((r << 16) | (g << 8) | b))
                }
            }
        }
        for i in 0..<24 {
            let c = UInt32(8 + i * 10)
            colors.append(color((c << 16) | (c << 8) | c))
        }
        return colors
    }

    private static func ns(_ rgb: UInt32, alpha: CGFloat = 1.0) -> NSColor {
        NSColor(red: CGFloat((rgb >> 16) & 0xff) / 255,
                green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255,
                alpha: alpha)
    }

    private static func color(_ rgb: UInt32) -> SwiftTerm.Color {
        let r = UInt16((rgb >> 16) & 0xff) * 257
        let g = UInt16((rgb >> 8) & 0xff) * 257
        let b = UInt16(rgb & 0xff) * 257
        return SwiftTerm.Color(red: r, green: g, blue: b)
    }
}
