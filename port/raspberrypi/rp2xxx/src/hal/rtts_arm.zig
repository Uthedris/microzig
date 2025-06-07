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

const FIFOCommand = enum(u8) {
    dispatch,
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

            // Set the priority of the PendSV exception to the lowest possible value (which
            // is numerically the highest value)

            _ = cpu.interrupt.exception.set_handler(.PendSV, .{ .naked = pendsv_ISR });
            _ = cpu.interrupt.exception.set_handler(.SysTick, .{ .c = sysTick_ISR });

            // On the RP2040 the available priority values are 0x00, 0x40, 0x80, and 0xC0.
            // The lowest priority is 0xC0 and the highest priority is 0x00.
            //
            // On the RP2350 the available priority values are 0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, and 0xE0.
            // The lowest priority is 0xE0 and the highest priority is 0x00.

            cpu.interrupt.exception.set_priority(.PendSV, .lowest);

            // Configure the systick timer

            _ = config.resolution;

            // var sys_tick_count = systick.CALIB.read().TENMS;
            // sys_tick_count = @intCast(@as(u32, 100) * sys_tick_count / config.resolution);

            // ### TODO ### automatically calculate the systick timer count based on clock frequency.

            systick.LOAD.write(.{
                .RELOAD = 1_530_000, // sys_tick_count,
            });

            systick.VAL.write(.{
                .CURRENT = 0,
            });

            systick.CTRL.write(.{
                .ENABLE = 1,
                .TICKINT = 0,
                .COUNTFLAG = 0,
                .CLKSOURCE = 1,
            });

            std.log.debug("-- SysTick CTRL: 0x{x:08}", .{systick.CTRL.raw});
            std.log.debug("-- SysTick CALIB: 0x{x:08}", .{systick.CALIB.raw});
            std.log.debug("-- SysTick VAL: {d}", .{systick.VAL.raw});
            std.log.debug("-- SysTick LOAD: {d}", .{systick.LOAD.raw});

            // Setup for multiple cores if configured.

            if (RTTS.core_count > 1) {
                if (irq.can_set_handler()) {
                    if (compatibility.chip == .RP2040) {
                        _ = irq.set_handler(.SIO_IRQ_PROC0, .{ .c = fifo_ISR });
                        _ = irq.set_handler(.SIO_IRQ_PROC1, .{ .c = fifo_ISR });
                    } else {
                        _ = irq.set_handler(.SIO_IRQ_BELL, .{ .c = doorbell_ISR });
                    }
                    // Note: We don't enable these interrupts until after the other core is
                    // launched, so we don't mess with the launch sequence.

                }

                multicore.launch_core1(run_first_task);
            }

            if (RTTS.first_timer != null) {
                enable_timer();
            }

            // Run the first task on this core

            run_first_task();
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (this core)
        ///
        pub fn reschedule() void {
            scb.ICSR.modify(.{ .PENDSVSET = 1 });
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (all cores)
        ///
        pub fn reschedule_all_cores() void {
            if (RTTS.core_count > 1) {
                if (compatibility.chip == .RP2040) {
                    send_fifo_command(.dispatch, null, null);
                } else {
                    multicore.doorbell.set(0);
                }

                microzig.cpu.sev();
            }

            scb.ICSR.modify(.{ .PENDSVSET = 1 });
        }

        //------------------------------------------------------------------------------
        /// Perfom a reschedule_all_cores from an ISR.
        /// For the RP2xxx this is the same as the normal reschedule_all_cores.
        ///
        pub fn reschedule_all_cores_isr() void {
            reschedule_all_cores();
        }

        //----------------------------------------------------------------------------
        /// Switch to the null task.
        pub fn switch_to_null_task() [*]usize {

            // Set up null task stack

            const null_task_stack_pointer: [*]usize = @ptrCast(&null_task_stack[core_id()][null_task_stack_len - 16]);

            null_task_stack_pointer[14] = @intFromPtr(&null_task_loop);
            null_task_stack_pointer[15] = 0x0100_0000;

            return null_task_stack_pointer;
        }

        //------------------------------------------------------------------------------
        /// Enable the timer interrupt
        pub fn enable_timer() void {
            systick.CTRL.modify(.{ .TICKINT = 1 });
        }

        //------------------------------------------------------------------------------
        /// Disable the timer interrupt
        pub fn disable_timer() void {
            systick.CTRL.modify(.{ .TICKINT = 0 });
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

            var target_sp: [*]usize = switch_to_null_task();
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
                        RTTS.next_task = a_task.next;

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
        // There are some ISR's that need to be registered.
        //  - pendsv_ISR  - (PendSV) The pendsv interrupt service routine
        //  - fifo_ISR    - (The inter-core communication interrupt service routine
        //
        //  For time functions?
        //  - sysTick_ISR - (SysTick) The sysTick interrupt service routine

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
        /// FIFO interrupt service routine (RP2040 only)
        ///
        pub fn fifo_ISR() callconv(.c) void {
            var theParam: u32 = 0;
            var theTask: ?*RTTS.TaskItem = null;

            SIO.FIFO_ST.raw = 0;

            while (multicore.fifo.read()) |first_word| {
                // The high order eight bits of the first word of
                // a transfer are always 0x80.
                if ((first_word & 0xFF000000) != 0x80000000) {
                    continue;
                }

                // And the next eight bits are the size of the transfer.
                const count = (first_word >> 16) & 0xFF;

                //This will always be either 1, 2, or 3.
                if (count < 1 or count > 3) {
                    continue;
                }

                if (count >= 2) {
                    theTask = @ptrFromInt(multicore.fifo.read_blocking());
                }

                if (count == 3) {
                    theParam = multicore.fifo.read_blocking();
                }

                const command: FIFOCommand = @enumFromInt(first_word & 0xFF);

                switch (command) {
                    .dispatch => {
                        scb.ICSR.modify(.{ .PENDSVSET = 1 });
                        asm volatile ("isb");
                    },
                    else => {
                        std.log.err("Unknown command: 0x{x:08}", .{@intFromEnum(command)});
                    },
                }
            }
        }

        //------------------------------------------------------------------------------
        /// Doorbell interrupt service routine (RP2350 only)
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

        var null_task_stack: [RTTS.core_count][null_task_stack_len]usize = undefined;

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
