import CoreGraphics
import Foundation

/// One colour in the icon's sky, as plain components.
///
/// Components rather than `CGColor` so a palette can be compared and tested:
/// `CGColor` equality depends on colour space and is not something a test
/// should have to reason about.
public struct SkyColour: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public func mixed(with other: SkyColour, _ amount: Double) -> SkyColour {
        let t = min(max(amount, 0), 1)
        return SkyColour(
            red + (other.red - red) * t,
            green + (other.green - green) * t,
            blue + (other.blue - blue) * t)
    }

    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

/// The sky the icon is drawn against, at a given time of day.
///
/// **Why the clock and not the weather.** WeatherKit would give real sunrise
/// and sunset, and it needs the `com.apple.developer.weatherkit` entitlement,
/// which needs a team identifier — the same wall that stops notifications
/// working in this build (see HANDOFF). Real solar times without it would mean
/// CoreLocation, and asking a download manager for the user's location so it
/// can tint an icon is not a trade worth offering. So the phases below are
/// clock times, which are wrong by up to an hour or so at the solstices and
/// right about the shape of a day everywhere.
///
/// `SolarTimes` is the seam: give it a real sunrise and sunset and every phase
/// shifts with them. Nothing supplies one yet.
public struct SkyPalette: Equatable, Sendable {
    public var top: SkyColour
    public var bottom: SkyColour
    /// What the clouds are lit by. White at noon, warm at either end of the
    /// day, and a cool slate at night — clouds take the colour of whatever is
    /// lighting them, which at dusk is the part of the sky the sun just left.
    public var cloud: SkyColour
    /// How present the clouds are. Lower after dark, where a bright cloud
    /// would read as a hole in the sky rather than as weather.
    public var cloudOpacity: Double

    public init(top: SkyColour, bottom: SkyColour, cloud: SkyColour, cloudOpacity: Double) {
        self.top = top
        self.bottom = bottom
        self.cloud = cloud
        self.cloudOpacity = cloudOpacity
    }

    public func mixed(with other: SkyPalette, _ amount: Double) -> SkyPalette {
        let t = min(max(amount, 0), 1)
        return SkyPalette(
            top: top.mixed(with: other.top, t),
            bottom: bottom.mixed(with: other.bottom, t),
            cloud: cloud.mixed(with: other.cloud, t),
            cloudOpacity: cloudOpacity + (other.cloudOpacity - cloudOpacity) * t)
    }

    // MARK: - The phases

    /// Midday, and the one the asset catalogue is rendered with: the bundle
    /// icon cannot change with the hour, so it is always noon on disk and the
    /// Dock is where the sky follows the clock.
    public static let day = SkyPalette(
        top: SkyColour(0.541, 0.796, 1.000),
        bottom: SkyColour(0.106, 0.478, 0.878),
        cloud: SkyColour(1, 1, 1),
        cloudOpacity: 1)

    static let night = SkyPalette(
        top: SkyColour(0.075, 0.106, 0.243),
        bottom: SkyColour(0.027, 0.043, 0.114),
        cloud: SkyColour(0.42, 0.48, 0.64),
        cloudOpacity: 0.62)

    static let firstLight = SkyPalette(
        top: SkyColour(0.192, 0.243, 0.451),
        bottom: SkyColour(0.404, 0.310, 0.408),
        cloud: SkyColour(0.72, 0.62, 0.68),
        cloudOpacity: 0.75)

    static let sunrise = SkyPalette(
        top: SkyColour(0.400, 0.573, 0.871),
        bottom: SkyColour(0.976, 0.639, 0.451),
        cloud: SkyColour(1.0, 0.87, 0.78),
        cloudOpacity: 1)

    static let goldenHour = SkyPalette(
        top: SkyColour(0.376, 0.596, 0.914),
        bottom: SkyColour(0.980, 0.671, 0.373),
        cloud: SkyColour(1.0, 0.85, 0.70),
        cloudOpacity: 1)

    static let sunset = SkyPalette(
        top: SkyColour(0.267, 0.318, 0.588),
        bottom: SkyColour(0.855, 0.400, 0.361),
        cloud: SkyColour(0.98, 0.72, 0.65),
        cloudOpacity: 0.95)

    static let dusk = SkyPalette(
        top: SkyColour(0.129, 0.161, 0.365),
        bottom: SkyColour(0.361, 0.216, 0.318),
        cloud: SkyColour(0.62, 0.55, 0.62),
        cloudOpacity: 0.75)

    // MARK: - Choosing one

    /// Where the sun is, as far as this cares. Clock times by default; hand it
    /// real ones and the whole day shifts to match.
    public struct SolarTimes: Equatable, Sendable {
        /// Hours after local midnight, fractional.
        public var sunrise: Double
        public var sunset: Double

        public init(sunrise: Double, sunset: Double) {
            self.sunrise = sunrise
            self.sunset = sunset
        }

        public static let clock = SolarTimes(sunrise: 6.5, sunset: 19.5)
    }

    /// The sky at a wall-clock moment.
    public static func at(
        _ date: Date, calendar: Calendar = .current, solar: SolarTimes = .clock
    ) -> SkyPalette {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
        return at(hour: hour, solar: solar)
    }

    /// **Phases are placed relative to sunrise and sunset, not at fixed
    /// hours.** Written the other way round first, and midwinter in a northern
    /// timezone then showed a bright noon sky at four in the afternoon while
    /// it was dark outside. Everything here is an offset from the two times
    /// that actually move.
    public static func at(hour: Double, solar: SolarTimes = .clock) -> SkyPalette {
        let keyframes: [(Double, SkyPalette)] = [
            (solar.sunrise - 1.5, night),
            (solar.sunrise - 0.6, firstLight),
            (solar.sunrise, sunrise),
            (solar.sunrise + 1.5, day),
            (solar.sunset - 1.5, day),
            (solar.sunset - 0.6, goldenHour),
            (solar.sunset, sunset),
            (solar.sunset + 0.9, dusk),
            (solar.sunset + 1.8, night),
        ]

        let now = hour.truncatingRemainder(dividingBy: 24)
        // Before the first keyframe or after the last is the same stretch of
        // night, wrapped round midnight — hence the modulo on the gap rather
        // than clamping to either end, which would freeze the sky between
        // 21:18 and 05:00 instead of carrying it through.
        guard let first = keyframes.first, let last = keyframes.last else { return day }
        if now < first.0 || now >= last.0 {
            let span = 24 - last.0 + first.0
            let elapsed = (now - last.0 + 24).truncatingRemainder(dividingBy: 24)
            return last.1.mixed(with: first.1, span > 0 ? elapsed / span : 0)
        }
        for (index, frame) in keyframes.enumerated().dropLast() {
            let next = keyframes[index + 1]
            guard now < next.0 else { continue }
            let span = next.0 - frame.0
            return frame.1.mixed(with: next.1, span > 0 ? (now - frame.0) / span : 0)
        }
        return day
    }
}
