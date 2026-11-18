import SwiftUI

@main
struct PointsEauApp: App {
    @StateObject private var donnees = Donnees()
    @StateObject private var position = Position()
    @StateObject private var jeu = Jeu()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(donnees)
                .environmentObject(position)
                .environmentObject(jeu)
                .task {
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("-demo") {
                        jeu.remplirDemo(points: donnees.points, recensement: donnees.recensement)
                    }
                    if arguments.contains("-victoire") {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        jeu.demoVictoire(points: donnees.points)
                    }
                    #endif
                    position.demarrer()
                }
                .onChange(of: phase) { _, nouvelle in
                    switch nouvelle {
                    case .active:
                        position.demarrer()
                        Task {
                            await donnees.rafraichir()
                            jeu.validerDefis(donnees.recensement)
                        }
                    case .background:
                        position.arreter()
                    default:
                        break
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var jeu: Jeu
    @State private var onglet = ContentView.ongletInitial

    /// Onglet de départ (argument « -onglet 1 » pour les captures d'écran, en mode Debug).
    static var ongletInitial: Int {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-onglet"), i + 1 < a.count { return Int(a[i + 1]) ?? 0 }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $onglet) {
            EcranCarte()
                .tabItem { Label("Carte", systemImage: "map.fill") }
                .tag(0)
            EcranDefis()
                .tabItem { Label("Défis", systemImage: "trophy.fill") }
                .tag(1)
            EcranCollection()
                .tabItem { Label("Collection", systemImage: "photo.stack.fill") }
                .tag(2)
        }
        .sheet(item: $jeu.celebration) { c in
            EcranVictoire(celebration: c)
                .presentationDetents([.large])
        }
    }
}
