import Foundation
import Photos
import CoreLocation

/// Turns photo GPS metadata into a place name and a "was this travel?" signal.
/// Photo coordinates are metadata (no location permission needed); reverse
/// geocoding sends only coordinates, never photos.
final class LocationResolver {
    private let geocoder = CLGeocoder()

    /// Compute and cache a rough "home" coordinate from the densest cluster of
    /// recent located photos. Coordinates only, no geocoding, so it's cheap.
    func ensureHomeComputed() {
        guard PreferenceStore.shared.home == nil else { return }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 2000
        let result = PHAsset.fetchAssets(with: .image, options: opts)

        var cells: [String: (count: Int, lat: Double, lon: Double)] = [:]
        result.enumerateObjects { asset, _, _ in
            guard let loc = asset.location else { return }
            // ~11km grid cells
            let key = "\(Int((loc.coordinate.latitude * 10).rounded()))_\(Int((loc.coordinate.longitude * 10).rounded()))"
            let current = cells[key]
            cells[key] = ((current?.count ?? 0) + 1, loc.coordinate.latitude, loc.coordinate.longitude)
        }

        if let best = cells.values.max(by: { $0.count < $1.count }) {
            PreferenceStore.shared.saveHome(lat: best.lat, lon: best.lon)
        }
    }

    func isTravel(_ location: CLLocation) -> Bool {
        guard let home = PreferenceStore.shared.home else { return false }
        let homeLoc = CLLocation(latitude: home.lat, longitude: home.lon)
        return location.distance(from: homeLoc) > 100_000 // > 100 km from home
    }

    /// Reverse-geocode a single photo's OWN coordinate into a display place string.
    ///
    /// Format: "City, State" when the photo is in the user's USUAL country, and
    /// "City, State, Country" only when it is NOT in the usual country. The usual
    /// country is inferred by reverse-geocoding the cached home cluster once and
    /// caching its ISO country code; if home is unknown we fall back to the device
    /// region (`Locale.current.region`).
    ///
    /// Accuracy: the city is taken from this placemark's own fields (`locality`
    /// first, then `subLocality`/`name`), never a cached or year-level location, so
    /// each photo resolves to where IT was actually taken.
    func placeName(for location: CLLocation, completion: @escaping (String?) -> Void) {
        resolveHomeCountryCode { [weak self] homeCountryCode in
            guard let self else { DispatchQueue.main.async { completion(nil) }; return }
            self.geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                let name = Self.placeString(from: placemarks?.first, homeCountryCode: homeCountryCode)
                DispatchQueue.main.async { completion(name) }
            }
        }
    }

    /// Build the display string from a placemark. City prefers `locality` (the actual
    /// city), then `subLocality`, then `name`; it never falls back to `administrativeArea`
    /// (which is the state/province) or `country` as the "city". The region (state) and
    /// country are appended per the home-country rule.
    static func placeString(from placemark: CLPlacemark?, homeCountryCode: String?) -> String? {
        guard let placemark else { return nil }

        let city = placemark.locality ?? placemark.subLocality ?? placemark.name
        let region = placemark.administrativeArea
        let country = placemark.country
        let isAbroad: Bool = {
            guard let here = placemark.isoCountryCode, let home = homeCountryCode else { return false }
            return here.caseInsensitiveCompare(home) != .orderedSame
        }()

        var parts: [String] = []
        if let city { parts.append(city) }
        // Only add the region if it isn't just a repeat of the city (some city-states do this).
        if let region, region.caseInsensitiveCompare(city ?? "") != .orderedSame { parts.append(region) }
        if isAbroad, let country, country.caseInsensitiveCompare(city ?? "") != .orderedSame {
            parts.append(country)
        }

        if parts.isEmpty { return country }
        return parts.joined(separator: ", ")
    }

    // MARK: Home country

    /// Cached ISO country code of the user's usual country, resolved once from the home
    /// cluster (or the device region as a fallback) and reused for every photo.
    private var homeCountryCode: String?
    private var homeCountryResolved = false
    private var pendingHomeCountry: [(String?) -> Void] = []

    private func resolveHomeCountryCode(_ completion: @escaping (String?) -> Void) {
        if homeCountryResolved { completion(homeCountryCode); return }

        pendingHomeCountry.append(completion)
        guard pendingHomeCountry.count == 1 else { return } // a resolve is already in flight

        let finish: (String?) -> Void = { [weak self] code in
            DispatchQueue.main.async {
                guard let self else { return }
                self.homeCountryCode = code
                self.homeCountryResolved = true
                let waiters = self.pendingHomeCountry
                self.pendingHomeCountry = []
                waiters.forEach { $0(code) }
            }
        }

        guard let home = PreferenceStore.shared.home else {
            finish(Locale.current.region?.identifier)
            return
        }
        let homeLoc = CLLocation(latitude: home.lat, longitude: home.lon)
        geocoder.reverseGeocodeLocation(homeLoc) { placemarks, _ in
            let code = placemarks?.first?.isoCountryCode ?? Locale.current.region?.identifier
            finish(code)
        }
    }
}
