import std/strutils

import pkg/cps

import httpleast/eventqueue

when leastQueue == "nim-sys":
  import sys/sockets

  type
    Client = AsyncConn[TCP]
    ClientAddr = IP4Endpoint
else:
  import std/nativesockets
  import std/net
  import std/os
  import std/posix

  type
    Client = SocketHandle
    ClientAddr = string

const
  leastPort {.intdefine.} = 8080
  leastAddress {.strdefine.} = "127.1"
  leastKeepAlive {.booldefine.} = true
  leastDelay {.intdefine.} = 0

when leastQueue != "nim-sys":
  template errorHandler(e: OSErrorCode; s: string) =
    case e.cint
    of {EAGAIN, EWOULDBLOCK}:  # it's the same picture
      continue
    else:
      raiseOSError e: s

template happyPath(op: untyped; logic: untyped): untyped {.dirty.} =
  ## do a read or write and handle the result, else run logic.
  ## we inject girth, which holds the result of your operation.
  let girth {.inject.} = op
  case girth
  of -1: # error
    when leastQueue != "nim-sys":
      errorHandler osLastError(): "i/o error in whassup"
    else:
      doAssert false, "unreachable"
  of 0: # disconnect
    break goodbye
  else:
    logic

let reply =
  when leastKeepAlive:
    "HTTP/1.1 200 ok\c\lContent-length: 13\c\lContent-Type: text/plain\c\l\c\lHello, World!"
  else:
    "HTTP/1.1 200 ok\c\lContent-length: 13\c\lContent-Type: text/plain\c\lConnection: close\c\l\c\lHello, World!"

proc whassup(client: Client; address: ClientAddr) {.cps: Cont.} =
  ## greet a client and find out what the fuck they want
  var buffer: array[256, char]      # an extra alloc is death
  var pos: int
  # a string large enough that we may not need a second alloc
  var received = newStringOfCap 256

  # iirc we inherit the flags?
  #setBlocking(client, false)

  ##
  ## connection
  ##
  block goodbye:
    while true:
      ##
      ## request
      ##
      setLen received, 0
      pos = 0
      while true:
        when leastQueue != "nim-sys":
          # wait for the client to send us something
          client.iowait {Read}
        # see what the client has to say for themselves
        happyPath do:
          when leastQueue != "nim-sys":
            read(client.cint, addr buffer[0], sizeof buffer)
          else:
            read(client, cast[ptr UncheckedArray[byte]](addr buffer[0]), sizeof buffer)
        do:
          # make an efficient copy of the buffer into the received string
          setLen(received, pos + girth)
          copyMem(addr received[pos], addr buffer[0], girth)
          pos += girth
          # maybe we've read all the headers?
          if received.endsWith "\c\l\c\l":
            break

      ##
      ## delay
      ##
      when leastDelay > 0:
        # simulate i/o wait for benchmarking
        delay leastDelay

      ##
      ## reply
      ##
      pos = 0
      while true:
        when leastQueue != "nim-sys":
          # wait until we can send a reply
          client.iowait {Write}

        happyPath do:
          when leastQueue != "nim-sys":
            write(client.cint, unsafeAddr reply[pos], reply.len - pos)
          else:
            write(client, cast[ptr UncheckedArray[byte]](unsafeAddr reply[pos]), reply.len - pos)
        do:
          pos += girth
          if pos == reply.len:
            break

      # testing allocators
      when not leastKeepAlive:
        break goodbye

  close client

when leastQueue != "nim-sys":
  proc server(sock: SocketHandle) {.cps: Cont.} =
    when leastQueue != "ioqueue":
      sock.persist {Read}
    while true:
      when leastQueue == "ioqueue":
        sock.iowait {Read}
      # the socket is ready; compose a client
      let (client, address) = accept sock
      if client == osInvalidSocket:
        raiseOsError osLastError()
      else:
        # spawn a continuation for the client
        spawn: whelp whassup(client, address)

      when leastQueue != "ioqueue":
        # wait for the socket to be readable
        dismiss()
else:
  proc server() {.cps: Cont.} =
    let sock = listenTcpAsync(leastAddress, leastPort.Port)
    while true:
      let (client, address) = accept sock
      # spawn a continuation for the client
      spawn: whelp whassup(client, address)

proc serve() {.nimcall.} =
  ## listen for connections on the `address` and `port`
  when leastQueue != "nim-sys":
    var socket = newSocket()
    socket.setSockOpt(OptReusePort, true)
    socket.setSockOpt(OptReuseAddr, true)
    socket.bindAddr(leastPort.Port, leastAddress)
    listen socket
    let fd = getFd socket
    setBlocking(fd, false)

    # spawn the server continuation
    spawn: whelp server(fd)
  else:
    spawn: whelp server()

  # run until there are no more continuations
  run()

when isMainModule:
  block service:
    when threaded:
      when leastQueue == "none" or leastQueue == "ioqueue":
        # thread N servers across N threads
        var threads: seq[Thread[void]]
        newSeq(threads, leastThreads)
        for thread in threads.mitems:
          createThread(thread, serve)
        for thread in threads.mitems:
          joinThread thread
        break service

    # thread 1 dispatcher for N threads
    serve()
