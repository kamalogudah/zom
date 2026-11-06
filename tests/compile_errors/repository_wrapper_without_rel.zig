// expect: zom: repository wrapper `repository_wrapper_without_rel.Users` for relation 'users' needs a `rel` field of type
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway },
    .relations = .{ .users = .{ fakes.ItemSchema, .default } },
});
const Users = struct {
    relation: @FieldType(App.Relations, "users"),
};
const Repo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users } });

comptime {
    _ = Repo;
}
