import BoatCore

/// Settings > Sightlines: how high the user's eye is. Stored as feet above the street, or -1 to use GPS altitude.
enum EyeHeightSetting {
    static let key = "eyeHeightFeet"
    static let automatic = -1
    /// Where the stepper starts when switched on: about the fifth floor.
    static let manualDefault = 50

    static func eyeHeight(setting feet: Int, gpsAltitude: Double?) -> EyeHeight {
        feet >= 0 ? .aboveGround(Double(feet) * 0.3048) : .altitude(gpsAltitude)
    }
}
