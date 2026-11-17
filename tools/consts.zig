//! Shared network defaults and framing byte used by the command-line tools.

/// Loopback address used when a tool is not given a host override.
pub const HOST = "127.0.0.1";
/// Default TCP port on which the local zcached server listens.
pub const PORT = 7556;

/// Terminates one protocol frame and marks the end of a command or response.
pub const EXT_CHAR: u8 = '\x03';
