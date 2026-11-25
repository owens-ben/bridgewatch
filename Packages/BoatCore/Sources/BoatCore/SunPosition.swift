import CoreLocation
import Foundation

/// Where the sun is, for night mode (docs/DESIGN.md: on between sunset and sunrise at the user's location).
/// NOAA's solar position equations: good to well under a minute for sunrise and sunset at the river's latitude.
public enum SunPosition {
    /// Elevation of the sun's center at sunrise and sunset, allowing for refraction and the sun's radius.
    public static let horizonDegrees = -0.833

    /// Elevation of the sun's center above the horizon, degrees (no refraction correction).
    public static func elevation(at date: Date, coordinate: CLLocationCoordinate2D) -> Double {
        let julianDay = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julianDay - 2_451_545) / 36_525

        let meanLongitude = (280.466_46 + t * (36_000.769_83 + t * 0.000_303_2)).truncatingRemainder(dividingBy: 360)
        let meanAnomaly = 357.529_11 + t * (35_999.050_29 - 0.000_153_7 * t)
        let eccentricity = 0.016_708_634 - t * (0.000_042_037 + 0.000_000_126_7 * t)
        let center = sin(rad(meanAnomaly)) * (1.914_602 - t * (0.004_817 + 0.000_014 * t))
            + sin(rad(2 * meanAnomaly)) * (0.019_993 - 0.000_101 * t)
            + sin(rad(3 * meanAnomaly)) * 0.000_289
        let omega = 125.04 - 1_934.136 * t
        let apparentLongitude = meanLongitude + center - 0.005_69 - 0.004_78 * sin(rad(omega))
        let meanObliquity = 23 + (26 + (21.448 - t * (46.815 + t * (0.000_59 - t * 0.001_813))) / 60) / 60
        let obliquity = meanObliquity + 0.002_56 * cos(rad(omega))
        let declination = asin(sin(rad(obliquity)) * sin(rad(apparentLongitude)))

        let y = pow(tan(rad(obliquity) / 2), 2)
        let l0 = rad(meanLongitude), m = rad(meanAnomaly)
        let equationOfTimeMinutes = 4 * deg(
            y * sin(2 * l0) - 2 * eccentricity * sin(m) + 4 * eccentricity * y * sin(m) * cos(2 * l0)
                - 0.5 * y * y * sin(4 * l0) - 1.25 * eccentricity * eccentricity * sin(2 * m))

        let secondsIntoUTCDay = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let minutesIntoUTCDay = (secondsIntoUTCDay < 0 ? secondsIntoUTCDay + 86_400 : secondsIntoUTCDay) / 60
        var trueSolarTime = (minutesIntoUTCDay + equationOfTimeMinutes + 4 * coordinate.longitude)
            .truncatingRemainder(dividingBy: 1_440)
        if trueSolarTime < 0 { trueSolarTime += 1_440 }
        var hourAngle = trueSolarTime / 4 - 180
        if hourAngle < -180 { hourAngle += 360 }

        let latitude = rad(coordinate.latitude)
        let cosZenith = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(rad(hourAngle))
        return 90 - deg(acos(max(-1, min(1, cosZenith))))
    }

    /// True between sunset and sunrise.
    public static func isNight(at date: Date, coordinate: CLLocationCoordinate2D) -> Bool {
        elevation(at: date, coordinate: coordinate) < horizonDegrees
    }

    /// The next sunrise or sunset after `date`, found to the second; nil if the sun neither rises nor sets within
    /// `window` (polar day or night).
    public static func nextTransition(
        after date: Date, coordinate: CLLocationCoordinate2D, within window: TimeInterval = 36 * 3_600
    ) -> (date: Date, becomesNight: Bool)? {
        func above(_ d: Date) -> Bool { elevation(at: d, coordinate: coordinate) >= horizonDegrees }
        let step: TimeInterval = 300
        var previous = date
        var wasAbove = above(date)
        var elapsed: TimeInterval = 0
        while elapsed < window {
            elapsed += step
            let next = date.addingTimeInterval(elapsed)
            let isAbove = above(next)
            if isAbove != wasAbove {
                // Bisect down to a second.
                var low = previous, high = next
                while high.timeIntervalSince(low) > 1 {
                    let mid = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if above(mid) == wasAbove { low = mid } else { high = mid }
                }
                return (high, becomesNight: wasAbove)
            }
            previous = next
            wasAbove = isAbove
        }
        return nil
    }
}

private func rad(_ degrees: Double) -> Double { degrees * .pi / 180 }
private func deg(_ radians: Double) -> Double { radians * 180 / .pi }
