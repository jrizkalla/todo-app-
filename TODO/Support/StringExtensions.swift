//
//  StringExtensions.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        guard self.hasSuffix(suffix) else { return self }
        return String(self.dropLast(suffix.count))
    }
}
