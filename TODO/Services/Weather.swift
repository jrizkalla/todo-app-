//
//  Weather.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//
import WeatherKit
import CoreLocation
import Combine

@MainActor
final class TodoWeatherService: NSObject, ObservableObject {
    
    static let shared = TodoWeatherService()
    
    private var locManager: CLLocationManager
    var currentLocation: CLLocation?
    @Published var weather: Weather?
    
    override init() {
        locManager = CLLocationManager()
        super.init()
        locManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locManager.delegate = self
        locManager.startUpdatingLocation()
    }
    
    deinit {
        locManager.stopUpdatingLocation()
    }
    
    func getWeather() async throws -> Weather? {
        guard let loc = currentLocation else { return nil }
        let service = WeatherService()
        return try await service.weather(for: loc)
    }
    
    func updateWeather() {
        Task {
            if let weather = try? await getWeather() {
                Task { @MainActor in
                    self.weather = weather
                }
            }
            
        }
    }
}


extension TodoWeatherService: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        print("got current location")
        currentLocation = locations.last!
        updateWeather()
    }
}
