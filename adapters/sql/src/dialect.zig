//! What differs between SQL databases, as far as the compiler is concerned.
//!
//! A `Dialect` is always passed as a comptime parameter, so each one gets
//! its own specialised compiler and none of these fields is looked at while
//! a statement is being rendered.

pub const Dialect = struct {
    placeholder: Placeholder,
    /// Wraps every identifier; a `quote` inside a name is doubled.
    /// `'"'` is standard SQL; MySQL uses `` '`' ``.
    quote: u8 = '"',
    /// Supports `INSERT ... RETURNING *` (Postgres, SQLite 3.35+). Read by
    /// the write statements, which come with the `zom-pg` gateway.
    returning: bool,
    /// Has `ILIKE`. Without it, `ilike` is rendered as
    /// `LOWER(x) LIKE LOWER(pattern)`.
    ilike: bool,
    /// Understands `ORDER BY x ASC NULLS LAST`. Without it, a nullable sort
    /// key is rendered as `x IS NULL ASC, x ASC`, which orders the same way.
    nulls_order: bool = true,
    /// What to put after `LIMIT` when there is an offset but no limit, for
    /// databases that reject a bare `OFFSET` (SQLite: `-1`). `null` when a
    /// bare `OFFSET` is valid.
    limit_all: ?[]const u8 = null,

    pub const Placeholder = enum {
        /// `$1`, `$2`, ...: Postgres.
        dollar_n,
        /// `?`: SQLite, MySQL.
        question,
    };

    pub const postgres: Dialect = .{
        .placeholder = .dollar_n,
        .returning = true,
        .ilike = true,
    };

    /// SQLite 3.35 or later (`RETURNING`; `NULLS FIRST` / `NULLS LAST`
    /// came in 3.30). SQLite's `LIKE` ignores ASCII case unless
    /// `PRAGMA case_sensitive_like = ON`, which zom's `like` assumes.
    pub const sqlite: Dialect = .{
        .placeholder = .question,
        .returning = true,
        .ilike = false,
        .limit_all = "-1",
    };
};
