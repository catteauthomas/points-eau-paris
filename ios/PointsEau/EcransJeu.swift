import SwiftUI

/// En-tête commun : niveau, points, avancement vers le niveau suivant.
struct CarteNiveau: View {
    @EnvironmentObject private var jeu: Jeu

    var body: some View {
        let n = jeu.niveau
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Niveau \(n.rang)").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    Text(n.nom).font(.title2.bold()).foregroundStyle(.white)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(jeu.total)").font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                    Text("points").font(.caption).foregroundStyle(.white.opacity(0.85))
                }
            }
            ProgressView(value: min(max(n.avancement(jeu.total), 0), 1))
                .tint(.white)
            if let s = n.suivant {
                Text("Encore \(s - jeu.total) points pour « \(Niveau.pour(s).nom) »")
                    .font(.caption).foregroundStyle(.white.opacity(0.9))
            } else {
                Text("Niveau maximum. Respect.").font(.caption).foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.7), .teal],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Défis

struct EcranDefis: View {
    @EnvironmentObject private var jeu: Jeu
    @EnvironmentObject private var donnees: Donnees

    var body: some View {
        NavigationStack {
            let c = jeu.contexte(donnees.recensement)
            List {
                Section {
                    CarteNiveau()
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                ForEach(Defi.Groupe.allCases, id: \.self) { g in
                    Section(g.rawValue) {
                        ForEach(lignes(g, c)) { l in
                            LigneDefi(defi: l.defi, fait: l.fait, objectif: l.objectif, reussi: jeu.defisReussis[l.defi.id])
                        }
                    }
                }
            }
            .navigationTitle("Défis")
        }
    }

    struct Ligne: Identifiable {
        let defi: Defi
        let fait: Int
        let objectif: Int
        var id: String { defi.id }
        var part: Double { Double(fait) / Double(max(objectif, 1)) }
    }

    /// Défis du groupe : réussis en bas ; pour les arrondissements, les plus avancés en premier.
    private func lignes(_ g: Defi.Groupe, _ c: Contexte) -> [Ligne] {
        let toutes = Defi.tous.filter { $0.groupe == g }
            .map { d -> Ligne in
                let m = d.mesure(c)
                return Ligne(defi: d, fait: min(m.fait, m.objectif), objectif: m.objectif)
            }
            .filter { $0.objectif > 0 }
        let aFaire = toutes.filter { jeu.defisReussis[$0.id] == nil }
        let faits = toutes.filter { jeu.defisReussis[$0.id] != nil }
        let tries = g == .arrondissements ? aFaire.sorted { $0.part > $1.part } : aFaire
        return tries + faits
    }
}

struct LigneDefi: View {
    let defi: Defi
    let fait: Int
    let objectif: Int
    let reussi: Date?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: defi.symbole)
                .font(.headline)
                .foregroundStyle(reussi != nil ? Color.white : Color.accentColor)
                .frame(width: 40, height: 40)
                .background(reussi != nil ? Color(StyleMarqueur.or) : Color.accentColor.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(defi.titre).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("+\(defi.bonus)").font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(reussi != nil ? Color(StyleMarqueur.or) : .secondary)
                }
                Text(defi.detail).font(.caption).foregroundStyle(.secondary)
                if let r = reussi {
                    Text("Réussi le \(r.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Color(StyleMarqueur.or))
                } else if objectif > 1 {
                    HStack(spacing: 8) {
                        ProgressView(value: Double(fait), total: Double(objectif))
                        Text("\(fait)/\(objectif)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .opacity(reussi != nil ? 0.75 : 1)
    }
}

// MARK: - Collection

struct EcranCollection: View {
    @EnvironmentObject private var jeu: Jeu
    @EnvironmentObject private var donnees: Donnees
    @State private var apropos = false
    @State private var photoOuverte: Visite?

    private let colonnes = [GridItem(.adaptive(minimum: 104), spacing: 6)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    CarteNiveau()
                    toutParis
                    arrondissements
                    album
                }
                .padding(16)
            }
            .navigationTitle("Collection")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        apropos = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("À propos et règles")
                }
            }
            .sheet(isPresented: $apropos) { APropos() }
            .sheet(item: $photoOuverte) { v in DetailVisite(visite: v).presentationDetents([.large]) }
        }
    }

    private var toutParis: some View {
        let c = jeu.contexte(donnees.recensement)
        let total = max(donnees.recensement.totalParis, 1)
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 10)
                Circle().trim(from: 0, to: CGFloat(c.nbParis) / CGFloat(total))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.1f %%", 100 * Double(c.nbParis) / Double(total)).replacingOccurrences(of: ".", with: ","))
                    .font(.caption.weight(.bold).monospacedDigit())
            }
            .frame(width: 74, height: 74)
            VStack(alignment: .leading, spacing: 3) {
                Text("Objectif : tout Paris").font(.headline)
                Text("\(c.nbParis) fontaine\(c.nbParis > 1 ? "s" : "") sur \(donnees.recensement.totalParis) dans les 20 arrondissements")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("\(jeu.defisReussis.count) défi\(jeu.defisReussis.count > 1 ? "s" : "") réussi\(jeu.defisReussis.count > 1 ? "s" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var arrondissements: some View {
        let c = jeu.contexte(donnees.recensement)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Arrondissements").font(.title3.bold())
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
                ForEach(1...20, id: \.self) { n in
                    let fait = c.parArrondissement[n] ?? 0
                    let total = max(donnees.recensement.parArrondissement[n] ?? 0, 1)
                    let part = min(Double(fait) / Double(total), 1)
                    VStack(spacing: 3) {
                        Text(Geo.arrondissement(n)).font(.subheadline.weight(.bold))
                        Text("\(fait)/\(total)").font(.caption2.monospacedDigit())
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(part >= 1 ? Color.white : Color.primary)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(part >= 1 ? Color(StyleMarqueur.or) : Color.accentColor.opacity(0.08 + 0.5 * part))
                    }
                }
            }
        }
    }

    @ViewBuilder private var album: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tes photos").font(.title3.bold())
            if jeu.visites.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "camera.viewfinder").font(.largeTitle).foregroundStyle(Color.accentColor)
                    Text("Aucune fontaine pour l'instant").font(.headline)
                    Text("Va jusqu'à une fontaine, et quand tu y es, prends-la en photo depuis la carte pour gagner tes premiers points.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                LazyVGrid(columns: colonnes, spacing: 6) {
                    ForEach(jeu.visitesTriees) { v in
                        Button {
                            photoOuverte = v
                        } label: {
                            Vignette(visite: v)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

struct Vignette: View {
    let visite: Visite
    @EnvironmentObject private var jeu: Jeu

    var body: some View {
        Color.accentColor.opacity(0.1)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let i = jeu.vignette(visite) {
                    Image(uiImage: i).resizable().scaledToFill()
                } else {
                    Image(systemName: "drop.fill").foregroundStyle(Color.accentColor)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text("+\(visite.pts)")
                    .font(.caption2.weight(.heavy))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .foregroundStyle(.white)
                    .background(Rarete(points: visite.pts).couleur, in: Capsule())
                    .padding(5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel("\(visite.type), \(visite.date.formatted(date: .abbreviated, time: .omitted))")
    }
}

struct DetailVisite: View {
    let visite: Visite
    @EnvironmentObject private var jeu: Jeu
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let i = jeu.photo(visite) {
                        Image(uiImage: i).resizable().scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    Text(visite.type).font(.title2.bold())
                    Text("\(visite.ar == 0 ? "Hors Paris" : "Paris " + Geo.arrondissement(visite.ar)) · \(Rarete(points: visite.pts).nom) · +\(visite.pts) points")
                        .foregroundStyle(.secondary)
                    Text("Collectée le \(visite.date.formatted(date: .complete, time: .shortened))")
                        .font(.subheadline)
                    if let i = jeu.photo(visite) {
                        ShareLink(item: Image(uiImage: i), preview: SharePreview(visite.type, image: Image(uiImage: i))) {
                            Label("Partager la photo", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
        }
    }
}

// MARK: - À propos

struct APropos: View {
    @EnvironmentObject private var donnees: Donnees
    @EnvironmentObject private var jeu: Jeu
    @Environment(\.dismiss) private var dismiss
    @State private var confirmer = false

    var body: some View {
        NavigationStack {
            List {
                Section("Comment jouer") {
                    Label("Va jusqu'à une fontaine : quand tu es à moins de \(Int(Regles.rayon)) m, un bouton apparaît pour la prendre en photo.",
                          systemImage: "figure.walk")
                    Label("Chaque fontaine photographiée te rapporte des points selon sa rareté, une seule fois.", systemImage: "star.fill")
                    Label("Les défis donnent des bonus. L'objectif ultime : toutes les fontaines des 20 arrondissements.",
                          systemImage: "trophy.fill")
                    Label("De 21 h à 7 h, la carte ne montre que les points accessibles : les fontaines des parcs, squares et cimetières sont fermées la nuit.",
                          systemImage: "moon.stars.fill")
                }
                Section("Points par fontaine") {
                    ligne("Fontaine à boire, borne, robinet", 10, .commune)
                    ligne("Arceau, Totem, 2 en 1", 15, .peuCommune)
                    ligne("Wallace", 20, .peuCommune)
                    ligne("Poing d'eau", 40, .rare)
                    ligne("Pétillante", 50, .rare)
                    ligne("Millénaire", 75, .legendaire)
                    ligne("Albien", 100, .legendaire)
                }
                Section("Données") {
                    Text("Fontaines et état du jour : Eau de Paris / Ville de Paris (Open Data Paris, licence ODbL)\(donnees.majTexte.isEmpty ? "" : ", données du " + donnees.majTexte).")
                    Text("Points d'eau complémentaires : © contributeurs OpenStreetMap (licence ODbL).")
                    Text("Fond de carte : Apple Plans.")
                }
                .font(.footnote)
                Section("Vie privée") {
                    Text("Ta position et tes photos restent sur ton téléphone. L'appli n'a ni compte, ni publicité, ni statistiques : elle télécharge seulement la liste des points d'eau du jour.")
                        .font(.footnote)
                    Link("Politique de confidentialité", destination: URL(string: "https://catteauthomas.github.io/points-eau-paris/confidentialite.html")!)
                    Link("Aide et contact", destination: URL(string: "https://catteauthomas.github.io/points-eau-paris/")!)
                }
                Section {
                    Button("Effacer ma partie", role: .destructive) { confirmer = true }
                        .disabled(jeu.visites.isEmpty)
                }
            }
            .navigationTitle("À propos")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } }
            }
            .confirmationDialog("Effacer toutes tes fontaines, tes photos et tes défis ?", isPresented: $confirmer,
                                titleVisibility: .visible) {
                Button("Tout effacer", role: .destructive) { jeu.toutEffacer() }
            }
        }
    }

    private func ligne(_ titre: String, _ pts: Int, _ r: Rarete) -> some View {
        HStack {
            Text(titre)
            Spacer()
            Text(r.nom).font(.caption).foregroundStyle(.secondary)
            PastillePoints(points: pts, couleur: r.couleur)
        }
    }
}
