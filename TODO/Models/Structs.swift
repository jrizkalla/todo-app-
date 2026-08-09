//
//  Structs.swift
//  TODO
//
//  Created by John Rizkalla on 8/8/26.
//

import Foundation
import FoundationModels

extension CompletionState: PromptRepresentable {
    var promptRepresentation: Prompt {
        self.rawValue
    }
}

struct TodoStruct : PromptRepresentable {
    var title: String
    var notes: String
    var state: CompletionState?
    
    var assignedDate: Date?
    var assignedHasTime: Bool
    
    var assignedString: String {
        guard let assignedDate else { return "none" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = assignedHasTime ? .short : .none
        return formatter.string(from: assignedDate)
    }
    
    var duration: TimeInterval?
    
    var dueDate: Date?
    var dueHasTime: Bool
    
    var dueDateString : String {
        guard let dueDate else { return "none" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = dueHasTime ? .short : .none
        return formatter.string(from: dueDate)
    }
    
    var isProject: Bool
    
    var space: SpaceStruct?
    
    var parentTitle: String?
    
    var promptRepresentation: Prompt {
        "\(self.isProject ? "project" : "TODO"): \(self.title)\n"
        "\tSpace: \(space?.name ?? "none")"
        "\tnotes:\n\(self.notes)\n"
        "\tstate: \(self.state?.rawValue ?? "none")\n"
        "\tassigned date: \(self.assignedString)\n"
        "\tduration: \(self.duration?.description.appending("s") ?? "none" )\n"
        "\tdue date: \(self.dueDateString)\n"
        "\tparent title: \(self.parentTitle ?? "none")"
    }
}


struct SpaceStruct {
    var name: String
    @Guide(description: "the symbol displayed in the UI")
    var symbolName: String
}


extension Space {
    func toStruct() -> SpaceStruct {
        .init(name: name, symbolName: symbolName)
    }
}

extension Todo {
    func toStruct() -> TodoStruct {
        .init(
            title: title,
            notes: notes,
            state: state,
            assignedDate: assignedDate,
            assignedHasTime: assignedHasTime,
            duration: duration,
            dueDate: dueDate,
            dueHasTime: dueHasTime,
            isProject: isProject,
            space: space?.toStruct(),
            parentTitle: parent?.title)
    }
}

