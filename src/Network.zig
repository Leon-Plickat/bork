const std = @import("std");
const datetime = @import("datetime");
const Channel = @import("utils/channel.zig").Channel;
const GlobalEventUnion = @import("main.zig").Event;
const Chat = @import("Chat.zig");
const parser = @import("network/parser.zig");
const EmoteCache = @import("network/EmoteCache.zig");

const build_opts = @import("build_options");

pub const checkTokenValidity = @import("network/auth.zig").checkTokenValidity;
pub const Event = union(enum) {
    message: Chat.Message,
    connected,
    disconnected,
    reconnected,
    clear: ?[]const u8, // optional nickname, if empty delete all
};

pub const UserCommand = union(enum) {
    message: []const u8,
    // ban: []const u8,
};
const Command = union(enum) {
    user: UserCommand,
    pong,
};

name: []const u8,
oauth: []const u8,
tz: datetime.Timezone,
allocator: std.mem.Allocator,
ch: *Channel(GlobalEventUnion),
emote_cache: EmoteCache,
socket: std.net.Stream,
reader: std.net.Stream.Reader,
writer: std.net.Stream.Writer,
writer_lock: std.event.Lock = .{},
_atomic_reconnecting: bool = false,

const Self = @This();

var reconnect_frame: @Frame(_reconnect) = undefined;
// var messages_frame: @Frame(receiveMessages) = undefined;
var messages_frame_bytes: []align(16) u8 = undefined;
var messages_result: void = undefined;

pub fn init(
    self: *Self,
    alloc: std.mem.Allocator,
    ch: *Channel(GlobalEventUnion),
    name: []const u8,
    oauth: []const u8,
    tz: datetime.Timezone,
) !void {
    var socket = try connect(alloc, name, oauth);
    self.* = Self{
        .name = name,
        .oauth = oauth,
        .tz = tz,
        .allocator = alloc,
        .ch = ch,
        .emote_cache = EmoteCache.init(alloc),
        .socket = socket,
        .reader = socket.reader(),
        .writer = socket.writer(),
    };

    // Allocate
    messages_frame_bytes = try alloc.alignedAlloc(u8, 16, @sizeOf(@Frame(receiveMessages)));

    // Start the reader
    {
        // messages_frame_bytes = async self.receiveMessages();
        _ = @asyncCall(messages_frame_bytes, &messages_result, receiveMessages, .{self});
    }
}

pub fn deinit(self: *Self) void {
    // Try to grab the reconnecting flag
    while (@atomicRmw(bool, &self._atomic_reconnecting, .Xchg, true, .SeqCst)) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    // Now we can kill the connection and nobody will try to reconnect
    std.os.shutdown(self.socket.handle, .both) catch |err| {
        std.log.debug("shutdown failed, err: {}", .{err});
    };
    await @ptrCast(anyframe->void, messages_frame_bytes);
    self.socket.close();
}

fn receiveMessages(self: *Self) void {
    defer std.log.debug("receiveMessages done", .{});
    std.log.debug("reader started", .{});
    // yield immediately so callers can go on
    // with their lives instead of risking being
    // trapped reading a spammy socket forever
    std.event.Loop.instance.?.yield();
    while (true) {
        const data = data: {
            const d = self.reader.readUntilDelimiterAlloc(self.allocator, '\n', 4096) catch |err| {
                std.log.debug("receiveMessages errored out: {e}", .{err});
                self.reconnect(null);
                return;
            };

            if (d.len >= 1 and d[d.len - 1] == '\r') {
                break :data d[0 .. d.len - 1];
            }

            break :data d;
        };

        std.log.debug("receiveMessages succeded", .{});

        const p = parser.parseMessage(data, self.allocator, self.tz) catch |err| {
            std.log.debug("parsing error: [{e}]", .{err});
            continue;
        };
        switch (p) {
            .ping => {
                self.send(.pong);
            },
            .clear => |c| {
                self.ch.put(GlobalEventUnion{ .network = .{ .clear = c } });
            },
            .message => |msg| {
                switch (msg.kind) {
                    else => {},
                    .chat => |c| {
                        self.emote_cache.fetch(c.emotes) catch |err| {
                            std.log.debug("fetching error: [{e}]", .{err});
                            continue;
                        };
                    },
                    .resub => |c| {
                        self.emote_cache.fetch(c.resub_message_emotes) catch |err| {
                            std.log.debug("fetching error: [{e}]", .{err});
                            continue;
                        };
                    },
                }

                self.ch.put(GlobalEventUnion{ .network = .{ .message = msg } });

                // Hack: when receiving resub events, we generate a fake chat message
                //       to display the resub message. In the future this should be
                //       dropped in favor of actually representing properly the resub.
                //       Also this message is pointing to data that "belongs" to another
                //       message. Kind of a bad idea.
                switch (msg.kind) {
                    .resub => |r| {
                        if (r.resub_message.len > 0) {
                            self.ch.put(GlobalEventUnion{
                                .network = .{
                                    .message = Chat.Message{
                                        .login_name = msg.login_name,
                                        .time = msg.time,
                                        .kind = .{
                                            .chat = .{
                                                .display_name = r.display_name,
                                                .text = r.resub_message,
                                                .sub_months = r.count,
                                                .is_founder = false, // std.mem.eql(u8, sub_badge.name, "founder"),
                                                .emotes = r.resub_message_emotes,
                                                .is_mod = false, // is_mod,
                                                .is_highlighted = true,
                                            },
                                        },
                                    },
                                },
                            });
                        }
                    },
                    else => {},
                }
            },
        }
    }
}

// Public interface for sending commands (messages, bans, ...)
pub fn sendCommand(self: *Self, cmd: UserCommand) void {
    // if (self.isReconnecting()) {
    //     return error.Reconnecting;
    // }
    return self.send(Command{ .user = cmd });
}
//     // NOTE: it could still be possible for a command
//     //       to remain stuck here while we are reconnecting,
//     //       but in most cases we'll be able to correctly
//     //       report that we can't carry out any command.
//     //       if the twitch chat system had unique command ids,
//     //       we could have opted to retry instead of failing
//     //       immediately, but without unique ids you risk
//     //       sending the same command twice.
// }

fn send(self: *Self, cmd: Command) void {
    var held = self.writer_lock.acquire();
    var comm = switch (cmd) {
        .pong => blk: {
            std.log.debug("PONG!", .{});
            break :blk self.writer.print("PONG :tmi.twitch.tv\n", .{});
        },
        .user => |uc| blk: {
            switch (uc) {
                .message => |msg| {
                    std.log.debug("SEND MESSAGE!", .{});
                    break :blk self.writer.print("PRIVMSG #{s} :{s}\n", .{ self.name, msg });
                },
            }
        },
    };

    if (comm) |_| {} else |_| {
        // Try to start the reconnect procedure
        self.reconnect(held);
    }

    held.release();
}

fn isReconnecting(self: *Self) bool {
    return @atomicLoad(bool, &self._atomic_reconnecting, .SeqCst);
}

// Public interface, used by the main control loop.
pub fn askToReconnect(self: *Self) void {
    self.reconnect(null);
}

// Tries to reconnect forever.
// As an optimization, writers can pass ownership of the lock directly.
fn reconnect(self: *Self, writer_held: ?std.event.Lock.Held) void {
    if (@atomicRmw(bool, &self._atomic_reconnecting, .Xchg, true, .SeqCst)) {
        if (writer_held) |h| h.release();
        return;
    }

    // Start the reconnect procedure
    reconnect_frame = async self._reconnect(writer_held);
}

// This function is a perfect example of what runDetached does,
// with the exception that we don't want to allocate dynamic
// memory for it.
fn _reconnect(self: *Self, writer_held: ?std.event.Lock.Held) void {
    var retries: usize = 0;
    var backoff = [_]usize{
        100, 400, 800, 2000, 5000, 10000, //ms
    };

    // Notify the system the connection is borked
    self.ch.put(GlobalEventUnion{ .network = .disconnected });

    // Ensure we have the writer lock
    var held = writer_held orelse self.writer_lock.acquire();

    // Sync with the reader. It will at one point notice
    // that the connection is borked and return.
    {
        std.os.shutdown(self.socket.handle, .both) catch unreachable;
        // await messages_frame;
        await @ptrCast(anyframe->void, messages_frame_bytes);
        self.socket.close();
    }

    // Reconnect the socket
    {
        // Compiler doesn't like the straight break from while,
        // nor the labeled block version :(

        // self.socket = while (true) {
        //     break connect(self.allocator, self.name, self.oauth) catch |err| {
        //         // TODO: panic on non-transient errors.
        //         std.time.sleep(backoff[retries] * std.time.ns_per_ms);
        //         if (retries < backoff.len - 1) {
        //             retries += 1;
        //         }
        //         continue;
        //     };
        // };

        // self.socket = blk: {
        //     while (true) {
        //         break :blk connect(self.allocator, self.name, self.oauth) catch |err| {
        //             // TODO: panic on non-transient errors.
        //             std.time.sleep(backoff[retries] * std.time.ns_per_ms);
        //             if (retries < backoff.len - 1) {
        //                 retries += 1;
        //             }
        //             continue;
        //         };
        //     }
        // };
        while (true) {
            var s = connect(self.allocator, self.name, self.oauth) catch {
                // TODO: panic on non-transient errors.
                std.time.sleep(backoff[retries] * std.time.ns_per_ms);
                if (retries < backoff.len - 1) {
                    retries += 1;
                }
                continue;
            };
            self.socket = s;
            break;
        }
    }
    self.reader = self.socket.reader();
    self.writer = self.socket.writer();

    // Suspend at the end to avoid a race condition
    // where the check to resume a potential awaiter
    // (nobody should be awaiting us) might end up
    // reading the frame while a second reconnect
    // attempt is running on the same frame, causing UB.
    suspend {
        // Reset the reconnecting flag
        std.debug.assert(@atomicRmw(
            bool,
            &self._atomic_reconnecting,
            .Xchg,
            false,
            .SeqCst,
        ));

        // Unblock commands
        held.release();

        // Notify the system all is good again
        self.ch.put(GlobalEventUnion{ .network = .reconnected });

        // Restart the reader
        {
            // messages_frame = async self.receiveMessages();
            _ = @asyncCall(messages_frame_bytes, &messages_result, receiveMessages, .{self});
        }
    }
}

pub fn connect(alloc: std.mem.Allocator, name: []const u8, oauth: []const u8) !std.net.Stream {
    var socket = if (build_opts.local)
        try std.net.tcpConnectToHost(alloc, "localhost", 6667)
    else
        try std.net.tcpConnectToHost(alloc, "irc.chat.twitch.tv", 6667);

    errdefer socket.close();

    const oua = if (build_opts.local) "foo" else oauth;

    try socket.writer().print(
        \\PASS {0s}
        \\NICK {1s}
        \\CAP REQ :twitch.tv/tags
        \\CAP REQ :twitch.tv/commands
        \\JOIN #{1s}
        \\
    , .{ oua, name });

    // TODO: read what we got back, instead of assuming that
    //       all went well just because the bytes were shipped.

    return socket;
}
