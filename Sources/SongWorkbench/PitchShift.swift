import Foundation

enum PitchShift {
    static let range = -12...12

    static func normalized(_ semitones: Int) -> Int {
        min(max(semitones, range.lowerBound), range.upperBound)
    }

    static func cents(for semitones: Int) -> Float {
        Float(normalized(semitones) * 100)
    }
}
