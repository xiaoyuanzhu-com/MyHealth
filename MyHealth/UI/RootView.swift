import SwiftUI

struct RootView: View {
    @EnvironmentObject var sessionStore: SessionStore
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        if hasSeenOnboarding {
            ContentView()
        } else {
            OnboardingView(onDone: { hasSeenOnboarding = true })
        }
    }
}
