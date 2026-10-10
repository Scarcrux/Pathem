import Foundation

public enum GestureSupportError: Error, Equatable, Sendable {
    case invalidStroke, invalidSegmentThreshold, invalidCaptureDuration
}

public enum StrokeDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var letter: String {
        switch self {
        case .left: return "L"
        case .right: return "R"
        case .up: return "U"
        case .down: return "D"
        }
    }

    public var arrow: String {
        switch self {
        case .left: return "←"
        case .right: return "→"
        case .up: return "↑"
        case .down: return "↓"
        }
    }
}

public struct StrokePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

public enum CoordinateConvention: Equatable, Sendable { case yUp, yDown }

public struct StrokeSample: Equatable, Sendable {
    public let point: StrokePoint
    public let timestamp: Double
    public init(x: Double, y: Double, timestamp: Double, convention: CoordinateConvention = .yUp) {
        point = StrokePoint(x: x, y: convention == .yUp ? y : -y)
        self.timestamp = timestamp
    }
}

public enum StrokeOverflowPolicy: Equatable, Sendable {
    /// Commandem refuses the entire overlong stroke.
    case reject
    /// Pathem historically recognizes only its first four directions.
    case prefix
}

public enum StrokeRejection: String, Codable, CaseIterable, Sendable {
    case invalidCoordinates, invalidTimestamp, outOfOrderTimestamp, segmentLimit
}

public enum StrokeCaptureState<Cancellation: Equatable & Sendable>: Equatable, Sendable {
    case capturing
    case rejected(StrokeRejection)
    case cancelled(Cancellation)
    case released
}

public enum StrokeCaptureResult<Cancellation: Equatable & Sendable>: Equatable, Sendable {
    case recognized([StrokeDirection])
    case empty
    case rejected(StrokeRejection)
    case cancelled(Cancellation)
}

/// One sequence, one terminal release. No app identity, commands, files, menus
/// or authorization enter this engine. Adapters supply cancellation reasons.
public struct StrokeCapture<Cancellation: Equatable & Sendable>: Sendable {
    public static var maximumVisualPoints: Int { 256 }
    public static var maximumSegments: Int { 4 }
    public private(set) var state: StrokeCaptureState<Cancellation> = .capturing
    public private(set) var directions: [StrokeDirection] = []
    private let threshold: Double
    private let duration: Double?
    private let timeoutReason: Cancellation
    private let overflow: StrokeOverflowPolicy
    private let startedAt: Double
    private var lastTimestamp: Double
    private var anchor: StrokePoint
    private var points: [StrokePoint] = []
    private var nextIndex = 0

    public init(
        origin: StrokeSample, threshold: Double = 18, maximumDuration: Double? = nil,
        overflow: StrokeOverflowPolicy = .reject, timeoutReason: Cancellation
    ) throws {
        guard threshold.isFinite, threshold > 0 else {
            throw GestureSupportError.invalidSegmentThreshold
        }
        if let maximumDuration {
            guard maximumDuration.isFinite, maximumDuration > 0 else {
                throw GestureSupportError.invalidCaptureDuration
            }
        }
        self.threshold = threshold
        duration = maximumDuration
        self.overflow = overflow
        self.timeoutReason = timeoutReason
        startedAt = origin.timestamp
        lastTimestamp = origin.timestamp
        anchor = origin.point
        points.reserveCapacity(Self.maximumVisualPoints)
        directions.reserveCapacity(Self.maximumSegments)
        if !origin.point.isFinite {
            state = .rejected(.invalidCoordinates)
        } else if !origin.timestamp.isFinite || origin.timestamp < 0 {
            state = .rejected(.invalidTimestamp)
        } else {
            appendVisual(origin.point)
        }
    }

    public var visualPointCount: Int { points.count }
    public var visualPoints: [StrokePoint] {
        guard points.count == Self.maximumVisualPoints, nextIndex != 0 else { return points }
        return Array(points[nextIndex...]) + Array(points[..<nextIndex])
    }

    /// Square dead zone, dominant axis, horizontal ties, accepted-anchor advance
    /// even when repeated directions collapse. Geometry is shared by both apps.
    @discardableResult
    public mutating func move(_ sample: StrokeSample, cancellation: Cancellation? = nil)
        -> StrokeCaptureState<Cancellation>
    {
        guard state == .capturing else { return state }
        if let cancellation {
            cancel(cancellation)
            return state
        }
        guard sample.point.isFinite else { return reject(.invalidCoordinates) }
        guard validateTime(sample.timestamp) else { return state }
        let dx = sample.point.x - anchor.x
        let dy = sample.point.y - anchor.y
        guard dx.isFinite, dy.isFinite else { return reject(.invalidCoordinates) }
        appendVisual(sample.point)
        guard max(abs(dx), abs(dy)) >= threshold else { return state }
        let direction: StrokeDirection =
            abs(dx) >= abs(dy)
            ? (dx >= 0 ? .right : .left) : (dy >= 0 ? .up : .down)
        anchor = sample.point
        if directions.last != direction {
            if directions.count == Self.maximumSegments {
                if overflow == .reject { return reject(.segmentLimit) }
            } else {
                directions.append(direction)
            }
        }
        return state
    }

    @discardableResult
    public mutating func advanceClock(to timestamp: Double, cancellation: Cancellation? = nil)
        -> StrokeCaptureState<Cancellation>
    {
        guard state == .capturing else { return state }
        if let cancellation { cancel(cancellation) } else { _ = validateTime(timestamp) }
        return state
    }

    public mutating func release(_ sample: StrokeSample, cancellation: Cancellation? = nil)
        -> StrokeCaptureResult<Cancellation>?
    {
        guard state != .released else { return nil }
        move(sample, cancellation: cancellation)
        let result: StrokeCaptureResult<Cancellation>
        switch state {
        case .capturing: result = directions.isEmpty ? .empty : .recognized(directions)
        case .rejected(let reason): result = .rejected(reason)
        case .cancelled(let reason): result = .cancelled(reason)
        case .released: return nil
        }
        state = .released
        clear()
        return result
    }

    public mutating func cancel(_ reason: Cancellation) {
        guard state == .capturing else { return }
        state = .cancelled(reason)
        clear()
    }

    private mutating func validateTime(_ timestamp: Double) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else {
            reject(.invalidTimestamp)
            return false
        }
        guard timestamp >= lastTimestamp else {
            reject(.outOfOrderTimestamp)
            return false
        }
        let elapsed = timestamp - startedAt
        guard elapsed.isFinite else {
            reject(.invalidTimestamp)
            return false
        }
        if let duration, elapsed >= duration {
            cancel(timeoutReason)
            return false
        }
        lastTimestamp = timestamp
        return true
    }

    @discardableResult
    private mutating func reject(_ reason: StrokeRejection) -> StrokeCaptureState<Cancellation> {
        state = .rejected(reason)
        clear()
        return state
    }
    private mutating func appendVisual(_ point: StrokePoint) {
        if points.count < Self.maximumVisualPoints {
            points.append(point)
        } else {
            points[nextIndex] = point
        }
        nextIndex = (nextIndex + 1) % Self.maximumVisualPoints
    }
    private mutating func clear() {
        directions.removeAll(keepingCapacity: true)
        points.removeAll(keepingCapacity: true)
        nextIndex = 0
    }
}
