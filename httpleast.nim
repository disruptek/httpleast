import std/strutils
import std/os
import std/net
import std/nativesockets
import std/posix

import cps

import httpleast/eventqueue

const
  leastPort {.intdefine.} = 8080
  leastAddress {.strdefine.} = "127.1"
  leastKeepAlive {.booldefine.} = true

template errorHandler(e: OSErrorCode; s: string) =
  case e.cint
  of {EAGAIN, EWOULDBLOCK}:  # it's the same picture
    continue
  else:
    raiseOSError e: s

let reply = "HTTP/1.1 200 ok\c\lContent-length: 13\c\lContent-Type: text/plain\c\l\c\lHello, World!"

proc whassup(client: SocketHandle; address: string) {.cps: Cont.} =
  ## greet a client and find out what the fuck they want
  var
    buffer: array[128, char]      # an extra alloc is death
    received: string              # this will end up in the continuation
    pos: int                      # with a default size of, like, 2000

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
        # wait for the client to send us something
        client.iowait {Read}
        # see what the client has to say for themselves
        let girth = read(client.cint, addr buffer[0], sizeof buffer)
        case girth
        of -1: # error
          errorHandler osLastError(): "unexpected read error"
        of 0: # disconnect
          break goodbye
        else:
          # make an efficient copy of the buffer into the received string
          setLen(received, pos + girth)
          copyMem(addr received[pos], addr buffer[0], girth)
          pos += girth
          # maybe we've read all the headers?
          if received.endsWith "\c\l\c\l":
            break

      ##
      ## reply
      ##
      pos = 0
      while true:
        # wait until we can send a reply
        client.iowait {Write}
        let girth = write(client.cint, unsafeAddr reply[pos], reply.len - pos)
        case girth
        of -1: # error
          errorHandler osLastError(): "unexpected write error"
        of 0: # disconnect
          break goodbye
        else:
          pos += girth
          if pos == reply.len:
            break

      # testing allocators
      when not leastKeepAlive:
        break goodbye

  close client

proc server(sock: SocketHandle) {.cps: Cont.} =
  sock.persist {Read}
  while true:
    # the socket is ready; compose a client
    let (client, address) = accept sock
    if client == osInvalidSocket:
      raiseOsError osLastError()
    else:
      # spawn a continuation for the client
      spawn: whelp whassup(client, address)

    # wait for the socket to be readable
    dismiss()

proc serve(address = leastAddress; port = leastPort) =
  ## listen for connections on the `address` and `port`
  let port = Port(port)
  var socket = newSocket()
  socket.setSockOpt(OptReusePort, true)
  socket.setSockOpt(OptReuseAddr, true)
  socket.bindAddr(port, address)
  listen socket
  let fd = getFd socket
  setBlocking(fd, false)

  # spawn the server continuation
  spawn: whelp server(fd)

  # run until there are no more continuations
  run()

when isMainModule:
  serve()
