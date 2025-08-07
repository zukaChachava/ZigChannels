const std = @import("std");
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;
const ChannelError = @import("./common.zig").ChannelError;

pub fn Topic(comptime T: type) type {
    return struct {
        readers: ArrayList(*Reader(T)),
        allocator: Allocator,
        mutex: Thread.Mutex,
        condition: Thread.Condition,
        completed: bool,

        const Self = @This();

        pub fn init(allocator: Allocator)  ChannelError!*Self {
            const topic = allocator.create(Self) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            topic.* = .{
                .allocator = allocator,
                .readers = std.ArrayList(*Reader(T)){},
                .mutex = Thread.Mutex{},
                .completed = false
            };

            return topic;
        }

        pub fn createReader(self: *Self) ChannelError!*Reader(T) {
            self.mutex.lock();
            defer self.mutex.unlock();
            const id = self.readers.items.len;

            const reader = try Reader(T).init(id, self);
            self.readers.append(reader) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            return reader;
        }

        fn removeReader(self: *Self, id: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.readers.swapRemove(id);
        }

        pub fn deinit(self: *Self) void {
            if(self.readers.items.len != 0){
                for (self.readers.items) |reader|{
                    reader.deinit();
                }
            }

            self.allocator.destroy(self);
        }
    };
}

fn Writer(comptime T: type) type {
    return struct {
        topic: *Topic(T),
        
        const Self = @This();

        fn init(topic: *Topic(T)) Self {
            return .{
                .topic = topic
            };
        }

        pub fn write(item: T) void {

        }
    };
}

fn Reader(comptime T: type) type {
    return struct {
        id: usize,
        allocator: Allocator,
        data: DoublyLinkedList(T),
        topic: *Topic(T),

        const Self = @This();

        fn init(id: usize, topic: *Topic(T)) ChannelError!*Self {
            const reader = topic.allocator.create(Self) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            reader.* = .{
                .id = id,
                .allocator = topic.allocator,
                .data = DoublyLinkedList(T){},
                .topic = topic,
            };

            return reader;
        }

        pub fn read(self: *Self) T {
            self.topic.mutex.lock();
            
        }

        pub fn deinit(self: *Self) void {
            self.topic.removeReader(self.id);
            self.allocator.destroy(self);
        }
    };
}