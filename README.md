# dumb-file-mirror

[![Build Status](https://travis-ci.org/fpco/dumb-file-mirror.svg?branch=master)](https://travis-ci.org/fpco/dumb-file-mirror)
[![Build status](https://ci.appveyor.com/api/projects/status/19mblbxaig48i26p/branch/master?svg=true)](https://ci.appveyor.com/project/snoyberg/dumb-file-mirror/branch/master)

## What it is

This is a dumb tool to mirror file changes made on one machine onto
another machine. In contrast with more naive approaches (like
combining `inotify` and `rsync`), this approach keeps a persistent TCP
connection open to decrease latency between writes. It is also a fully
cross-platform tool, and uses OS-specific file watching APIs when
available.

I initially wrote this tool to make our lives a little bit nicer when
doing some coding on remote build machines. However, it turned out to
be a good demonstration of some practical Haskell, as well as using
the [conduit library](https://github.com/snoyberg/conduit#readme) for
non-trivial network operations.

## Get started quickly

* Clone the repo: `git clone https://github.com/fpco/dumb-file-mirror`
* Get the
  [Haskell Stack build tool](https://haskell-lang.org/get-started). On
  most POSIX systems, just run `curl -sSL
  https://get.haskellstack.org/ | sh`
* Inside the `dumb-file-mirror` directory, run `stack install
  --install-ghc`. (This will take a while, it's going to set up an
  entire toolchain and build a bunch of dependencies.)
* Run `dumb-file-mirror remote 1234 dest-dir` on the remote machine
* Run `dumb-file-mirror local remote-host-name 1234 src-dir` on the local machine
* Edit away!

You can of course get a lot more inventive with this, especially with
SSH tunneling. For example, try running these in two different
terminals:

```shell
$ ssh user@host -L 12345:localhost:12345 /path/to/bin/dumb-file-mirror remote 12345 /some/dest/dir
$ dumb-file-mirror local localhost 12345 /some/source/dir
```

## How it works
