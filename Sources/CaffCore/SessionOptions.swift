public struct SessionOptions: Equatable, Sendable {
    public var duration: SessionDuration
    public var source: SessionSource
    public var keepDisplayAwake: Bool
    public var reason: String

    public init(
        duration: SessionDuration,
        source: SessionSource = .manual,
        keepDisplayAwake: Bool = false,
        reason: String = "Caff is keeping this Mac awake"
    ) {
        self.duration = duration
        self.source = source
        self.keepDisplayAwake = keepDisplayAwake
        self.reason = reason
    }
}
