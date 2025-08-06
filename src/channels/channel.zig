const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;
const ChannelError = @import("./common.zig").ChannelError;

pub fn Channel(comptime T: type) type {
    return struct {
        allocator: Allocator,
        data: DoublyLinkedList(T),
        mutex: Thread.Mutex,
        signal: Thread.Condition,
        completed: bool,

        const Self = @This();

        pub fn init(allocator: Allocator) ChannelError!*Self {
            const channel = allocator.create(Self) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            channel.* = .{ .allocator = allocator, .data = DoublyLinkedList(T){}, .mutex = Thread.Mutex{}, .signal = Thread.Condition{}, .completed = false };

            return channel;
        }

        pub fn getReader(self: *Self) Reader(T) {
            return .{ .channel = self };
        }

        pub fn getWriter(self: *Self) Writer(T) {
            return .{ .channel = self };
        }

        pub fn deinit(self: *Self) void {
            while (self.data.len != 0) {
                const node = self.data.popFirst().?;
                self.allocator.destroy(node);
            }

            self.allocator.destroy(self);
        }
    };
}

fn Writer(comptime T: type) type {
    return struct {
        channel: *Channel(T),
        const Self = @This();

        pub fn write(self: Self, data: T) ChannelError!void {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            if (self.channel.completed)
                return ChannelError.ChannelClosed;

            const node = self.channel.allocator.create(std.DoublyLinkedList(T).Node) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            node.data = data;
            self.channel.data.append(node);
            self.channel.signal.signal();
        }

        pub fn complete(self: Self) ChannelError!void {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            if (self.channel.completed)
                return ChannelError.ChannelClosed;

            self.channel.completed = true;
            self.channel.signal.broadcast();
        }
    };
}

fn Reader(comptime T: type) type {
    return struct {
        channel: *Channel(T),

        const Self = @This();

        pub fn read(self: Self) ?T {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            while (self.channel.data.len == 0) {
                if (self.channel.completed)
                    return null;

                self.channel.signal.wait(&self.channel.mutex);
            }

            const node = self.channel.data.popFirst().?;
            defer self.channel.allocator.destroy(node);

            return node.data;
        }
    };
}

// Tests
const testing = std.testing;

test "Channel init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    try testing.expect(channel.completed == false);
    try testing.expect(channel.data.len == 0);
}

test "Channel basic write and read" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    try writer.write(42);
    const data = reader.read();

    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 42), data.?);
}

test "Channel multiple writes and reads" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    // Write multiple values
    try writer.write(1);
    try writer.write(2);
    try writer.write(3);

    // Read them back in order (FIFO)
    try testing.expectEqual(@as(i32, 1), reader.read().?);
    try testing.expectEqual(@as(i32, 2), reader.read().?);
    try testing.expectEqual(@as(i32, 3), reader.read().?);
}

test "Channel completion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    try writer.complete();
    const data = reader.read();

    try testing.expect(data == null);
    try testing.expect(channel.completed == true);
}

test "Write to completed channel returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();

    try writer.complete();

    const result = writer.write(42);
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Complete already completed channel returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();

    try writer.complete();

    const result = writer.complete();
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Channel with string data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel([]const u8).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    try writer.write("hello");
    try writer.write("world");

    const data1 = reader.read();
    const data2 = reader.read();

    try testing.expect(data1 != null);
    try testing.expect(data2 != null);
    try testing.expectEqualStrings("hello", data1.?);
    try testing.expectEqualStrings("world", data2.?);
}

test "Channel read from completed channel with remaining data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const writer = channel.getWriter();
    const reader = channel.getReader();

    // Write data first
    try writer.write(100);
    try writer.write(200);

    // Then complete the channel
    try writer.complete();

    // Should still be able to read existing data
    try testing.expectEqual(@as(i32, 100), reader.read().?);
    try testing.expectEqual(@as(i32, 200), reader.read().?);

    // After all data is consumed, should return null
    try testing.expect(reader.read() == null);
}

test "Channel with different data types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with bool
    {
        const channel = try Channel(bool).init(allocator);
        defer channel.deinit();

        const writer = channel.getWriter();
        const reader = channel.getReader();

        try writer.write(true);
        try testing.expectEqual(true, reader.read().?);
    }

    // Test with f64
    {
        const channel = try Channel(f64).init(allocator);
        defer channel.deinit();

        const writer = channel.getWriter();
        const reader = channel.getReader();

        try writer.write(3.14159);
        try testing.expectEqual(@as(f64, 3.14159), reader.read().?);
    }
}

test "Channel threaded producer consumer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const Context = struct {
        channel: *Channel(i32),
        sum: *i32,
        mutex: *Thread.Mutex,
    };

    var sum: i32 = 0;
    var sum_mutex = Thread.Mutex{};

    const context = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
    };

    const producer = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.channel.getWriter();
            var i: i32 = 1;
            while (i <= 10) : (i += 1) {
                try writer.write(i);
                std.time.sleep(1_000_000); // 1ms delay
            }
            try writer.complete();
        }
    }.run, .{context});

    const consumer = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) void {
            const reader = ctx.channel.getReader();
            while (reader.read()) |data| {
                ctx.mutex.lock();
                ctx.sum.* += data;
                ctx.mutex.unlock();
            }
        }
    }.run, .{context});

    producer.join();
    consumer.join();

    try testing.expectEqual(@as(i32, 55), sum); // 1+2+...+10 = 55
}

test "Channel multiple producers single consumer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const channel = try Channel(i32).init(allocator);
    defer channel.deinit();

    const Context = struct {
        channel: *Channel(i32),
        sum: *i32,
        mutex: *Thread.Mutex,
        producer_id: i32,
    };

    var sum: i32 = 0;
    var sum_mutex = Thread.Mutex{};

    const producer1_ctx = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
        .producer_id = 1,
    };

    const producer2_ctx = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
        .producer_id = 2,
    };

    const consumer_ctx = Context{
        .channel = channel,
        .sum = &sum,
        .mutex = &sum_mutex,
        .producer_id = 0,
    };

    const producer1 = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.channel.getWriter();
            var i: i32 = 1;
            while (i <= 5) : (i += 1) {
                try writer.write(ctx.producer_id * 10 + i); // 11, 12, 13, 14, 15
            }
        }
    }.run, .{producer1_ctx});

    const producer2 = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.channel.getWriter();
            var i: i32 = 1;
            while (i <= 5) : (i += 1) {
                try writer.write(ctx.producer_id * 10 + i); // 21, 22, 23, 24, 25
            }
        }
    }.run, .{producer2_ctx});

    const consumer = try Thread.spawn(.{}, struct {
        fn run(ctx: Context) void {
            const reader = ctx.channel.getReader();
            var count: i32 = 0;
            while (count < 10) : (count += 1) {
                if (reader.read()) |data| {
                    ctx.mutex.lock();
                    ctx.sum.* += data;
                    ctx.mutex.unlock();
                }
            }
        }
    }.run, .{consumer_ctx});

    producer1.join();
    producer2.join();

    // Complete the channel after producers finish
    try channel.getWriter().complete();

    consumer.join();

    // Sum should be (11+12+13+14+15) + (21+22+23+24+25) = 65 + 115 = 180
    try testing.expectEqual(@as(i32, 180), sum);
}
