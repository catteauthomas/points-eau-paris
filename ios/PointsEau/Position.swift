import CoreLocation
import Foundation

/// Position de l'utilisateur, en direct (autorisation « Pendant l'utilisation de l'app » seulement).
@MainActor
final class Position: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var location: CLLocation?
    @Published private(set) var autorisation: CLAuthorizationStatus

    private let manager = CLLocationManager()

    override init() {
        autorisation = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .fitness
    }

    var refusee: Bool { autorisation == .denied || autorisation == .restricted }

    func demarrer() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        manager.startUpdatingLocation()
    }

    func arreter() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in self.location = l }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let statut = manager.authorizationStatus
        Task { @MainActor in
            self.autorisation = statut
            if statut == .authorizedWhenInUse || statut == .authorizedAlways {
                self.manager.startUpdatingLocation()
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
