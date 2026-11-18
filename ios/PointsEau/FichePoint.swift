import CoreLocation
import SwiftUI
import UIKit

/// Détail d'un point d'eau : état, rareté, photo si collectée, itinéraire, photo pour collecter.
struct FichePoint: View {
    let point: PointEau
    var onItineraire: () -> Void
    var onPhoto: () -> Void

    @EnvironmentObject private var position: Position
    @EnvironmentObject private var jeu: Jeu

    private var distance: CLLocationDistance? { position.location.map { $0.distance(from: point.position) } }
    private var visite: Visite? { jeu.visites[point.id] }
    private var aPortee: Bool { position.location.map { Regles.aPortee(point, depuis: $0) } ?? false }
    private var style: (UIColor, String) { StyleMarqueur.style(point, collectee: visite != nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                entete
                etat
                if point.estFontaine { jeuSection }
                HStack(spacing: 10) {
                    Button(action: onItineraire) {
                        Label("Itinéraire à pied", systemImage: "figure.walk").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Itineraire.ouvrirDansPlans(point)
                    } label: {
                        Label("Plans", systemImage: "map").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(20)
        }
    }

    private var entete: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: style.1)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(Color(style.0), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(point.titre).font(.title2.bold())
                Text(sousTitre).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if point.estFontaine {
                PastillePoints(points: point.points, couleur: point.rarete.couleur)
            }
        }
    }

    private var sousTitre: String {
        var morceaux: [String] = []
        if point.categorie == .commerce {
            morceaux.append("Ici, je choisis l'Eau de Paris")
        } else {
            morceaux.append(point.arrondissement == 0 ? "Hors Paris" : "Paris \(Geo.arrondissement(point.arrondissement))")
        }
        if let d = distance { morceaux.append("à \(Geo.distance(d))") }
        return morceaux.joined(separator: " · ")
    }

    @ViewBuilder private var etat: some View {
        VStack(alignment: .leading, spacing: 8) {
            if point.categorie == .commerce {
                Label("Gourde remplie ou verre d'eau gratuit, aux heures d'ouverture du commerce.",
                      systemImage: "cup.and.saucer.fill")
            } else if point.ok {
                Label("En service", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Label("Hors service : \(point.motif ?? "indisponible")", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                if let r = point.retourTexte {
                    Text("Retour prévu le \(r)").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if point.categorie == .petillante {
                Label("Eau plate, fraîche ou pétillante : apporte ta gourde.", systemImage: "bubbles.and.sparkles")
            }
            if let h = point.horaires {
                Label("Horaires : \(h)", systemImage: "clock")
            }
            if point.fermeNuit == true {
                Label(point.src == "osm" ? "Pas accessible à toute heure." : "Dans un parc, un square ou un cimetière : fermée la nuit.",
                      systemImage: "moon.zzz.fill")
                    .foregroundStyle(.indigo)
            } else if point.estFontaine {
                Label("Accessible jour et nuit.", systemImage: "moon.stars.fill")
                    .foregroundStyle(.secondary)
            }
            if point.saison == true {
                Label("Fermée une partie de l'année (point saisonnier).", systemImage: "snowflake")
            }
            if point.src == "osm" {
                Text("Point signalé par OpenStreetMap.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    @ViewBuilder private var jeuSection: some View {
        if let v = visite {
            VStack(alignment: .leading, spacing: 8) {
                if let image = jeu.photo(v) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                Label("Collectée le \(v.date.formatted(date: .long, time: .shortened))", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(StyleMarqueur.or))
            }
        } else if aPortee {
            Button(action: onPhoto) {
                Label("Prendre en photo · +\(point.points) pts", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(point.rarete.couleur)
        } else {
            HStack(spacing: 10) {
                Image(systemName: "camera.viewfinder").font(.title2).foregroundStyle(point.rarete.couleur)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rareté : \(point.rarete.nom)").font(.subheadline.weight(.semibold))
                    Text("Va jusqu'à cette fontaine et prends-la en photo (à moins de \(Int(Regles.rayon)) m) pour gagner \(point.points) points.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(point.rarete.couleur.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Appareil photo (pas de photo de la galerie : il faut être sur place). Sur le simulateur, la galerie remplace l'appareil.
struct AppareilPhoto: UIViewControllerRepresentable {
    var fin: (UIImage?) -> Void

    func makeCoordinator() -> Coordinateur { Coordinateur(fin: fin) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        #if targetEnvironment(simulator)
        c.sourceType = .photoLibrary
        #else
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            c.sourceType = .camera
            c.cameraCaptureMode = .photo
        }
        #endif
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ c: UIImagePickerController, context: Context) {}

    final class Coordinateur: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let fin: (UIImage?) -> Void

        init(fin: @escaping (UIImage?) -> Void) {
            self.fin = fin
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            fin(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            fin(nil)
        }
    }
}

/// Écran de victoire après une photo.
struct EcranVictoire: View {
    let celebration: Celebration

    @EnvironmentObject private var jeu: Jeu
    @Environment(\.dismiss) private var dismiss
    @State private var apparu = false

    var body: some View {
        GeometryReader { geo in
        ScrollView {
            VStack(spacing: 14) {
                Group {
                    if let image = jeu.photo(celebration.visite) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "drop.fill").font(.system(size: 60)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor)
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(Circle())
                .overlay(Circle().stroke(celebration.point.rarete.couleur, lineWidth: 5))
                .scaleEffect(apparu ? 1 : 0.4)

                Text("+\(celebration.visite.pts)")
                    .font(.system(size: 60, weight: .heavy, design: .rounded))
                    .foregroundStyle(celebration.point.rarete.couleur)
                    .scaleEffect(apparu ? 1 : 0.2)

                VStack(spacing: 4) {
                    Text(celebration.point.titre).font(.title3.bold())
                    Text("\(celebration.point.rarete.nom) · \(celebration.point.arrondissement == 0 ? "Hors Paris" : "Paris " + Geo.arrondissement(celebration.point.arrondissement))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                if let n = celebration.nouveauNiveau {
                    Label("Niveau \(n.rang) : \(n.nom) !", systemImage: "arrow.up.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }

                ForEach(celebration.defis) { d in
                    HStack(spacing: 12) {
                        Image(systemName: d.symbole)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color(StyleMarqueur.or), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Défi réussi").font(.caption).foregroundStyle(.secondary)
                            Text(d.titre).font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                        Text("+\(d.bonus)").font(.headline.monospacedDigit()).foregroundStyle(Color(StyleMarqueur.or))
                    }
                    .padding(12)
                    .background(Color(StyleMarqueur.or).opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                Text("Total : \(jeu.total) points · \(jeu.visites.count) fontaine\(jeu.visites.count > 1 ? "s" : "")")
                    .font(.subheadline).foregroundStyle(.secondary)

                Button {
                    dismiss()
                } label: {
                    Text("Continuer").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, minHeight: geo.size.height)
        }
        }
        .onAppear {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) { apparu = true }
        }
    }
}
