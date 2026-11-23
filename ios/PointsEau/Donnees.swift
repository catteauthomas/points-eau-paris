import CoreLocation
import Foundation

/// Les points d'eau : copie embarquée dans l'appli, puis version du jour téléchargée depuis GitHub Pages
/// (mise à jour chaque matin par le workflow « Données »).
@MainActor
final class Donnees: ObservableObject {
    static let urlDistante = URL(string: "https://catteauthomas.github.io/points-eau-paris/data/points.json")!

    @Published private(set) var points: [PointEau] = []
    @Published private(set) var recensement = Recensement()
    @Published private(set) var genere = ""
    @Published private(set) var majFontaines: String?
    /// Fontaines coupées pour l'hiver en ce moment (0 hors saison : la pastille « Coupées l'hiver » disparaît).
    @Published private(set) var nbCoupeesHiver = 0
    private(set) var parId: [String: PointEau] = [:]

    private let cache: URL
    private var dernierEssai = Date.distantPast

    init(cache: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.cache = cache ?? support.appendingPathComponent("points.json")
        chargerLocal()
    }

    /// Le plus récent entre la copie embarquée et la dernière version téléchargée.
    func chargerLocal() {
        var meilleur: FichierDonnees?
        for url in [cache, Bundle.main.url(forResource: "points", withExtension: "json")].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url),
                  let f = try? JSONDecoder().decode(FichierDonnees.self, from: data) else { continue }
            if meilleur == nil || f.genere > meilleur!.genere { meilleur = f }
        }
        if let m = meilleur { appliquer(m) }
    }

    /// Télécharge la version du jour (au plus une fois par demi-heure).
    func rafraichir() async {
        guard Date().timeIntervalSince(dernierEssai) > 1800 else { return }
        dernierEssai = Date()
        let req = URLRequest(url: Self.urlDistante, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        guard let resultat = try? await URLSession.shared.data(for: req) else { return }
        let (data, rep) = resultat
        guard (rep as? HTTPURLResponse)?.statusCode == 200,
              let f = try? JSONDecoder().decode(FichierDonnees.self, from: data),
              f.points.count > 1000, f.genere > genere else { return }
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
        appliquer(f)
    }

    private func appliquer(_ f: FichierDonnees) {
        points = f.points.filter { $0.categorie != .commerce }
        parId = Dictionary(points.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        recensement = Recensement(points: points)
        nbCoupeesHiver = points.filter(\.coupeeHiver).count
        genere = f.genere
        majFontaines = f.sources["fontaines"]?.maj ?? f.sources["fontaines"]?.date
    }

    /// « 16/11/2026 » : date de l'état des fontaines Eau de Paris.
    var majTexte: String {
        guard let m = majFontaines, m.count >= 10 else { return "" }
        let p = m.prefix(10).split(separator: "-")
        return p.count == 3 ? "\(p[2])/\(p[1])/\(p[0])" : ""
    }

    /// Fontaine en service la plus proche (la nuit, seulement celles qui sont accessibles).
    func plusProche(de l: CLLocation, filtre: (PointEau) -> Bool = { _ in true }) -> (PointEau, CLLocationDistance)? {
        let nuit = Geo.estLaNuit()
        return Calcul.plusProche(de: l, parmi: points) { $0.estFontaine && $0.ok && (!nuit || $0.ouvertLaNuit) && filtre($0) }
    }
}

enum Calcul {
    static func plusProche(de l: CLLocation, parmi points: [PointEau],
                           filtre: (PointEau) -> Bool) -> (PointEau, CLLocationDistance)? {
        var meilleur: (PointEau, CLLocationDistance)?
        for p in points where filtre(p) {
            let d = l.distance(from: p.position)
            if meilleur == nil || d < meilleur!.1 { meilleur = (p, d) }
        }
        return meilleur
    }
}
