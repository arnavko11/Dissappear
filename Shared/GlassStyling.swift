import SwiftUI

/// Liquid Glass surfaces, with a material fallback.
///
/// The glass APIs arrived in the macOS 26 / iOS 26 SDK, so they are guarded
/// twice: `#if compiler(>=6.2)` keeps the code compiling on older toolchains,
/// and the availability check keeps it correct on older systems at runtime.
public extension View {
    /// A floating panel, the way the current Maps places its controls over the map.
    func glassPanel(cornerRadius: CGFloat = 16, interactive: Bool = false) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, interactive: interactive))
    }

    /// A pill-shaped control cluster.
    func glassCapsule(interactive: Bool = false) -> some View {
        modifier(GlassCapsule(interactive: interactive))
    }

    /// Glass button styling where available, bordered otherwise.
    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }
}

private struct GlassPanel: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular,
                                in: .rect(cornerRadius: cornerRadius))
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.5)))
    }
}

private struct GlassCapsule: ViewModifier {
    let interactive: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    private func fallback(_ content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator.opacity(0.5)))
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            if prominent {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.glass)
            }
        } else {
            fallback(content)
        }
        #else
        fallback(content)
        #endif
    }

    @ViewBuilder
    private func fallback(_ content: Content) -> some View {
        if prominent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Groups nearby glass shapes so they blend and morph as one, instead of
/// reading as separate panes stacked on the map.
public struct GlassGroup<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
        #else
        content
        #endif
    }
}
