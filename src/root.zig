const std = @import("std");
const Thread = std.Thread;
const Allocator = std.mem.Allocator;
const DoublyLinkedList = std.DoublyLinkedList;

pub fn Channel(comptime T: type) type{
    return struct {
        allocator: Allocator,
        data: DoublyLinkedList(T),
        mutex: Thread.Mutex,
        signal: Thread.Condition,

        const Self = @This();

        pub fn init(allocator: Allocator) Self{
            return .{
                .allocator = allocator,
                .data = DoublyLinkedList(T){},
                .mutex = Thread.Mutex{},
                .signal = Thread.Condition{}
            };
        } 

        pub fn getReader(self: *Self) Reader(T){
            return .{
                .channel = self
            };
        }

        pub fn getWriter(self: *Self) Writer(T){
            return .{
                .channel = self
            };
        }
    };
}

fn Writer(comptime T: type) type {
    return struct {
        channel: *Channel(T),
        const Self = @This();

        pub fn write(self: *Self, data: T) !void {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            var node = try self.channel.allocator.create(std.DoublyLinkedList(T).Node);
            node.data = data;
            self.channel.data.append(node);

            self.channel.signal.signal();
        }
    };
}

fn Reader(comptime T: type) type{
    return struct {
        channel: *Channel(T),

        const Self = @This();

        pub fn read(self: *Self) T {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();
            
            while (self.channel.data.len == 0){
                self.channel.signal.wait(&self.channel.mutex);
            }

            const node = self.channel.data.popFirst().?;
            defer self.channel.allocator.destroy(node);

            return node.data;
        }
    };
}