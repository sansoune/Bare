# Bare: development tasks. Run `just` to list them.


default:
  @just --list

# Runs the emulator
run-emu:
  zig run ./emulator/emu.zig

test:
  zig build test --summary all
