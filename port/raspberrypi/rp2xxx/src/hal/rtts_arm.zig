//! This is the platform specific code for the RTTS scheduler for the
//! RP2xxx dual core ARM processors.
//!
//! //! To use dual processor mode, RTTS must be started on core 0.
//!
//! System resources used (all processor types)
//!   - SVC handler for SVC instruction dispatch.
//!
//! System resources used (RP2040)
//!   - Inter-core FIFO and associated interrupts (when configured for both cores).
//!
//! System resources used (RP2350)
//!   - Inter-core doorbell and associated interrupts (when configured for both cores).
//!
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
const systick = cpu.peripherals.systick;

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

// ### TODO ###  Support running tasks in unprivileged mode

pub fn configure(comptime RTTS: type, comptime config: RTTS.Configuration) type {

    return struct {
        const Platform = @This();

        pub const cores_available = 0x03;

        //==============================================================================
        // RTTS Platform Functions
        //==============================================================================
        // These function are called from the common RTTS code and implement the
        // platform specific functionality.

        //------------------------------------------------------------------------------
        /// Get the index of the current core [0..RTTS.core_count]
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

            var sp = in_stack - 16;

            for (sp[0..14]) |*reg| {
                reg.* = 0xface_fade; // so we can spot bad values
            }

            sp[14] = @intFromPtr(in_pc);
            sp[15] = 0x0100_0000;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {

            // Set up null task stack

            null_task_stack[null_task_stack_len - 2] = @intFromPtr(&null_task_loop);
            null_task_stack[null_task_stack_len - 1] = 0x01000000;

            null_task_stack_pointer = @ptrCast(&null_task_stack[null_task_stack_len - 16]);

            // Set the priority of the PendSV exception to the lowest possible value (which
            // is numerically the highest value)

            if (compatibility.chip == .RP2040) {
                PPB.SHPR3.modify(.{ .PRI_14 = 3 });
            } else {
                PPB.SHPR3.modify(.{ .PRI_14_3 = 7 });
            }

            _ = cpu.interrupt.exception.set_handler(.SVCall, .{ .naked = svc_ISR });
            _ = cpu.interrupt.exception.set_handler(.PendSV, .{ .naked = pendsv_ISR });
            _ = cpu.interrupt.exception.set_handler(.SysTick, .{ .c = sysTick_ISR });

            // Configure the systick timer

            var sys_tick_count = systick.CALIB.read().TENMS;
            sys_tick_count = @intCast(@as(u32, 100) * sys_tick_count  / config.ticks_per_second);

            systick.LOAD.write(.{
                .RELOAD = 1_530_000, // sys_tick_count,
            });
    
            systick.VAL.write(.{
                .CURRENT = 0,
            });

            systick.CTRL.write(.{
                .ENABLE = 1,
                .TICKINT = 1,
                .COUNTFLAG = 0,
                .CLKSOURCE = 1,
            });

            std.log.debug("-- SysTick CTRL: 0x{x:08}", .{systick.CTRL.raw});
            std.log.debug("-- SysTick CALIB: 0x{x:08}", .{systick.CALIB.raw});
            std.log.debug("-- SysTick VAL: {d}", .{systick.VAL.raw});
            std.log.debug("-- SysTick LOAD: {d}", .{systick.LOAD.raw});

            // Setup for multiple cores if configured.

            if (irq.has_ram_vectors()) {
                if (RTTS.core_count > 1) {
                    if (compatibility.chip == .RP2040) {
                        _ = irq.set_handler(.SIO_IRQ_PROC0, .{ .c = fifo_ISR });
                        _ = irq.set_handler(.SIO_IRQ_PROC1, .{ .c = fifo_ISR });
                    } else {
                        _ = irq.set_handler(.SIO_IRQ_BELL, .{ .c = doorbell_ISR });
                    }
                    // Note: We don't enable these interrupts until after the other core is
                    // launched, so we don't mess with the launch sequence.

                    multicore.launch_core1(run_first_task);
                }
            }

            // Run the first task on this core

            run_first_task();
        }

        //------------------------------------------------------------------------------
        /// Send the yield SVC
        ///
        pub fn yield() void {
            asm volatile ("svc #0");
        }

        //------------------------------------------------------------------------------
        /// Send the significant event SVC
        ///
        pub fn significant_event() void {
            asm volatile ("svc #1");
        }

        //------------------------------------------------------------------------------
        /// Send the significant event SVC
        ///
        pub fn significant_event_isr() void {
            for (&RTTS.sig_event) |*sig_event| {
                sig_event.* = true;
            }

            if (RTTS.core_count > 1) {
                if (compatibility.chip == .RP2040) {
                    send_fifo_command(.dispatch, null, null);
                } else {
                    multicore.doorbell.set(0);
                }
            }

            // Set pendsv to switch the task after the handler returns
            scb.ICSR.modify(.{ .PENDSVSET = 1 });
        }

        //------------------------------------------------------------------------------
        /// Send the wait SVC
        ///
        pub fn wait() void {
            asm volatile ("svc #2");
        }

        //==============================================================================
        // Local thread mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Run the first task on this core
        fn run_first_task() noreturn {
            std.log.debug("{s}Entered run_first_task", .{debug_core()});

            // Enable the FIFO interrupt

            if (RTTS.core_count > 1) {
                multicore.fifo.drain();
                SIO.FIFO_ST.raw = 0;

                if (compatibility.chip == .RP2040) {
                    if (core_id() == 0) {
                        irq.enable(.SIO_IRQ_PROC0);
                    } else {
                        irq.enable(.SIO_IRQ_PROC1);
                    }
                } else {
                    _ = multicore.doorbell.read_and_clear();
                    irq.enable(.SIO_IRQ_BELL);
                }

                irq.globally_enable();
            }

            // Find the highest priority task.  If launched on multiple
            // cores, each will pick a different task.

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

        //==============================================================================
        // Interrupt service routines
        //==============================================================================
        // There are three ISR's that need to be registered.
        //  1. svc_ISR     - (SVCall) The svc interrupt service routine
        //  2. pendsv_ISR  - (PendSV) The pendsv interrupt service routine
        //  3. fifo_ISR    - (The inter-core communication interrupt service routine
        //
        //  For time functions?
        //  4. sysTick_ISR - (SysTick) The sysTick interrupt service routine

        //------------------------------------------------------------------------------
        /// SVC interrupt service routine
        ///
        /// This ISR is registered as a naked function, so we can save the registers
        /// and restore the registers in a predicable way.
        ///
        pub fn svc_ISR() callconv(.naked) noreturn {
            // Upon entry the caller's stack looks like this:
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
            //  When Calling do_SVC the caller's stack looks like this:
            //
            //       +--------+
            //       |  r8    | <- Stack pointer (thread mode)
            //       |  r9    | +  4
            //       |  r10   | +  8
            //       |  r11   | + 12
            //       |  r4    | + 16
            //       |  r5    | + 20
            //       |  r6    | + 24
            //       |  r7    | + 28
            //       |  r0    | + 32      <-- Stack pointer (handler mode)
            //       |  r1    | + 36      + 4
            //       |  r2    | + 40      + 8
            //       |  r3    | + 44      + 12
            //       |  r12   | + 48      + 16
            //       |  lr    | + 52      + 20
            //       |  pc    | + 56      + 24
            //       |  xPSR  | + 60      + 28
            //       +--------+

            asm volatile (
                \\    movs  r0,   #0xff
                \\    mov   r1,   lr
                \\    ands  r0,   r1
                \\    cmp   r0,   #0xf1
                \\    beq   handler_mode
                \\
                \\    mrs   r0,    psp
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
                \\                                      @ Pass the old task's stack pointer
                \\    movs  r1,   #56
                \\    ldr   r1,   [r1, r0]              @ set 2nd param to caller's pc
                \\    movs  r2,   #0                    @ set 3rd param to false
                \\    bl    %[do_SVC]                   @ to findNextTaskSP, which returns
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
                \\
                \\ handler_mode:
                \\    mov   r5,   lr
                \\    movs  r1,   #24
                \\    ldr   r1,   [r0, r1]              @ set 2nd param to caller's pc
                \\    movs  r3,   #1                    @ set 3rd param to true
                \\    bl    %[do_SVC]                   @ to findNextTaskSP, which returns
                \\    mov   lr,   r5                    @ the new task's stack pointer.
                \\    bx    lr
                :
                : [do_SVC] "s" (&do_SVC),
            );
        }

        // If we were called from thread mode all the registers have been saved
        // we can do the dispatch directly and return the new stack pointer.

        fn do_SVC(in_sp: [*]usize, in_pc: usize, in_handler_mode: bool) callconv(.c) [*]usize {
            const svc_id: SvcID = @enumFromInt(@as(*u16, @ptrFromInt(in_pc - 2)).* & 0xff);

            if (in_handler_mode) {
                std.log.err("SVC {s} called from handler mode. -- ignored", .{@tagName(svc_id)});
                return in_sp;
            }

            // std.log.debug("do_SVC: svc_id: {s} in_sp: 0x{x:08} in_pc: 0x{x:08} handler_mode: {s}", .{@tagName(svc_id), @intFromPtr(in_sp), in_pc, if (in_handler_mode) "true" else "false"});

            // for (0..16) |i| {
            //     std.log.debug("    sp +{d:3}  0x{x:08}", .{i * 4, in_sp[i]});
            // }

            std.log.debug("{s}  Dispatch: {s}", .{ debug_core(), @tagName(svc_id) });

            switch (svc_id) {
                .yield => {
                    if (RTTS.current_task[core_id()]) |task| {
                        task.state = .yielded;
                        return RTTS.find_next_task_sp(in_sp);
                    }
                },
                .significant_event => {
                    for (&RTTS.sig_event) |*sig_event| {
                        sig_event.* = true;
                    }

                    if (RTTS.core_count > 1) {
                        if (compatibility.chip == .RP2040) {
                            send_fifo_command(.dispatch, null, null);
                        } else {
                            multicore.doorbell.set(0);
                        }
                    }

                    return RTTS.find_next_task_sp(in_sp);
                },
                .wait => {
                    if (RTTS.current_task[core_id()]) |task| {
                        // We need to wait if we have a mask and no
                        // mask bit has a corresponding event flag set.

                        if (task.event_mask != 0 and task.event_mask & task.event_flags == 0) {
                            task.state = .waiting;
                            return RTTS.find_next_task_sp(in_sp);
                        }
                    }
                },
            }

            return in_sp;
        }
        
        //------------------------------------------------------------------------------
        /// sysTick interrupt service routine
        ///
        pub fn sysTick_ISR() callconv(.c) void {
            RTTS.Timer.tick();
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
                \\                                      @ Pass the old task's stack pointer from r0
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

        //------------------------------------------------------------------------------
        /// Doorbell interrupt service routine
        ///
        ///
        pub fn doorbell_ISR() callconv(.c) void {
            _ = multicore.doorbell.read_and_clear();

            scb.ICSR.modify(.{ .PENDSVSET = 1 });
            asm volatile ("isb");
        }

        //==============================================================================
        // Local handler mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Send a command to the other core
        /// Parameters:
        ///   in_command - The command to send
        ///   in_task    - The task the command applies to
        ///   in_param   - The parameter to send
        fn send_fifo_command(in_command: FIFOCommand, in_task: ?*RTTS.TaskItem, in_param: ?u32) void {
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

            const cs = microzig.interrupt.enter_critical_section();
            defer cs.leave();

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
        pub var null_task_stack_pointer: [*]usize = undefined;

        // ------------------------------------------------------------------------
        // The null task just calls wait for interrupt in an infinite loop.
        // A user who want to "replace" the null task should just run the
        // replacement code as the lowest priority task.

        fn null_task_loop() callconv(.naked) noreturn {
            asm volatile (
                \\ null_loop:
                \\       wfe
                \\       b null_loop
            );
        }
    };
}
