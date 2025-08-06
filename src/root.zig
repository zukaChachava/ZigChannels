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
        completed: bool,

        const Self = @This();

        pub fn init(allocator: Allocator) ChannelError!*Self {
            const channel = allocator.create(Self) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            channel.* = .{
                .allocator = allocator,
                .data = DoublyLinkedList(T){},
                .mutex = Thread.Mutex{},
                .signal = Thread.Condition{},
                .completed = false
            };

            return channel;
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

        pub fn deinit(self: *Self) void{
            while(self.data.len != 0){
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

            if(self.channel.completed)
                return ChannelError.ChannelClosed;

            const node = self.channel.allocator.create(std.DoublyLinkedList(T).Node) catch | err | switch (err) {
                error.OutOfMemory => return ChannelError.OutOfMemory,
                else => unreachable
            };

            node.data = data;
            self.channel.data.append(node);
            self.channel.signal.signal();
        }

        pub fn complete(self: Self) ChannelError!void {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();

            if(self.channel.completed)
                return ChannelError.ChannelClosed;

            self.channel.completed = true;
            self.channel.signal.broadcast();
        }
    };
}

fn Reader(comptime T: type) type{
    return struct {
        channel: *Channel(T),

        const Self = @This();

        pub fn read(self: Self) ?T {
            self.channel.mutex.lock();
            defer self.channel.mutex.unlock();
            
            while (self.channel.data.len == 0){

                if(self.channel.completed)
                    return null;

                self.channel.signal.wait(&self.channel.mutex);
            }

            const node = self.channel.data.popFirst().?;
            defer self.channel.allocator.destroy(node);

            return node.data;
        }
    };
}

const ChannelError = error {
    OutOfMemory,
    ChannelClosed
};