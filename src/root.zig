//! zom: a Ruby Object Mapper (rom-rb) style data mapping toolkit for Zig.
//!
//! Layers, mirroring ROM:
//!   Gateway / Dataset  -> adapters (memory today, SQL compiler, more later)
//!   Schema             -> tuple struct + dataset name + primary key
//!   Relation           -> immutable, chainable query over a dataset
//!   Changeset          -> create / update data, committed explicitly
//!   Mapper / combine   -> tuples to domain structs, nested associations

const std = @import("std");

pub const query = @import("query.zig");
pub const Op = query.Op;
pub const Direction = query.Direction;
pub const Value = query.Value;
pub const Query = query.Query;

pub const Schema = @import("schema.zig").Schema;
pub const Relation = @import("relation.zig").Relation;

pub const changeset = @import("changeset.zig");

pub const mapper = @import("mapper.zig");
pub const Mapper = mapper.Mapper;
pub const combineMany = mapper.combineMany;

pub const memory = @import("adapters/memory.zig");
pub const sql = @import("adapters/sql.zig");

test {
    _ = @import("tests.zig");
}
