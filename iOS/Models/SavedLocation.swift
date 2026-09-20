import CoreLocation
import Foundation
import SwiftData

@Model
final class SavedLocation {
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double
    var isFavorite: Bool
    var createdAt: Date

    init(name: String,
         address: String = "",
         latitude: Double,
         longitude: Double,
         isFavorite: Bool = false,
         createdAt: Date = .now) {
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.isFavorite = isFavorite
        self.createdAt = createdAt
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
