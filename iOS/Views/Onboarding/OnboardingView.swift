import SwiftUI

/// First launch. It says what this app is for in the first sentence, because
/// the answer — spoofing the location your iPhone reports — is the whole
/// reason it exists, and a user who does not know that cannot use it.
struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PreferenceKey.didCompleteOnboarding) private var didComplete = false
    @State private var page = 0

    private let pages = OnboardingPage.all

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, item in
                    OnboardingPageView(page: item)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            footer
        }
        .background(backdrop)
        .interactiveDismissDisabled()
    }

    private var backdrop: some View {
        LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.clear],
                       startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
            .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Color.accentColor : Color.secondary.opacity(0.28))
                        .frame(width: index == page ? 22 : 7, height: 7)
                        .animation(.spring(response: 0.34, dampingFraction: 0.78), value: page)
                }
            }
            .accessibilityHidden(true)

            Button {
                if page < pages.count - 1 {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { page += 1 }
                } else {
                    didComplete = true
                    dismiss()
                }
            } label: {
                Text(page < pages.count - 1 ? "Continue" : "Start Spoofing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .glassButton(prominent: true)
            .controlSize(.large)

            Button("Skip") {
                didComplete = true
                dismiss()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .opacity(page < pages.count - 1 ? 1 : 0)
            .accessibilityHidden(page == pages.count - 1)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

struct OnboardingPage: Identifiable {
    var symbol: String
    var title: String
    var body: String
    var bullets: [String] = []
    var isWarning = false

    var id: String { title }

    static let all: [OnboardingPage] = [
        OnboardingPage(
            symbol: "location.slash.fill",
            title: "This app spoofs your location",
            body: """
            That is what it is for. You pick a point anywhere on Earth and your \
            iPhone reports being there instead of where it actually is.
            """,
            bullets: [
                "Stand in Tokyo without leaving the sofa",
                "Walk a route at a speed you choose",
                "Put the real GPS back with one tap"
            ]),

        OnboardingPage(
            symbol: "iphone.gen3.radiowaves.left.and.right",
            title: "Two modes, and they differ",
            body: """
            On its own, this app spoofs the location inside itself — useful for \
            trying a route out. Paired with the Mac companion, it spoofs the \
            whole phone.
            """,
            bullets: [
                "In-app only: nothing outside Dissappear is affected",
                "With the Mac companion: every app on the phone sees it, Maps and Find My included",
                "Device-wide spoofing needs the Mac plugged in and awake"
            ]),

        OnboardingPage(
            symbol: "laptopcomputer.and.iphone",
            title: "Pair the Mac to go device-wide",
            body: """
            Run Dissappear Companion on a Mac on the same network. It finds \
            itself; you type the pairing code it shows once.
            """,
            bullets: [
                "Open Remote in this app and pick your Mac",
                "Enter the eight-character pairing code",
                "Away from home, put both on a mesh VPN such as Tailscale"
            ]),

        OnboardingPage(
            symbol: "exclamationmark.shield.fill",
            title: "Where this is not fair game",
            body: """
            Device-wide spoofing goes through Apple's own developer service, so \
            it is visible to whoever holds the phone — never hidden from them.
            """,
            bullets: [
                "Do not spoof a phone that is not yours",
                "Lying about your location can breach an app's terms, or a law",
                "Emergency services read the real GPS, not this — but clear the spoof anyway"
            ],
            isWarning: true)
    ]
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: page.symbol)
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(page.isWarning ? Color.orange : Color.accentColor)
                    .padding(.top, 36)
                    .accessibilityHidden(true)

                Text(page.title)
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)

                Text(page.body)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !page.bullets.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(page.bullets, id: \.self) { bullet in
                            HStack(alignment: .firstTextBaseline, spacing: 11) {
                                Image(systemName: page.isWarning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                                    .foregroundStyle(page.isWarning ? Color.orange : Color.accentColor)
                                    .imageScale(.medium)
                                Text(bullet)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassPanel(cornerRadius: 20)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}
