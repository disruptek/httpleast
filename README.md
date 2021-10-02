# httpleast

'twas beauty that killed the beast

## Defines

Most importantly,

- `--define:leastThreads=N` set number of threads to `N`.

And then,

- `--define:leastQueue=none`

This uses the specified number of threads, each running their own server and
creating and dispatching client continuations in a thread-local eventqueue.

- `--define:leastQueue=loony`

This uses a single thread accepting clients and setting up a continuation for
each one; the continuation is pushed into a `LoonyQueue` that is serviced by
the specified number of threads. Each thread runs as many continuations as
remain in the running state, competing to receive new continuations from the
queue.

- `--define:leastRecycle=true` reduces continuation allocs.

When using Loony, recycle completed continuations via a multi-threaded queue;
when using no queue, recycle completed continuations with a thread-local stack.

Also...

- `--define:leastPort=8080` listen on port 8080.
- `--define:leastAddress="127.1"` listen on given interface.
- `--define:leastDebug=true` adds extra event queue debugging.
- `--define:leastKeepAlive=false` turns off connection reuse.

## License
MIT
