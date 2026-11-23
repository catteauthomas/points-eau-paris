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
        XCTAssertGreaterThan(f.points.count, 1500)
        XCTAssertFalse(f.points.contains { $0.cat == "commerce" })
        XCTAssertGreaterThan(f.points.filter { $0.fermeNuit == true }.count, 100)
        XCTAssertEqual(Set(f.points.map(\.id)).count, f.points.count)
        let r = Recensement(points: f.points)
        XCTAssertGreaterThan(r.totalParis, 1000)
        XCTAssertEqual(r.parArrondissement.count, 20)
        XCTAssertGreaterThan(r.petillantes, 5)
        XCTAssertTrue(f.points.allSatisfy { (48.6...49.1).contains($0.lat) && (2.0...2.7).contains($0.lon) })
        // Les cinq communes voisines entre Paris et la Seine ont des points d'eau, et seulement elles
        XCTAssertEqual(Set(r.parCommune.keys), Set(Geo.voisines))
        XCTAssertGreaterThan(r.parCommune["Boulogne-Billancourt"] ?? 0, 40)
        XCTAssertTrue(f.points.allSatisfy { $0.com == nil || $0.arrondissement == 0 })
        XCTAssertTrue(f.points.allSatisfy { $0.gel != true || !$0.ok })
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

    func testNuit() {
        let cal = Calendar.current
        let jour = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 14))!
        let nuit = cal.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 3))!
        XCTAssertFalse(Geo.estLaNuit(jour))
        XCTAssertTrue(Geo.estLaNuit(nuit))
        var parc = point("parc")
        parc.fermeNuit = true
        XCTAssertFalse(Filtres(nuit: true).montre(parc, collectee: false))
        XCTAssertTrue(Filtres(nuit: false).montre(parc, collectee: false))
        XCTAssertTrue(Filtres(nuit: true).montre(point("rue"), collectee: false))
    }

    /// Fontaine coupée pour l'hiver : flocon sur la carte, pas proposée comme fontaine la plus proche, masquable.
    func testCoupeeHiver() throws {
        let json = #"{"id":"f1","src":"fontaine","cat":"fontaine","lat":48.86,"lon":2.34,"type":"Fontaine à boire","ok":false,"motif":"Coupée pour l'hiver (gel)","gel":true,"ar":12,"pts":10}"#
        let gelee = try JSONDecoder().decode(PointEau.self, from: Data(json.utf8))
        XCTAssertTrue(gelee.coupeeHiver)
        XCTAssertEqual(StyleMarqueur.style(gelee, collectee: false).1, "snowflake")
        XCTAssertEqual(StyleMarqueur.style(gelee, collectee: true).1, "checkmark")
        XCTAssertTrue(Filtres(nuit: false).montre(gelee, collectee: false))
        XCTAssertFalse(Filtres(nuit: false, gel: false).montre(gelee, collectee: false))
        // Une autre panne reste masquée par défaut
        XCTAssertFalse(Filtres(nuit: false).montre(point("panne", ok: false), collectee: false))
        XCTAssertFalse(point("panne", ok: false).coupeeHiver)
        let ici = CLLocation(latitude: 48.8600, longitude: 2.3400)
        let r = Calcul.plusProche(de: ici, parmi: [gelee, point("rue", lat: 48.8610)]) { $0.estFontaine && $0.ok }
        XCTAssertEqual(r?.0.id, "rue")
        // Hiver : de novembre à mars
        let cal = Calendar.current
        XCTAssertTrue(Geo.estLHiver(cal.date(from: DateComponents(year: 2026, month: 12, day: 1))!))
        XCTAssertFalse(Geo.estLHiver(cal.date(from: DateComponents(year: 2027, month: 6, day: 1))!))
    }

    /// Points des communes voisines : lieu affiché, recensement et défis « Autour de Paris ».
    func testCommunesVoisines() {
        var lev1 = point("lev1", ar: 0)
        lev1.com = "Levallois-Perret"
        var lev2 = point("lev2", ar: 0)
        lev2.com = "Levallois-Perret"
        var neu = point("neu", ar: 0)
        neu.com = "Neuilly-sur-Seine"
        let paris = point("p11", ar: 11)
        XCTAssertEqual(lev1.lieu, "Levallois-Perret")
        XCTAssertEqual(paris.lieu, "Paris 11e")
        XCTAssertEqual(point("thiais", ar: 0).lieu, "Hors Paris")
        let r = Recensement(points: [lev1, lev2, neu, paris])
        XCTAssertEqual(r.parCommune, ["Levallois-Perret": 2, "Neuilly-sur-Seine": 1])
        XCTAssertEqual(r.totalParis, 1)

        let jeu = Jeu(dossier: dossierTemporaire())
        jeu.collecter(lev1, image: image(), recensement: r)
        XCTAssertEqual(jeu.visites["lev1"]?.lieu, "Levallois-Perret")
        XCTAssertNotNil(jeu.defisReussis["periph"])
        XCTAssertNil(jeu.defisReussis["com-levallois"])
        jeu.collecter(lev2, image: image(), recensement: r)
        XCTAssertNotNil(jeu.defisReussis["com-levallois"])
        XCTAssertNil(jeu.defisReussis["boucle"])
        jeu.collecter(neu, image: image(), recensement: r)
        XCTAssertNotNil(jeu.defisReussis["boucle"])
        XCTAssertNotNil(jeu.defisReussis["com-neuilly"])
        // Les communes ne comptent pas pour « Tout Paris »
        XCTAssertNil(jeu.defisReussis["toutparis"])
        XCTAssertEqual(Jeu(dossier: jeu.dossier).visites["neu"]?.com, "Neuilly-sur-Seine")
    }

    /// Une partie enregistrée par la version 1.0 (visites sans commune) se relit sans perte.
    func testSauvegardeVersion1() throws {
        let dossier = dossierTemporaire()
        try FileManager.default.createDirectory(at: dossier, withIntermediateDirectories: true)
        let ancienne = #"{"visites":[{"id":"f9","date":"2026-11-19T10:00:00Z","type":"Fontaine Wallace","pts":20,"ar":4,"cat":"fontaine","lat":48.85,"lon":2.35,"photo":"f9.jpg"}],"defis":{"premiere":"2026-11-19T10:00:00Z"}}"#
        try Data(ancienne.utf8).write(to: dossier.appendingPathComponent("jeu.json"))
        let jeu = Jeu(dossier: dossier)
        XCTAssertEqual(jeu.visites.count, 1)
        XCTAssertEqual(jeu.visites["f9"]?.lieu, "Paris 4e")
        XCTAssertEqual(jeu.total, 20 + 20)
    }

    /// Un point de Levallois collecté avec la version 1.0 (visite sans commune) compte pour les défis après la mise à jour.
    func testCommuneRetrouvee() {
        var lev = point("lev", ar: 0)
        let r0 = Recensement(points: [lev])
        let jeu = Jeu(dossier: dossierTemporaire())
        jeu.collecter(lev, image: image(), recensement: r0)
        XCTAssertNil(jeu.visites["lev"]?.com)
        lev.com = "Levallois-Perret"
        let r = Recensement(points: [lev])
        jeu.completerCommunes(["lev": lev])
        jeu.validerDefis(r)
        XCTAssertEqual(jeu.visites["lev"]?.lieu, "Levallois-Perret")
        XCTAssertNotNil(jeu.defisReussis["com-levallois"])
        XCTAssertEqual(Jeu(dossier: jeu.dossier).visites["lev"]?.com, "Levallois-Perret")
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
