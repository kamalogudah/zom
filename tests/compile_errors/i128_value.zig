// expect: zom: i128 is a signed integer wider than 64 bits; only unsigned ones go up to 128
const zom = @import("zom");

export fn entry() void {
    _ = zom.query.toValue(@as(i128, -1));
}
