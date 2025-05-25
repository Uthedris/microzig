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
            yielded,
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

        /// Test true if the core needs to scan the task list from the top.
        pub var sig_event: [core_count]bool = @splat(false);

        /// The mutex used to synchronize access to the task list.
        pub var schedule_mutex: interrupt.Mutex = .{};

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

                std.log.debug("Initialized task \"{s}\":", .{task.name});
                std.log.debug("  func: {any}", .{task.func});
                std.log.debug("  stack_size: {d}", .{task.stack_size});
                std.log.debug("  stack: {any}", .{task_list[i].stack_pointer});
                std.log.debug("  event_flags: {x}", .{task_list[i].event_flags});
                std.log.debug("  event_mask: {x}", .{task_list[i].event_mask});
                std.log.debug("  state: {s}", .{@tagName(task_list[i].state)});

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
            return current_task[platform.core_id()] orelse unreachable;
        }

        //----------------------------------------------------------------------------
        /// Wait for an event.
        ///
        /// This function will set the current task's event mask to the value
        /// specified in in_event_mask.  If in_clear_flags is true, it will also
        /// clear the matching event flags.
        ///
        /// Finally, if a bit-wise and of the task's event flags and event mask is
        /// zero, the task will be set to the waiting state.
        ///
        /// To reactivate the task, some other task or interrupt service routine
        /// must set at lease one of this task's event flags that match a bit in this
        /// task's event mask.
        ///
        /// Parameters:
        ///   in_event_mask - The event mask to wait for
        ///   in_clear_flags - If true, clear event flags that match the event mask
        ///
        pub fn wait_for_event(in_event_mask: EventFlags, in_clear_flags: bool) void {
            const the_task = get_current_task();

            the_task.event_mask = in_event_mask;
            if (in_clear_flags) the_task.event_flags &= ~in_event_mask;

            if ((the_task.event_flags & the_task.event_mask) == 0) {
                platform.wait(); // Wait for an event
            }
        }

        //----------------------------------------------------------------------------
        /// Yield to a lower priority task.
        ///
        /// The current task will let other tasks of lower priority run.  It will
        /// run again after the next significant event or if no other tasks want
        /// to run.
        pub fn yield() void {
            const the_task = get_current_task();
            the_task.state = .yielded;

            platform.yield();
        }

        //----------------------------------------------------------------------------
        /// Declare a significant event.
        ///
        /// The scheduler will re-scan the task list and the highest priority
        /// runnable tasks will be run.  A call to this function on one core can
        /// change the tasks assigned to any core.
        pub fn significant_event() void {
            platform.significant_event();
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
        pub fn signal_event(in_task: TaskTag, in_event: u8) void {
            std.debug.assert(in_event < config.event_flags_count);

            var need_significant_event = false;
            const the_task = &task_list[@intFromEnum(in_task)];

            std.log.debug("{s}  Signaling event {d} to task {s} ({s})", .{ platform.debug_core(), in_event, @tagName(in_task), @tagName(the_task.state) });

            {
                schedule_mutex.lock();
                defer schedule_mutex.unlock();

                const setFlag = @as(EventFlags, 1) << @intCast(in_event - 1);

                the_task.event_flags |= setFlag;

                if ((the_task.event_mask & setFlag) != 0 and the_task.state == .waiting) {
                    the_task.state = .runnable;
                    need_significant_event = true;
                }
            }

            if (need_significant_event) platform.significant_event();
        }

        //----------------------------------------------------------------------------
        /// Get the priority of a task.
        ///
        /// Parameters:
        ///   in_task - The task to get the priority of
        /// Returns:
        ///   The priority of the task.  0 is the highest priority.
        pub fn get_priority(in_task: TaskTag) usize {
            schedule_mutex.lock();
            defer schedule_mutex.unlock();

            var priority: usize = 0;
            const task = &task_list[@intFromEnum(in_task)];

            var a_task = highest_priority_task;
            while (a_task != null and a_task != task) {
                priority += 1;
                a_task = a_task.next;
            }

            return priority;
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
            defer significant_event();

            // Sanity check -- we do nothing if task_a and task_b are the same

            if (in_task_b) |t| {
                if (t == in_task_a) return;
            }

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
            std.log.debug("{s}  Finding next task", .{platform.debug_core()});

            schedule_mutex.lock();
            defer schedule_mutex.unlock();

            // Save the stack pointer for the current task and, if it was running,
            // set it to runnable.

            if (current_task[platform.core_id()]) |task| {
                task.stack_pointer = in_sp;
                if (task.state == .running) task.state = .runnable;
            }

            var has_significant_event = sig_event[platform.core_id()];
            sig_event[platform.core_id()] = false;

            // Scan the task list for the highest priority runnable task

            while (true) {
                if (has_significant_event) clear_yield_flags();

                var a_task: ?*TaskItem = highest_priority_task;
                while (a_task) |task| {
                    if (task.state == .runnable) {
                        std.log.debug("{s}  Switch to task {s} sp: 0x{X:08}", .{ platform.debug_core(), @tagName(task.tag), @intFromPtr(task.stack_pointer) });

                        task.state = .running;
                        current_task[platform.core_id()] = task;
                        return task.stack_pointer;
                    }

                    a_task = task.next;
                }

                // If we get here we didn't find a runnable task, one of two things happened:
                // 1. We had a significant event - since nothing wants to run we run the null task.
                // 2. We didn't have a significant event - scan again as if we did to check for yielded tasks.

                if (has_significant_event) break;

                has_significant_event = true;
            }

            std.log.debug("{s}  Switch to null task  sp: 0x{X:08}", .{ platform.debug_core(), @intFromPtr(platform.null_task_stack_pointer) });

            current_task[platform.core_id()] = null;
            return platform.null_task_stack_pointer;
        }

        //----------------------------------------------------------------------------
        /// Clear any yield flags making the yielded tasks runnable.
        ///
        pub fn clear_yield_flags() void {
            for (&task_list) |*an_item| {
                if (an_item.state == .yielded) {
                    an_item.state = .runnable;
                }
            }
        }

        //----------------------------------------------------------------------------
        /// Find the lowest priority task that is assigned to a core
        /// Note: This function should be called from within a critical section.
        pub fn find_lowest_priority_running() ?*TaskItem {
            var retval: *TaskItem = &task_list[0];

            for (0..core_count) |i| {
                if (core_mask & (@as(u8, 1) << @intCast(i)) == 0) continue;

                if (current_task[i]) |a_task| {
                    std.log.debug("{s}  core {d} has task {s}", .{ platform.debug_core(), i, @tagName(a_task.tag) });
                    if (priority_compare(a_task, retval) < 0) {
                        retval = a_task;
                    }
                } else {
                    // Found null task -- it's always the lowest priority
                    std.log.debug("{s}  core {d} has null task", .{ platform.debug_core(), i });
                    return null;
                }
            }

            return retval;
        }
    };
}
