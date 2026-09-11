/**
 Wraps a secret so accidental interpolation, logging, or reflection cannot
 leak it. Reading the real value requires naming `exposedValue`, which is
 greppable in review.
 */
public struct Redacted<Value: Sendable>: Sendable, CustomStringConvertible,
                                          CustomDebugStringConvertible,
                                          CustomReflectable {
    public let exposedValue: Value
    public init(_ value: Value) { self.exposedValue = value }
    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }

    public var customMirror: Mirror { Mirror(self, children: []) }
}

extension Redacted: Equatable where Value: Equatable {}
