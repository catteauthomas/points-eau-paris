import CoreLocation
import SwiftUI

/// Catégorie d'un point d'eau (champ « cat » du fichier de données).
enum Categorie: String, CaseIterable {
    case fontaine, petillante, commerce
}

/// Un point d'eau, tel qu'écrit par scraper/scrape.py.
struct PointEau: Codable, Identifiable, Hashable {
    let id: String
    let src: String
    let cat: String
    let lat: Double
    let lon: Double
    let type: String
    let ok: Bool
    var motif: String?
    var retour: String?
    var nom: String?
    var horaires: String?
    var saison: Bool?
    var fermeNuit: Bool?
    /// Coupée pour l'hiver par Eau de Paris (risque de gel).
    var gel: Bool?
    var ar: Int?
    /// Commune voisine (Levallois-Perret, Neuilly-sur-Seine…) pour un point hors Paris.
    var com: String?
    var pts: Int?

    var categorie: Categorie { Categorie(rawValue: cat) ?? .fontaine }
    var coordonnee: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
    var position: CLLocation { CLLocation(latitude: lat, longitude: lon) }
    /// Les commerces partenaires sont sur la carte mais ne comptent pas dans le jeu.
    var estFontaine: Bool { categorie != .commerce }
    var points: Int { pts ?? 10 }
    var arrondissement: Int { ar ?? 0 }
    var titre: String { nom ?? type }
    /// « Paris 11e », « Levallois-Perret » ou « Hors Paris ».
    var lieu: String { Geo.lieu(ar: arrondissement, com: com) }
    /// Ne coule pas en ce moment : coupée pour l'hiver à cause du gel.
    var coupeeHiver: Bool { gel == true && !ok }
    /// Seule Eau de Paris publie ses coupures d'hiver : pour les autres points, on ne sait pas s'ils coulent quand il gèle.
    var hiverConnu: Bool { src == "fontaine" }
    /// Accessible à toute heure (pas dans un parc, un square ou un cimetière, pas d'horaires limités).
    var ouvertLaNuit: Bool { fermeNuit != true }
    var rarete: Rarete { Rarete(points: points) }

    /// Date de retour en service, en clair (« 27/11 »).
    var retourTexte: String? {
        guard let r = retour, r.count >= 10 else { return nil }
        let morceaux = r.prefix(10).split(separator: "-")
        guard morceaux.count == 3 else { return nil }
        return "\(morceaux[2])/\(morceaux[1])/\(morceaux[0])"
    }
}

struct InfoSource: Codable {
    var date: String?
    var points: Int?
    var maj: String?
}

struct FichierDonnees: Codable {
    let version: Int
    let genere: String
    let sources: [String: InfoSource]
    let points: [PointEau]
}

/// Rareté d'une fontaine, déduite de ses points.
enum Rarete: Int, Comparable {
    case commune, peuCommune, rare, legendaire

    init(points: Int) {
        switch points {
        case ..<15: self = .commune
        case ..<40: self = .peuCommune
        case ..<75: self = .rare
        default: self = .legendaire
        }
    }

    static func < (a: Rarete, b: Rarete) -> Bool { a.rawValue < b.rawValue }

    var nom: String {
        switch self {
        case .commune: return "Commune"
        case .peuCommune: return "Peu commune"
        case .rare: return "Rare"
        case .legendaire: return "Légendaire"
        }
    }

    var couleur: Color {
        switch self {
        case .commune: return .blue
        case .peuCommune: return .teal
        case .rare: return .purple
        case .legendaire: return .pink
        }
    }
}

/// Une fontaine prise en photo sur place.
struct Visite: Codable, Identifiable, Hashable {
    let id: String        // identifiant du point d'eau
    let date: Date
    let type: String
    let pts: Int
    let ar: Int
    let cat: String
    let lat: Double
    let lon: Double
    var photo: String     // nom du fichier dans le dossier des photos
    var com: String? = nil  // commune voisine (absent des sauvegardes de la version 1.0)

    var lieu: String { Geo.lieu(ar: ar, com: com) }
}

/// Nombre de fontaines par type et par arrondissement, pour les objectifs du jeu.
struct Recensement {
    var total = 0
    var totalParis = 0
    var parType: [String: Int] = [:]
    var parArrondissement: [Int: Int] = [:]
    var parCommune: [String: Int] = [:]
    var petillantes = 0

    init() {}

    init(points: [PointEau]) {
        for p in points where p.estFontaine {
            total += 1
            parType[p.type, default: 0] += 1
            if p.categorie == .petillante { petillantes += 1 }
            if (1...20).contains(p.arrondissement) {
                totalParis += 1
                parArrondissement[p.arrondissement, default: 0] += 1
            } else if let c = p.com {
                parCommune[c, default: 0] += 1
            }
        }
    }
}

enum Geo {
    /// Centre de Paris (Hôtel de Ville).
    static let paris = CLLocation(latitude: 48.8566, longitude: 2.3522)

    static func estAParis(_ l: CLLocation) -> Bool { l.distance(from: paris) < 20_000 }

    /// Communes entre Paris et la Seine dont les points d'eau sont sur la carte (même liste que scraper/scrape.py).
    static let voisines = ["Boulogne-Billancourt", "Neuilly-sur-Seine", "Levallois-Perret", "Clichy", "Saint-Ouen-sur-Seine"]

    /// Nom court d'une commune voisine, pour les défis et la grille (« Levallois », « Saint-Ouen »).
    static func court(_ commune: String) -> String {
        switch commune {
        case "Boulogne-Billancourt": return "Boulogne"
        case "Neuilly-sur-Seine": return "Neuilly"
        case "Levallois-Perret": return "Levallois"
        case "Saint-Ouen-sur-Seine": return "Saint-Ouen"
        default: return commune
        }
    }

    static func lieu(ar: Int, com: String?) -> String {
        if (1...20).contains(ar) { return "Paris \(arrondissement(ar))" }
        return com ?? "Hors Paris"
    }

    /// De novembre à mars, les fontaines peuvent être coupées à cause du gel.
    static func estLHiver(_ date: Date = Date()) -> Bool {
        [11, 12, 1, 2, 3].contains(Calendar.current.component(.month, from: date))
    }

    /// Entre 21 h et 7 h, les parcs, squares et cimetières sont fermés.
    static func estLaNuit(_ date: Date = Date()) -> Bool {
        let h = Calendar.current.component(.hour, from: date)
        return h >= 21 || h < 7
    }

    /// Distance lisible : « 85 m », « 1,2 km ».
    static func distance(_ m: CLLocationDistance) -> String {
        if m < 1000 { return "\(Int((m / 5).rounded() * 5)) m" }
        let km = (m / 100).rounded() / 10
        return String(format: "%.1f km", km).replacingOccurrences(of: ".", with: ",")
    }

    /// Temps de marche (environ 80 m par minute).
    static func marche(_ m: CLLocationDistance) -> String {
        let min = max(1, Int((m / 80).rounded()))
        if min < 60 { return "\(min) min" }
        return "\(min / 60) h \(String(format: "%02d", min % 60))"
    }

    static func arrondissement(_ n: Int) -> String {
        n == 0 ? "Hors Paris" : (n == 1 ? "1er" : "\(n)e")
    }
}
