//! This is the platform specific code for the RTTS scheduler for a single
//! core risc-v processor.
//!
//! System resources used:
//!   - Interrupts 30 and 31
//!   - systimer alarm2
//!   - from_cpu_intr0
//!
//!

const std = @import("std");
const microzig = @import("microzig");

const hal = microzig.hal;
const cpu = microzig.cpu;
const chip = microzig.chip;

const irq = hal.irq;
const multicore = hal.multicore;
const time = hal.time;
const systimer = hal.systimer;
const compatibility = hal.compatibility;

const peripherals = chip.peripherals;

const PPB = peripherals.PPB;
const SIO = peripherals.SIO;

const csr = cpu.csr;

const Alarm = systimer.Alarm;

const timg0 = peripherals.TIMG0;


pub fn configure(comptime RTTS: type, comptime config: RTTS.Configuration) type {
    return struct {
        const Platform = @This();

        pub const timer_interrupt = cpu.Interrupt.interrupt30;
        pub const reschedule_interrupt = cpu.Interrupt.interrupt31;

        pub const cores_available = 0x01;

        //==============================================================================
        // RTTS Platform Function
        //==============================================================================
        // These function are called from the common RTTS code and implement the
        // platform specific functionality.

        //------------------------------------------------------------------------------
        /// Get the ID of the current core.  We only have one so the id is always 0.
        ///
        pub fn core_id() u8 {
            return 0;
        }

        //------------------------------------------------------------------------------
        /// Get the name of the current core.  We only have one so it is always ""
        ///
        pub fn debug_core() []const u8 {
            return "";
        }

        //------------------------------------------------------------------------------
        /// Initialize the stack for a task as though it had been swapped out
        ///
        pub fn initialize_stack(in_stack: [*]usize, in_pc: *const fn () void) [*]usize {
            var sp = in_stack - 35;

            for (sp[0..35]) |*reg| {
                reg.* = 0xface_fade; // so we can spot bad values
            }

            sp[30] = @intFromPtr(in_stack);
            sp[31] = @intFromPtr(in_pc);
            sp[32] = if (config.run_unprivileged) 0x0000_0081 else 0x0000_1881;

            return sp;
        }

        //------------------------------------------------------------------------------
        /// Initialize the cores
        ///
        pub fn start_cores() noreturn {

            // Set up null task stack

            null_task_stack_pointer = @ptrCast(&null_task_stack[null_task_stack_len - 35]);

            null_task_stack_pointer[30] = @intFromPtr(&null_task_stack) + 4 * null_task_stack_len;
            null_task_stack_pointer[31] = @intFromPtr(&null_task_loop);
            null_task_stack_pointer[32] = if (config.run_unprivileged) 0x0000_0081 else 0x0000_1881;

            // Configure the reschedule interrupt

            cpu.interrupt.map(.from_cpu_intr0, reschedule_interrupt);
            cpu.interrupt.set_priority(reschedule_interrupt, .lowest);

            // Configure the timer

            const initial_timer_value: u26 = @intCast(1_000_000 * systimer.ticks_per_us() / config.resolution);


            Alarm.alarm2.set_interrupt_enabled(false);
            Alarm.alarm2.clear_interrupt();

            Alarm.alarm2.set_enabled(false);
            Alarm.alarm2.set_unit(.unit0);
            Alarm.alarm2.set_mode(.period);
            Alarm.alarm2.set_period(initial_timer_value);
            Alarm.alarm2.set_enabled(true);
        
            const period = microzig.chip.peripherals.SYSTIMER.TARGET2_CONF.read().TARGET2_PERIOD;

            std.log.debug("-- Timer period: {d}", .{period});

            var target:u64 = microzig.chip.peripherals.SYSTIMER.TARGET2_HI.raw;
            target <<= 32;
            target |= microzig.chip.peripherals.SYSTIMER.TARGET2_LO.raw;

            std.log.debug("-- Timer target: {d}", .{target}); 

        std.log.debug(" -- systimer target2 period: {d}", .{microzig.chip.peripherals.SYSTIMER.TARGET2_CONF.read().TARGET2_PERIOD});
        std.log.debug(" -- systimer target2 period mode: {d}", .{microzig.chip.peripherals.SYSTIMER.TARGET2_CONF.read().TARGET2_PERIOD_MODE});
        std.log.debug(" -- systimer target2 timer unit sel: {d}", .{microzig.chip.peripherals.SYSTIMER.TARGET2_CONF.read().TARGET2_TIMER_UNIT_SEL});

        std.log.debug(" -- systimer conf  target2 work en: {d}", .{microzig.chip.peripherals.SYSTIMER.CONF.read().TARGET2_WORK_EN});
        std.log.debug(" -- systimer conf  timer unit0 work en: {d}", .{microzig.chip.peripherals.SYSTIMER.CONF.read().TIMER_UNIT0_WORK_EN});
        std.log.debug(" -- systimer conf  timer unit0 core0 stall en: {d}", .{microzig.chip.peripherals.SYSTIMER.CONF.read().TIMER_UNIT0_CORE0_STALL_EN});

            cpu.interrupt.map(.systimer_target2, timer_interrupt);
            cpu.interrupt.set_priority(timer_interrupt, @enumFromInt(2));
            cpu.interrupt.enable(timer_interrupt);

        std.log.debug("-- systimer unit0 start: {d}", .{hal.systimer.Unit.unit0.read()});

            run_first_task();
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (this core)
        ///
        pub fn reschedule() void {
            peripherals.SYSTEM.CPU_INTR_FROM_CPU_0.write_raw(1);
        }

        //------------------------------------------------------------------------------
        /// Perform a reschedule (all cores)
        ///
        pub fn reschedule_all_cores() void {
            reschedule();
        }

        //------------------------------------------------------------------------------
        /// Perfom a reschedule_all_cores from an ISR.
        /// For the RP2xxx this is the same as the normal reschedule_all_cores.
        ///
        pub fn reschedule_all_cores_isr() void {
            reschedule();
        }

        //------------------------------------------------------------------------------
        /// Enable the timer interrupt
        pub fn enable_timer() void {
            // var new_time: u64 = SIO.MTIMEH.raw;
            // new_time <<= 32; 
            // new_time += SIO.MTIME.raw;

            // new_time += 1_000_000 / config.resolution;
            
            // SIO.MTIMECMPH.write_raw(@intCast(new_time >> 32));
            // SIO.MTIMECMP.write_raw(@truncate(new_time));            

            Alarm.alarm2.set_interrupt_enabled(true);
        }

        //------------------------------------------------------------------------------
        /// Disable the timer interrupt
        pub fn disable_timer() void {
            Alarm.alarm2.set_interrupt_enabled(false);
        }

        //==============================================================================
        // Local thread mode functions
        //==============================================================================

        //------------------------------------------------------------------------------
        /// Run the first task on this core
        fn run_first_task() noreturn {
            std.log.debug("{s}Entered run_first_task", .{debug_core()});

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
                        // the initialized stack then clear the stack.

                        target_pc = a_task.stack_pointer[31];
                        target_sp = a_task.stack_pointer + 35;

                        std.log.debug("Starting task {s} pc: 0x{x:08} sp: 0x{x:08}", .{ @tagName(a_task.tag), target_pc, @intFromPtr(target_sp) });
                        break;
                    }
                }
            }

            if (RTTS.first_timer != null) {
                Alarm.alarm2.clear_interrupt();
                Alarm.alarm2.set_interrupt_enabled(true);
            }

            cpu.interrupt.enable(reschedule_interrupt);
            cpu.interrupt.enable_interrupts();

            if (config.run_unprivileged) {
                asm volatile (
                    \\    mv    sp, %[sp]        // Set the process stack pointer
                    \\    li    t0, 0x00000081   // Set the MSTATUS register
                    \\    csrs  MSTATUS, t0
                    \\    csrs  MEPC, %[pc]      // Set the MEPC register to the target PC
                    \\    mret
                    :
                    : [sp] "r" (target_sp),
                      [pc] "r" (target_pc),
                    : "t0"
                );
            } else {
                asm volatile (
                    \\    mv    sp, %[sp]        // Set the process stack pointer
                    \\    li    t0, 0x00001881   // Set the MSTATUS register
                    \\    csrs  MSTATUS, t0
                    \\    csrs  MEPC, %[pc]      // Set the MEPC register to the target PC
                    \\    mret
                    :
                    : [sp] "r" (target_sp),
                      [pc] "r" (target_pc),
                    : "t0"
                );
            }

            unreachable;
        }

        //==============================================================================
        // Interrupt service routines
        //==============================================================================
        // These ISR's  need to be registered.
        //  1. machine_software_ISR   - (Software)
        //  2. machine_timer_ISR      - (Timer)

        //------------------------------------------------------------------------------
        /// Machine_software interrupt service routine
        ///
        /// This isr fires when machine software interrupt is triggered.
        /// We use this to handle ecall instructions.
        ///
        //     // Upon Entry the TrapFrame is:
        //
        //      +------------+
        //      |  ra        | <--- TrapFrame pointer
        //      |  t0        |    +  4 ( 1)
        //      |  t1        |    +  8 ( 2)
        //      |  t2        |    + 12 ( 3)
        //      |  t3        |    + 16 ( 4)
        //      |  t4        |    + 20 ( 5)
        //      |  t5        |    + 24 ( 6)
        //      |  t6        |    + 28 ( 7)
        //      |  a0        |    + 32 ( 8)
        //      |  a1        |    + 36 ( 9)
        //      |  a2        |    + 40 (10)
        //      |  a3        |    + 44 (11)
        //      |  a4        |    + 48 (12)
        //      |  a5        |    + 52 (13)
        //      |  a6        |    + 56 (14)
        //      |  a7        |    + 60 (15)
        //      |  s0        |    + 64 (16)
        //      |  s1        |    + 68 (17)
        //      |  s2        |    + 72 (18)
        //      |  s3        |    + 76 (19)
        //      |  s4        |    + 80 (20)
        //      |  s5        |    + 84 (21)
        //      |  s6        |    + 88 (22)
        //      |  s7        |    + 92 (23)
        //      |  s8        |    + 96 (24)
        //      |  s9        |    +100 (25)
        //      |  s10       |    +104 (26)
        //      |  s11       |    +108 (27)
        //      |  gp        |    +112 (28)
        //      |  tp        |    +116 (29)
        //      |  sp        |    +120 (30)
        //      |  pc        |    +124 (31)
        //      |  mstatus   |    +128 (32)
        //      |  mcause    |    +132 (33)
        //      |  mtval     |    +136 (34)
        //      +------------+

        fn _machine_software_ISR(_: *cpu.TrapFrame) callconv(.naked) void {
            asm volatile (
                \\                   // the frame pointer is already in a0
                \\    mv    s0, ra   // save our return address
                \\    call  %[fnt]   // call do_machine_software
                \\    mv    sp, a0   // use the new stack pointer returned by do_machine_software
                \\    jr    s0       // return
                :
                : [fnt] "i" (do_machine_software)
            );
        }

        // We have to cheat a bit here.  This function above is callconv (.naked) because we need
        // to be precise in our register usage, but the ISR is callconv(.c), so we need to cast it
        // to a callconv(.c) InterruptHandler function pointer.

        pub const machine_software_ISR: cpu.InterruptHandler = @ptrCast(&_machine_software_ISR);

        /// This function is called from the machine_software_ISR
        ///
        /// It does the actual dispatching of the ecall instruction
        ///
        export fn do_machine_software(in_frame: *cpu.TrapFrame) callconv(.c) [*]usize {
            // const ptr: [*]usize = @ptrCast(in_frame);
            // std.log.debug("frame at: 0x{x:08}", .{@intFromPtr(in_frame)});
            // for (0..35) |i| {
            //     std.log.debug("In:  {d:2}: 0x{x:08}", .{ i, ptr[i] }); 
            // }

            // Clear the softirq for this core
            peripherals.SYSTEM.CPU_INTR_FROM_CPU_0.write_raw(0);

            const result = RTTS.find_next_task_sp(@ptrCast(in_frame));

            // std.log.debug("next sp at: 0x{x:08}", .{@intFromPtr(result)});
            // for (0..35) |i| {
            //     std.log.debug("Out: {d:2}: 0x{x:08}", .{ i, result[i] }); 
            // }

            return result;
        }

        //------------------------------------------------------------------------------
        /// Machine_timer interrupt service routine
        ///
        /// This isr fires when machine timer interrupt is triggered.
        ///

        pub fn machine_timer_ISR(in_frame: *cpu.TrapFrame) callconv(.c) void {
            _ = @TypeOf(in_frame);
                        
            Alarm.alarm2.clear_interrupt();
            
            RTTS.Timer.tick();
        }

        //==============================================================================
        // Null Task
        //==============================================================================

        const null_task_stack_len = 48;

        var null_task_stack: [null_task_stack_len]usize = undefined;
        pub var null_task_stack_pointer: [*]usize = undefined;

        // ------------------------------------------------------------------------
        // The null task just calls wait for interrupt in an infinite loop.
        // A user who want to "replace" the null task should just run the
        // replacement code as the lowest priority task.

        fn null_task_loop() callconv(.naked) noreturn {
            asm volatile (
                \\ null_loop:
                \\       slt zero, zero, x0
                \\       j null_loop
            );
        }
    };
}
