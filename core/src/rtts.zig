//! This is the common code for the realtime task scheduler.

const std = @import("std");

pub const microzig_config = @import("config");
pub const hal = if (microzig_config.has_hal) @import("hal") else void;

pub const interrupt = @import("interrupt.zig");

//============================================================================
// Configuration
//============================================================================

/// A structure containing the configuration for the RTTS Scheduler.
pub const Config = struct {
    /// A bit mask of cores to use.  If 0xFF, all available cores are used.
    use_cores: u8 = 0xFF,

    /// The number of event flags to use.
    event_flags_count: u8 = 8,

    /// run tasks in unprivileged mode
    run_unprivileged: bool = false,

    /// Resolution of the timer in ticks per second
    resolution: u32 = 100,

    /// Platform specific code override.
    platform: ?type = null,
};

/// A structure containing the task configuration data.
pub const Task = struct {
    /// The name of the task
    name: [:0]const u8,
    // The task function
    func: *const fn () noreturn,
    // The stack size
    stack_size: usize = 256,
    // The initial event mask
    event_mask: usize = 0,
};

/// Configure the RTTS Scheduler an return a namespace
/// containing functions to control in_tasks.
///
/// Parameters:
///   config - The configuration for the RTTS Scheduler
///   tasks - An array of tasks to run
///
/// Returns:
///   The scheduler namespace
///
pub fn scheduler(comptime config: Config, comptime tasks: []const Task) type {
    return struct {
        const Sched = @This();

        pub const Configuration = Config;

        pub const platform = if (config.platform) |p|
            p
        else if (@hasDecl(hal, "rtts"))
            hal.rtts.configure(Sched, config)
        else
            @compileError("No platform specific functions found");

        //============================================================================
        // Type Definitions
        //============================================================================

        pub const TaskState = enum {
            running,
            runnable,
            waiting,
        };

        const EventFlags = std.meta.Int(.unsigned, config.event_flags_count);

        /// A task item
        pub const TaskItem = struct {
            /// The next task in priority order
            next: ?*TaskItem = null,
            /// The task tag
            tag: TaskTag,
            /// The stack pointer
            stack_pointer: [*]usize,
            /// The event flags
            event_flags: EventFlags,
            /// The event mask
            event_mask: EventFlags,
            /// The task state
            state: TaskState,
        };

        //============================================================================
        // Global Context
        //============================================================================

        /// The core mask. Bits set to 1 indicate cores to use.
        pub const core_mask = config.use_cores & platform.cores_available;

        /// The number of cores to use
        pub const core_count = @popCount(core_mask);

        /// The current task on each core
        pub var current_task: [core_count]?*TaskItem = @splat(null);

        /// Last scheduled task
        pub var next_task: ?*TaskItem = null;

        /// The mutex used to synchronize access to the task list.
        pub var schedule_mutex: interrupt.Mutex = .{};

        /// The mutex used to synchronize access to the timer list.
        pub var timer_mutex: interrupt.Mutex = .{};

        /// The task list
        pub var task_list: [tasks.len]TaskItem = undefined;

        /// The highest priority task
        pub var highest_priority_task: *TaskItem = &task_list[0];

        /// Task stack space -- this holds all the tasks' stacks
        pub var task_stacks: blk: {
            var size: usize = 0;
            for (tasks) |task| {
                size += task.stack_size;
            }
            break :blk @Type(.{ .array = .{ .child = usize, .len = size, .sentinel_ptr = null } });
        } = undefined;

        /// The task tag type.  An enum of task name with values of task index.
        pub const TaskTag = blk: {
            // Construct the TaskTag enum
            var task_tag_fields: [tasks.len]std.builtin.Type.EnumField = undefined;

            const task_tag_info: std.builtin.Type =
                .{
                    .@"enum" = .{
                        .tag_type = u8,
                        .decls = &.{},
                        .fields = &task_tag_fields,
                        .is_exhaustive = true,
                    },
                };

            for (tasks, 0..) |task, i| {
                task_tag_fields[i] = .{
                    .name = task.name,
                    .value = @intCast(i),
                };
            }

            break :blk @Type(task_tag_info);
        };

        /// The list of pending timers
        pub var first_timer: ?*Timer = null;

        //============================================================================
        // RTTS startup
        //============================================================================

        // ---------------------------------------------------------------------------
        /// Run the RTTS scheduler.  This function never returns.
        ///
        /// This scheduler runs tasks in strict priority order.  The processor
        /// cores are assigned to the highest priority tasks until they yield or
        /// wait on an event.
        ///
        pub fn run(comptime in_tasks: []const Task) noreturn {
            var last_task: ?*TaskItem = null;

            var sp: [*]usize = task_stacks[0..];

            for (in_tasks, 0..) |task, i| {
                if (last_task) |lt| {
                    lt.next = &task_list[i];
                }

                sp += task.stack_size;

                task_list[i] = .{
                    .tag = @enumFromInt(i),
                    .event_mask = @intCast(task.event_mask),
                    .event_flags = 0,
                    .state = if (task.event_mask != 0) .waiting else .runnable,
                    .stack_pointer = platform.initialize_stack(sp, task.func),
                };

                last_task = &task_list[i];

                // std.log.debug("Initialized task \"{s}\":", .{task.name});
                // std.log.debug("  func: {any}", .{task.func});
                // std.log.debug("  stack_size: {d}", .{task.stack_size});
                // std.log.debug("  stack: {any}", .{task_list[i].stack_pointer});
                // std.log.debug("  event_flags: {x}", .{task_list[i].event_flags});
                // std.log.debug("  event_mask: {x}", .{task_list[i].event_mask});
                // std.log.debug("  state: {s}", .{@tagName(task_list[i].state)});

                // for (0..16) |j| {
                //     std.log.debug("  sp + {d:2}: 0x{X:08}", .{ j, task_list[i].stack_pointer[j] });
                // }
            }

            platform.start_cores();
        }

        //============================================================================
        // Task Functions
        //============================================================================
        // Individual tasks can call these functions get the current task, or control
        // the RTTS scheduler.

        //----------------------------------------------------------------------------
        /// Return a pointer to the currently running task.
        ///
        /// Returns:
        ///   A pointer to the currently running task
        pub fn get_current_task() *TaskItem {
            return current_task[platform.core_id()] orelse @panic("Cannot call task functions outside of a task");
        }

        //----------------------------------------------------------------------------
        /// Wait for an event.
        ///
        /// This function will set the current task's event mask to the value
        /// specified in in_event_mask.  If in_clear_flags is true, it will also
        /// clear the matching event flags.
        ///
        /// Finally, if a bit-wise and of the task's event flags and event mask
        /// is zero, the task will be set to the waiting state.
        ///
        /// To reactivate the task, some other task or interrupt service routine
        /// must set at lease one of this task's event flags that match a bit in
        /// this task's event mask.
        ///
        /// Note: The event flags are numbered 0 to N-1, where N is the value of
        ///       config.event_flags_count.  The low order bit in the event mask
        ///       corresponds to event flag 0, the next bit to event flag 1, and
        ///       so on.
        ///
        /// Parameters:
        ///   in_event_mask - The event mask to wait for
        ///   in_clear_flags - If true, clear event flags that match the event mask
        ///
        pub fn wait_for_event(in_event_mask: EventFlags, in_clear_flags: bool) void {
            const the_task = get_current_task();

            the_task.event_mask = in_event_mask;
            if (in_clear_flags) the_task.event_flags &= ~in_event_mask;

            var reschedule = false;

            {
                schedule_mutex.lock();
                defer schedule_mutex.unlock();

                if ((the_task.event_flags & the_task.event_mask) == 0) {
                    the_task.state = .waiting;
                    // std.log.debug("{s}  Set task {s} to waiting", .{ platform.debug_core(), @tagName(the_task.tag) });
                    reschedule = true;
                }
            }

            if (reschedule) {
                platform.reschedule();
            }
        }

        //----------------------------------------------------------------------------
        /// Yield to a lower priority task.
        ///
        /// The current task will let other tasks of lower priority run.  It will
        /// run again after the next significant event or if no other tasks want
        /// to run.
        ///
        /// Do not call this function from an interrupt service routine.
        ///
        pub fn yield() void {
            // const the_task = get_current_task();

            // the_task.state = .runnable;
            // std.log.debug("{s}  Set task {s} to runnable", .{ platform.debug_core(), @tagName(the_task.tag) });

            platform.reschedule();
        }

        //----------------------------------------------------------------------------
        /// Declare a significant event.
        ///
        /// The scheduler will re-scan the task list and the highest priority
        /// runnable tasks will be run.  A call to this function on one core can
        /// change the tasks assigned to any core.
        ///
        /// Do not call this function from an interrupt service routine.
        ///
        pub fn significant_event() void {
            next_task = highest_priority_task;
            platform.reschedule_all_cores();
        }

        //----------------------------------------------------------------------------
        /// Signal an event to the indicated task.
        ///
        /// This function will set the specified event flag for the task, and, if the
        /// task was waiting on that event flag, the task will be marked as runnable
        /// and a significant event will be declared.
        ///
        /// Parameters:
        ///   in_task  - The index of the task to signal
        ///   in_event - The event to signal
        ///
        /// Do not call this function from an interrupt service routine.
        ///
        pub fn signal_event(in_task: TaskTag, in_event: u8) !void {
            if (try _signal_task(in_task, in_event)) {
                significant_event();
            }
        }

        //----------------------------------------------------------------------------
        /// Clear task's own event flags
        ///
        /// This function will clear the specified event flag for the task.
        ///
        /// Parameters:
        ///   in_event_mask - The event mask to clear
        ///
        /// Do not call this function from an interrupt service routine.
        ///
        pub fn clear_event_flags(in_event_mask: EventFlags) void {
            const the_task = get_current_task();
            the_task.event_flags &= ~in_event_mask;
        }

        //============================================================================
        // Interrupt Service Routine Scheduler Functions
        //============================================================================

        //----------------------------------------------------------------------------
        /// Declare a significant event from an interrupt service routine.
        ///
        /// The scheduler will re-scan the task list and the highest priority
        /// runnable tasks will be run.  A call to this function on one core can
        /// change the tasks assigned to any core.
        ///
        pub fn significant_event_isr() void {
            next_task = highest_priority_task;
            platform.reschedule_all_cores_isr();
        }

        //----------------------------------------------------------------------------
        /// Signal an event to the indicated task from an interrupt service routine.
        ///
        /// This function will set the specified event flag for the task, and, if the
        /// task was waiting on that event flag, the task will be marked as runnable
        /// and a significant event will be declared.
        ///
        /// Parameters:
        ///   in_task  - The index of the task to signal
        ///   in_event - The event to signal
        ///
        /// Do not call this function from an interrupt service routine.
        ///
        pub fn signal_event_isr(in_task: TaskTag, in_event: u8) !void {
            if (try _signal_task(in_task, in_event)) {
                significant_event_isr();
            }
        }

        //----------------------------------------------------------------------------
        /// Set the priority of a task to be just _above_ the priority of another task.
        ///
        /// Parameters:
        ///   in_task_a - The task whose priority we want to set.
        ///   in_task_b - The task to place in_task_a above.  If null, the task
        ///               will be placed at the bottom of the priority list.
        ///
        pub fn set_priority(in_task_a: TaskTag, in_task_b: ?TaskTag) void {

            // Sanity check -- we do nothing if task_a and task_b are the same

            if (in_task_b) |t| {
                if (t == in_task_a) return;
            }

            {
                schedule_mutex.lock();
                defer schedule_mutex.unlock();

                const task_a = &task_list[@intFromEnum(in_task_a)];

                // Unlink task_a from priority list

                if (highest_priority_task == task_a) {
                    highest_priority_task = task_a.next.?;
                } else {
                    for (&task_list) |*an_item| {
                        if (an_item.next) |next| {
                            if (next == task_a) {
                                an_item.next = task_a.next;
                                break;
                            }
                        }
                    }
                }

                if (in_task_b) |t| {
                    // Link task_a into priority list before task_b
                    const task_b = &task_list[@intFromEnum(t)];

                    for (&task_list) |*an_item| {
                        if (an_item.next) |next| {
                            if (next == task_b) {
                                an_item.next = task_a;
                                task_a.next = task_b;
                                break;
                            }
                        }
                    }
                } else {
                    // Link task_a into priority list at end

                    for (&task_list) |*an_item| {
                        if (an_item.next == null) {
                            an_item.next = task_a;
                            task_a.next = null;
                            break;
                        }
                    }

                    task_a.next = null;
                }
            }

            significant_event();
        }

        //============================================================================
        // Internal Use Only
        //============================================================================

        //----------------------------------------------------------------------------
        /// Get priority relationship between two tasks.
        ///
        /// Returns:
        ///   <0 - in_task_a has lower priority than in_task_b
        ///   0  - in_task_a has same priority as in_task_b
        ///   >0 - in_task_a has higher priority than in_task_b
        pub fn priority_compare(in_task_a: *TaskItem, in_task_b: *TaskItem) isize {
            if (in_task_a == in_task_b) return 0;

            // Starting at in_task_a, follow the "next" pointers. If we
            // find in_task_b, then in_task_a has higher priority than in_task_b.
            // Otherwise, in_task_a has lower priority than in_task_b.

            var t: ?*TaskItem = in_task_a;
            while (t) |task| {
                t = task.next;
                if (t == in_task_b) return 1;
            }

            return -1;
        }

        //----------------------------------------------------------------------------
        /// Find the stack pointer for the next task to run on current core.
        pub fn find_next_task_sp(in_sp: [*]usize) [*]usize {
            // std.log.debug("{s}  Finding next task", .{platform.debug_core()});

            schedule_mutex.lock();
            defer schedule_mutex.unlock();

            const core_id = platform.core_id();

            // Save the stack pointer for the current task and, if it was running,
            // set it to runnable.

            if (current_task[core_id]) |task| {
                task.stack_pointer = in_sp;

                if (task.state == .running) {
                    task.state = .runnable;
                    // std.log.debug("{s}  Set current task {s} to runnable", .{ platform.debug_core(), @tagName(task.tag) });
                }
            }

            // Scan the task list for the highest priority runnable task

            while (next_task) |task| {
                next_task = task.next;

                if (task.state == .runnable) {
                    // std.log.debug("{s}  Switch to task {s} sp: 0x{X:08}", .{ platform.debug_core(), @tagName(task.tag), @intFromPtr(task.stack_pointer) });

                    task.state = .running;
                    // std.log.debug("{s}  Set task {s} to running", .{ platform.debug_core(), @tagName(task.tag) });

                    current_task[core_id] = task;
                    return task.stack_pointer;
                }
            }

            next_task = null;
            current_task[core_id] = null;
            const null_task_sp = platform.switch_to_null_task();

            // std.log.debug("{s}  Switch to null task  sp: 0x{X:08}", .{ platform.debug_core(), @intFromPtr(null_task_sp) });

            return null_task_sp;
        }

        //----------------------------------------------------------------------------

        fn _signal_task(in_task: TaskTag, in_event: u8) !bool {
            if (in_event >= config.event_flags_count) {
                return error.InvalidEventFlag;
            }

            var need_significant_event = false;
            const the_task = &task_list[@intFromEnum(in_task)];

            //std.log.debug("{s}  Signaling event {d} to task {s} ({s})", .{ platform.debug_core(), in_event, @tagName(in_task), @tagName(the_task.state) });

            {
                schedule_mutex.lock();
                defer schedule_mutex.unlock();

                const setFlag = @as(EventFlags, 1) << @intCast(in_event);

                the_task.event_flags |= setFlag;

                if ((the_task.event_mask & setFlag) != 0 and the_task.state == .waiting) {
                    the_task.state = .runnable;
                    // std.log.debug("{s}  Set task {s} to runnable", .{ platform.debug_core(), @tagName(the_task.tag) });
                    need_significant_event = true;
                }
            }

            return need_significant_event;
        }

        //============================================================================
        // RTTS Timer
        //============================================================================

        pub const TimerMode = enum {
            event_flag,
            function,
        };

        /// The scheduler maintains a list of timers.  Each timer has a delay and an action.
        /// Normally a timer will wake a task, by setting an event flag. However, it can also
        /// call a function.  The function runs in handler mode and should not block or take
        /// long to execute.
        ///
        /// Timers delay times are specified in milliseconds, but are converted to ticks
        /// based on the config.resolution parameter.
        ///
        pub const Timer = struct {
            /// The next timer in priority order
            next: ?*Timer = null,
            /// Time from prior task (or now if this is the first timer)
            expire_in: u32 = 0,
            /// Delay in ticks from the timer being scheduled to the timer expiring.
            delay: u32,
            /// If true, the timer will be respawned when it expires.
            respawn: bool,
            /// Timer action
            action: union(TimerMode) {
                event_flag: struct {
                    task_tag: TaskTag,
                    event_flag: u8,
                },
                function: struct {
                    func: *const fn (param: ?*anyopaque) void,
                    param: ?*anyopaque,
                },
            },

            /// Returns a timer initialized with a function
            ///
            /// Parameters:
            ///   in_delay - The delay in milliseconds. (See RTTS.Config.resolution)
            ///   in_respawn - If true, the timer will be respawned when it expires
            ///   in_func - The function to call when the timer expires
            ///   in_param - The parameter to pass to the function
            pub fn init_with_function(in_delay: u32, in_respawn: bool, in_func: *const fn (param: *anyopaque) bool, in_param: ?*anyopaque) Timer {
                return .{
                    .delay = delay_to_ticks(in_delay),
                    .respawn = in_respawn,
                    .action = .{
                        .function = .{
                            .func = in_func,
                            .param = in_param,
                        },
                    },
                };
            }

            //------------------------------------------------------------------------------
            /// Returns a timer initialized with an event flag
            ///
            /// Parameters:
            ///   in_delay - The delay in milliseconds. (See RTTS.Config.resolution)
            ///   in_respawn - If true, the timer will be respawned when it expires
            ///   in_task_tag - The task tag to signal
            ///   in_event_flag - The event flag number to signal
            pub fn init_with_event_flag(in_delay: u32, in_respawn: bool, in_task_tag: TaskTag, in_event_flag: u8) !Timer {
                if (in_event_flag >= config.event_flags_count) {
                    return error.InvalidEventFlag;
                }

                return .{
                    .delay = delay_to_ticks(in_delay),
                    .respawn = in_respawn,
                    .action = .{
                        .event_flag = .{
                            .task_tag = in_task_tag,
                            .event_flag = in_event_flag,
                        },
                    },
                };
            }

            //------------------------------------------------------------------------------
            /// Is this timer on the pending list?
            pub fn is_pending(self: *Timer) bool {
                return self.expire_in != 0;
            }

            //------------------------------------------------------------------------------
            /// Delay before this timer will expire in milliseconds
            /// Returns 0 if the timer is not on the pending list
            pub fn get_expiry(self: *Timer) u32 {
                if (self.expire_in == 0) return 0;

                timer_mutex.lock();
                defer timer_mutex.unlock();

                var expiry: u32 = 0;

                var an_item = first_timer;
                while (an_item != null) {
                    expiry += an_item.?.expire_in;
                    if (an_item.? == self) {
                        return ticks_to_delay(expiry);
                    }
                    an_item = an_item.?.next;
                }

                return 0;
            }

            //------------------------------------------------------------------------------
            /// Schedule the timer.  If the timer is already on the pending list,
            /// it is removed and reinserted at the correct position.
            ///
            /// Parameters:
            ///   in_new_delay - The new delay in milliseconds -- if null the
            ///                  delay is unchanged.
            pub fn schedule(self: *Timer, in_new_delay: ?u32) void {
                self.cancel();

                if (in_new_delay) |delay| self.delay = delay_to_ticks(delay);

                self.expire_in = self.delay;

                timer_mutex.lock();
                defer timer_mutex.unlock();

                self._do_schedule();
            }

            //------------------------------------------------------------------------------
            /// add timer to pending list
            pub fn _do_schedule(self: *Timer) void {
                self.expire_in = self.delay;

                if (first_timer) |first| {
                    // We have scheduled timers, if "self" expires before (or
                    // at the same time) as the first timer, insert it at the
                    // front of the list, adjusting the delay of the original
                    // first timer to account for the delay of "self".

                    if (first.expire_in >= self.expire_in) {
                        first.expire_in -= self.expire_in;
                        self.next = first;
                        first_timer = self;
                    } else {

                        // Scan the list looking for the correct position for "self"

                        var an_item = first_timer;
                        while (an_item.?.next) |next| {
                            self.expire_in -= an_item.?.expire_in;

                            if (next.expire_in <= self.expire_in) {
                                next.expire_in -= self.expire_in;
                                self.next = next;
                                an_item.?.next = self;
                                break;
                            }

                            an_item = next;
                        }
                    }
                } else {
                    // No timers on the list, so we are the first

                    first_timer = self;
                    self.next = null;

                    platform.enable_timer();
                }
            }

            // Remove the timer from the pending list
            pub fn cancel(self: *Timer) void {
                if (self.expire_in == 0) return;

                timer_mutex.lock();
                defer timer_mutex.unlock();

                self.expire_in = 0;

                if (first_timer == self) {
                    first_timer = self.next;

                    if (first_timer == null) {
                        platform.disable_timer();
                    }

                    return;
                }

                var an_item = first_timer;
                while (an_item) |item| {
                    if (item.next.? == self) {
                        item.next = self.next;
                        break;
                    }
                    an_item = item.next;
                }
            }

            //------------------------------------------------------------------------------
            pub fn delay_to_ticks(in_delay: u32) u32 {
                var delay: u64 = in_delay;
                delay *= config.resolution;
                return @intCast((delay + 500) / 1000);
            }

            //------------------------------------------------------------------------------
            pub fn ticks_to_delay(in_ticks: u32) u32 {
                var delay: u64 = in_ticks;
                delay *= 1000;
                return @intCast(delay / config.resolution);
            }

            //------------------------------------------------------------------------------
            /// Tick the timer
            pub fn tick() void {
                timer_mutex.lock();
                defer timer_mutex.unlock();

                // decrement the expire_in for the first timer

                if (first_timer) |timer| timer.expire_in -= 1;

                // Perform actions for expired timers

                while (first_timer) |timer| {
                    if (timer.expire_in != 0) break;

                    // Remove the timer from the (beginning of) pending list

                    first_timer = timer.next;

                    // std.log.debug("Timer expired for task 0x{x:08} next {any}", .{ @intFromPtr(timer), timer.next });

                    if (timer.respawn) {
                        // std.log.debug("Timer respawned", .{});
                        timer._do_schedule();
                    } else {
                        // std.log.debug("Timer not respawned", .{});
                    }

                    if (first_timer == null) {
                        platform.disable_timer();
                    }

                    switch (timer.action) {
                        .function => {
                            timer.action.function.func(timer.action.function.param);
                        },
                        .event_flag => {
                            //std.log.debug("Sending task {s} event flag {d}", .{ @tagName(timer.action.event_flag.task_tag), timer.action.event_flag.event_flag });
                            signal_event_isr(timer.action.event_flag.task_tag, timer.action.event_flag.event_flag) catch unreachable;
                        },
                    }
                }
            }
        };

        //============================================================================
        // RTTS Mailbox
        //============================================================================
        /// A mailbox is a queue of messages that can be sent to a task.
        ///
        /// A mailbox is initialized with an allocator, an event flag, and a receiver.
        /// The receiver is the task that will receive messages from the mailbox.
        /// If the receiver is null the current task will be used.
        ///
        /// Messages are sent to the mailbox with the `send` method.  This does a shallow
        /// copy of the message data.  The mailbox will signal the receiver when a message
        /// is available.
        ///
        /// Messages are received from the mailbox with the `receive` method.  The
        /// receiver will block until a message is available.
        ///
        /// Messages are freed when the next message is received or when the `free_message`
        /// method is called.
        ///
        /// If the type `T` is a container with a function named `callback`, that function
        /// will be called with a pointer to the internal copy of the message data before
        /// the message is freed.  This allows the message sender to perform any additional
        /// cleanup.
        ///
        /// Parameters:
        ///   T - The type of the data passed in the message.
        pub fn mailbox(T: type) type {
            return struct {
                const Mailbox = @This();

                allocator: std.mem.Allocator,
                receiver: *TaskTag,
                event_flag: u8,
                messages: ?*Message = null,
                last_message: ?*Message = null,
                recieved_message: ?*Message = null,
                message_mutex: interrupt.Mutex = .{},

                const Message = struct { next: ?*Message = null, data: T };

                const Callback = fn (*const T) void;

                // ---------------------------------------------------------------------------
                /// Initialize an instance of the mailbox.
                ///
                /// Parameters:
                ///   allocator - The allocator to use for memory allocation
                ///   event_flag - The event flag to use for signaling
                ///   receiver - The task that will receive messages from the mailbox
                ///     If null the current task will be used
                ///
                pub fn init(allocator: std.mem.Allocator, event_flag: u8, receiver: ?*TaskTag) Mailbox {
                    return Mailbox{
                        .allocator = allocator,
                        .receiver = if (receiver) |r| r else get_current_task().tag,
                        .event_flag = event_flag,
                        .messages = null,
                        .last_message = null,
                        .recieved_message = null,
                        .message_mutex = interrupt.Mutex{},
                    };
                }

                // ---------------------------------------------------------------------------
                /// Add a message to the mailbox.  Any task waiting for a message will be
                /// have the mailbox signaled.
                ///
                /// Do not call this function from an interrupt service routine.
                ///
                /// Parameters:
                ///   in_data - The data to add to the mailbox
                ///
                pub fn send(self: *Mailbox, in_data: T) !void {
                    try self.do_send(in_data);
                    try signal_event(self.receiver, self.event_flag);
                }

                // ---------------------------------------------------------------------------
                /// Add a message to the mailbox.  Any task waiting for a message will be
                /// have the mailbox signaled.
                ///
                /// This method is safe to be called from an interrupt service routine.
                ///
                /// Parameters:
                ///   in_data - The data to add to the mailbox
                ///
                pub fn send_isr(self: *Mailbox, in_data: T) !void {
                    try self.do_send(in_data);
                    try signal_event_isr(self.receiver, self.event_flag);
                }

                // ---------------------------------------------------------------------------
                /// Internal function to add a message to the mailbox.
                fn do_send(self: *Mailbox, in_data: T) !void {
                    const message = try self.allocator.create(Message);
                    message.* = .{
                        .next = null,
                        .data = in_data,
                    };

                    self.message_mutex.lock();
                    defer self.message_mutex.unlock();

                    if (self.messages) |last| {
                        last.next = message;
                    } else {
                        self.messages = message;
                    }

                    self.last_message = message;
                }

                // ---------------------------------------------------------------------------
                /// Check if there is a message in the mailbox
                ///
                /// Returns:
                ///   true if there is a message in the mailbox false otherwise
                pub fn has_message(self: *Mailbox) bool {
                    return self.messages != null;
                }

                // ---------------------------------------------------------------------------
                /// Receive a message from the mailbox.  If no message is available the task
                /// calling this method will wait until a message is available.
                ///
                /// Returns a pointer to the data in the message.
                ///
                /// This method with free the previously received message when it is called,
                /// so the returned pointer is only valid until the next call to `receive`.
                ///
                /// Raises:
                ///   error.InvalidTask - If the `receive` method is called by a task
                ///     that is not the receiver.
                ///
                pub fn receive(self: *Mailbox) !*T {
                    if (get_current_task().tag != self.receiver) {
                        return error.InvalidTask;
                    }

                    const mask: EventFlags = @as(EventFlags, 1) << @intCast(self.event_flag);

                    while (true) {
                        {
                            self.message_mutex.lock();
                            defer self.message_mutex.unlock();

                            if (self.recieved_message) |message| {
                                self.allocator.destroy(message);
                                self.recieved_message = null;
                            }

                            if (self.messages) |message| {
                                self.recieved_message = message;
                                self.messages = message.next;

                                if (self.messages == null) {
                                    self.last_message = null;
                                    self.receiver.clear_event(self.event_flag);
                                    clear_event_flags(mask);
                                }

                                return &message.data;
                            }
                        }

                        wait_for_event(mask, false);
                    }
                }

                // ---------------------------------------------------------------------------
                /// Free the last fetched message
                pub fn free_message(self: *Mailbox) void {
                    self.message_mutex.lock();
                    defer self.message_mutex.unlock();

                    if (self.recieved_message) |message| {
                        self.allocator.destroy(message);
                        self.recieved_message = null;
                    }
                }
            };
        }
    };
}
