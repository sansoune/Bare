# Bare: development tasks. Run `just` to list them.


default:
  @just --list

# Runs the emulator
run-emu file:
  zig run ./emulator/emu.zig -- {{file}}

test:
  zig build test --summary all
