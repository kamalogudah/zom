// expect: zom: gateway 'tb' (adapter 'tigerbeetle') does not support transactions
// expect: TigerBeetle's all-or-nothing writes are linked event chains: `relation.linked().add(a).add(b).commit()`
//! TigerBeetle has no transactions; the error points to linked chains.
const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");

const App = zom.Container(.{
    .gateways = .{ .tb = zom_tigerbeetle.Gateway },
    .relations = .{ .transfers = .{ zom_tigerbeetle.Transfer, .tb } },
});

export fn entry() void {
    var app: App = undefined;
    app.transaction(.tb, {}, struct {
        fn f(_: void, tx: App.Relations) !void {
            _ = tx;
        }
    }.f) catch {};
}
