import std/strutils
import std/hashes
import std/macros
import std/os
import std/selectors
import std/monotimes
import std/nativesockets
import std/tables
import std/times
import std/deques

import cps

export Event

const
  leastDebug {.booldefine, used.} = false   ## emit extra debugging output
  leastPoolSize {.intdefine, used.} = 64    ## expected pending continuations
  leastThreads {.intdefine, used.} = 0      ## 0 means "guess"
  threaded = compileOption"threads"
  triggers = not threaded

type
  Clock = MonoTime
  Id = distinct int
  Fd = distinct int

  # base continuation type
  Cont* = ref object of Continuation
    when leastDebug:
      clock: Clock                  ## time of latest poll loop
      delay: Duration               ## polling overhead
      id: Id                        ## our last registration
      fd: Fd                        ## our last file-descriptor

when leastDebug:
  import std/strutils

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

  import loony

  type
    ContQueue = LoonyQueue[Cont]
    QueueThread = Thread[ContQueue]

type
  Readiness = enum
    Unready = "the default state, pre-initialized"
    Stopped = "we are outside an event loop but available for queuing events"
    Running = "we're in a loop polling for events and running continuations"
    Stopping = "we're tearing down the dispatcher and it will shortly stop"

  WaitingIds = seq[Id]

  EventQueue = object
    state: Readiness              ## dispatcher readiness
    waiting: WaitingIds           ## maps waiting selector Fds to Ids
    goto: Table[Id, Cont]         ## where to go from here!
    lastId: Id                    ## id of last-issued registration
    selector: Selector[Id]        ## watches selectable stuff
    yields: Deque[Cont]           ## continuations ready to run
    waiters: int                  ## a count of selector listeners

    serverFd: Fd                  ## server's persistent file-descriptor
    serverCont: Cont              ## server's continuation

    eager: bool                   ## debounce wake-up triggers
    when triggers:
      timer: Fd                     ## file-descriptor of polling timer
      manager: Selector[Clock]      ## monitor polling, wake-ups
      wake: SelectEvent             ## wake-up event for queue actions
    when threaded:
      queue: ContQueue
      threads: seq[QueueThread]

const
  wakeupId = Id(-1)
  invalidId = Id(0)
  invalidFd = Fd(-1)

var eq {.threadvar.}: EventQueue

template now(): Clock {.used.} = getMonoTime()

proc `$`(id: Id): string {.used.} = "{" & system.`$`(id.int) & "}"
proc `$`(fd: Fd): string {.used.} = "[" & system.`$`(fd.int) & "]"
proc `$`(c: Cont): string {.used.} = "&" & $cast[uint](c)

proc `<`(a, b: Id): bool {.borrow, used.}
proc `<`(a, b: Fd): bool {.borrow, used.}
proc `==`(a, b: Id): bool {.borrow, used.}
proc `==`(a, b: Fd): bool {.borrow, used.}

proc put(w: var WaitingIds; fd: int | Fd; id: Id) =
  while fd.int >= w.len:
    setLen(w, w.len * 2)
  system.`[]=`(w, fd.int, id)
  case id
  of wakeupId, invalidId:             # don't count invalid ids
    discard
  else:
    inc eq.waiters
    assert eq.waiters > 0

proc reset(w: var WaitingIds; fd: int | Fd; write = true): Id =
  ## fetch the id for a given fd; forget about the fd if `write==true`
  result = w[fd.int]
  if write:
    if result != wakeupId:              # don't zap our wakeup id
      if result != invalidId:           # don't count invalid ids
        dec eq.waiters
      w[fd.int] = invalidId

when threaded:
  proc consumer(q: ContQueue) {.thread.}

proc init() {.inline.} =
  ## initialize the event queue to prepare it for requests
  if eq.state == Unready:
    eq.serverFd = invalidFd
    eq.serverCont = nil
    eq.eager = false
    eq.selector = newSelector[Id]()
    eq.waiters = 0

    when threaded:
      if eq.queue.isNil:
        eq.queue = initLoonyQueue[Continuation]().ContQueue
        # create consumer threads to service the queue
        let cores =
          if leastThreads == 0:
            countProcessors()
          else:
            leastThreads
        newSeq(eq.threads, cores)
        for thread in eq.threads.mitems:
          createThread(thread, consumer, eq.queue)

    when triggers:
      eq.timer = invalidFd
      # the manager wakes up when triggered to do so
      eq.manager = newSelector[Clock]()
      registerEvent(eq.manager, eq.wake, now())

      # so does the main selector
      eq.wake = newSelectEvent()
      registerEvent(eq.selector, eq.wake, wakeupId)

      # XXX: this seems to be the only reasonable way to get our wakeup fd
      # we want to get the fd used for the wakeup event
      trigger eq.wake
      for ready in select(eq.selector, -1):
        assert User in ready.events
        eq.waiting.put(ready.fd, wakeupId)

    # make sure we have a decent amount of space for registrations
    if len(eq.waiting) < leastPoolSize:
      eq.waiting = newSeq[Id](leastPoolSize).WaitingIds

    eq.lastId = invalidId
    eq.yields = initDeque[Cont]()
    eq.state = Stopped

proc nextId(): Id {.inline.} =
  ## generate a new registration identifier
  init()
  # rollover is pretty unlikely, right?
  when sizeof(eq.lastId) < 8:
    if (unlikely) eq.lastId == high(eq.lastId):
      eq.lastId = succ(invalidId)
    else:
      inc eq.lastId
  else:
    inc eq.lastId
  result = eq.lastId

when triggers:
  proc wakeUp() =
    case eq.state
    of Unready:
      init()
    of Stopped:
      discard "ignored wake-up to stopped dispatcher"
    of Running:
      if not eq.eager:
        when triggers:
          trigger eq.wake
        eq.eager = true
    of Stopping:
      discard "ignored wake-up request; dispatcher is stopping"
else:
  template wakeUp(): untyped = discard

template wakeAfter(body: untyped): untyped =
  ## wake up the dispatcher after performing the following block
  init()
  try:
    body
  finally:
    wakeUp()

proc len*(eq: EventQueue): int =
  ## The number of pending continuations.
  result = len(eq.goto) + len(eq.yields)

proc `[]=`(eq: var EventQueue; id: Id; cont: Cont) =
  ## put a continuation into the queue according to its registration
  assert id != invalidId
  assert id != wakeupId
  assert id notin eq.goto
  eq.goto[id] = cont

proc add(eq: var EventQueue; cont: Cont): Id =
  ## Add a continuation to the queue; returns a registration.
  result = nextId()
  eq[result] = cont
  debug "🤞queue", result, "now", len(eq), "items"

proc stop*() =
  ## Tell the dispatcher to stop, discarding all pending continuations.
  if eq.state == Running:
    eq.state = Stopping

    when triggers:
      # tear down the manager
      assert not eq.manager.isNil
      eq.manager.unregister eq.wake
      if eq.timer != invalidFd:
        eq.manager.unregister eq.timer.int
        eq.timer = invalidFd
      close eq.manager

      # shutdown the wake-up trigger
      eq.selector.unregister eq.wake
      close eq.wake

    # discard the current selector to dismiss any pending events
    close eq.selector

    # discard the contents of the continuation cache
    clear eq.goto

    # re-initialize the queue
    eq.state = Unready
    init()

proc trampoline*(c: Cont) =
  ## Run the supplied continuation until it is complete.
  {.gcsafe.}:
    when leastDebug:
      var c: Continuation = c
      trampolineIt c:
        debug "🎪tramp", Cont(c), "at", Cont(c).clock
    else:
      discard cps.trampoline c

proc manic(timeout = 0): int =
  if eq.state != Running: return 0

  eq.eager = false    # make sure we can trigger again

  if eq.waiters > 0:
    when leastDebug:
      let clock = now()

    # ready holds the ready file descriptors and their events.
    let ready = select(eq.selector, timeout)
    for event in ready.items:
      # see if this is the server's listening socket
      let isServer = eq.serverFd == Fd(event.fd)

      # reset the registration of the pending continuation
      let id = eq.waiting.reset(event.fd, write = not isServer)

      # the id will be wakeupId if it's a wake-up event
      if id != wakeupId:
        var cont: Cont
        if isServer:
          cont = eq.serverCont
        else:
          # stop listening on this fd
          unregister(eq.selector, event.fd)
          if take(eq.goto, id, cont):
            when leastDebug:
              cont.clock = clock
              cont.delay = now() - clock
              cont.id = id
              cont.fd = event.fd.Fd
              debug "💈delay", id, cont.delay
          else:
            raise KeyError.newException "missing registration " & $id

        # queue it for trampolining below
        eq.yields.addLast cont

  if eq.yields.len > 0:
    # run no more than the current number of ready continuations
    for index in 1 .. eq.yields.len:
      let cont = popFirst eq.yields
      inc result
      trampoline cont

proc poll*() =
  ## See what continuations need running and run them.
  if eq.state != Running: return

  # long-poll for i/o or yields or whatever
  discard manic -1

  when triggers:
    # if there are no pending continuations,
    if eq.len == 0:
      # and there is no polling timer setup,
      if eq.timer == invalidFd:
        # then we'll stop the dispatcher now.
        stop()
      else:
        when leastDebug:
          debug "💈"
        # else wait until the next polling interval or signal
        for ready in eq.manager.select(-1):
          # if we get any kind of error, all we can reasonably do is stop
          if ready.errorCode.int != 0:
            stop()
            raiseOSError(ready.errorCode, "eventqueue error")
          break

proc run*(interval: Duration = DurationZero) =
  ## The dispatcher runs with a maximal polling interval; an `interval` of
  ## `DurationZero` causes the dispatcher to return when the queue is empty.

  # make sure the eventqueue is ready to run
  init()
  assert eq.state in {Running, Stopped}, $eq.state
  when triggers:
    if interval.inMilliseconds == 0:
      discard "the dispatcher returns after emptying the queue"
    else:
      # the manager wakes up repeatedly, according to the provided interval
      eq.timer = registerTimer(eq.manager,
                               timeout = interval.inMilliseconds.int,
                               oneshot = false, data = now()).Fd

  # the dispatcher is now running
  eq.state = Running
  while eq.state == Running:
    poll()

  when threaded:
    for thread in eq.threads.mitems:
      joinThread thread

proc spawn*(c: Cont) =
  ## Queue the supplied continuation `c`; control remains in the calling
  ## procedure.
  block done:
    when threaded:
      # spawn to a thread if possible
      if not eq.queue.isNil:
        eq.queue.push c
        break done

    # else, spawn to the local eventqueue
    wakeAfter:
      addLast(eq.yields, c)

proc dismiss*(c: Cont): Cont {.cpsMagic.} = discard

proc iowait*(c: Cont; file: int | SocketHandle;
             events: set[Event]): Cont {.cpsMagic.} =
  ## Continue upon any of `events` on the given file-descriptor or
  ## SocketHandle.
  if len(events) == 0:
    raise newException(ValueError, "no events supplied")
  else:
    wakeAfter:
      if eq.serverFd.int != file.int:
        let id = eq.add(c)
        registerHandle(eq.selector, file, events = events, data = id)
        eq.waiting.put(file.int, id)
        debug "📂file", $Fd(file)

proc persist*(c: Cont; file: int | SocketHandle;
              events: set[Event]): Cont {.cpsMagic.} =
  ## Let the event queue know you want long-running registrations.
  assert eq.serverFd == invalidFd, "call persist only once"
  result = iowait(c, file, events)
  eq.serverCont = c
  eq.serverFd = Fd(file)

when threaded:
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
