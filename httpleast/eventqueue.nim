import std/strutils
import std/macros
import std/os
import std/monotimes
import std/nativesockets
import std/tables
import std/times
import std/deques

import cps

const
  leastDebug {.booldefine, used.} = false   ## emit extra debugging output
  leastPoolSize {.intdefine, used.} = 64    ## expected pending continuations
  leastThreads* {.intdefine, used.} = 0     ## 0 means "guess"
  threaded* = compileOption"threads"
  leastRecycle {.booldefine, used.} = false ## recycle continuations
  leastQueue* {.strdefine, used.} = "none"

when leastQueue == "nim-sys" or leastQueue == "ioqueue":
  import sys/ioqueue

  export Event
else:
  import std/selectors

  export Event

type
  Clock = MonoTime
  Fd = distinct int

  # base continuation type
  Cont* = ref object of Continuation
    when leastDebug:
      clock: Clock                  ## time of latest poll loop
      delay: Duration               ## polling overhead
      fd: Fd                        ## our last file-descriptor

when leastDebug:
  when threaded:
    import std/locks
    var dL: Lock
    initLock dL
    template debug(args: varargs[string, `$`]): untyped =
      withLock dL:
        stderr.writeLine join(args, " ") & " on " & $getThreadId()
  else:
    template debug(args: varargs[string, `$`]): untyped =
      stderr.writeLine join(args, " ")
else:
  template debug(args: varargs[string, `$`]): untyped = discard

when threaded:
  import std/osproc

  when leastQueue == "loony":
    import pkg/loony
    type ContQueue = LoonyQueue[Cont]

    proc needsInit(q: var ContQueue): bool =
      q.isNil

    proc initQueue(q: var ContQueue) =
      q = ContQueue initLoonyQueue[Continuation]()

    proc consumer(q: ContQueue) {.thread.}

  elif leastQueue == "taskpools":
    import pkg/taskpools
    type ContQueue = Taskpool

    proc needsInit(q: var ContQueue): bool =
      q.isNil

    proc initQueue(q: var ContQueue) =
      q = Taskpool.new(numThreads = leastThreads)

  elif leastQueue == "none":
    type ContQueue = bool

    proc needsInit(q: var ContQueue): bool =
      q == false

    proc initQueue(q: var ContQueue) =
      q = true

  elif leastQueue == "nim-sys" or leastQueue == "ioqueue":
    import std/options
    import sys/handles

    type ContQueue = bool

    proc needsInit(q: var ContQueue): bool =
      q == false

    proc initQueue(q: var ContQueue) =
      q = true

  type QueueThread = Thread[ContQueue]

type
  Readiness = enum
    Unready = "the default state, pre-initialized"
    Stopped = "we are outside an event loop but available for queuing events"
    Running = "we're in a loop polling for events and running continuations"
    Stopping = "we're tearing down the dispatcher and it will shortly stop"

  EventQueue = object
    state: Readiness              ## dispatcher readiness
    when leastQueue != "nim-sys" and leastQueue != "ioqueue":
      selector: Selector[Cont]      ## watches selectable stuff
      waiters: int                  ## a count of selector listeners
      serverFd: Fd                  ## server's persistent file-descriptor
    else:
      runnable: seq[Continuation] ## continuations from sys/ioqueue ready to run
    yields: Deque[Cont]           ## continuations ready to run
    when threaded:
      queue: ContQueue
      threads: seq[QueueThread]

const
  invalidFd = Fd(-1)

var eq {.threadvar.}: EventQueue

template now(): Clock {.used.} = getMonoTime()

proc `$`(fd: Fd): string {.used.} = "[" & system.`$`(fd.int) & "]"
proc `$`(c: Cont): string {.used.} = "&" & $cast[uint](c)

proc `<`(a, b: Fd): bool {.borrow, used.}
proc `==`(a, b: Fd): bool {.borrow, used.}

proc len*(eq: EventQueue): int =
  ## The number of pending continuations.
  when leastQueue != "nim-sys" and leastQueue != "ioqueue":
    eq.waiters + eq.yields.len
  else:
    # ioqueue does not expose "number of waiters", so emulate it by counting a
    # running queue as 1 waiter.
    ord(ioqueue.running()) + eq.yields.len

when leastRecycle:
  when threaded and leastQueue == "loony":
    # creating a queue for continuation objects for reuse
    var recycled = initLoonyQueue[Continuation]()
    proc alloc*(U: typedesc[Cont]; E: typedesc[Cont]): E =
      result = E: recycled.pop()
      if result.isNil:
        result = new E
  else:
    # creating a stack of continuation objects for reuse
    var recycled {.threadvar.}: seq[Continuation]
    proc alloc*(U: typedesc[Cont]; E: typedesc[Cont]): E =
      if recycled.len == 0:
        result = new E
      else:
        result = E: pop recycled

proc init() {.inline.} =
  ## initialize the event queue to prepare it for requests
  if eq.state == Unready:
    when leastQueue != "nim-sys" and leastQueue != "ioqueue":
      eq.serverFd = invalidFd
      eq.selector = newSelector[Cont]()
      eq.waiters = 0

    when threaded:
      if eq.queue.needsInit:
        initQueue eq.queue

        when leastQueue == "loony":
          # create consumer threads to service the queue
          let cores =
            if leastThreads == 0:
              countProcessors()
            else:
              leastThreads
          newSeq(eq.threads, cores)
          for thread in eq.threads.mitems:
            createThread(thread, consumer, eq.queue)
        elif leastQueue == "taskpools":
          discard
        elif leastQueue == "none":
          discard
        elif leastQueue == "nim-sys":
          discard
        elif leastQueue == "ioqueue":
          discard

    eq.state = Stopped

proc stop*() =
  ## Tell the dispatcher to stop, discarding all pending continuations.
  when leastQueue != "nim-sys" and leastQueue != "ioqueue":
    if eq.state == Running:
      eq.state = Stopping

      # discard the current selector to dismiss any pending events
      close eq.selector

      when leastQueue == "taskpools":
        if not eq.queue.needsInit:
          shutdown eq.queue
          eq.queue = nil
      elif leastQueue == "none":
        if not eq.queue.needsInit:
          eq.queue = false

      # re-initialize the queue
      eq.state = Unready
      init()
  else:
    raise newException(Defect, "nim-sys does not support stopping the queue")

proc trampoline*(c: sink Cont) {.inline.} =
  ## Run the supplied continuation until it is complete.
  {.gcsafe.}:
    when leastRecycle:
      # recycling the continuation for reuse
      var c: Cont = Cont cps.trampoline(c)
      if not c.dismissed:
        when threaded and leastQueue == "loony":
          recycled.push c
        else:
          recycled.add c
    else:
      discard cps.trampoline(c)

proc manic(timeout = 0): int {.inline.} =
  if eq.state != Running: return 0

  when leastQueue != "nim-sys" and leastQueue != "ioqueue":
    if eq.waiters > 0:
      when leastDebug:
        let clock = now()

      # ready holds the ready file descriptors and their events.
      let ready = select(eq.selector, timeout)
      for event in ready.items:
        # see if this is the server's listening socket
        let isServer = eq.serverFd == Fd(event.fd)

        # retrieve the continuation from the selector
        var cont = getData(eq.selector, event.fd)

        if not isServer:
          # stop listening on this fd
          unregister(eq.selector, event.fd)
          dec eq.waiters
          when leastDebug:
            cont.clock = clock
            cont.delay = now() - clock
            cont.fd = event.fd.Fd
            debug "💈delay", cont.delay

        # add to the deque of ready-to-run continuations
        eq.yields.addLast cont
  else:
    if ioqueue.running():
      eq.runnable.setLen(0)

      poll(eq.runnable):
        if timeout < 0:
          none Duration
        else:
          some initDuration(milliseconds = timeout)

  # run any ready continuations
  while eq.yields.len > 0:
    inc result
    trampoline:
      popFirst eq.yields

  when leastQueue == "nim-sys" or leastQueue == "ioqueue":
    while eq.runnable.len > 0:
      let cont = pop eq.runnable
      inc result
      when leastQueue == "ioqueue":
        # When using ioqueue, all continuations are of type `Cont`
        trampoline Cont(cont)
      else:
        discard trampoline cont

proc run*(interval: Duration = DurationZero) =
  ## The dispatcher runs with a maximal polling interval; an `interval` of
  ## `DurationZero` causes the dispatcher to return when the queue is empty.

  # make sure the eventqueue is ready to run
  init()

  # the dispatcher is now running
  eq.state = Running
  while eq.state == Running:
    discard manic -1

  when threaded:
    when leastQueue == "loony":
      for thread in eq.threads.mitems:
        joinThread thread
    elif leastQueue == "taskpools":
      if not eq.queue.needsInit:
        shutdown eq.queue
        eq.queue = nil
    elif leastQueue == "none":
      if not eq.queue.needsInit:
        eq.queue = false
    elif leastQueue == "nim-sys":
      if not eq.queue.needsInit:
        eq.queue = false

proc spawn*(c: sink Cont) {.inline.} =
  ## Queue the supplied continuation `c`; control remains in the calling
  ## procedure.
  block done:
    when threaded:
      # spawn to a thread if possible
      if not eq.queue.needsInit:
        when leastQueue == "loony":
          eq.queue.push c
          break done
        elif leastQueue == "taskpools":
          eq.queue.spawn trampoline(c)
          break done
        elif leastQueue == "none":
          addLast(eq.yields, c)
          break done
        elif leastQueue == "nim-sys":
          addLast(eq.yields, c)
          break done

    # else, spawn to the local eventqueue
    addLast(eq.yields, c)

proc iowait*(c: sink Cont; file: int | SocketHandle;
             events: set[Event]): Cont {.cpsMagic.} =
  ## Continue upon any of `events` on the given file-descriptor or
  ## SocketHandle.
  when leastQueue == "nim-sys":
    # While supported by ioqueue, httpleast should not have to use this function at all
    raise newException(Defect, "iowait() shouldn't be used")
  elif leastQueue == "ioqueue":
    if events.len > 1:
      raise newException(ValueError, "iowait() only supports one event")
    elif events.len > 0:
      let event = block:
        var r: Event

        for i in events:
          r = i
          break

        r

      # Wait returns nil to suspend continuation
      discard wait(c, handles.FD(file), event)
      debug "📂file", $Fd(file)
  else:
    if events.len > 0:
      if eq.serverFd.int != file.int:
        registerHandle(eq.selector, file, events = events, data = c)
        inc eq.waiters
        debug "📂file", $Fd(file)

proc persist*(c: sink Cont; file: int | SocketHandle;
              events: set[Event]): Cont {.cpsMagic.} =
  ## Let the event queue know you want long-running registrations.
  when leastQueue == "nim-sys" or leastQueue == "ioqueue":
    # ioqueue does not support this feature
    raise newException(Defect, "persist() is not supported")
  else:
    assert eq.serverFd == invalidFd, "call persist only once"
    result = iowait(c, file, events)
    eq.serverFd = Fd(file)

proc delay*(c: sink Cont; ms: Natural): Cont {.cpsMagic.} =
  ## Do nothing for `ms` milliseconds before continuing.
  when leastQueue == "nim-sys" or leastQueue == "ioqueue":
    # ioqueue does not support this feature yet
    raise newException(Defect, "delay() is not supported")
  else:
    if ms < 1:
      result = c
    else:
      registerTimer(eq.selector, timeout = ms,
                    oneshot = true, data = c)
      inc eq.waiters
      debug "💤sleep", $ms

when threaded and leastQueue == "loony":
  proc consumer(q: ContQueue) {.thread.} =
    # setup our local eventqueue
    eq.queue = q
    init()
    eq.state = Running
    while eq.state == Running:
      # try to grab a continuation from the distributor
      var c = pop q
      if not c.dismissed:
        # put it in our local eventqueue
        addLast(eq.yields, c)

      # service our local eventqueue
      discard manic()
