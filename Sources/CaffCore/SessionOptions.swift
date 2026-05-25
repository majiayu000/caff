public struct SessionOptions: Equatable, Sendable {
    public var duration: SessionDuration
    public var keepDisplayAwake: Bool
    public var reason: String

    public init(
        duration: SessionDuration,
        keepDisplayAwake: Bool = false,
        reason: String = "Caff is keeping this Mac awake"
    ) {
        self.duration = duration
        self.keepDisplayAwake = keepDisplayAwake
        self.reason = reason
    }
}
