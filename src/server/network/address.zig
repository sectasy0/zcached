const std = @import("std");

const IpAddress = std.Io.net.IpAddress;

pub const Address = struct {
    ip: IpAddress,
    pub fn fromIp(ip: IpAddress) Address {
        return .{ .ip = ip };
    }

    pub fn initIp4(bytes: [4]u8, port: u16) Address {
        return fromIp(.{ .ip4 = .{ .bytes = bytes, .port = port } });
    }

    pub fn initIp6(bytes: [16]u8, port: u16, flow: u32, interface_index: u32) Address {
        return fromIp(.{ .ip6 = .{
            .bytes = bytes,
            .port = port,
            .flow = flow,
            .interface = .{ .index = interface_index },
        } });
    }

    pub fn parseIp(text: []const u8, port: u16) !Address {
        return fromIp(try IpAddress.parse(text, port));
    }

    pub fn getPort(self: Address) u16 {
        return self.ip.getPort();
    }

    pub fn setPort(self: *Address, port: u16) void {
        var ip = self.ip;
        ip.setPort(port);
        self.* = fromIp(ip);
    }

    pub fn eql(a: Address, b: Address) bool {
        return a.ip.eql(&b.ip);
    }

    pub fn eqlIp(a: Address, b: Address) bool {
        var a_ip = a.ip;
        var b_ip = b.ip;
        a_ip.setPort(0);
        b_ip.setPort(0);
        return a_ip.eql(&b_ip);
    }
};
