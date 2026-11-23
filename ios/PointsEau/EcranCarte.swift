import MapKit
import SwiftUI

struct EcranCarte: View {
    @EnvironmentObject private var donnees: Donnees
    @EnvironmentObject private var position: Position
    @EnvironmentObject private var jeu: Jeu

    @State private var filtres = Filtres()
    @State private var selection: PointEau?
    @State private var aPhotographier: PointEau?
    @State private var route: MKRoute?
    @State private var routeVers: PointEau?
    @State private var commande: Commande?
    @State private var suivi: MKUserTrackingMode = .none
    @State private var calculEnCours = false
    @State private var alerte: String?
    @State private var centreSurMoi = false

    var body: some View {
        ZStack {
            CarteView(points: donnees.points, genere: donnees.genere, filtres: filtres, collectees: Set(jeu.visites.keys),
                      route: route, commande: commande,
                      onSelect: { selection = $0 }, onSuivi: { suivi = $0 })
                .ignoresSafeArea(edges: .top)

            VStack(spacing: 10) {
                BarreFiltres(filtres: $filtres, hiver: donnees.nbCoupeesHiver > 0)
                Spacer()
                HStack {
                    Spacer()
                    boutonPosition
                }
                bandeau
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .sheet(item: $selection) { p in
            FichePoint(point: p,
                       onItineraire: { allerA(p) },
                       onPhoto: { photographier(p) })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $aPhotographier) { p in
            AppareilPhoto { image in
                aPhotographier = nil
                guard let image else { return }
                guard let l = position.location, Regles.aPortee(p, depuis: l) else {
                    alerte = "Tu t'es éloigné de la fontaine pendant la photo. Reviens à moins de \(Int(Regles.rayon)) m et réessaie."
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    jeu.collecter(p, image: image, recensement: donnees.recensement)
                    if routeVers?.id == p.id { arreterRoute() }
                }
            }
            .ignoresSafeArea()
        }
        .onAppear {
            centrerAuDebut(position.location)
            #if DEBUG
            // Captures d'écran : « -fiche <id> » ouvre la fiche d'un point d'eau
            let a = ProcessInfo.processInfo.arguments
            if let i = a.firstIndex(of: "-fiche"), i + 1 < a.count, let p = donnees.parId[a[i + 1]] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { selection = p }
            }
            #endif
        }
        .onChange(of: position.location) { _, l in centrerAuDebut(l) }
        .alert("Pas tout à fait", isPresented: Binding(get: { alerte != nil }, set: { if !$0 { alerte = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alerte ?? "")
        }
    }

    // MARK: Bouton « ma position »

    private var boutonPosition: some View {
        Button {
            commande = Commande(action: .suivre(boussole: suivi == .follow))
        } label: {
            Image(systemName: suivi == .followWithHeading ? "location.north.line.fill" : (suivi == .follow ? "location.fill" : "location"))
                .font(.title3.weight(.semibold))
                .frame(width: 48, height: 48)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        }
        .accessibilityLabel("Ma position")
    }

    // MARK: Bandeau du bas

    /// Fontaine pas encore collectée, assez proche pour être prise en photo maintenant.
    private func collectable(_ l: CLLocation) -> PointEau? {
        guard let (p, _) = Calcul.plusProche(de: l, parmi: donnees.points, filtre: { $0.estFontaine && !jeu.estCollectee($0.id) }),
              Regles.aPortee(p, depuis: l) else { return nil }
        return p
    }

    @ViewBuilder private var bandeau: some View {
        if let l = position.location {
            if let p = collectable(l) {
                BandeauCollecte(point: p, distance: l.distance(from: p.position)) { photographier(p) }
            } else if let r = route, let dest = routeVers {
                BandeauRoute(point: dest, route: r, distance: l.distance(from: dest.position)) { arreterRoute() }
            } else if !Geo.estAParis(l) {
                Carte {
                    Label("Tu n'es pas à Paris : la carte montre les points d'eau de Paris et des communes voisines.",
                          systemImage: "info.circle")
                        .font(.subheadline)
                }
            } else if let (p, d) = donnees.plusProche(de: l) {
                BandeauProche(point: p, distance: d, collectee: jeu.estCollectee(p.id),
                              prochaine: prochaineACollecter(l, sauf: p.id),
                              calculEnCours: calculEnCours,
                              onTap: { selection = p },
                              onAller: { allerA(p) },
                              onProchaine: { q in selection = q })
            }
        } else if position.refusee {
            Carte {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Localisation désactivée", systemImage: "location.slash.fill").font(.headline)
                    Text("Sans ta position, l'appli ne peut pas trouver la fontaine la plus proche ni valider tes photos.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Ouvrir les Réglages") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        } else {
            Carte {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Recherche de ta position…").font(.subheadline)
                }
            }
        }
    }

    private func prochaineACollecter(_ l: CLLocation, sauf id: String) -> (PointEau, CLLocationDistance)? {
        let nuit = Geo.estLaNuit()
        return Calcul.plusProche(de: l, parmi: donnees.points) {
            $0.estFontaine && $0.ok && $0.id != id && !jeu.estCollectee($0.id) && (!nuit || $0.ouvertLaNuit)
        }
    }

    // MARK: Actions

    /// Au premier point GPS (à Paris), la carte zoome sur toi et te suit.
    private func centrerAuDebut(_ l: CLLocation?) {
        guard !centreSurMoi, let l else { return }
        centreSurMoi = true
        guard Geo.estAParis(l) else { return }
        commande = Commande(action: .centrer(lat: l.coordinate.latitude, lon: l.coordinate.longitude, metres: 900, suivre: true))
    }

    private func photographier(_ p: PointEau) {
        guard let l = position.location, Regles.aPortee(p, depuis: l) else {
            alerte = "Approche-toi à moins de \(Int(Regles.rayon)) m de la fontaine pour la prendre en photo."
            return
        }
        if selection != nil {
            selection = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { aPhotographier = p }
        } else {
            aPhotographier = p
        }
    }

    private func allerA(_ p: PointEau) {
        selection = nil
        guard position.location != nil else {
            Itineraire.ouvrirDansPlans(p)
            return
        }
        calculEnCours = true
        Itineraire.calculer(vers: p) { r in
            calculEnCours = false
            if let r {
                routeVers = p
                route = r
            } else {
                Itineraire.ouvrirDansPlans(p)
            }
        }
    }

    private func arreterRoute() {
        route = nil
        routeVers = nil
    }
}

enum Itineraire {
    static func calculer(vers p: PointEau, fin: @escaping (MKRoute?) -> Void) {
        let req = MKDirections.Request()
        req.source = MKMapItem.forCurrentLocation()
        req.destination = MKMapItem(placemark: MKPlacemark(coordinate: p.coordonnee))
        req.transportType = .walking
        MKDirections(request: req).calculate { rep, _ in
            DispatchQueue.main.async { fin(rep?.routes.first) }
        }
    }

    static func ouvrirDansPlans(_ p: PointEau) {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: p.coordonnee))
        item.name = p.titre
        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
    }
}

// MARK: - Éléments du bandeau

/// Fond commun des bandeaux.
struct Carte<Contenu: View>: View {
    @ViewBuilder var contenu: Contenu

    var body: some View {
        contenu
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

struct PastillePoints: View {
    let points: Int
    let couleur: Color

    var body: some View {
        Text("+\(points)")
            .font(.subheadline.weight(.heavy).monospacedDigit())
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(.white)
            .background(couleur, in: Capsule())
    }
}

struct BandeauCollecte: View {
    let point: PointEau
    let distance: CLLocationDistance
    var onPhoto: () -> Void

    var body: some View {
        Carte {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Tu es à une fontaine !").font(.headline)
                    Spacer()
                    PastillePoints(points: point.points, couleur: point.rarete.couleur)
                }
                Text("\(point.titre) · \(point.rarete.nom.lowercased()) · \(Geo.distance(distance))")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(action: onPhoto) {
                    Label("Prendre en photo", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(point.rarete.couleur)
            }
        }
    }
}

struct BandeauProche: View {
    let point: PointEau
    let distance: CLLocationDistance
    let collectee: Bool
    let prochaine: (PointEau, CLLocationDistance)?
    let calculEnCours: Bool
    var onTap: () -> Void
    var onAller: () -> Void
    var onProchaine: (PointEau) -> Void

    var body: some View {
        Carte {
            VStack(alignment: .leading, spacing: 10) {
                Button(action: onTap) {
                    HStack(spacing: 12) {
                        Image(systemName: "drop.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.accentColor, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Fontaine la plus proche").font(.caption).foregroundStyle(.secondary)
                            Text(point.titre).font(.headline).lineLimit(1)
                            Text("\(Geo.distance(distance)) · \(Geo.marche(distance)) à pied")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    Button(action: onAller) {
                        Group {
                            if calculEnCours {
                                ProgressView()
                            } else {
                                Label("Y aller", systemImage: "figure.walk")
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    if let (q, d) = prochaine {
                        Button {
                            onProchaine(q)
                        } label: {
                            Label("Collecter · \(Geo.distance(d))", systemImage: "camera.viewfinder")
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
}

struct BandeauRoute: View {
    let point: PointEau
    let route: MKRoute
    let distance: CLLocationDistance
    var onArreter: () -> Void

    var body: some View {
        Carte {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("En route vers").font(.caption).foregroundStyle(.secondary)
                    Text(point.titre).font(.headline).lineLimit(1)
                    Text("\(Geo.distance(distance)) · environ \(max(1, Int((route.expectedTravelTime / 60).rounded()))) min")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onArreter) {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.secondary)
                }
                .accessibilityLabel("Arrêter l'itinéraire")
            }
        }
    }
}

// MARK: - Filtres

struct BarreFiltres: View {
    @Binding var filtres: Filtres
    /// Des fontaines sont coupées pour l'hiver : on propose de les masquer.
    var hiver = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Pastille(titre: "Fontaines", symbole: "drop.fill", couleur: .blue, actif: $filtres.fontaines)
                Pastille(titre: "Pétillantes", symbole: "bubbles.and.sparkles.fill", couleur: .purple, actif: $filtres.petillantes)
                Pastille(titre: "Ouvertes la nuit", symbole: "moon.stars.fill", couleur: .indigo, actif: $filtres.nuit)
                Pastille(titre: "Collectées", symbole: "checkmark", couleur: Color(StyleMarqueur.or), actif: $filtres.collectees)
                if hiver {
                    Pastille(titre: "Coupées l'hiver", symbole: "snowflake", couleur: Color(StyleMarqueur.glace), actif: $filtres.gel)
                }
                Pastille(titre: "Hors service", symbole: "xmark", couleur: .gray, actif: $filtres.horsService)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
    }
}

struct Pastille: View {
    let titre: String
    let symbole: String
    let couleur: Color
    @Binding var actif: Bool

    var body: some View {
        Button {
            actif.toggle()
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Label(titre, systemImage: symbole)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(actif ? Color.white : Color.primary)
                .background {
                    if actif {
                        Capsule().fill(couleur)
                    } else {
                        Capsule().fill(.regularMaterial)
                    }
                }
                .shadow(color: .black.opacity(0.1), radius: 4, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(actif ? .isSelected : [])
    }
}
