//
//  Weather.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//
import CoreLocation
import Combine
import FoundationModels

@MainActor
final class TodoWeatherService: NSObject, ObservableObject {
    
    static let shared = TodoWeatherService()
    
    private var locManager: CLLocationManager
    var currentLocation: CLLocation?
    @Published var weather: WeatherForecast?
    
    override init() {
        locManager = CLLocationManager()
        super.init()
        locManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locManager.delegate = self
        locManager.requestLocation()
    }
    
    
    func getWeather() async throws -> WeatherForecast? {
        guard let loc = currentLocation else { return nil }
        return try await fetchForecast(for: loc)
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
        guard currentLocation != locations.last! else { return }
        print("got current location")
        currentLocation = locations.last!
        updateWeather()
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        print(error)
    }
}

// MARK: Open-Mataeo API (code from ChatGPT snippet)

struct WeatherForecast: Equatable, Decodable, PromptRepresentable {
    let latitude: Double
    let longitude: Double
    let timezone: String
    let daily: DailyForecast

    struct DailyForecast: Equatable, Decodable, PromptRepresentable {
        
        let time: [String]
        let temperatureMax: [Double]
        let temperatureMin: [Double]
        let precipitationProbabilityMax: [Int?]

        enum CodingKeys: String, CodingKey {
            case time
            case temperatureMax = "temperature_2m_max"
            case temperatureMin = "temperature_2m_min"
            case precipitationProbabilityMax = "precipitation_probability_max"
        }
        
        var promptRepresentation: Prompt {
            "Hourly forcast:\n".appending(
                (0..<time.count).map{ i in
                    "\(time): temp \(temperatureMin[i]) - \(temperatureMax[i]), precipitation: \(precipitationProbabilityMax[i]?.description ?? "none")"
                }.joined(separator: "\n")
            )
        }
    }
    
    var promptRepresentation: Prompt {
        "Daily weather for (\(latitude), \(longitude)):\n"
        daily
    }
}

enum WeatherError: Error {
    case invalidURL
    case invalidResponse
}

enum TempUnit: String {
    case celsius
    case fahrenheit
}

func fetchForecast(for location: CLLocation, unit: TempUnit = .celsius) async throws -> WeatherForecast {
    var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
    components?.queryItems = [
        URLQueryItem(name: "latitude", value: "\(location.coordinate.latitude)"),
        URLQueryItem(name: "longitude", value: "\(location.coordinate.longitude)"),
        URLQueryItem(
            name: "daily",
            value: "temperature_2m_max,temperature_2m_min,precipitation_probability_max"
        ),
        URLQueryItem(name: "temperature_unit", value: unit.rawValue),
        URLQueryItem(name: "timezone", value: "auto"),
        URLQueryItem(name: "forecast_days", value: "7")
    ]

    guard let url = components?.url else {
        throw WeatherError.invalidURL
    }
    print(url)

    var request = URLRequest(url: url)
    request.timeoutInterval = 10

    let (data, response) = try await URLSession.shared.data(for: request)

    guard let httpResponse = response as? HTTPURLResponse,
          200..<300 ~= httpResponse.statusCode else {
        throw WeatherError.invalidResponse
    }

    return try JSONDecoder().decode(WeatherForecast.self, from: data)
}


