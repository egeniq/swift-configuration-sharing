import Configuration
import Dependencies
import Foundation
import Logging
import ServiceLifecycle

/// Protocol for services that support explicit refresh
public protocol Refreshable: Sendable {
    func refresh() async throws
}

/// A default configuration provider dependency with async initialization support.
///
/// Most configuration providers have async initializers, so this dependency provides
/// a factory pattern that allows you to set up the initialization logic in
/// `prepareDependencies` (which is synchronous) and then call it asynchronously
/// when needed.
///
/// The reader is cached after the first initialization, so subsequent calls return
/// the same instance. If services are provided, they are automatically managed in a
/// ServiceGroup for lifecycle management.
///
/// ## Platform Requirements
///
/// This library declares a minimum deployment target of **iOS 15 / macOS 12 / tvOS 15 /
/// watchOS 8 / visionOS 1**. The library's own code is fully compatible with these targets:
/// - Swift Concurrency (`async`/`await`, `actor`, `Task`) — available since iOS 15, which
///   sets the practical floor for this library.
/// - `ServiceGroup` from swift-service-lifecycle — fully compatible with the iOS 15 minimum.
/// - `@SharedReader` from swift-sharing — fully compatible with the iOS 15 minimum.
///
/// ### Known limitation: `swift-configuration` dependency
///
/// The `swift-configuration` package (Apple, v1.x) internally uses `Synchronization.Mutex`,
/// which requires **iOS 18 / macOS 15 / tvOS 18 / watchOS 11** on Apple platforms.
/// Until upstream provides a version that backports that synchronization primitive (e.g., via
/// `NSLock` or `os_unfair_lock`), apps targeting iOS 15–17 will receive a compiler error when
/// building for Apple platforms, even though the rest of this library is compatible.
///
/// When a version of `swift-configuration` that supports iOS 15+ becomes available, simply
/// updating the dependency pin in `Package.resolved` will be sufficient; no other code changes
/// are required in this library.
///
/// ### Features that degrade gracefully
///
/// - **Service lifecycle management** via `ServiceGroup` already uses `#available` guards
///   internally for newer OS optimisations and works without changes within the iOS 15 minimum.
/// - All `@SharedReader`/`@Dependency` integration is compatible with the iOS 15 minimum.
///
/// Example usage:
/// ```swift
/// @main
/// struct MyApp: App {
///     init() {
///         prepareDependencies {
///             $0.defaultConfigurationReader = DefaultConfigurationReader(
///                 initialize: {
///                     var logger = Logger(label: "com.example.config")
///                     logger.logLevel = .debug
///                     
///                     let provider = try await AppRemoteConfigProvider(
///                         url: configURL,
///                         pollInterval: .seconds(30),
///                         resolutionContext: context,
///                         logger: logger
///                     )
///                     
///                     // Return reader, services to manage, and logger
///                     return (ConfigReader(providers: [provider]), [provider], logger)
///                 }
///             )
///         }
///     }
/// 
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///         }
///     }
/// }
/// ```
public struct DefaultConfigurationReader: Sendable {
    /// Async initialization function that creates and returns a configuration reader.
    /// Returns a tuple of (ConfigReader, services to manage, optional logger).
    /// If services are provided, they will be managed in a ServiceGroup using the logger.
    private let initializeImpl: @Sendable () async throws -> (ConfigReader, [any Service]?, Logging.Logger?)
    
    /// Refresh method that can be called to trigger configuration updates.
    /// Providers that conform to the Refreshable protocol will be refreshed.
    /// This is useful when returning from the background to ensure fresh configuration.
    public var refresh: @Sendable () async -> Void
    
    public init(initialize: @escaping @Sendable () async throws -> (ConfigReader, [any Service]?, Logging.Logger?)) {
        self.initializeImpl = {
            try await GlobalReaderCache.shared.getOrInitialize(with: initialize)
        }
        self.refresh = {
            await GlobalReaderCache.shared.refresh()
        }
    }
    
    /// Public async initialization method that uses the wrapped factory
    public var initialize: @Sendable () async throws -> (ConfigReader, [any Service]?, Logging.Logger?) {
        get { initializeImpl }
    }
}

/// Internal actor for managing the initialized ConfigReader and its services globally.
private actor GlobalReaderCache {
    static let shared = GlobalReaderCache()
    private var cachedReader: ConfigReader?
    private var serviceGroup: ServiceGroup?
    private var services: [any Service]?
    private var ongoingInitialization: Task<(ConfigReader, [any Service]?, Logging.Logger?), Error>?
    
    func getOrInitialize(
        with factory: @escaping @Sendable () async throws -> (ConfigReader, [any Service]?, Logging.Logger?)
    ) async throws -> (ConfigReader, [any Service]?, Logging.Logger?) {
        // Fast path: check if already cached (doesn't require actor re-entry for subsequent calls)
        if let cached = cachedReader {
            return (cached, nil, nil)
        }
        
        // For initialization, we need actor serialization
        // This returns immediately if initialization is in progress
        return try await initializeIfNeeded(with: factory)
    }
    
    private func initializeIfNeeded(
        with factory: @escaping @Sendable () async throws -> (ConfigReader, [any Service]?, Logging.Logger?)
    ) async throws -> (ConfigReader, [any Service]?, Logging.Logger?) {
        // Double-check in case another task beat us here
        if let cached = cachedReader {
            return (cached, nil, nil)
        }
        
        // If already initializing, wait for that initialization
        if let existingTask = ongoingInitialization {
            return try await existingTask.value
        }
        
        // We're the first - start initialization
        let task = Task<(ConfigReader, [any Service]?, Logging.Logger?), Error> {
            return try await factory()
        }
        
        ongoingInitialization = task
        
        do {
            let result = try await task.value
            ongoingInitialization = nil
            
            // Store the result
            storeResult(reader: result.0, services: result.1, logger: result.2)
            
            return result
        } catch {
            ongoingInitialization = nil
            throw error
        }
    }
    
    private func storeResult(reader: ConfigReader, services: [any Service]?, logger: Logging.Logger?) {
        cachedReader = reader
        self.services = services
        
        // If services are provided, manage them in a ServiceGroup
        if let services = services, !services.isEmpty {
            let group = ServiceGroup(services: services, logger: logger ?? Logger(label: "ConfigurationSharing"))
            self.serviceGroup = group
            
            // Run the service group in the background
            Task.detached(priority: .userInitiated) {
                do {
                    try await group.run()
                } catch {
                    // Log but don't fail - configuration reader still works
                    if let logger = logger {
                        logger.error("ServiceGroup error: \(error)")
                    }
                }
            }
        }
    }
    
    func refresh() async {
        // Call refresh on any providers that support it
        if let services = services {
            for service in services {
                // Check if service conforms to Refreshable protocol
                if let refreshable = service as? Refreshable {
                    try? await refreshable.refresh()
                }
            }
        }
        
        // Trigger a snapshot update to notify watchers of potential configuration changes
        guard let reader = cachedReader else { return }
        
        // Create a fresh snapshot to prompt any watchers to check for updates
        _ = reader.snapshot()
    }
}

extension DependencyValues {
    /// The default configuration reader factory for async initialization.
    ///
    /// Set this in `prepareDependencies` to provide a factory function that creates
    /// your configuration reader asynchronously.
    ///
    /// Example:
    /// ```swift
    /// prepareDependencies {
    ///     $0.defaultConfigurationReader = DefaultConfigurationReader(initialize: {
    ///         var logger = Logger(label: "com.example.config")
    ///         let provider = try await YourConfigProvider(logger: logger)
    ///         // Pass services that conform to Service for lifecycle management
    ///         return (ConfigReader(providers: [provider]), [provider], logger)
    ///     })
    /// }
    /// ```
    public var defaultConfigurationReader: DefaultConfigurationReader {
        get { self[DefaultConfigurationReaderKey.self] }
        set { self[DefaultConfigurationReaderKey.self] = newValue }
    }
}

private enum DefaultConfigurationReaderKey: DependencyKey {
    static let liveValue = DefaultConfigurationReader {
        fatalError(
            """
            No default configuration reader has been configured.
            
            Set one in prepareDependencies:
            
                prepareDependencies {
                    $0.defaultConfigurationReader = DefaultConfigurationReader(initialize: {
                        var logger = Logger(label: "com.app.config")
                        let provider = try await YourConfigProvider(logger: logger)
                        return (ConfigReader(providers: [provider]), [provider], logger)
                    })
                }
            """
        )
    }
    
    static let testValue = DefaultConfigurationReader {
        fatalError(
            """
            Unimplemented: @Dependency(\\.defaultConfigurationReader)
            
            Provide a test reader:
            
                withDependencies {
                    $0.defaultConfigurationReader = DefaultConfigurationReader(initialize: {
                        (ConfigReader(providers: []), nil, nil)
                    })
                } operation: {
                    // Test code here
                }
            """
        )
    }
}
