# zigChannels

A thread-safe channel implementation for Zig, providing Go-style communication between threads using condition variables and mutexes.

## Features

- **Thread-safe**: Uses mutex and condition variables for proper synchronization
- **Generic**: Works with any type `T`
- **Efficient**: Uses condition variables to avoid busy-waiting
- **Simple API**: Easy-to-use reader/writer pattern
- **Memory managed**: Proper allocation and deallocation of channel nodes

## Installation

### Using Zig Package Manager

Add to your `build.zig.zon`:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .zigChannels = .{
            .url = "https://github.com/yourusername/zigChannels/archive/main.tar.gz",
            .hash = "...", // Will be filled automatically
        },
    },
}
```

Then in your `build.zig`:

```zig
const zigChannels = b.dependency("zigChannels", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zigChannels", zigChannels.module("zigChannels"));
```

### Manual Installation

Clone this repository and add the `src/root.zig` file to your project.

## Usage

### Basic Example

```zig
const std = @import("std");
const zigChannels = @import("zigChannels");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a channel for i32 values
    var channel = zigChannels.Channel(i32).init(allocator);
    
    // Get reader and writer
    var writer = channel.getWriter();
    var reader = channel.getReader();

    // Write to channel (from another thread)
    try writer.write(42);
    
    // Read from channel (blocks until data available)
    const value = reader.read();
    std.debug.print("Received: {}\n", .{value});
}
```

### Producer-Consumer Example

```zig
const std = @import("std");
const zigChannels = @import("zigChannels");
const Thread = std.Thread;

const WorkerData = struct {
    channel: *zigChannels.Channel(i32),
    start: i32,
    end: i32,
};

fn producer(data: *WorkerData) void {
    var writer = data.channel.getWriter();
    
    for (data.start..data.end) |i| {
        writer.write(@intCast(i)) catch |err| {
            std.debug.print("Write error: {}\n", .{err});
            return;
        };
        std.time.sleep(100 * std.time.ns_per_ms); // Simulate work
    }
}

fn consumer(channel: *zigChannels.Channel(i32)) void {
    var reader = channel.getReader();
    
    for (0..10) |_| {
        const value = reader.read();
        std.debug.print("Consumed: {}\n", .{value});
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var channel = zigChannels.Channel(i32).init(allocator);
    
    var worker_data = WorkerData{
        .channel = &channel,
        .start = 1,
        .end = 11,
    };

    // Start producer thread
    const producer_thread = try Thread.spawn(.{}, producer, .{&worker_data});
    
    // Start consumer thread  
    const consumer_thread = try Thread.spawn(.{}, consumer, .{&channel});

    // Wait for threads to complete
    producer_thread.join();
    consumer_thread.join();
}
```

## API Reference

### Channel(T)

Generic channel type for values of type `T`.

#### Methods

##### `init(allocator: Allocator) Self`

Creates a new channel with the given allocator.

**Parameters:**
- `allocator`: Memory allocator for internal data structures

**Returns:** New channel instance

##### `getReader(self: *Self) Reader(T)`

Creates a reader for this channel.

**Returns:** Reader instance

##### `getWriter(self: *Self) Writer(T)`

Creates a writer for this channel.

**Returns:** Writer instance

### Writer(T)

Writer handle for sending data to a channel.

#### Methods

##### `write(self: *Self, data: T) !void`

Writes data to the channel. This operation is thread-safe and will wake up any waiting readers.

**Parameters:**
- `data`: Value to write to the channel

**Errors:**
- `OutOfMemory`: If allocation fails

### Reader(T)

Reader handle for receiving data from a channel.

#### Methods

##### `read(self: *Self) T`

Reads data from the channel. Blocks until data is available.

**Returns:** Value read from the channel

## How It Works

The channel implementation uses:

1. **DoublyLinkedList**: For storing queued messages
2. **Mutex**: For thread-safe access to the queue
3. **Condition Variable**: For efficient blocking when no data is available

### Synchronization Flow

1. **Writer**: Acquires mutex → adds data to queue → signals condition → releases mutex
2. **Reader**: Acquires mutex → checks if data available → if not, waits on condition → when woken, removes data → releases mutex

This avoids busy-waiting and provides efficient thread coordination.

## Building

```bash
# Build the library
zig build

# Run tests (if available)
zig build test

# Build in release mode
zig build -Doptimize=ReleaseFast
```

## Requirements

- Zig 0.11.0 or later

## Thread Safety

All operations are thread-safe:
- Multiple readers can safely read from the same channel
- Multiple writers can safely write to the same channel  
- Readers and writers can operate concurrently

## Memory Management

- Channel nodes are allocated using the provided allocator
- Memory is automatically freed when messages are consumed
- No manual cleanup required for messages

## Performance Considerations

- Uses condition variables for efficient blocking (no busy-waiting)
- Minimal lock contention with proper mutex usage
- Memory allocation only occurs when writing to the channel

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Similar Projects

- Go channels (inspiration)
- Rust's `std::sync::mpsc`
- C++ condition variables

## Acknowledgments

Inspired by Go's channel implementation and built using modern Zig threading primitives.
