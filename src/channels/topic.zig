const std = @import("std");
const ChannelError = @import("./common.zig").ChannelError;
const Thread = std.Thread;
const ArrayList = std.ArrayList;
const ArrayHashMap = std.ArrayHashMap;
const DoublyLinkedList = std.DoublyLinkedList;
const Allocator = std.mem.Allocator;

pub fn Topic(comptime T: type) type {
    return struct {
        readers: ArrayHashMap(usize, *Reader(T), std.hash_map.DefaultContext(usize), 80),
        allocator: Allocator,
        mutex: Thread.Mutex,
        condition: Thread.Condition,
        completed: bool,
        readerIndex: usize,

        const Self = @This();

        pub fn init(allocator: Allocator)  ChannelError!*Self {
            const topic = allocator.create(Self) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            topic.* = .{
                .allocator = allocator,
                .readers = ArrayHashMap(usize, *Reader(T), std.hash_map.DefaultContext(usize), 80).init(allocator),
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
            self.readers.put(id, reader) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            return reader;
        }

        pub fn createWriter(self: *Self) Writer(T) {
            return .{
                .topic = self
            };
        }

        fn removeReader(self: *Self, id: usize) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            _ = self.readers.swapRemove(id);
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.readers.iterator();

            while (iterator.next()) | entry | {
                const reader = entry.value_ptr.*;
                reader.deinitFromTopic();
            }

            self.readers.deinit();
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

        pub fn write(self: Self, item: T) ChannelError!void {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            if(self.topic.completed)
                return ChannelError.ChannelClosed;

            var iterator = self.topic.readers.iterator();

            while (iterator.next()) | entry | {
                const reader = entry.value_ptr.*;

                var node = self.topic.allocator.create(DoublyLinkedList(T).Node) catch |err| switch (err) {
                    error.OutOfMemory => return ChannelError.OutOfMemory,
                    else => unreachable
                };

                node.data = item;
                reader.data.append(node);
            }

            self.topic.condition.broadcast();
        }

        pub fn complete(self: Self) ChannelError!void {
            self.topic.mutex.lock();
            defer self.topic.mutex.unlock();

            if(self.topic.completed)
                return ChannelError.ChannelClosed;

            self.topic.completed = true;
            self.topic.condition.broadcast();
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