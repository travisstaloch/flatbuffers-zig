const std = @import("std");
const StringPool = @import("string_pool.zig").StringPool;
const types = @import("types.zig");
const Type = @import("./type.zig").Type;

const Allocator = std.mem.Allocator;
const log = types.log;

fn writeComment(writer: anytype, e: anytype, doc_comment: bool) !void {
    const prefix = if (doc_comment) "///" else "//";
    for (0..e.DocumentationLen()) |i| if (e.Documentation(i)) |d| try writer.print("\n{s}{s}", .{ prefix, d });
}

pub fn getBasename(fname: []const u8) []const u8 {
    const last_slash = std.mem.lastIndexOf(u8, fname, "/") orelse 0;
    return fname[last_slash + 1 ..];
}

fn getDeclarationName(fname: []const u8) []const u8 {
    const basename = getBasename(fname);
    const first_dot = std.mem.indexOfScalar(u8, basename, '.') orelse basename.len;
    return basename[0..first_dot];
}

fn changeCase(writer: anytype, input: []const u8, mode: enum { camel, title }) !void {
    var capitalize_next = mode == .title;
    for (input, 0..) |c, i| {
        switch (c) {
            '_', '-', ' ' => {
                capitalize_next = true;
            },
            else => {
                try writer.writeByte(if (i == 0 and mode == .camel)
                    std.ascii.toLower(c)
                else if (capitalize_next)
                    std.ascii.toUpper(c)
                else
                    c);
                capitalize_next = false;
            },
        }
    }
}

fn toCamelCase(writer: anytype, input: []const u8) !void {
    try changeCase(writer, input, .camel);
}

test "toCamelCase" {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();

    try toCamelCase(buf.writer(), "not_camel_case");
    try std.testing.expectEqualStrings("notCamelCase", buf.items);

    try buf.resize(0);
    try toCamelCase(buf.writer(), "Not_Camel_Case");
    try std.testing.expectEqualStrings("notCamelCase", buf.items);

    try buf.resize(0);
    try toCamelCase(buf.writer(), "Not Camel Case");
    try std.testing.expectEqualStrings("notCamelCase", buf.items);
}

fn toTitleCase(writer: anytype, input: []const u8) !void {
    try changeCase(writer, input, .title);
}

fn toSnakeCase(writer: anytype, input: []const u8) !void {
    for (input, 0..) |c, i| {
        if (((c >= 'A' and c <= 'Z') or c == ' ') and i != 0) try writer.writeByte('_');
        if (c != ' ') try writer.writeByte(std.ascii.toLower(c));
    }
}

fn fieldLessThan(context: void, a: types.Field, b: types.Field) bool {
    _ = context;
    return a.Id() < b.Id();
}

pub const CodeWriter = struct {
    const Self = @This();
    const ImportDeclarations = std.StringHashMap([]const u8);
    const IndexOffset = struct {
        index: usize,
        offset: usize,
    };
    const OffsetMap = std.StringHashMap([]const u8);

    allocator: Allocator,
    import_declarations: ImportDeclarations,
    string_pool: StringPool,
    schema: types.Schema,
    opts: types.Options,
    fname: []const u8,

    pub fn init(allocator: Allocator, schema: types.Schema, opts: types.Options, fname: []const u8) Self {
        return .{
            .allocator = allocator,
            .import_declarations = ImportDeclarations.init(allocator),
            .string_pool = StringPool.init(allocator),
            .schema = schema,
            .opts = opts,
            .fname = fname,
        };
    }

    pub fn deinit(self: *Self) void {
        self.import_declarations.deinit();
        self.string_pool.deinit();
    }

    fn putDeclaration(self: *Self, decl: []const u8, mod: []const u8) !void {
        const owned_decl = try self.string_pool.getOrPut(decl);
        const owned_mod = try self.string_pool.getOrPut(mod);
        try self.import_declarations.put(owned_decl, owned_mod);
    }

    fn addDeclaration(self: *Self, declaration: []const u8) !void {
        var module = std.ArrayList(u8).init(self.allocator);
        defer module.deinit();

        try module.appendSlice(declaration);
        try module.appendSlice(self.opts.extension);
        try self.putDeclaration(declaration, module.items);
    }

    fn writeIndexDeclaration(self: *Self, writer: anytype, declaration: []const u8) !void {
        // This prevents CodeWriter having to return a ArrayList([]const u8) and codegen accumulating it
        // into a StringHashMap
        const fname = self.fname[self.opts.gen_path.len..];
        try writer.print("pub const {0s} = @import(\".{1s}\").{0s};", .{ declaration, fname });
    }

    // This struct owns returned string
    fn getIdentifier(self: *Self, ident: []const u8) ![]const u8 {
        const zig = std.zig;
        if (zig.Token.getKeyword(ident) != null or zig.primitives.isPrimitive(ident)) {
            const buf = try std.fmt.allocPrint(self.allocator, "@\"{s}\"", .{ident});
            defer self.allocator.free(buf);
            return self.string_pool.getOrPut(buf);
        } else {
            return self.string_pool.getOrPut(ident);
        }
    }

    // This struct owns returned string
    fn getPrefixedIdentifier(self: *Self, ident: []const u8, prefix: []const u8) ![]const u8 {
        var prefixed = std.fmt.allocPrint(self.allocator, "{s} {s}", .{ prefix, ident });
        defer self.allocator.free(prefixed);

        return try getIdentifier(prefixed);
    }

    // This struct owns returned string
    fn getFunctionName(self: *Self, name: []const u8) ![]const u8 {
        var res = std.ArrayList(u8).init(self.allocator);
        defer res.deinit();

        try toCamelCase(res.writer(), name);
        return try self.getIdentifier(res.items);
    }

    // This struct owns returned string
    fn getFieldName(self: *Self, name: []const u8) ![]const u8 {
        var res = std.ArrayList(u8).init(self.allocator);
        defer res.deinit();

        try toSnakeCase(res.writer(), name);
        return self.string_pool.getOrPut(res.items);
    }

    // This struct owns returned string
    fn getFieldNameForField(self: *Self, field: types.Field) ![]const u8 {
        if (field.Type().?.BaseType() == .UType) {
            // Remove "_type" suffix
            const name = field.Name();
            return try self.getFieldName(name[0 .. name.len - "_type".len]);
        }

        return try self.getFieldName(field.Name());
    }

    // This struct owns returned string
    fn getPrefixedTypeName(self: *Self, prefix: []const u8, name: []const u8) ![]const u8 {
        var tmp = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, name });
        defer self.allocator.free(tmp);

        var res = std.ArrayList(u8).init(self.allocator);
        defer res.deinit();

        try toTitleCase(res.writer(), tmp);
        return try self.getIdentifier(res.items);
    }

    // This struct owns returned string
    fn getTypeName(self: *Self, name: []const u8, is_packed: bool) ![]const u8 {
        return self.getPrefixedTypeName(if (is_packed) "packed " else "", name);
    }

    fn getMaybeModuleTypeName(self: *Self, type_: Type) ![]const u8 {
        switch (type_.base_type) {
            .Array, .Vector => |t| {
                const next_type = Type{
                    .base_type = type_.element,
                    .index = type_.index,
                    .is_packed = type_.is_packed,
                };
                const next_name = try self.getMaybeModuleTypeName(next_type);
                if (t == .Array) {
                    return try std.fmt.allocPrint(self.allocator, "[{d}]{s}", .{ type_.fixed_len, next_name });
                } else {
                    return try std.fmt.allocPrint(self.allocator, "[]{s}", .{next_name});
                }
            },
            else => |t| {
                if (type_.child(self.schema)) |child| {
                    // Capture the modules.
                    const decl_name = getDeclarationName(child.declarationFile());
                    const module = try self.getPrefixedTypeName(decl_name, " types");
                    try self.addDeclaration(module);

                    const is_packed = (type_.base_type == .Union or type_.base_type == .Obj) and type_.is_packed;

                    const typename = try self.getTypeName(child.name(), is_packed);
                    return std.fmt.allocPrint(self.allocator, "{s}{s}.{s}{s}", .{ if (type_.is_optional) "?" else "", module, typename, if (t == .UType) ".Tag" else "" });
                } else if (t == .UType or t == .Obj or t == .Union) {
                    const err = try std.fmt.allocPrint(self.allocator, "type index {d} for {any} not in schema", .{ type_.index, t });
                    log.err("{s}", .{err});
                    return err;
                } else {
                    return try std.fmt.allocPrint(self.allocator, "{s}", .{type_.name()});
                }
            },
        }
    }

    // This struct owns returned string.
    fn getType(self: *Self, type_: types.Type, is_packed: bool, is_optional: bool) ![]const u8 {
        var ty = Type.init(type_);
        ty.is_packed = is_packed;
        ty.is_optional = is_optional;

        const maybe_module_type_name = try self.getMaybeModuleTypeName(ty);
        defer self.allocator.free(maybe_module_type_name);

        return self.string_pool.getOrPut(maybe_module_type_name);
    }

    // Caller owns returned slice.
    fn sortedFields(self: *Self, object: types.Object) ![]types.Field {
        var res = std.ArrayList(types.Field).init(self.allocator);
        for (0..object.FieldsLen()) |i| try res.append(object.Fields(i).?);

        std.sort.pdq(types.Field, res.items, {}, fieldLessThan);

        return res.toOwnedSlice();
    }

    fn writeObjectFields(self: *Self, writer: anytype, object: types.Object, comptime is_packed: bool) !void {
        const fields = try self.sortedFields(object);
        defer self.allocator.free(fields);

        for (fields) |field| {
            const ty = field.Type().?;
            if (field.Deprecated() or ty.BaseType() == .UType) continue;
            const name = try self.getFieldNameForField(field);
            const typename = try self.getType(ty, is_packed, field.Optional());
            try writeComment(writer, field, true);
            if (is_packed) {
                const getter_name = try self.getFunctionName(name);
                var setter_buf = std.ArrayList(u8).init(self.allocator);
                defer setter_buf.deinit();
                try setter_buf.appendSlice("set");
                try setter_buf.append(std.ascii.toUpper(getter_name[0]));
                try setter_buf.appendSlice(getter_name[1..]);
                const setter_name = setter_buf.items;

                try writer.writeByte('\n');
                switch (ty.BaseType()) {
                    .UType, .Bool, .Byte, .UByte, .Short, .UShort, .Int, .UInt, .Long, .ULong, .Float, .Double => {
                        try writer.print(
                            \\
                            \\pub fn {0s}(self: Self) {1s} {{
                            \\  return self.table.read({1s}, self.table._tab.pos + {3d});
                            \\}}
                            \\pub fn {2s}(self: Self, val: {1s}) void {{
                            \\  self.table._tab.mutate({1s}, self.table._tab.pos + {3d}, val);
                            \\}}
                        , .{ getter_name, typename, setter_name, field.Offset() });
                    },
                    .String => {
                        try writer.print(
                            \\
                            \\pub fn {0s}(self: Self) {1s} {{
                            \\  const offset = self.table.offset({2d});
                            \\  if (offset == 0) {{
                            \\    // Vtable shows deprecated or out of bounds.
                            \\    return "";
                            \\  }} else {{
                            \\    return self.table.byteVector(offset);
                            \\  }}
                            \\}}
                        , .{ getter_name, typename, field.Offset() });
                    },
                    .Vector => {
                        // > Vectors are stored as contiguous aligned scalar elements prefixed by a 32bit element count
                        try writer.print(
                            \\
                            \\pub fn {0s}(self: Self) {1s} {{
                            \\  const len_offset = self.table.offset({2d});
                            \\  const len = if (len_offset == 0) 0 else self.table.vectorLen(len_offset);
                            \\  if (len == 0) return &.{{}};
                            \\  const offset = self.table.vector(len_offset);
                            \\  return std.mem.bytesAsSlice({1s}, self.table.bytes[offset..@sizeOf({1s}) * len]);
                            \\}}
                        , .{ getter_name, typename, field.Offset() });
                        try self.putDeclaration("std", "std");
                    },
                    .Obj => {
                        try writer.print(
                            \\
                            \\pub fn {0s}(self: Self) {1s} {{
                            \\  const offset = self.table.offset({2d});
                            \\  if (offset == 0) {{
                            \\    // Vtable shows deprecated or out of bounds.
                            \\    return null;
                            \\  }} else {{
                            \\    const offset2 = self.table.indirect(offset);
                            \\    return {1s}.init(self.table.bytes[offset2]);
                            \\  }}
                            \\}}
                        , .{ getter_name, typename, field.Offset() });
                    },
                    .Union => {
                        try writer.print(
                            \\
                            \\pub fn {0s}(self: Self) {1s} {{
                            \\  const offset = self.table.offset({2d});
                            \\  if (offset == 0) {{
                            \\    // Vtable shows deprecated or out of bounds.
                            \\    return null;
                            \\  }} else {{
                            \\    const union_table = self.table.union_(offset);
                            \\    return {1s}.init(union_table.bytes);
                            \\  }}
                            \\}}
                        , .{ getter_name, typename, field.Offset() });
                    },
                    .Array => {
                        try writer.print(
                            \\
                            \\pub fn {0s}(self: Self) {1s} {{
                            \\  // what to do for array at offset {2d}?
                            \\}}
                        , .{ getter_name, typename, field.Offset() });
                    },
                    else => {},
                }
            } else {
                try writer.print("\n    {s}: {s},", .{ name, typename });
            }
        }
    }

    // Struct owns returned string.
    fn getDefault(self: *Self, field: types.Field) ![]const u8 {
        const res = switch (field.Type().?.BaseType()) {
            .UType => try std.fmt.allocPrint(self.allocator, "@intToEnum({s}, {d})", .{ try self.getType(field.Type().?, false, false), field.DefaultInteger() }),
            .Bool => try std.fmt.allocPrint(self.allocator, "{s}", .{if (field.DefaultInteger() == 0) "false" else "true"}),
            .Byte, .UByte, .Short, .UShort, .Int, .UInt, .Long, .ULong => try std.fmt.allocPrint(self.allocator, "{d}", .{field.DefaultInteger()}),
            .Float, .Double => try std.fmt.allocPrint(self.allocator, "{}", .{field.DefaultReal()}),
            .String => try std.fmt.allocPrint(self.allocator, "\"\"", .{}),
            .Vector, .Array => try std.fmt.allocPrint(self.allocator, "{s}", .{".{}"}),
            .Obj => try std.fmt.allocPrint(self.allocator, "{s}", .{if (field.Optional()) "null" else ".{}"}),
            else => |t| {
                log.err("cannot get default for base type {any}", .{t});
                return error.InvalidBaseType;
            },
        };
        defer self.allocator.free(res);

        return self.string_pool.getOrPut(res);
    }

    fn writePackForField(self: *Self, writer: anytype, field: types.Field, is_struct: bool, offset_map: *OffsetMap) !void {
        if (field.Padding() != 0) try writer.print("\n    builder.pad({d});", .{field.Padding()});
        const field_name = try self.getFieldNameForField(field);
        const ty = Type.initFromField(field);
        const ty_name = try self.getMaybeModuleTypeName(ty);
        switch (ty.base_type) {
            .None => {},
            .UType, .Bool, .Byte, .UByte, .Short, .UShort, .Int, .UInt, .Long, .ULong, .Float, .Double, .Array => {
                if (ty.is_optional or is_struct) {
                    try writer.print(
                        \\
                        \\    try builder.prepend({s}, self.{s});
                    , .{ ty_name, field_name });
                } else {
                    try writer.print(
                        \\
                        \\    try builder.prependSlot({s}, {d}, self.{s}, {s});
                    , .{ ty_name, field.Id(), field_name, try self.getDefault(field) });
                }
            },
            .String => {
                const offset = try self.string_pool.getOrPutFmt("try builder.createString(self.{s})", .{field_name});
                try offset_map.put(field_name, offset);
                try writer.print(
                    \\
                    \\    try builder.prependSlotUOff({d}, field_offsets.{s}, 0);
                , .{ field.Id(), field_name });
            },
            .Vector => {
                const alignment = 1;
                const offset = try self.string_pool.getOrPutFmt("try builder.createVector({s}, self.{s}, {d}, {d})", .{ ty_name[2..], field_name, ty.element_size, alignment });
                try offset_map.put(field_name, offset);
                try writer.print(
                    \\
                    \\    try builder.prependSlotUOff({d}, field_offsets.{s}, 0);
                , .{ field.Id(), field_name });
            },
            .Obj, .Union => {
                const offset = try self.string_pool.getOrPutFmt("try self.{s}.pack(builder)", .{field_name});
                try offset_map.put(field_name, offset);
                try writer.print(
                    \\
                    \\    try builder.prependSlotUOff({d}, field_offsets.{s});
                , .{ field.Id(), field_name });
            },
        }
    }

    fn writePackFn(self: *Self, writer: anytype, object: types.Object) !void {
        var offset_map = OffsetMap.init(self.allocator);
        defer offset_map.deinit();

        // Write field pack code to buffer to gather offsets
        var field_pack_code = std.ArrayList(u8).init(self.allocator);
        defer field_pack_code.deinit();
        const fields = try self.sortedFields(object);
        defer self.allocator.free(fields);
        for (fields) |field| {
            try self.writePackForField(field_pack_code.writer(), field, object.IsStruct(), &offset_map);
        }

        try writer.writeAll(
            \\
            \\
            \\pub fn pack(self: Self, builder: *flatbufferz.Builder) !u32 {
        );
        try self.putDeclaration("flatbufferz", "flatbufferz");

        if (offset_map.count() > 0) {
            try writer.writeAll("\nconst field_offsets = .{");
            var iter = offset_map.iterator();
            while (iter.next()) |kv| {
                try writer.print(
                    \\
                    \\    .{s} = {s},
                , .{ kv.key_ptr.*, kv.value_ptr.* });
            }
            try writer.writeAll("\n};");
        }
        try writer.writeByte('\n');

        if (fields.len > 0) {
            if (object.IsStruct()) {
                try writer.print(
                    \\
                    \\    try builder.prep({d}, {d});
                , .{ object.Minalign(), object.Bytesize() });
            } else {
                try writer.print(
                    \\
                    \\    try builder.startObject({d});
                , .{fields.len});
            }
        } else {
            try writer.writeAll(
                \\
                \\    _ = self;
                \\    _ = builder;
            );
        }

        try writer.writeAll(field_pack_code.items);

        if (fields.len > 0) {
            if (object.IsStruct()) {
                try writer.writeAll(
                    \\
                    \\    return builder.offset();
                );
            } else {
                try writer.writeAll(
                    \\
                    \\    return builder.endObject();
                );
            }
        }
        try writer.writeAll("\n}");
    }

    fn writeObjectPacked(self: *Self, writer: anytype, index_writer: anytype, object: types.Object, comptime is_packed: bool) !void {
        try writeComment(writer, object, true);
        const name = try self.getTypeName(object.Name(), false);
        const packed_name = try self.getTypeName(object.Name(), true);

        if (is_packed) {
            try self.writeIndexDeclaration(index_writer, packed_name);
            try writer.print("\n\npub const {s} = struct {{", .{packed_name});
            try writer.writeAll(
                \\
                \\table: flatbufferz.Table,
                \\
                \\const Self = @This();
                \\
                \\pub fn init(bytes: []u8) Self {
                \\    return .{ .table = .{ ._tab = .{ .bytes = bytes, .pos = 0 } } };
                \\}
                \\
                \\pub fn initRoot(bytes: []u8) Self {
                \\    const size = flatbufferz.encode.read(u32, bytes);
                \\    return Self.init(bytes[size + @sizeOf(u32)..]);
                \\}
            );
            try self.putDeclaration("flatbufferz", "flatbufferz");
            try self.writeObjectFields(writer, object, is_packed);
        } else {
            try self.writeIndexDeclaration(index_writer, name);
            try writer.print("\n\npub const {s} = struct {{", .{name});
            try self.writeObjectFields(writer, object, is_packed);
            try writer.print(
                \\
                \\
                \\const Self = @This();
                \\
                \\pub fn init(packed_struct: {s}) !Self {{
                \\    {s}
                \\    return .{{
            , .{ packed_name, if (object.FieldsLen() == 0) "_ = packed_struct;" else "" });
            for (0..object.FieldsLen()) |i| {
                const field = object.Fields(i).?;
                if (field.Type().?.BaseType() == .UType) continue;
                const field_name = try self.getFieldNameForField(field);
                const field_getter = try self.getFunctionName(field_name);
                try writer.print(
                    \\
                    \\    .{s} = packed_struct.{s}(),
                , .{ field_name, field_getter });
            }
            try writer.writeAll(
                \\
                \\    };
                \\}
            );
            try self.writePackFn(writer, object);
        }
        try writer.writeAll("\n};");
    }

    pub fn writeObject(self: *Self, writer: anytype, index_writer: anytype, object: types.Object) !void {
        try self.writeObjectPacked(writer, index_writer, object, false);
        try self.writeObjectPacked(writer, index_writer, object, true);
    }

    fn writeEnumFields(self: *Self, writer: anytype, enum_: types.Enum, is_union: bool, comptime is_packed: bool) !void {
        for (0..enum_.ValuesLen()) |i| {
            const enum_val = enum_.Values(i).?;
            try writeComment(writer, enum_val, true);
            if (is_union) {
                if (enum_val.Value() == 0) {
                    try writer.print("\n\t{s},", .{enum_val.Name()});
                } else {
                    const ty = enum_val.UnionType().?;
                    const typename = try self.getType(ty, is_packed, false);
                    try writer.print("\n\t{s}: {s},", .{ enum_val.Name(), typename });
                }
            } else {
                try writer.print("\n\t{s} = {},", .{ enum_val.Name(), enum_val.Value() });
            }
        }
    }

    fn writeEnumPacked(self: *Self, writer: anytype, index_writer: anytype, enum_: types.Enum, comptime is_packed: bool) !void {
        const underlying = enum_.UnderlyingType().?;
        const base_type = underlying.BaseType();
        const is_union = base_type == .Union or base_type == .UType;
        if (!is_union and is_packed) return;

        const name = try self.getTypeName(enum_.Name(), false);
        const packed_name = try self.getTypeName(enum_.Name(), true);
        const declaration = if (is_packed) packed_name else name;
        try self.writeIndexDeclaration(index_writer, declaration);
        try writer.writeByte('\n');
        try writeComment(writer, enum_, true);
        try writer.print("\n\npub const {s} = ", .{declaration});
        if (is_union) {
            try writer.writeAll("union(");
            if (is_packed) {
                try writer.writeAll("enum");
            } else {
                try writer.print("{s}.Tag", .{packed_name});
            }
            try writer.writeAll(") {");
        } else {
            const typename = Type.init(underlying).name();
            try writer.print(" enum({s}) {{", .{typename});
        }
        try self.writeEnumFields(writer, enum_, is_union, is_packed);
        if (is_union) {
            if (is_packed) {
                try writer.writeAll("\n\npub const Tag = std.meta.Tag(@This());");
            } else {
                try writer.print(
                    \\
                    \\
                    \\const Self = @This();
                    \\
                    \\pub fn init(packed_union: {s}) Self {{
                    \\    switch (packed_union) {{
                    \\        inline else => |field, union_tag| {{
                    \\            const UnionValue = @TypeOf(field);
                    \\            const union_value = UnionValue.init(packed_union);
                    \\            return @unionInit(Self, @tagName(union_tag), union_value);
                    \\        }},
                    \\    }}
                    \\}}
                    \\
                    \\pub fn pack(self: Self, builder: *flatbufferz.Builder) !u32 {{
                    \\    // Just packs value, not the utype tag.
                    \\    switch (self) {{
                    \\         inline else => |f| f.pack(builder),
                    \\    }}
                    \\}}
                , .{packed_name});
                try self.putDeclaration("std", "std");
                try self.putDeclaration("flatbufferz", "flatbufferz");
            }
        }

        try writer.writeAll("\n};");
    }

    pub fn writeEnum(self: *Self, writer: anytype, index_writer: anytype, enum_: types.Enum) !void {
        try self.writeEnumPacked(writer, index_writer, enum_, false);
        try self.writeEnumPacked(writer, index_writer, enum_, true);
    }

    fn isRootTable(self: Self, name: []const u8) bool {
        return if (self.schema.RootTable()) |root_table|
            std.mem.eql(u8, name, root_table.Name())
        else
            false;
    }

    pub fn writePrelude(self: *Self, writer: anytype, prelude: types.Prelude, name: []const u8) !void {
        try writer.print(
            \\//!
            \\//! generated by flatc-zig
            \\//! binary:     {s}
            \\//! schema:     {s}.fbs
            \\//! file ident: {?s}
            \\//! typename    {?s}
            \\//!
            \\
        , .{ prelude.bfbs_path, prelude.filename_noext, prelude.file_ident, name });
        try self.writeImportDeclarations(writer);

        if (self.isRootTable(name)) {
            try writer.print(
                \\
                \\
                \\pub const file_ident: flatbufferz.Builder.Fid = "{s}".*;
                \\pub const file_ext = "{s}";
            , .{ self.schema.FileIdent(), self.schema.FileExt() });
        }
    }

    fn writeImportDeclarations(self: Self, writer: anytype) !void {
        // Rely on index file. This can cause recursive deps for the root file, but zig handles that
        // without a problem.
        try writer.writeByte('\n');
        var iter = self.import_declarations.iterator();
        while (iter.next()) |kv| {
            try writer.print("\nconst {s} = @import(\"{s}\"); ", .{ kv.key_ptr.*, kv.value_ptr.* });
        }
    }
};
