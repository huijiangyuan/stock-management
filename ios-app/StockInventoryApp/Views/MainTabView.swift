import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("首页", systemImage: "house.fill") }
            SKUListView()
                .tabItem { Label("库存", systemImage: "shippingbox.fill") }
            OrderHistoryView()
                .tabItem { Label("单据", systemImage: "doc.plaintext.fill") }
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
        .accentColor(.brand)
        .preferredColorScheme(.dark)
    }
}
