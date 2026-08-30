import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FreeFireFeaturesView()
                .tabItem {
                    Label("Free Fire", systemImage: "flame.fill")
                }
                .tag(0)

            PatchProjectsView()
                .tabItem {
                    Label("Patch", systemImage: "shippingbox.fill")
                }
                .tag(1)
        }
        .tint(Color(red: 1.0, green: 0.72, blue: 0.05))
        .preferredColorScheme(.dark)
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil {
                selectedTab = 1
            }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil {
                selectedTab = 1
            }
        }
    }
}
