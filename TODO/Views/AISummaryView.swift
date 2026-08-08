//
//  AISummaryView.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//
import SwiftUI
import WeatherKit

struct AISummaryView : View {
    
    @Environment(AppSettings.self) private var settings
    @StateObject var weatherService = TodoWeatherService.shared
    
    var timeOfDay: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 4..<12:
            "morning"
        case 12..<(12+5):
            "afternoon"
        case (12+5)..<(12+9):
            "evening"
        default:
            "night"
        }
    }
    
    var nameGreeting: String {
        settings.userInfo.name.map {
            " \($0)"
        } ?? ""
    }
    
    
    var body: some View {
        VStack(alignment: .leading) {
            Text("Good \(timeOfDay)\(nameGreeting)")
                .font(.largeTitle)
                .fontWeight(.medium)
            
            if let weather = weatherService.weather {
                Text("Weather: \(weather.hourlyForecast)")
            } else {
                Text("No weather info available")
            }
        }
    }
}


#if DEBUG

#Preview {
    AISummaryView()
        .padding(.top)
        .previewEnvironment()
}

#endif
