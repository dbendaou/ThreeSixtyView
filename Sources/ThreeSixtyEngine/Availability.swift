public enum EngineAvailability {
    #if os(macOS)
    public static let supportsPlayback = true
    #else
    public static let supportsPlayback = false
    #endif
}
