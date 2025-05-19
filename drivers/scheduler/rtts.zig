// zig fmt: off

const std      = @import( "std" );
const microzig = @import( "microzig" );

const hal           = microzig.hal;
const time          = hal.time;

//============================================================================
// Configuration
//============================================================================

/// These are the priority modes supported by RTTS.
pub const PriorityMode = enum
{
  /// Task priority is fixed at compile time.
  fixed,
  /// Task priority can be changed at runtime.
  changeable,
  /// Task priority can be changed at runtime and the scheduler will
  /// automatically adjust priorities of a subset of tasks to share the
  /// available processing time.
  dynamic,
};

/// A structure containing the configuration for the RTTS Scheduler.
pub const Config = struct
{
  /// A bit mask of cores to use.  If 0xFF, all available cores are used.
  use_cores         : u8 = 0xFF,

  /// The number of event flags to use.
  event_flags_count : u8 = 8,

  /// The priority mode.
  priority_mode     : PriorityMode = .fixed,
};

/// A structure containing the configuration for a task.
pub const Task = struct
{
  name          : []const u8,
  loop          : *const fn( type ) void,
  stack_size    : usize,
  event_mask    : usize,

  /// A function to create a task.
  ///
  /// Parameters:
  ///   in_name - The name of the task
  ///   in_loop - The main loop function for the task
  ///   in_stack_size - The stack size for the task
  ///   in_event_mask - The event mask for the task
  /// Returns:
  ///   A Task

  pub fn init( in_name       : []const u8,
               in_loop       : *const fn( type ) void,
               in_stack_size : usize,
               in_event_mask : usize ) Task
  {
    return .{
      .name          = in_name,
      .loop          = in_loop,
      .stack_size    = in_stack_size,
      .event_mask    = in_event_mask,
    };
  }
};

/// Configure the RTTS Scheduler an return a namespace
/// containing functions to control in_tasks.
///
/// Parameters:
///   config - The configuration for the RTTS Scheduler
///   tasks - An array of tasks to run
///
/// Returns:
///   The scheduler namespace/
///
pub fn scheduler( comptime config : Config,
                  comptime tasks : []const Task ) type
{
  const result = struct
  {
    const Self = @This();

    pub const Platform =
      if (std.mem.eql( u8, microzig.config.chip_name, "RP2040"   ))
        @import( "rp2xxxx_arm/rtts.zig" ).Configure( Self )
      else if (std.mem.eql( u8, microzig.config.chip_name, "RP2350" ))
        if (std.mem.eql( u8, microzig.config.cpu_name, "hazard3" ))
          @import( "rp2350_riscv/rtts.zig" ).Configure( Self )
        else
          @import( "rp2xxxx_arm/rtts.zig" ).Configure( Self )
      // else if (std.mem.eql( u8, microzig.config.chip_name, "ESP32-C3" ))
      //   @import( "esp32_c3/rtts.zig" ).Configure( Self )
      // else if (std.mem.eql( u8, microzig.config.chip_name, "ATmega328P" ))
      //   @import( "avr_ATmega328/rtts.zig" ).Configure( Self )
      else
        @compileError( "Unsupported chip for RTTS: " ++ microzig.config.chip_name );

    //============================================================================
    // Type Definitions
    //============================================================================

    pub const TaskState = enum
    {
      running,
      runnable,
      waiting,
    };

    const Task = opaque{};

    const EventFlags = std.meta.Int( .unsigned, config.event_flags_count);

    /// A task item
    pub const TaskItem = switch (config.priority_mode)
    {
      .fixed => struct
      {
        name          : []const u8,
        loop          : *const fn() noreturn,
        stack_pointer : [*]usize,
        event_flags   : EventFlags,
        event_mask    : EventFlags,
        state         : TaskState,
      },
      .changeable => struct
      {
        next          : ?*TaskItem,
        name          : []const u8,
        loop          : *const fn() noreturn,
        stack_pointer : [*]usize,
        event_flags   : EventFlags,
        event_mask    : EventFlags,
        state         : TaskState,
      },
      .dynamic => struct
      {
        next          : ?*TaskItem,
        name          : []const u8,
        loop          : *const fn() noreturn,
        stack_pointer : [*]usize,
        event_flags   : EventFlags,
        event_mask    : EventFlags,
        state         : TaskState,
        quanta        : u16,
        active_time   : time.Time,
      },
    };

    //============================================================================
    // Global Context
    //============================================================================

    /// The core mask. Bits set to 1 indicate cores to use.
    pub const core_mask = config.use_cores & Platform.cores_available;

    /// The number of cores to use
    pub const core_count = @popCount( core_mask );

    /// The list of tasks
    pub var task_list : [tasks.len]TaskItem = undefined;

    /// Pointer to just beyond last task on list.
    pub export var task_list_end : *TaskItem = undefined;

    /// The current task on each core
    pub var current_task : [core_count]?*TaskItem = @splat( null );

    /// Test true if the core needs to scan the task list from the top.
    pub var sig_event : [core_count]bool = @splat( false );

    /// The mutex used to synchronize access to the task list.
    pub var schedule_mutex : microzig.interrupt.Mutex = .{};

    //============================================================================
    // RTTS startup
    //============================================================================

    // ---------------------------------------------------------------------------
    /// This function is used at comptime to return an initialized TaskItem.
    ///
    /// Create a new task
    /// Parameters:
    ///   in_name - The name of the task
    ///   in_loop - The main loop function for the task
    ///   in_stack_size - The size of the stack for the task (in bytes)
    ///   in_event_mask - The event mask for the task
    /// Returns:
    ///   A TaskItem that can be passed to `run`.

    pub fn taskItem( in_name : []const u8,
                     in_loop : *const fn( type ) void,
                     in_stack : []usize,
                     in_event_mask : EventFlags ) TaskItem
    {
      // Point to just beyond end of stack

      var sp : [*]usize = @ptrCast( in_stack.ptr );
      sp += in_stack.len;

      // Wrap the in_loop function in an infinite loop

      const loop_fn = struct { fn f() noreturn { while (true) in_loop( Self ); } };

      return .{
        .name          = in_name,
        .loop          = loop_fn.f,
        .event_mask    = in_event_mask,
        .event_flags   = 0,
        .state         = if (in_event_mask != 0) .waiting else .runnable,
        .stack_pointer = sp,
      };
    }

    // ---------------------------------------------------------------------------
    /// Configure and run the RTTS scheduler.  This function never returns.
    ///
    /// This scheduler runs tasks in strict priority order.  The processor
    /// cores are assigned to the highest priority tasks until they yield or
    /// wait on an event.
    ///
    /// Parameters:
    ///   in_tasks - An array of task item in priority order
    ///              (highest priority first)
    pub fn run( in_tasks : []TaskItem ) noreturn
    {
      task_list = in_tasks;
      task_list_end = @ptrCast( in_tasks.ptr + in_tasks.len );

      // Run any init functions in the tasks

      for (task_list) |*an_item|
      {
        an_item.stack_pointer = Platform.initializeStack( an_item.stack_pointer,
                                                          an_item.loop );


        for (0..16  ) |i|
        {
          std.log.debug( "  r{}: 0x{X:08}", .{ i, an_item.stack_pointer[i] } );
        }

        std.log.debug( "Initialized task \"{s}\":", .{ an_item.name } );
        std.log.debug( "  loop: {any}", .{ an_item.loop } );
        std.log.debug( "  stack: {any}", .{ an_item.stack_pointer } );
        // std.log.debug( "  event_flags: {x}", .{ an_item.event_flags } );
        // std.log.debug( "  event_mask: {x}", .{ an_item.event_mask } );
        // std.log.debug( "  state: {}", .{ an_item.state } );
      }

      Platform.startCores();
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
    pub fn currentTask() *TaskItem
    {
      return current_task[Platform.coreID()] orelse unreachable;
    }

    //----------------------------------------------------------------------------
    /// Return a pointer to the task with the specified name.
    ///
    /// Parameters:
    ///   in_name - The name of the task
    /// Returns:
    ///   A pointer to the task with the specified name
    pub fn taskNamed( in_name : []const u8 ) *TaskItem
    {
      for (task_list) |*an_item|
      {
        if (std.mem.eql( u8, an_item.name, in_name ))
        {
          return an_item;
        }
      }

      @panic( "Invalid task name" );
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
    pub fn waitForEvent( in_event_mask: EventFlags, in_clear_flags: bool ) void
    {
      const the_task = currentTask();

      the_task.event_mask = in_event_mask;
      if (in_clear_flags) the_task.event_flags = 0;

      if ((the_task.event_flags & the_task.event_mask) == 0)
      {
        Platform.wait(); // Wait for an event
      }
    }

    //----------------------------------------------------------------------------
    /// Yield to a lower priority task.  The current task will not be run again
    /// until after the next significant event.
    pub fn yield() void
    {
      Platform.yield();
    }

    //----------------------------------------------------------------------------
    /// Declare a significant event.
    /// The scheduler will re-scan the task list and the highest priority
    /// runnable tasks will be run.  A call to this function on one core can
    /// change the tasks assigned to any core.
    pub fn significantEvent() void
    {
      Platform.significantEvent();
    }

    //----------------------------------------------------------------------------
    /// Signal an event to the indicated task.
    ///
    /// This function will set the specified event flag for the task, and, if the
    /// task was waiting on that event flag, it will be marked as runnable and a
    /// significant event will be declared.
    ///
    /// Parameters:
    ///   in_event - The event to signal
    ///   in_task  - The the task to signal
    pub fn signalEvent( in_event : u8, in_task : *TaskItem ) void
    {
      std.debug.assert( in_event < config.event_flags_count );

      var   need_significant_event = false;

      std.log.debug( "{s}  Signaling event {d} to task {s}", .{ Platform.debugCore(), in_event, in_task.name } );

      {
        schedule_mutex.lock();
        defer schedule_mutex.unlock();

        const setFlag = @as( EventFlags, 1 ) << @intCast( in_event - 1 );

        in_task.event_flags |= setFlag;

        if (    (in_task.event_mask & setFlag) != 0
            and in_task.state == .waiting)
        {
          in_task.state = .runnable;
          need_significant_event = true;
        }
      }

      if (need_significant_event)
      {
        std.log.debug( "{s}  Signaling significant event", .{ Platform.debugCore() } );

        Platform.significantEvent();
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
    pub fn _priorityCompare( in_task_a : *TaskItem, in_task_b : *TaskItem ) isize
    {
      // Note: This subtraction appears backwards, but it is correct;
      // the task with the highest priority is the one with the lowest address.
      return  @intCast( @intFromPtr( in_task_b ) - @intFromPtr( in_task_a ) );
    }

    //----------------------------------------------------------------------------
    /// Find the next task to run on current core.
    /// Returns:
    ///   The stack pointer for the next task to run
    pub fn _findNextTaskSP( in_sp : usize ) usize
    {
      std.log.debug( "{s}  Finding next task", .{ Platform.debugCore() } );

      var a_task : *TaskItem = undefined;

      schedule_mutex.lock();
      defer schedule_mutex.unlock();

      // If current task is running, set it to runnable

      if (current_task[Platform.coreID()]) |task|
      {
        if (task.state == .running) task.state = .runnable;
        task.stack_pointer = @ptrFromInt( in_sp );
      }

      // Figure out where to start our scan

      if (sig_event[Platform.coreID()])
      {
        // With significant event, start at the top of the task list.
        sig_event[Platform.coreID()] = false;
        a_task = &task_list[0];
      }
      else if (_findLowestPriorityRunning()) |task|
      {
        // With no significant event, start after the lowest priority task that is running.
        a_task = @ptrFromInt( @intFromPtr( task ) + @sizeOf( TaskItem ) );
      }
      else
      {
        std.log.debug( "{s}  Null already running  sp: 0x{X:08}", .{ Platform.debugCore(), Platform.null_task_stack_pointer } );
        current_task[Platform.coreID()] = null;
        return Platform.null_task_stack_pointer;
      }

      // Look for a runnable task

      while (_priorityCompare( a_task, task_list_end ) > 0)
      {
        if (a_task.state == .runnable)
        {
          std.log.debug( "{s}  Switch to task \"{s}\"  sp: 0x{X:08}", .{ Platform.debugCore(), a_task.name, @intFromPtr( a_task.stack_pointer ) } );

          a_task.state = .running;
          current_task[Platform.coreID()] = a_task;
          return @intFromPtr( a_task.stack_pointer );
        }

        a_task = @ptrFromInt( @intFromPtr( a_task ) + @sizeOf( TaskItem ) );
      }

      std.log.debug( "{s}  Switch to null task  sp: 0x{X:08}", .{ Platform.debugCore(), Platform.null_task_stack_pointer } );

      current_task[Platform.coreID()] = null;
      return Platform.null_task_stack_pointer;
    }

    //----------------------------------------------------------------------------
    /// Find the lowest priority task that is assigned to a core
    /// Note: This function should be called from within a critical section.
    pub fn _findLowestPriorityRunning() ?*TaskItem
    {
      var retval : *TaskItem = &task_list[0];

      for (0..core_count) |i|
      {
        if (current_task[i]) |a_task|
        {
          if (_priorityCompare( a_task, retval ) < 0)
          {
            retval = a_task;
          }
        }
        else
        {
          // Found null task -- it's always the lowest priority
          return null;
        }
      }

      return retval;
    }
  };

  for (tasks, 0..) |a_task, i|
  {
    const loop_fn = struct { fn f() noreturn { while (true) a_task.loop( result ); } };

    const stack = struct { var data: [a_task.stack_size]u8 = undefined; };

    result.task_list[i] = .{
      .name          = a_task.name,
      .loop          = loop_fn.f,
      .stack_pointer = @ptrFromInt( @intFromPtr( &stack.data ) + stack.data.len ),
      .event_flags   = 0,
      .event_mask    = @intCast( a_task.event_mask ),
      .state         = if (a_task.event_mask != 0) .waiting else .runnable,
    };
  }

  return result;
}