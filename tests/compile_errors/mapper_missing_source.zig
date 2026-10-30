// expect: zom.Mapper: mapper_missing_source.Profile.nickname has no source attribute `nickname` and no default
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Profile = struct { id: u32, nickname: []const u8 };
const ProfileMapper = zom.Mapper(User, Profile, .{});

export fn entry() void {
    _ = ProfileMapper.call(.{ .id = 1, .name = "Achieng" });
}
