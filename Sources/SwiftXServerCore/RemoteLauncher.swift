import Foundation

/// Common surface for the launcher types. TelnetLauncher and SSHLauncher
/// both conform; AppDelegate holds whichever one fits the entry's transport.
public protocol RemoteLauncher: AnyObject, Sendable {
    /// Short status lines for the progress window's header area
    /// ("Connecting…", "Connected.", "Launched.").
    func onStatus(_ callback: @escaping (String) -> Void)
    /// Streamed transcript output. `bold` marks our own injected lines
    /// (commands we sent, masked password) vs the remote's reply.
    func onText(_ callback: @escaping (String, Bool) -> Void)
    /// Start the launch. `completion` fires once on the main queue.
    func launch(completion: @escaping (Result<Void, Error>) -> Void)
    /// Abort an in-flight launch (user clicked Cancel).
    func cancel()
}

extension TelnetLauncher: RemoteLauncher {}
