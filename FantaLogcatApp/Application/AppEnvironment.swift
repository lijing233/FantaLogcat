struct AppEnvironment: Sendable {
    static let production = AppEnvironment()
    static let test = AppEnvironment()
}
