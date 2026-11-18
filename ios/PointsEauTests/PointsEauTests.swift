import CoreLocation
import UIKit
import XCTest
@testable import PointsEau

@MainActor
final class PointsEauTests: XCTestCase {
    private func point(_ id: String, _ type: String = "Fontaine à boire", cat: String = "fontaine", lat: Double = 48.86,
                       lon: Double = 2.34, ok: Bool = true, ar: Int = 1, pts: Int = 10) -> PointEau {
        PointEau(id: id, src: "fontaine", cat: cat, lat: lat, lon: lon, type: type, ok: ok, ar: ar, pts: pts)
    }

    private func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { c in
            UIColor.blue.setFill()
            c.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
    }

    private func dossierTemporaire() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Le fichier embarqué dans l'appli est lisible, complet et sans doublon d'identifiant.
    func testDonneesEmbarquees() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "points", withExtension: "json"))
        let f = try JSONDecoder().decode(FichierDonnees.self, from: Data(contentsOf: url))
        XCTAssertGreaterThan(f.points.count, 2500)
        XCTAssertEqual(Set(f.points.map(\.id)).count, f.points.count)
        let r = Recensement(points: f.points)
        XCTAssertGreaterThan(r.totalParis, 1000)
        XCTAssertEqual(r.parArrondissement.count, 20)
        XCTAssertGreaterThan(r.petillantes, 5)
        XCTAssertTrue(f.points.allSatisfy { (48.6...49.1).contains($0.lat) && (2.0...2.7).contains($0.lon) })
    }

    func testPlusProcheIgnoreCommercesEtHorsService() {
        let ici = CLLocation(latitude: 48.8600, longitude: 2.3400)
        let points = [
            point("commerce", cat: "commerce", lat: 48.86001, lon: 2.34001),
            point("panne", lat: 48.86002, lon: 2.34002, ok: false),
            point("loin", lat: 48.8700, lon: 2.3400),
            point("proche", lat: 48.8610, lon: 2.3400),
        ]
        let r = Calcul.plusProche(de: ici, parmi: points) { $0.estFontaine && $0.ok }
        XCTAssertEqual(r?.0.id, "proche")
        XCTAssertEqual(r?.1 ?? 0, 111, accuracy: 2)
    }

    func testPortee() {
        let f = point("f", lat: 48.8600, lon: 2.3400)
        func a(_ metresNord: Double, precision: Double) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 48.8600 + metresNord / 111_000, longitude: 2.3400),
                       altitude: 0, horizontalAccuracy: precision, verticalAccuracy: 10, timestamp: Date())
        }
        XCTAssertTrue(Regles.aPortee(f, depuis: a(30, precision: 8)))
        XCTAssertFalse(Regles.aPortee(f, depuis: a(90, precision: 8)))
        XCTAssertFalse(Regles.aPortee(f, depuis: a(10, precision: 120)))
        XCTAssertFalse(Regles.aPortee(point("c", cat: "commerce", lat: 48.86, lon: 2.34), depuis: a(0, precision: 5)))
    }

    func testCollecteDefisEtSauvegarde() {
        let dossier = dossierTemporaire()
        let points = [
            point("w1", "Fontaine Wallace", ar: 1, pts: 20),
            point("p1", "Fontaine pétillante", cat: "petillante", ar: 1, pts: 50),
            point("a1", ar: 2),
            point("a2", ar: 2),
            point("a3", ar: 3),
        ]
        let r = Recensement(points: points)
        let jeu = Jeu(dossier: dossier)
        for p in points { jeu.collecter(p, image: image(), recensement: r) }
        XCTAssertEqual(jeu.visites.count, 5)
        XCTAssertEqual(jeu.pointsFontaines, 100)
        for id in ["premiere", "wallace1", "petillante1", "petillanteTout", "jour5", "ar1", "ar2", "ar3"] {
            XCTAssertNotNil(jeu.defisReussis[id], "défi \(id) non validé")
        }
        XCTAssertNil(jeu.defisReussis["c10"])
        // Défi « Tout Paris » : toutes les fontaines des 20 arrondissements (ici les 5 du recensement)
        XCTAssertNotNil(jeu.defisReussis["toutparis"])
        XCTAssertEqual(jeu.total, jeu.pointsFontaines + jeu.pointsDefis)
        XCTAssertNotNil(jeu.photo(jeu.visites["w1"]!))
        // Une fontaine ne rapporte qu'une fois
        jeu.collecter(points[0], image: image(), recensement: r)
        XCTAssertEqual(jeu.visites.count, 5)
        // Rechargement depuis le disque
        let relu = Jeu(dossier: dossier)
        XCTAssertEqual(relu.visites.count, 5)
        XCTAssertEqual(relu.total, jeu.total)
        relu.toutEffacer()
        XCTAssertEqual(Jeu(dossier: dossier).visites.count, 0)
    }

    func testSerieDeJours() {
        let cal = Calendar(identifier: .gregorian)
        let base = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        func v(_ jour: Int) -> Visite {
            Visite(id: "v\(jour)", date: cal.date(byAdding: .day, value: jour, to: base)!, type: "Fontaine à boire", pts: 10,
                   ar: 1, cat: "fontaine", lat: 48.86, lon: 2.34, photo: "")
        }
        let c = Contexte(visites: [v(0), v(1), v(2), v(4), v(5)], recensement: Recensement(), calendrier: cal)
        XCTAssertEqual(c.serie, 3)
        XCTAssertEqual(c.maxParJour, 1)
    }

    func testNiveaux() {
        XCTAssertEqual(Niveau.pour(0).nom, "Goutte")
        XCTAssertEqual(Niveau.pour(99).rang, 1)
        XCTAssertEqual(Niveau.pour(100).nom, "Flaque")
        XCTAssertEqual(Niveau.pour(50_000).suivant, nil)
        XCTAssertEqual(Niveau.pour(200).avancement(200), 0.5, accuracy: 0.001)
    }

    func testIdentifiantsDesDefisUniques() {
        XCTAssertEqual(Set(Defi.tous.map(\.id)).count, Defi.tous.count)
    }
}
