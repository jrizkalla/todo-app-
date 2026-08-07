//
//  Item.swift
//  TODO
//
//  Created by John Rizkalla on 8/7/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
