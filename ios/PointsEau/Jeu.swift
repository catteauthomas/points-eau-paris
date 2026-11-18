import CoreLocation
import SwiftUI
import UIKit

// MARK: - Règles du jeu

enum Regles {
    /// Distance maximale entre toi et la fontaine pour pouvoir la collecter.
    static let rayon: CLLocationDistance = 40
    /// Au-delà de cette imprécision GPS, on ne valide pas (sous un pont, dans le métro…).
    static let precisionMax: CLLocationAccuracy = 65

    /// Peut-on collecter ce point depuis cette position ? (marge = une partie de l'imprécision du GPS)
    static func aPortee(_ p: PointEau, depuis l: CLLocation) -> Bool {
        guard p.estFontaine, l.horizontalAccuracy >= 0, l.horizontalAccuracy <= precisionMax else { return false }
        return l.distance(from: p.position) <= rayon + min(l.horizontalAccuracy, 25)
    }
}

struct Niveau: Equatable {
    let rang: Int
    let nom: String
    let seuil: Int
    let suivant: Int?

    static let paliers: [(String, Int)] = [
        ("Goutte", 0), ("Flaque", 100), ("Ruisseau", 300), ("Rivière", 800), ("Canal Saint-Martin", 2000),
        ("La Seine", 5000), ("Fontainier de Paris", 10000), ("Légende des fontaines", 20000),
    ]

    static func pour(_ points: Int) -> Niveau {
        var i = 0
        for (k, palier) in paliers.enumerated() where points >= palier.1 { i = k }
        let suivant = i + 1 < paliers.count ? paliers[i + 1].1 : nil
        return Niveau(rang: i + 1, nom: paliers[i].0, seuil: paliers[i].1, suivant: suivant)
    }

    /// Avancement vers le niveau suivant, entre 0 et 1.
    func avancement(_ points: Int) -> Double {
        guard let s = suivant else { return 1 }
        return Double(points - seuil) / Double(s - seuil)
    }
}

// MARK: - Défis

/// Ce que le joueur a fait, résumé pour évaluer les défis.
struct Contexte {
    let visites: [Visite]
    let recensement: Recensement
    let parType: [String: Int]
    let parArrondissement: [Int: Int]
    let nbParis: Int
    let petillantes: Int
    let maxParJour: Int
    let serie: Int

    init(visites: [Visite], recensement: Recensement, calendrier: Calendar = .current) {
        self.visites = visites
        self.recensement = recensement
        var types: [String: Int] = [:]
        var ars: [Int: Int] = [:]
        var jours: [Date: Int] = [:]
        var paris = 0
        var bulles = 0
        for v in visites {
            types[v.type, default: 0] += 1
            if (1...20).contains(v.ar) {
                ars[v.ar, default: 0] += 1
                paris += 1
            }
            if v.cat == Categorie.petillante.rawValue { bulles += 1 }
            jours[calendrier.startOfDay(for: v.date), default: 0] += 1
        }
        parType = types
        parArrondissement = ars
        nbParis = paris
        petillantes = bulles
        maxParJour = jours.values.max() ?? 0
        var meilleure = 0
        var courante = 0
        var veille: Date?
        for j in jours.keys.sorted() {
            if let v = veille, calendrier.date(byAdding: .day, value: 1, to: v) == j {
                courante += 1
            } else {
                courante = 1
            }
            meilleure = max(meilleure, courante)
            veille = j
        }
        serie = meilleure
    }

    func heures(_ test: (Int) -> Bool) -> Int {
        visites.contains { test(Calendar.current.component(.hour, from: $0.date)) } ? 1 : 0
    }

    func mois(_ liste: Set<Int>) -> Int {
        visites.contains { liste.contains(Calendar.current.component(.month, from: $0.date)) } ? 1 : 0
    }
}

struct Defi: Identifiable {
    enum Groupe: String, CaseIterable {
        case collection = "Collection"
        case rares = "Fontaines rares"
        case arrondissements = "Arrondissements"
        case rythme = "Rythme"
    }

    let id: String
    let groupe: Groupe
    let titre: String
    let detail: String
    let symbole: String
    let bonus: Int
    /// (fait, objectif). Un objectif à 0 = défi impossible avec les données actuelles (masqué).
    let mesure: (Contexte) -> (fait: Int, objectif: Int)

    static let typesOfficiels = [
        "Fontaine à boire", "Borne-fontaine", "Fontaine 2 en 1", "Fontaine Arceau", "Fontaine Totem",
        "Fontaine Wallace", "Fontaine Poing d'eau", "Fontaine pétillante", "Fontaine du Millénaire", "Fontaine à l'albien",
    ]

    static let tous: [Defi] = {
        var d: [Defi] = [
            Defi(id: "premiere", groupe: .collection, titre: "Première gorgée", detail: "Prends ta première fontaine en photo.",
                 symbole: "drop.fill", bonus: 20) { c in (c.visites.count, 1) },
            Defi(id: "c10", groupe: .collection, titre: "Petite soif", detail: "Collecte 10 fontaines.",
                 symbole: "10.circle.fill", bonus: 50) { c in (c.visites.count, 10) },
            Defi(id: "c50", groupe: .collection, titre: "Grande soif", detail: "Collecte 50 fontaines.",
                 symbole: "50.circle.fill", bonus: 150) { c in (c.visites.count, 50) },
            Defi(id: "c100", groupe: .collection, titre: "Centenaire", detail: "Collecte 100 fontaines.",
                 symbole: "medal.fill", bonus: 300) { c in (c.visites.count, 100) },
            Defi(id: "c250", groupe: .collection, titre: "Chasseur de sources", detail: "Collecte 250 fontaines.",
                 symbole: "scope", bonus: 600) { c in (c.visites.count, 250) },
            Defi(id: "c500", groupe: .collection, titre: "Hydratation maximale", detail: "Collecte 500 fontaines.",
                 symbole: "flame.fill", bonus: 1200) { c in (c.visites.count, 500) },
            Defi(id: "c1000", groupe: .collection, titre: "Mille sources", detail: "Collecte 1 000 fontaines.",
                 symbole: "sparkles", bonus: 2500) { c in (c.visites.count, 1000) },
            Defi(id: "toutparis", groupe: .collection, titre: "Tout Paris",
                 detail: "Collecte toutes les fontaines des 20 arrondissements. Le défi ultime.",
                 symbole: "crown.fill", bonus: 5000) { c in (c.nbParis, c.recensement.totalParis) },

            Defi(id: "wallace1", groupe: .rares, titre: "Merci Monsieur Wallace",
                 detail: "Trouve une fontaine Wallace, le symbole de Paris depuis 1872.",
                 symbole: "building.columns.fill", bonus: 20) { c in (c.parType["Fontaine Wallace"] ?? 0, 1) },
            Defi(id: "wallace25", groupe: .rares, titre: "Collection Wallace", detail: "Collecte 25 fontaines Wallace.",
                 symbole: "building.columns.fill", bonus: 250) { c in (c.parType["Fontaine Wallace"] ?? 0, 25) },
            Defi(id: "wallaceTout", groupe: .rares, titre: "Toutes les Wallace", detail: "Collecte toutes les fontaines Wallace.",
                 symbole: "building.columns.circle.fill", bonus: 1500) { c in
                (c.parType["Fontaine Wallace"] ?? 0, c.recensement.parType["Fontaine Wallace"] ?? 0)
            },
            Defi(id: "petillante1", groupe: .rares, titre: "Ça pétille",
                 detail: "Trouve une fontaine pétillante : eau plate ou gazeuse, gratuite.",
                 symbole: "bubbles.and.sparkles.fill", bonus: 50) { c in (c.petillantes, 1) },
            Defi(id: "petillanteTout", groupe: .rares, titre: "Bulles de Paris", detail: "Collecte toutes les fontaines pétillantes.",
                 symbole: "bubbles.and.sparkles.fill", bonus: 500) { c in (c.petillantes, c.recensement.petillantes) },
            Defi(id: "albien", groupe: .rares, titre: "Venue des profondeurs",
                 detail: "Les fontaines à l'albien puisent une eau à 600 m sous Paris. Trouve-les toutes.",
                 symbole: "arrow.down.to.line", bonus: 300) { c in
                (c.parType["Fontaine à l'albien"] ?? 0, c.recensement.parType["Fontaine à l'albien"] ?? 0)
            },
            Defi(id: "millenaire", groupe: .rares, titre: "Le Millénaire", detail: "Collecte toutes les fontaines du Millénaire.",
                 symbole: "hourglass", bonus: 300) { c in
                (c.parType["Fontaine du Millénaire"] ?? 0, c.recensement.parType["Fontaine du Millénaire"] ?? 0)
            },
            Defi(id: "poing", groupe: .rares, titre: "Poing levé", detail: "Collecte toutes les fontaines Poing d'eau.",
                 symbole: "hand.raised.fill", bonus: 200) { c in
                (c.parType["Fontaine Poing d'eau"] ?? 0, c.recensement.parType["Fontaine Poing d'eau"] ?? 0)
            },
            Defi(id: "modeles", groupe: .rares, titre: "Tous les modèles",
                 detail: "Collecte au moins une fontaine de chaque modèle d'Eau de Paris.",
                 symbole: "square.grid.3x3.fill", bonus: 400) { c in
                let existants = typesOfficiels.filter { (c.recensement.parType[$0] ?? 0) > 0 }
                return (existants.filter { (c.parType[$0] ?? 0) > 0 }.count, existants.count)
            },

            Defi(id: "tour20", groupe: .arrondissements, titre: "Tour de Paris",
                 detail: "Collecte au moins une fontaine dans chacun des 20 arrondissements.",
                 symbole: "map.fill", bonus: 400) { c in (c.parArrondissement.count, 20) },
            Defi(id: "horsmurs", groupe: .arrondissements, titre: "Hors les murs",
                 detail: "Trouve une fontaine Eau de Paris hors de Paris (dans un cimetière parisien, par exemple).",
                 symbole: "signpost.right.fill", bonus: 50) { c in
                (c.visites.filter { $0.ar == 0 && $0.id.hasPrefix("f") }.count, 1)
            },

            Defi(id: "jour5", groupe: .rythme, titre: "Tournée des fontaines", detail: "Collecte 5 fontaines dans la même journée.",
                 symbole: "figure.walk", bonus: 100) { c in (c.maxParJour, 5) },
            Defi(id: "jour10", groupe: .rythme, titre: "Marathon de l'eau", detail: "Collecte 10 fontaines dans la même journée.",
                 symbole: "figure.run", bonus: 250) { c in (c.maxParJour, 10) },
            Defi(id: "jour25", groupe: .rythme, titre: "Ultra-trail", detail: "Collecte 25 fontaines dans la même journée.",
                 symbole: "bicycle", bonus: 600) { c in (c.maxParJour, 25) },
            Defi(id: "serie3", groupe: .rythme, titre: "Bonne habitude", detail: "Collecte une fontaine 3 jours d'affilée.",
                 symbole: "calendar", bonus: 100) { c in (c.serie, 3) },
            Defi(id: "serie7", groupe: .rythme, titre: "Semaine parfaite", detail: "Collecte une fontaine 7 jours d'affilée.",
                 symbole: "calendar.badge.checkmark", bonus: 300) { c in (c.serie, 7) },
            Defi(id: "levetot", groupe: .rythme, titre: "Lève-tôt", detail: "Collecte une fontaine avant 8 h.",
                 symbole: "sunrise.fill", bonus: 30) { c in (c.heures { $0 < 8 }, 1) },
            Defi(id: "noctambule", groupe: .rythme, titre: "Noctambule", detail: "Collecte une fontaine après 22 h.",
                 symbole: "moon.stars.fill", bonus: 30) { c in (c.heures { $0 >= 22 }, 1) },
            Defi(id: "hiver", groupe: .rythme, titre: "Même pas froid", detail: "Collecte une fontaine en décembre, janvier ou février.",
                 symbole: "snowflake", bonus: 50) { c in (c.mois([12, 1, 2]), 1) },
            Defi(id: "ete", groupe: .rythme, titre: "Canicule", detail: "Collecte une fontaine en juillet ou en août.",
                 symbole: "sun.max.fill", bonus: 50) { c in (c.mois([7, 8]), 1) },
        ]
        for n in 1...20 {
            let nom = Geo.arrondissement(n)
            d.append(Defi(id: "ar\(n)", groupe: .arrondissements, titre: "\(nom) arrondissement complet",
                          detail: "Collecte toutes les fontaines du \(nom) arrondissement.",
                          symbole: "\(n).square.fill", bonus: 300) { c in
                (c.parArrondissement[n] ?? 0, c.recensement.parArrondissement[n] ?? 0)
            })
        }
        return d
    }()

    static let parId: [String: Defi] = Dictionary(uniqueKeysWithValues: tous.map { ($0.id, $0) })
}

// MARK: - Partie en cours

struct Celebration: Identifiable {
    let id = UUID()
    let point: PointEau
    let visite: Visite
    let defis: [Defi]
    let nouveauNiveau: Niveau?
}

/// Fontaines collectées, défis réussis et photos. Tout reste sur le téléphone (Application Support).
@MainActor
final class Jeu: ObservableObject {
    @Published private(set) var visites: [String: Visite] = [:]
    @Published private(set) var defisReussis: [String: Date] = [:]
    @Published var celebration: Celebration?

    let dossier: URL
    var dossierPhotos: URL { dossier.appendingPathComponent("photos", isDirectory: true) }
    private var fichier: URL { dossier.appendingPathComponent("jeu.json") }
    private let vignettes = NSCache<NSString, UIImage>()

    private struct Sauvegarde: Codable {
        var visites: [Visite]
        var defis: [String: Date]
    }

    init(dossier: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.dossier = dossier ?? support.appendingPathComponent("Jeu", isDirectory: true)
        try? FileManager.default.createDirectory(at: dossierPhotos, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: fichier) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let s = try? dec.decode(Sauvegarde.self, from: data) {
                visites = Dictionary(s.visites.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                defisReussis = s.defis
            }
        }
    }

    // Score
    var pointsFontaines: Int { visites.values.reduce(0) { $0 + $1.pts } }
    var pointsDefis: Int { defisReussis.keys.reduce(0) { $0 + (Defi.parId[$1]?.bonus ?? 0) } }
    var total: Int { pointsFontaines + pointsDefis }
    var niveau: Niveau { Niveau.pour(total) }
    var visitesTriees: [Visite] { visites.values.sorted { $0.date > $1.date } }

    func estCollectee(_ id: String) -> Bool { visites[id] != nil }

    func contexte(_ r: Recensement) -> Contexte { Contexte(visites: Array(visites.values), recensement: r) }

    /// Enregistre la photo et la fontaine, ajoute les points, valide les défis atteints.
    func collecter(_ p: PointEau, image: UIImage, recensement: Recensement) {
        guard p.estFontaine, visites[p.id] == nil else { return }
        let niveauAvant = niveau
        let nom = "\(p.id)-\(Int(Date().timeIntervalSince1970)).jpg"
        if let data = Jeu.reduire(image, cote: 1600).jpegData(compressionQuality: 0.82) {
            try? data.write(to: dossierPhotos.appendingPathComponent(nom), options: .atomic)
        }
        let v = Visite(id: p.id, date: Date(), type: p.type, pts: p.points, ar: p.arrondissement, cat: p.cat,
                       lat: p.lat, lon: p.lon, photo: nom)
        visites[p.id] = v
        let nouveaux = validerDefis(recensement)
        sauver()
        let apres = niveau
        celebration = Celebration(point: p, visite: v, defis: nouveaux, nouveauNiveau: apres.rang > niveauAvant.rang ? apres : nil)
    }

    /// Valide les défis atteints (à appeler aussi quand les données changent). Renvoie les nouveaux.
    @discardableResult
    func validerDefis(_ r: Recensement) -> [Defi] {
        let c = contexte(r)
        var nouveaux: [Defi] = []
        for d in Defi.tous where defisReussis[d.id] == nil {
            let m = d.mesure(c)
            if m.objectif > 0 && m.fait >= m.objectif {
                defisReussis[d.id] = Date()
                nouveaux.append(d)
            }
        }
        return nouveaux
    }

    func photo(_ v: Visite) -> UIImage? {
        UIImage(contentsOfFile: dossierPhotos.appendingPathComponent(v.photo).path)
    }

    func vignette(_ v: Visite) -> UIImage? {
        if let i = vignettes.object(forKey: v.photo as NSString) { return i }
        guard let i = photo(v)?.preparingThumbnail(of: CGSize(width: 300, height: 300)) else { return nil }
        vignettes.setObject(i, forKey: v.photo as NSString)
        return i
    }

    /// Efface toute la partie (photos comprises).
    func toutEffacer() {
        try? FileManager.default.removeItem(at: dossier)
        try? FileManager.default.createDirectory(at: dossierPhotos, withIntermediateDirectories: true)
        visites = [:]
        defisReussis = [:]
        vignettes.removeAllObjects()
    }

    private func sauver() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(Sauvegarde(visites: Array(visites.values), defis: defisReussis)) else { return }
        try? data.write(to: fichier, options: .atomic)
    }

    static func reduire(_ image: UIImage, cote: CGFloat) -> UIImage {
        let plusGrand = max(image.size.width, image.size.height)
        guard plusGrand > cote else { return image }
        let k = cote / plusGrand
        let taille = CGSize(width: (image.size.width * k).rounded(), height: (image.size.height * k).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: taille, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: taille))
        }
    }

    #if DEBUG
    /// Partie de démonstration (argument de lancement -demo) pour les captures d'écran.
    func remplirDemo(points: [PointEau], recensement: Recensement) {
        guard visites.isEmpty else { return }
        let centre = CLLocation(latitude: 48.8606, longitude: 2.3376)
        let proches = points.filter { $0.estFontaine && $0.ok }
            .sorted { $0.position.distance(from: centre) < $1.position.distance(from: centre) }
        var choix = Array(proches.prefix(38))
        choix += points.filter { $0.categorie == .petillante }.prefix(3)
        let maintenant = Date()
        for (i, p) in choix.enumerated() where visites[p.id] == nil {
            let date = maintenant.addingTimeInterval(-Double(i) * 3600 * 7)
            let nom = "\(p.id)-demo.jpg"
            if let data = Jeu.imageDemo(i).jpegData(compressionQuality: 0.8) {
                try? data.write(to: dossierPhotos.appendingPathComponent(nom), options: .atomic)
            }
            visites[p.id] = Visite(id: p.id, date: date, type: p.type, pts: p.points, ar: p.arrondissement,
                                   cat: p.cat, lat: p.lat, lon: p.lon, photo: nom)
        }
        validerDefis(recensement)
        sauver()
    }

    /// Écran de victoire de démonstration (argument -victoire) pour les captures d'écran.
    func demoVictoire(points: [PointEau]) {
        guard let p = points.first(where: { $0.categorie == .petillante && visites[$0.id] != nil }),
              let v = visites[p.id] else { return }
        let defis = [Defi.parId["petillante1"], Defi.parId["jour5"]].compactMap { $0 }
        celebration = Celebration(point: p, visite: v, defis: defis, nouveauNiveau: niveau)
    }

    private static func imageDemo(_ i: Int) -> UIImage {
        let teintes: [UIColor] = [.systemTeal, .systemBlue, .systemIndigo, .systemCyan, .systemMint, .systemGreen]
        let taille = CGSize(width: 600, height: 600)
        return UIGraphicsImageRenderer(size: taille).image { ctx in
            let c = teintes[i % teintes.count]
            let couleurs = [c.withAlphaComponent(0.55).cgColor, c.cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: couleurs, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 600, y: 600), options: [])
            }
            let symbole = UIImage(systemName: "drop.fill")?.withTintColor(.white.withAlphaComponent(0.85), renderingMode: .alwaysOriginal)
            symbole?.draw(in: CGRect(x: 220, y: 200, width: 160, height: 210))
        }
    }
    #endif
}
