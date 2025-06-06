# C3 Fzy

A very simple (no fancy matching algo, no scoring/sorting) fuzzy filter written in C3 as an excercise.

## Building

There is a git submodule in `./lib/terminal-interface.c3l` so make sure you init submodules first.
This repo uses the C3 build system, it can be simply ran via `c3c run`.

## Terminal interface
A part of this software is a simple terminal interface library for working with ANSI compatible terminals on POSIX, enabling the creation of interactive terminal UI.

This will most likely be separated into a proper library in the future.
