//! Shared request-framing and client-buffer settings for the network layer.
/// Initial capacity and preferred initial read size for each client.
pub const CLIENT_BUFFER: usize = 4096;

/// Byte that terminates a protocol frame on the client stream.
pub const EXT_CHAR: u8 = '\x03';
