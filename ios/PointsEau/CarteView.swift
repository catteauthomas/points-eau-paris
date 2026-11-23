import MapKit
import SwiftUI

/// Ce qu'on affiche sur la carte (pastilles en haut de l'écran).
struct Filtres: Equatable {
    var fontaines = true
    var petillantes = true
    var commerces = false
    /// Seulement les points accessibles à toute heure (activé tout seul la nuit).
    var nuit = Geo.estLaNuit()
    var horsService = false
    /// Fontaines coupées pour l'hiver (gel) : affichées avec un flocon, pour savoir qu'il ne faut pas y compter.
    var gel = true
    var collectees = true

    func montre(_ p: PointEau, collectee: Bool) -> Bool {
        if collectee && !collectees { return false }
        if nuit && !p.ouvertLaNuit { return false }
        if p.coupeeHiver && !collectee {
            if !gel { return false }
        } else if !p.ok && !horsService && !collectee {
            return false
        }
        switch p.categorie {
        case .fontaine: return fontaines
        case .petillante: return petillantes
        case .commerce: return commerces
        }
    }
}

/// Ordre envoyé à la carte (centrer, suivre la position…). Chaque ordre n'est exécuté qu'une fois.
struct Commande: Equatable {
    enum Action: Equatable {
        case centrer(lat: Double, lon: Double, metres: Double, suivre: Bool = false)
        case suivre(boussole: Bool)
    }

    let id = UUID()
    let action: Action

    static func == (a: Commande, b: Commande) -> Bool { a.id == b.id }
}

enum StyleMarqueur {
    static let or = UIColor(red: 0.96, green: 0.72, blue: 0.10, alpha: 1)
    /// Bleu glacier, un peu éteint : la fontaine existe mais ne coule pas cet hiver.
    static let glace = UIColor(red: 0.47, green: 0.66, blue: 0.82, alpha: 1)

    static func style(_ p: PointEau, collectee: Bool) -> (UIColor, String) {
        if collectee { return (or, "checkmark") }
        if p.coupeeHiver { return (glace, "snowflake") }
        if !p.ok { return (.systemGray, "xmark") }
        switch p.categorie {
        case .commerce: return (.systemOrange, "cup.and.saucer.fill")
        case .petillante: return (.systemPurple, "bubbles.and.sparkles.fill")
        case .fontaine:
            if p.type == "Fontaine Wallace" { return (.systemTeal, "building.columns.fill") }
            switch p.rarete {
            case .legendaire: return (.systemPink, "star.fill")
            case .rare: return (.systemPurple, "sparkles")
            default: return (.systemBlue, "drop.fill")
            }
        }
    }
}

final class AnnotationEau: NSObject, MKAnnotation {
    let point: PointEau
    let collectee: Bool
    let coordinate: CLLocationCoordinate2D

    init(point: PointEau, collectee: Bool) {
        self.point = point
        self.collectee = collectee
        coordinate = point.coordonnee
    }
}

/// Carte Apple Plans (MapKit) avec regroupement des points : les rues et les lieux viennent du fond de carte.
struct CarteView: UIViewRepresentable {
    let points: [PointEau]
    let genere: String
    let filtres: Filtres
    let collectees: Set<String>
    let route: MKRoute?
    let commande: Commande?
    var onSelect: (PointEau) -> Void
    var onSuivi: (MKUserTrackingMode) -> Void

    func makeCoordinator() -> Coordinateur { Coordinateur(self) }

    func makeUIView(context: Context) -> MKMapView {
        let carte = MKMapView()
        carte.delegate = context.coordinator
        carte.showsUserLocation = true
        carte.pointOfInterestFilter = .excludingAll
        carte.showsCompass = true
        carte.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinateur.idPoint)
        carte.register(MKMarkerAnnotationView.self,
                       forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        carte.setRegion(MKCoordinateRegion(center: Geo.paris.coordinate, latitudinalMeters: 9000, longitudinalMeters: 9000),
                        animated: false)
        return carte
    }

    func updateUIView(_ carte: MKMapView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.majAnnotations(carte)
        c.majRoute(carte)
        if let cmd = commande, cmd.id != c.derniereCommande {
            c.derniereCommande = cmd.id
            c.executer(cmd, carte)
        }
    }

    final class Coordinateur: NSObject, MKMapViewDelegate {
        static let idPoint = "eau"

        var parent: CarteView
        var derniereCommande: UUID?
        private var annotations: [String: AnnotationEau] = [:]
        private var signature = ""
        private var routeAffichee: MKRoute?

        init(_ parent: CarteView) {
            self.parent = parent
        }

        /// Ajoute et retire seulement ce qui a changé (des milliers de points).
        func majAnnotations(_ carte: MKMapView) {
            let p = parent
            let sig = "\(p.genere)|\(p.points.count)|\(p.filtres)|\(p.collectees.count)"
            guard sig != signature else { return }
            signature = sig
            var voulues: [String: PointEau] = [:]
            for pt in p.points where p.filtres.montre(pt, collectee: p.collectees.contains(pt.id)) {
                voulues[pt.id] = pt
            }
            var aRetirer: [AnnotationEau] = []
            var aAjouter: [AnnotationEau] = []
            for (id, a) in annotations {
                if let pt = voulues[id] {
                    let col = p.collectees.contains(id)
                    if a.collectee != col || a.point != pt {
                        aRetirer.append(a)
                        let n = AnnotationEau(point: pt, collectee: col)
                        annotations[id] = n
                        aAjouter.append(n)
                    }
                } else {
                    aRetirer.append(a)
                    annotations[id] = nil
                }
            }
            for (id, pt) in voulues where annotations[id] == nil {
                let n = AnnotationEau(point: pt, collectee: p.collectees.contains(id))
                annotations[id] = n
                aAjouter.append(n)
            }
            if !aRetirer.isEmpty { carte.removeAnnotations(aRetirer) }
            if !aAjouter.isEmpty { carte.addAnnotations(aAjouter) }
        }

        func majRoute(_ carte: MKMapView) {
            if parent.route === routeAffichee { return }
            carte.removeOverlays(carte.overlays)
            routeAffichee = parent.route
            guard let r = parent.route else { return }
            carte.addOverlay(r.polyline, level: .aboveRoads)
            carte.setVisibleMapRect(r.polyline.boundingMapRect,
                                    edgePadding: UIEdgeInsets(top: 140, left: 60, bottom: 280, right: 60), animated: true)
        }

        func executer(_ c: Commande, _ carte: MKMapView) {
            switch c.action {
            case let .centrer(lat, lon, metres, suivre):
                carte.setUserTrackingMode(.none, animated: false)
                let centre = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                carte.setRegion(MKCoordinateRegion(center: centre, latitudinalMeters: metres, longitudinalMeters: metres),
                                animated: !suivre)
                if suivre { carte.setUserTrackingMode(.follow, animated: true) }
            case let .suivre(boussole):
                carte.setUserTrackingMode(boussole ? .followWithHeading : .follow, animated: true)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ carte: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }
            if let groupe = annotation as? MKClusterAnnotation {
                let v = carte.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: annotation)
                guard let m = v as? MKMarkerAnnotationView else { return v }
                let membres = groupe.memberAnnotations.compactMap { $0 as? AnnotationEau }
                if !membres.isEmpty && membres.allSatisfy({ $0.collectee }) {
                    m.markerTintColor = StyleMarqueur.or
                } else if !membres.isEmpty && membres.allSatisfy({ $0.point.coupeeHiver }) {
                    m.markerTintColor = StyleMarqueur.glace
                } else if membres.first?.point.categorie == .commerce {
                    m.markerTintColor = .systemOrange
                } else {
                    m.markerTintColor = UIColor(named: "AccentColor") ?? .systemBlue
                }
                m.glyphImage = nil
                m.glyphText = "\(groupe.memberAnnotations.count)"
                m.displayPriority = .defaultHigh
                m.titleVisibility = .hidden
                m.subtitleVisibility = .hidden
                return m
            }
            guard let a = annotation as? AnnotationEau else { return nil }
            let v = carte.dequeueReusableAnnotationView(withIdentifier: Coordinateur.idPoint, for: annotation)
            guard let m = v as? MKMarkerAnnotationView else { return v }
            let (couleur, symbole) = StyleMarqueur.style(a.point, collectee: a.collectee)
            m.markerTintColor = couleur
            m.glyphText = nil
            m.glyphImage = UIImage(systemName: symbole)
            m.titleVisibility = .hidden
            m.subtitleVisibility = .hidden
            m.canShowCallout = false
            if a.point.categorie == .commerce {
                m.clusteringIdentifier = "commerce"
                m.displayPriority = .defaultLow
            } else if a.point.coupeeHiver && !a.collectee {
                // Regroupées entre elles : un groupe de fontaines en service ne compte pas celles qui sont gelées
                m.clusteringIdentifier = "gel"
                m.displayPriority = .defaultLow
            } else {
                m.clusteringIdentifier = a.collectee ? "collectee" : "eau"
                m.displayPriority = a.point.rarete >= .rare && !a.collectee ? .required : .defaultHigh
            }
            return m
        }

        func mapView(_ carte: MKMapView, didSelect view: MKAnnotationView) {
            if let groupe = view.annotation as? MKClusterAnnotation {
                carte.deselectAnnotation(groupe, animated: false)
                carte.showAnnotations(groupe.memberAnnotations, animated: true)
                return
            }
            if let a = view.annotation as? AnnotationEau {
                carte.deselectAnnotation(a, animated: false)
                parent.onSelect(a.point)
            }
        }

        func mapView(_ carte: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = UIColor(named: "AccentColor") ?? .systemBlue
            r.lineWidth = 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }

        func mapView(_ carte: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            let suivi = parent.onSuivi
            DispatchQueue.main.async { suivi(mode) }
        }
    }
}
