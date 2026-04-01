import Foundation

/// Generates a unique name by appending " (1)", " (2)", etc. if the base name already exists.
func nextUniqueName(base: String, existingNames: Set<String>) -> String {
    if !existingNames.contains(base) {
        return base
    }
    var counter = 1
    while existingNames.contains("\(base) (\(counter))") {
        counter += 1
    }
    return "\(base) (\(counter))"
}
