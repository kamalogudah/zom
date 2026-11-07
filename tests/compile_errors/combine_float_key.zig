// expect: zom.combine(.readings) on relation 'sensors': cannot group by a key of type `f64`; a combine key must be an integer (up to i64 or u128), an enum, a bool or a string
const zom = @import("zom");

const Sensor = struct { id: f64, name: []const u8 };
const Reading = struct { id: u32, sensor_id: f64, value: f64 };
const SensorSchema = zom.Schema(Sensor, "sensors", .id, .{
    .associations = struct {
        pub const readings = zom.hasMany(ReadingSchema, .sensor_id);
    },
});
const ReadingSchema = zom.Schema(Reading, "readings", .id, .{});

export fn entry() void {
    const std = @import("std");
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const sensors = zom.Relation(SensorSchema, zom.memory.Gateway).init(&gw) catch return;
    const readings = zom.Relation(ReadingSchema, zom.memory.Gateway).init(&gw) catch return;
    const Out = struct { id: f64, readings: []const Reading };
    _ = sensors.combine(.readings, readings).mapTo(Out, std.heap.page_allocator) catch return;
}
