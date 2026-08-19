import SwiftUI
import SwiftData

@main
struct StockInventoryAppApp: App {
    let container: ModelContainer

    init() {
        container = StockModelContainer.create()
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .modelContainer(container)
                .environment(\.locale, Locale(identifier: "zh_CN"))
        }
    }
}
