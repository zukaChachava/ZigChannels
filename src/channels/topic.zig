const std = @import("std");
const ChannelError = @import("./common.zig").ChannelError;
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const ArrayHashMap = std.AutoArrayHashMap;
const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

pub fn Topic(comptime T: type) type {
    return struct {
        readers: ArrayHashMap(usize, *Reader(T)),
        allocator: Allocator,
        mutex: Thread.Mutex,
        condition: Thread.Condition,
        completed: bool,
        readerIndex: usize,

        const Self = @This();

        pub fn init(allocator: Allocator) ChannelError!*Self {
            const topic = allocator.create(Self) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            topic.* = .{
                .allocator = allocator,
                .readers = ArrayHashMap(usize, *Reader(T)).init(allocator),
                .mutex = Thread.Mutex{},
                .completed = false,
                .readerIndex = 0,
                .condition = Thread.Condition{},
            };

            return topic;
        }

        pub fn createReader(self: *Self) ChannelError!*Reader(T) {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.readerIndex;
            self.readerIndex += 1;

            const reader = try Reader(T).init(id, self);
            self.readers.put(id, reader) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            return reader;
        }

        pub fn createWriter(self: *Self) Writer(T) {
            return .{ .topic = self };
        }

        fn removeReader(self: *Self, id: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            _ = self.readers.swapRemove(id);
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.readers.iterator();

            while (iterator.next()) |entry| {
                const reader = entry.value_ptr.*;
                reader.deinitFromTopic();
            }

            self.readers.deinit();
            self.allocator.destroy(self);
        }
    };
}

pub fn Writer(comptime T: type) type {
    return struct {
        topic: *Topic(T),

        const Self = @This();

        fn init(topic: *Topic(T)) Self {
            return .{ .topic = topic };
        }

        pub fn write(self: Self, item: T) ChannelError!void {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            if (self.topic.completed)
                return ChannelError.ChannelClosed;

            var iterator = self.topic.readers.iterator();

            while (iterator.next()) |entry| {
                const reader = entry.value_ptr.*;

                var node = self.topic.allocator.create(DoublyLinkedList(T).Node) catch |err| switch (err) {
                    error.OutOfMemory => return ChannelError.OutOfMemory,
                    else => unreachable,
                };

                node.data = item;
                reader.data.append(node);
            }

            self.topic.condition.broadcast();
        }

        pub fn complete(self: Self) ChannelError!void {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            if (self.topic.completed)
                return ChannelError.ChannelClosed;

            self.topic.completed = true;
            self.topic.condition.broadcast();
        }
    };
}

pub fn Reader(comptime T: type) type {
    return struct {
        id: usize,
        allocator: Allocator,
        data: DoublyLinkedList(T),
        topic: *Topic(T),

        const Self = @This();

        fn init(id: usize, topic: *Topic(T)) ChannelError!*Self {
            const reader = topic.allocator.create(Self) catch |err| switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable,
            };

            reader.* = .{
                .id = id,
                .allocator = topic.allocator,
                .data = DoublyLinkedList(T){},
                .topic = topic,
            };

            return reader;
        }

        pub fn read(self: *Self) ?T {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            while (self.data.len == 0) {
                if (self.topic.completed)
                    return null;

                self.topic.condition.wait(&self.topic.mutex);
            }

            const node = self.data.popFirst().?;
            defer self.topic.allocator.destroy(node);
            return node.data;
        }

        // Info: just destroys object, the pointer to this object still remains in topic
        fn deinitFromTopic(self: *Self) void {
            while (self.data.popFirst()) |node| {
                self.allocator.destroy(node);
            }

            self.allocator.destroy(self);
        }

        // Info: removes reader from topic and destroys object
        pub fn deinit(self: *Self) void {
            while (self.data.popFirst()) |node| {
                self.allocator.destroy(node);
            }

            self.topic.removeReader(self.id); // Info: lock is used inside function
            self.allocator.destroy(self);
        }
    };
}

// Tests
const testing = std.testing;

test "Topic init and deinit" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    try testing.expect(topic.completed == false);
    try testing.expect(topic.readerIndex == 0);
}

test "Topic create single reader" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const reader = try topic.createReader();
    defer reader.deinit();

    try testing.expect(reader.id == 0);
    try testing.expect(topic.readerIndex == 1);
}

test "Topic create multiple readers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();
    const reader3 = try topic.createReader();

    defer reader1.deinit();
    defer reader2.deinit();
    defer reader3.deinit();

    try testing.expect(reader1.id == 0);
    try testing.expect(reader2.id == 1);
    try testing.expect(reader3.id == 2);
    try testing.expect(topic.readerIndex == 3);
}

test "Topic writer write and reader read" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader = try topic.createReader();
    defer reader.deinit();

    try writer.write(42);

    const data = reader.read();
    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 42), data.?);
}

test "Topic broadcast to multiple readers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();
    const reader3 = try topic.createReader();

    defer reader1.deinit();
    defer reader2.deinit();
    defer reader3.deinit();

    // Write one message - all readers should receive it
    try writer.write(100);

    // All readers should get the same message
    try testing.expectEqual(@as(i32, 100), reader1.read().?);
    try testing.expectEqual(@as(i32, 100), reader2.read().?);
    try testing.expectEqual(@as(i32, 100), reader3.read().?);
}

test "Topic multiple messages to multiple readers" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();

    defer reader1.deinit();
    defer reader2.deinit();

    // Write multiple messages
    try writer.write(1);
    try writer.write(2);
    try writer.write(3);

    // Reader1 should receive all messages in order
    try testing.expectEqual(@as(i32, 1), reader1.read().?);
    try testing.expectEqual(@as(i32, 2), reader1.read().?);
    try testing.expectEqual(@as(i32, 3), reader1.read().?);

    // Reader2 should also receive all messages in order
    try testing.expectEqual(@as(i32, 1), reader2.read().?);
    try testing.expectEqual(@as(i32, 2), reader2.read().?);
    try testing.expectEqual(@as(i32, 3), reader2.read().?);
}

test "Topic completion" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader = try topic.createReader();
    defer reader.deinit();

    try writer.complete();

    try testing.expect(topic.completed == true);

    // Reading from completed topic should return null
    const data = reader.read();
    try testing.expect(data == null);
}

test "Write to completed topic returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();

    try writer.complete();

    const result = writer.write(42);
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Complete already completed topic returns error" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();

    try writer.complete();

    const result = writer.complete();
    try testing.expectError(ChannelError.ChannelClosed, result);
}

test "Topic read from completed topic with remaining data" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader = try topic.createReader();
    defer reader.deinit();

    // Write data first
    try writer.write(100);
    try writer.write(200);

    // Then complete the topic
    try writer.complete();

    // Should still be able to read existing data
    try testing.expectEqual(@as(i32, 100), reader.read().?);
    try testing.expectEqual(@as(i32, 200), reader.read().?);

    // After all data is consumed, should return null
    try testing.expect(reader.read() == null);
}

test "Topic with different data types" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test with bool
    {
        const topic = try Topic(bool).init(allocator);
        defer topic.deinit();

        const writer = topic.createWriter();
        const reader = try topic.createReader();
        defer reader.deinit();

        try writer.write(true);
        try testing.expectEqual(true, reader.read().?);
    }

    // Test with f64
    {
        const topic = try Topic(f64).init(allocator);
        defer topic.deinit();

        const writer = topic.createWriter();
        const reader = try topic.createReader();
        defer reader.deinit();

        try writer.write(3.14159);
        try testing.expectEqual(@as(f64, 3.14159), reader.read().?);
    }

    // Test with strings
    {
        const topic = try Topic([]const u8).init(allocator);
        defer topic.deinit();

        const writer = topic.createWriter();
        const reader = try topic.createReader();
        defer reader.deinit();

        try writer.write("hello");
        try testing.expectEqualStrings("hello", reader.read().?);
    }
}

test "Topic reader removal" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const writer = topic.createWriter();
    const reader1 = try topic.createReader();
    const reader2 = try topic.createReader();

    // reader2 will be cleaned up manually
    defer reader1.deinit();

    // Write message to both readers
    try writer.write(42);

    // Both readers should receive the message
    try testing.expectEqual(@as(i32, 42), reader1.read().?);
    try testing.expectEqual(@as(i32, 42), reader2.read().?);

    // Remove reader2
    reader2.deinit();

    // Write another message - only reader1 should receive it
    try writer.write(100);
    try testing.expectEqual(@as(i32, 100), reader1.read().?);
}

test "Topic threaded producer consumer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const topic = try Topic(i32).init(allocator);
    defer topic.deinit();

    const Context = struct {
        topic: *Topic(i32),
        sum: *i32,
        mutex: *std.Thread.Mutex,
        reader_id: u8,
    };

    var sum1: i32 = 0;
    var sum2: i32 = 0;
    var sum_mutex = std.Thread.Mutex{};

    const context1 = Context{
        .topic = topic,
        .sum = &sum1,
        .mutex = &sum_mutex,
        .reader_id = 1,
    };

    const context2 = Context{
        .topic = topic,
        .sum = &sum2,
        .mutex = &sum_mutex,
        .reader_id = 2,
    };

    const producer = try std.Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const writer = ctx.topic.createWriter();
            var i: i32 = 1;
            while (i <= 5) : (i += 1) {
                try writer.write(i);
                std.time.sleep(1_000_000); // 1ms delay
            }
            try writer.complete();
        }
    }.run, .{context1});

    const consumer1 = try std.Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const reader = try ctx.topic.createReader();
            defer reader.deinit();

            while (reader.read()) |data| {
                ctx.mutex.lock();
                ctx.sum.* += data;
                ctx.mutex.unlock();
            }
        }
    }.run, .{context1});

    const consumer2 = try std.Thread.spawn(.{}, struct {
        fn run(ctx: Context) !void {
            const reader = try ctx.topic.createReader();
            defer reader.deinit();

            while (reader.read()) |data| {
                ctx.mutex.lock();
                ctx.sum.* += data;
                ctx.mutex.unlock();
            }
        }
    }.run, .{context2});

    producer.join();
    consumer1.join();
    consumer2.join();

    // Both consumers should receive all messages: 1+2+3+4+5 = 15
    try testing.expectEqual(@as(i32, 15), sum1);
    try testing.expectEqual(@as(i32, 15), sum2);
}
