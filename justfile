# Bare: development tasks. Run `just` to list them.


default:
  @just --list

# Runs the emulator
run-emu file:
  zig build run -- {{file}}

test filter="":
  zig build test --summary all {{ if filter == "" { "" } else { "-Dfilter=" + filter } }}
