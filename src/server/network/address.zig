//! IPv4/IPv6 address value helpers used by the network server.
const std = @import("std");

const IpAddress = std.Io.net.IpAddress;

/// Wraps a standard-library IP address while exposing port-aware helpers.
pub const Address = struct {
    /// The IP family, address bytes, and port represented by this value.
    ip: IpAddress,

    /// Creates an address from an already parsed standard-library IP value.
    pub fn fromIp(ip: IpAddress) Address {
        return .{ .ip = ip };
    }

    /// Constructs an IPv4 address from its four bytes and listening port.
    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return fromIp(.{ .ip4 = .{ .bytes = bytes, .port = port } });
    }

    /// Constructs an IPv6 address, including flow and interface metadata.
    pub fn initIp6(bytes: [16]u8, port: u16, flow: u32, interface_index: u32) Address {
        return fromIp(.{ .ip6 = .{
            .bytes = bytes,
            .port = port,
            .flow = flow,
            .interface = .{ .index = interface_index },
        } });
    }

    /// Parses an IP literal with the supplied port; propagates parse errors.
    pub fn parseIp(text: []const u8, port: u16) !Address {
        return fromIp(try IpAddress.parse(text, port));
    }

    /// Returns the port associated with this address.
    pub fn getPort(self: Address) u16 {
        return self.ip.getPort();
    }

    /// Replaces this address's port without changing its IP or family metadata.
    pub fn setPort(self: *Address, port: u16) void {
        var ip = self.ip;
        ip.setPort(port);
        self.* = fromIp(ip);
    }

    /// Compares the complete IP address, including its port.
    pub fn eql(a: Address, b: Address) bool {
        return a.ip.eql(&b.ip);
    }

    /// Compares IP identity while deliberately ignoring both ports.
    pub fn eqlIp(a: Address, b: Address) bool {
        var a_ip = a.ip;
        var b_ip = b.ip;
        a_ip.setPort(0);
        b_ip.setPort(0);
        return a_ip.eql(&b_ip);
    }
};
