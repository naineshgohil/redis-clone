const std = @import("std");

const StoredValue = struct {
    value: []const u8,

    // Unix timestamp in milliseconds, null = no expiration
    expires_at: ?i64,

    pub fn isExpired(self: StoredValue) bool {
        if (self.expires_at) |expiry| {
            const now = std.time.milliTimestamp();
            return now >= expiry;
        }

        return false;
    }
};

pub const Storage = struct {
    map: std.StringHashMap(StoredValue),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Storage {
        return Storage{
            .map = std.StringHashMap(StoredValue).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Storage) void {
        var it = self.map.iterator();

        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.value);
        }

        self.map.deinit();
    }

    pub fn set(self: *Storage, key: []const u8, value: []const u8) !void {
        // Check if key already exists
        if (self.map.getPtr(key)) |stored_value_ptr| {
            self.allocator.free(stored_value_ptr.value);

            const value_copy = try self.allocator.dupe(u8, value);
            stored_value_ptr.* = StoredValue{ .value = value_copy, .expires_at = null };
        } else {

            // Duplicate the key and value to own the memory
            const key_copy = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_copy);

            const value_copy = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_copy);

            try self.map.put(key_copy, StoredValue{ .value = value_copy, .expires_at = null });
        }
    }

    pub fn get(self: *Storage, key: []const u8) ?[]const u8 {
        if (self.map.getPtr(key)) |stored_value| {
            // Check if expired
            if (stored_value.isExpired()) {
                try self.deleteKey(key);
                return null;
            }

            return stored_value.value;
        }

        return null;
    }

    pub fn delete(self: *Storage, key: []const u8) !bool {
        if (self.map.fetchRemove(key)) |kv| {
            self.allocator.free(kv.value.value);
            self.allocator.free(kv.key);
            return true;
        }

        return false;
    }

    fn deleteKey(self: *Storage, key: []const u8) !void {
        _ = try self.delete(key);
    }

    pub fn exists(self: *Storage, key: []const u8) bool {
        if (self.map.getPtr(key)) |stored_value| {
            if (stored_value.isExpired()) {
                try self.deleteKey(key);
                return false;
            }

            return true;
        }

        return false;
    }

    pub fn expire(self: *Storage, key: []const u8, seconds: i64) !bool {
        if (self.map.getPtr(key)) |stored_value_ptr| {
            if (stored_value_ptr.isExpired()) {
                try self.deleteKey(key);
                return false;
            }

            const now = std.time.milliTimestamp();
            stored_value_ptr.* = StoredValue{ .value = stored_value_ptr.value, .expires_at = now + (seconds * 1000) };

            return true;
        }

        return false;
    }

    pub fn persist(
        self: *Storage,
        key: []const u8,
    ) !bool {
        if (self.map.getPtr(key)) |stored_value_ptr| {
            if (stored_value_ptr.isExpired()) {
                try self.deleteKey(key);
                return false;
            }

            if (stored_value_ptr.expires_at != null) {
                stored_value_ptr.* = StoredValue{ .value = stored_value_ptr.value, .expires_at = null };
                return true;
            }

            return false;
        }

        return false;
    }

    // Time to live
    pub fn ttl(self: *Storage, key: []const u8) ?i64 {
        if (self.map.getPtr(key)) |stored_value| {
            if (stored_value.isExpired()) {
                try self.deleteKey(key);
                return null;
            }

            if (stored_value.expires_at) |expiry| {
                const now = std.time.milliTimestamp();
                const remaining_ms = expiry - now;
                return @divFloor(remaining_ms, 1000);
            }

            // no expiration set
            return -1;
        }

        // key doesn't exists
        return null;
    }

    pub fn keys(self: *Storage, allocator: std.mem.Allocator, pattern: []const u8) ![][]const u8 {
        var result = std.ArrayListUnmanaged([]const u8){};

        errdefer {
            for (result.items) |key| {
                allocator.free(key);
            }
            result.deinit(allocator);
        }

        var it = self.map.iterator();

        while (it.next()) |entry| {
            if (entry.value_ptr.isExpired()) {
                continue;
            }

            if (std.mem.eql(u8, pattern, "*") or matchPattern(entry.key_ptr.*, pattern)) {
                const key_copy = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key_copy);
                try result.append(allocator, key_copy);
            }
        }

        const slice = try result.toOwnedSlice(allocator);
        std.debug.print("keys() returning {d} keys\n", .{slice.len});

        for (slice, 0..) |key, i| {
            std.debug.print("Key {d}: '{s}'\n", .{ i, key });
        }

        return slice;
    }
};

fn matchPattern(str: []const u8, pattern: []const u8) bool {
    // TODO: Implement proper glob matching
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        if (star_pos == 0) {
            const suffix = pattern[1..];
            return std.mem.endsWith(u8, str, suffix);
        } else if (star_pos == pattern.len - 1) {
            const prefix = pattern[0..star_pos];
            return std.mem.startsWith(u8, str, prefix);
        }
    }

    return std.mem.eql(u8, str, pattern);
}

// === TESTS ===

test "Storage: set and get" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");
    const value = stor.get("key1");

    try testing.expect(value != null);
    try testing.expectEqualStrings("value1", value.?);
}

test "Storage: get: non-existent key" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    const value = stor.get("non-existent");
    try testing.expect(value == null);
}

test "Storage: overwrite existing key" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");
    try stor.set("key1", "value2");

    const value = stor.get("key1");

    try testing.expect(value != null);
    try testing.expectEqualStrings("value2", value.?);
}

test "Storage: delete key" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");
    const deleted = try stor.delete("key1");

    try testing.expectEqual(true, deleted);
    try testing.expect(stor.get("key1") == null);
}

test "Storage: delete non-existent key" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    const deleted = stor.delete("non-existent");
    try testing.expectEqual(false, deleted);
}

test "Storage: exists check" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");

    try testing.expect(stor.exists("key1"));
    try testing.expectEqual(false, stor.exists("non-existent"));
}

test "Storage: expire key" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");
    const expire = try stor.expire("key1", 1);

    try testing.expectEqual(true, expire);
    try testing.expect(stor.exists("key1"));

    std.Thread.sleep(1000 * std.time.ns_per_ms);

    try testing.expectEqual(false, stor.exists("key1"));
}

test "Storage: expire non-existent key" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    const expire = try stor.expire("non-existent", 10);
    try testing.expectEqual(false, expire);
}

test "Storage: expired key is deleted on access" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");
    _ = try stor.expire("key1", 1);

    std.Thread.sleep(1000 * std.time.ns_per_ms);

    _ = stor.get("key1");

    try testing.expectEqual(false, stor.exists("key1"));
}

test "Storage: ttl returns remaining seconds" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");
    _ = try stor.expire("key1", 100);

    const ttl_value = stor.ttl("key1");
    try testing.expect(ttl_value.? > 90 and ttl_value.? <= 100);
}

test "Storage: ttl returns -1 for key without expiration" {
    const testing = std.testing;
    var stor = Storage.init(testing.allocator);
    defer stor.deinit();

    try stor.set("key1", "value1");

    const ttl_value = stor.ttl("key1");
    try testing.expectEqual(-1, ttl_value);
}
