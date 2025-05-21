const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const cpu = microzig.cpu;
const chip = microzig.chip;

const irq = hal.irq;
const multicore = hal.multicore;
const time = hal.time;
const compatibility = hal.compatibility;

const peripherals = chip.peripherals;

const PPB = peripherals.PPB;
const SIO = peripherals.SIO;

const scb = cpu.peripherals.scb;

const SvcID = enum(u8) {
    yield = 0x00,
    significant_event = 0x01,
    wait = 0x02,
};

const FIFOCommand = enum(u8) {
    dispatch,
    block,
    _,
};

pub fn configure(comptime RTTS: type) type {
    return struct {
        const Platform = @This();

        pub const cores_available = 0x03;

        //==============================================================================
        // RTTS Platform Functions
        //==============================================================================
        // These function are called from the common RTTS code and implement the
        // platform specific functionality.

        //------------------------------------------------------------------------------
        /// Get the ID of the current core
        ///
        pub fn core_id() u8 {
            return @intCast(hal.get_cpu_id());
        }

        pub fn debug_core() []const u8 {
            return if (core_id() == 0) "Core 0 " else "Core 1                                       ";
        }

        //------------------------------------------------------------------------------
        /// Initialize the stack for a task as though it had been swapped out
        ///
        pub fn initialize_stack(in_stack: [*]usize, in_pc: *const fn () void) [*]usize {
            // We want to duplicate how the pendSV handler saves registers
            //      +--------+
            //      |  r8    | <- Stack pointer
            //      |  r9    | +   1
            //      |  r10   | +   2
            //      |  r11   | +   3
            //      |  r4    | +   4
            //      |  r5    | +   5
            //      |  r6    | +   6
            //      |  r7    | +   7
            //      |  r0    | +   8
            //      |  r1    | +   9
            //      |  r2    | +  10
            //      |  r3    | +  11
            //      |  r12   | +  12
            //      |  lr    | +  13
            //      |  pc    | +  14
            //      |  xPSR  | +  15
            //      +--------+

            var sp = in_stack;

            _ = @TypeOf(in_pc);
            _ = @TypeOf(sp);

            asm volatile (
                \\    mov    r1,    %[sp]
                \\
                \\    subs   r1,    #16              @ Reserve 16 bytes on stack
                \\    movs   r2,    #0               @ r12
                \\    movs   r3,    #0               @ lr
                \\    mov    r4,    %[pc]            @ pc
                \\    movs   r5,    #0x01            @ xPSR  <--- 0x0100_0000
                \\    rev    r5,    r5
                \\    stm    r1!,   {r2-r5}
                \\    subs   r1,    #16
                \\
                \\    subs   r1,    #16              @ Reserve 16 bytes on stack
                \\    movs   r4,    #0               @ r0, r1, r2, r3
                \\    movs   r5,    #0
                \\    stm    r1!,   {r2-r5}
                \\    subs   r1,    #16
                \\
                \\    subs   r1,    #16              @ Reserve 16 bytes on stack
                \\    stm    r1!,   {r2-r5}          @ r4, r5, r6, r7
                \\    subs   r1,    #16
                \\
                \\    subs   r1,    #16              @ Reserve 16 bytes on stack
                \\    stm    r1!,   {r2-r5}          @ r8, r9, r10, r11
                \\    subs   r1,    #16
                \\    mov    %[sp], r1
                : [sp] "+r" (sp),
                : [pc] "r" (in_pc),
                : "r1", "r2", "r3", "r4", "r5"
            );

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {
            // Set the priority of the PendSV exception to the lowest possible value

            if (compatibility.chip == .RP2040) {
                PPB.SHPR3.modify(.{ .PRI_14 = 0, .PRI_15 = 0 });
            } else {
                PPB.SHPR3.modify(.{ .PRI_14_3 = 0, .PRI_15_3 = 0 });
            }

            _ = cpu.interrupt.exception.set_handler(.SVCall, .{ .c = svc_ISR });
            _ = cpu.interrupt.exception.set_handler(.PendSV, .{ .naked = pendsv_ISR });

            if (RTTS.core_mask & 0x02 != 0) {
                if (compatibility.chip == .RP2040) {
                    _ = hal.irq.set_handler(.SIO_IRQ_PROC0, .{ .c = fifo_ISR });
                    _ = hal.irq.set_handler(.SIO_IRQ_PROC1, .{ .c = fifo_ISR });
                } else {
                    _ = hal.irq.set_handler(.SIO_IRQ_FIFO, .{ .c = fifo_ISR });
                }
                // Note: We don't enable these interrupts until after the other core is
                // launched, so we don't mess with the launch sequence.
            }

            // Set up null task stack

            null_task_stack[null_task_stack_len - 2] = @intFromPtr(&null_task_loop);
            null_task_stack[null_task_stack_len - 1] = 0x01000000;

            null_task_stack_pointer = @intFromPtr(&null_task_stack[null_task_stack_len - 16]);

            // Launch the other core

            if (RTTS.core_mask & 0x02 != 0) {
                multicore.launch_core1(blk: {
                    const s = struct {
                        fn core1_init() noreturn {
                            run_first_task();
                        }
                    };

                    break :blk s.core1_init;
                });
            }

            run_first_task();
        }

        //------------------------------------------------------------------------------
        /// Send the yield SVC
        ///
        pub fn yield() void {
            // If we're in thread mode use a SVC to post yield event, otherwise
            // set the pendSV flag to do the task swap

            if (scb.ICSR.read().VECTACTIVE == 0) {
                asm volatile ("svc #0");
            } else {
                scb.ICSR.modify(.{ .PENDSVSET = 1 });
                asm volatile ("isb");
            }
        }

        //------------------------------------------------------------------------------
        /// Post a significant event
        ///
        pub fn significant_event() void {
            // If we're in thread mode use a SVC to post the significant event, otherwise
            // set the pendSV flag

            if (scb.ICSR.read().VECTACTIVE == 0) {
                asm volatile ("svc #1");
            } else {
                for (&RTTS.sig_event) |*sig_event| {
                    sig_event.* = true;
                }

                scb.ICSR.modify(.{ .PENDSVSET = 1 });
                asm volatile ("isb");

                send_fifo_command(.dispatch, null, null);
            }
        }

        //------------------------------------------------------------------------------
        /// Send the wait SVC
        ///
        pub fn wait() void {
            // If we're in thread mode use a SVC to post yield event, otherwise
            // set we check the current task's event flags under the mask
            // and yield if none are set;

            if (scb.ICSR.read().VECTACTIVE == 0) {
                asm volatile ("svc #2");
            } else {
                if (RTTS.current_task[core_id()]) |task| {
                    // We need to wait if we have a mask and no
                    // mask bit has a corresponding event flag set.
                    if (task.event_mask != 0 and task.event_mask & task.event_flags == 0) {
                        task.state = .waiting;
                        scb.ICSR.modify(.{ .PENDSVSET = 1 });
                        asm volatile ("isb");
                    }
                }
            }
        }

        //==============================================================================
        // Interrupt service routines
        //==============================================================================
        // There are three ISR's that need to be registered.
        //  1. svc_ISR     - (SVCall) The svc interrupt service routine
        //  2. pendsv_ISR  - (PendSV) The pendsv interrupt service routine
        //  3. fifo_ISR    - (The inter-core communication interrupt service routine
        //
        //  4. sysTick_ISR - (SysTick) The sysTick interrupt service routine

        //------------------------------------------------------------------------------
        /// svc interrupt service routine
        ///
        fn svc_ISR() callconv(.c) void {
            //    We need to get a pointer to the callers stack so we can figure out
            //    the trap code How we do it depends on whether the SVC was called
            //    from code using a process stack (a task) or the main stack (an
            //    interrupt service routine).
            //
            //    We can tell by looking at the link register:
            //          LR value       source mode    source stack
            //       --------------    -----------    -------------------
            //       -3 (0xfffffffd)   Thread mode    Process stack
            //       -7 (0xfffffff9)   Thread mode    Main stack (not used)
            //      -15 (0xfffffff1)   Handler mode   Main stack
            //
            //    If we were called from a task, the link register will be -3, and
            //    the task's stack pointer will be saved in PSP special register.
            //
            //    If we were called from an interrupt service routine, the link
            //    register will be -7 or -15 and the current stack pointer will be
            //    the same as the caller.
            //

            // After a SVC call the caller's stack looks like this:
            //      +--------+
            //      |  r0    | <- Stack pointer
            //      |  r1    | +  1
            //      |  r2    | +  2
            //      |  r3    | +  3
            //      |  r12   | +  4
            //      |  lr    | +  5
            //      |  pc    | +  6
            //      |  xPSR  | +  7
            //      +--------+

            var lr: i32 = undefined;
            var sp: [*]u32 = undefined;

            asm volatile (
                \\    mov   %[lr], lr
                \\    mov   %[sp], sp
                : [lr] "+r" (lr),
                  [sp] "+r" (sp),
            );

            if (lr == -3) {
                // get the process stack pointer
                asm volatile (
                    \\    mrs   %[sp], psp
                    : [sp] "+r" (sp),
                    :
                    : "r0"
                );
            }

            const pc = sp[6];

            const svc_id: SvcID = @enumFromInt(@as(*u16, @ptrFromInt(pc - 2)).* & 0xff);

            std.log.debug("{s}SVC: {}", .{ debug_core(), @intFromEnum(svc_id) });

            switch (svc_id) {
                .yield => yield(),
                .significant_event => significant_event(),
                .wait => wait(),
            }
        }

        //------------------------------------------------------------------------------
        /// pendsv interrupt service routine
        ///
        // Since this ISR must be able to save the context of the current
        // task, the pendsv exception should only run in thread mode.  This is
        // accomplished by setting the the pendsv to the lowest possible
        // priority.  Thus, if the pendsv is scheduled when in another ISR
        // it will not actually trigger until that interrupt is complete.

        pub fn pendsv_ISR() callconv(.naked) noreturn {
            // If there is a non-null task running on the core, save the other
            // registers and the stack pointer.

            // On entry the task's registers have been saved on the task's stack:
            //      +--------+
            //      |  r0    | <- Stack pointer
            //      |  r1    | +  1
            //      |  r2    | +  2
            //      |  r3    | +  3
            //      |  r12   | +  4
            //      |  lr    | +  5
            //      |  pc    | +  6
            //      |  xPSR  | +  7
            //      +--------+
            //
            // After saving the additional registers, the task's stack should look like this:
            //      +--------+
            //      |  r8    | <- Stack pointer
            //      |  r9    | +  1
            //      |  r10   | +  2
            //      |  r11   | +  3
            //      |  r4    | +  4
            //      |  r5    | +  5
            //      |  r6    | +  6
            //      |  r7    | +  7
            //      |  r0    | +  8
            //      |  r1    | +  9
            //      |  r2    | + 10
            //      |  r3    | + 11
            //      |  r12   | + 12
            //      |  lr    | + 13
            //      |  pc    | + 14
            //      |  xPSR  | + 15
            //      +--------+

            // First we need to the save the rest of the registers to the task's stack.

            asm volatile (
                \\    mrs   r0,    psp                 @ Save the rest of the registers
                \\    subs  r0,    #16
                \\    stm   r0!,   {r4, r5, r6, r7}
                \\    mov   r4,    r8
                \\    mov   r5,    r9
                \\    mov   r6,    r10
                \\    mov   r7,    r11
                \\    subs  r0,    #16
                \\
                \\    subs  r0,    #16
                \\    stm   r0!,   {r4, r5, r6, r7}
                \\    subs  r0,    #16
                \\
                \\    mov   r5,   lr
                \\    mov   r1,   r0                    @ Pass the old task's stack pointer
                \\    bl    %[find_next]                @ to findNextTaskSP, which returns
                \\    mov   lr,   r5                    @ the new task's stack pointer.
                \\
                \\    ldm   r0!,  {r4, r5, r6, r7}      @ Restore the registers we saved
                \\    mov   r8,   r4
                \\    mov   r9,   r5
                \\    mov   r10,  r6
                \\    mov   r11,  r7
                \\    ldm   r0!,  {r4, r5, r6, r7}
                \\    msr   psp,  r0
                \\    bx    lr
                :
                : [find_next] "s" (&RTTS.find_next_task_sp),
            );
        }

        //------------------------------------------------------------------------------
        /// FIFO interrupt service routine
        ///
        pub fn fifo_ISR() callconv(.c) void {
            var theParam: u32 = 0;
            var theTask: ?*RTTS.TaskItem = null;

            std.log.debug("{s}FIFO ISR   FIFO_ST: 0x{x:08}", .{ debug_core(), SIO.FIFO_ST.raw });

            SIO.FIFO_ST.raw = 0;

            while (multicore.fifo.read()) |first_word| {
                // The high order eight bits of the first word of
                // a transfer are always 0x80.
                if ((first_word & 0xFF000000) != 0x80000000) {
                    std.log.debug("{s}   bad command 0x{x:08}", .{ debug_core(), first_word });
                    continue;
                }

                // And the next eight bits are the size of the transfer.
                const count = (first_word >> 16) & 0xFF;

                //This will always be either 1, 2, or 3.
                if (count < 1 or count > 3) {
                    std.log.debug("{s}   bad command 0x{x:08}  count: {d}", .{ debug_core(), first_word, count });
                    continue;
                }

                if (count >= 2) {
                    theTask = @ptrFromInt(multicore.fifo.read_blocking());
                }

                if (count == 3) {
                    theParam = multicore.fifo.read_blocking();
                }

                const command: FIFOCommand = @enumFromInt(first_word & 0xFF);

                if (theTask) |task| {
                    std.log.debug("{s}   dispatch: {} {s} {d}", .{ debug_core(), @intFromEnum(command), @tagName(task.tag), theParam });
                } else {
                    std.log.debug("{s}   dispatch: {} null {d}", .{ debug_core(), @intFromEnum(command), theParam });
                }

                switch (command) {
                    .dispatch => {
                        scb.ICSR.modify(.{ .PENDSVSET = 1 });
                        asm volatile ("isb");
                    },
                    .block => {},
                    else => {
                        std.log.debug("Unknown command: 0x{x:08}", .{@intFromEnum(command)});
                    },
                }
            }

            std.log.debug("{s}   done", .{debug_core()});
        }

        //==============================================================================
        // Local thread mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Run the first task on this core
        fn run_first_task() noreturn {
            // Enable the FIFO interrupt

            if (RTTS.core_mask & 0x02 != 0) {
                multicore.fifo.drain();
                SIO.FIFO_ST.raw = 0;

                if (compatibility.chip == .RP2040) {
                    if (core_id() == 0) {
                        hal.irq.enable(.SIO_IRQ_PROC0);
                    } else {
                        hal.irq.enable(.SIO_IRQ_PROC1);
                    }
                } else {
                    hal.irq.enable(.SIO_IRQ_FIFO);
                }

                cpu.interrupt.enable_interrupts();
            }

            // Switch to the highest priority task

            std.log.debug("{s}Entered run_first_task", .{debug_core()});

            var target_sp: [*]usize = &null_task_stack;
            var target_pc: usize = @intFromPtr(&null_task_loop);

            {
                RTTS.schedule_mutex.lock();
                defer RTTS.schedule_mutex.unlock();

                for (&RTTS.task_list) |*a_task| {
                    if (a_task.state == .runnable) {
                        RTTS.current_task[core_id()] = a_task;
                        a_task.state = .running;

                        // We found the task we want to run.  Get the initial PC from
                        // the initalized stack then clear the stack.

                        target_pc = a_task.stack_pointer[14];
                        target_sp = a_task.stack_pointer + 16;

                        std.log.debug("{s}   Starting task {s}", .{ debug_core(), @tagName(a_task.tag) });
                        break;
                    }
                }
            }

            asm volatile (
                \\    msr   PSP, %[sp]   @ Set the process stack pointer
                \\    movs  r0, #02
                \\    msr   CONTROL, r0  @ Set the control register (use PSP)
                \\    mov   sp, %[sp]    @ Set the stack pointer
                \\    bx    %[pc]        @ Branch to the target PC
                :
                : [sp] "r" (target_sp),
                  [pc] "r" (target_pc),
                : "r0"
            );

            unreachable;
        }

        //------------------------------------------------------------------------------
        /// Core1 initialization
        fn core1_init() noreturn {
            std.log.debug("{s}Init", .{debug_core()});
            run_first_task();
        }

        //==============================================================================
        // Local handler mode functions
        //==============================================================================
        // These functions are with the scheduler mutex locked
        // and must not be called from user mode.

        //------------------------------------------------------------------------------
        /// Send a command to the other core
        /// Parameters:
        ///   in_command - The command to send
        ///   in_task    - The task the command applies to
        ///   in_param   - The parameter to send
        fn send_fifo_command(in_command: FIFOCommand, in_task: ?*RTTS.TaskItem, in_param: ?u32) void {
            // If we're not using core1 then just return

            if (RTTS.core_mask & 0x02 == 0) return;

            // Compute and queue the command word:
            //
            // +---------+---------+---------+---------+
            // |  0x80   | msg len |  command number   |
            // +---------+---------+---------+---------+

            var msg_len: usize = 1;

            if (in_task != null) msg_len += 1;
            if (in_param != null) msg_len += 1;

            const command = 0x80000000 | (msg_len << 16) | @intFromEnum(in_command);

            // If the send fifo is full then we have to  wait until the
            // other core reads something off of the fifo so we can
            // send some data.

            // If the send fifo is full then ping the other core
            // so that it reads something off of the fifo.

            if (!multicore.fifo.is_write_ready()) cpu.sev();

            multicore.fifo.write_blocking(command);

            if (in_task) |task| {
                multicore.fifo.write_blocking(@intFromPtr(task));
            }

            if (in_param) |param| {
                multicore.fifo.write_blocking(param);
            }
        }

        //==============================================================================
        // Null Task
        //==============================================================================

        const null_task_stack_len = 24;

        var null_task_stack: [null_task_stack_len]usize = undefined;
        pub var null_task_stack_pointer: usize = undefined;

        // ------------------------------------------------------------------------
        // The null task just calls wait for interrupt in an infinite loop.
        // A user who want to "replace" the null task should just run the
        // replacement code as the lowest priority task.

        fn null_task_loop() callconv(.naked) noreturn {
            // while (true)
            // {
            //   // hal.scb.scr |= hal.scb.SCR_SEVONPEND;
            //   asm volatile ( "wfe" );
            // }
            asm volatile (
                \\ null_loop:
                \\       wfe
                \\       b null_loop
            );
        }
    };
}
