//! zom-sql = rom's `rom-sql`, minus the driver: compiles a relation's query
//! into a parameterized statement for a `Dialect`. A gateway such as
//! zom-pg pairs it with a driver: compile, bind `params`, decode rows.
//!
//!     const compiled = try zom_sql.compileRelation(.postgres, allocator, users.where(.age, .gte, 18));
//!     defer compiled.deinit(allocator);
//!     // compiled.sql: SELECT "id", ... FROM "users" WHERE "age" >= $1

pub const Dialect = @import("dialect.zig").Dialect;

const compile = @import("compile.zig");
pub const Compiled = compile.Compiled;
pub const CompileError = compile.CompileError;
pub const RenderError = compile.RenderError;
pub const Params = compile.Params;
pub const compileSelect = compile.compileSelect;
pub const compileProjected = compile.compileProjected;
pub const compileRelation = compile.compileRelation;
pub const writeSelect = compile.writeSelect;
pub const writeIdent = compile.writeIdent;

test {
    _ = compile;
    _ = @import("compile_test.zig");
}
