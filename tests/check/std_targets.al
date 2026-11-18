// every bundled module that exists on every target, so that `alc check --all-targets` (see
// tests/run.sh) type-checks the OS layers that std.window, std.input and std.audio include
// with `when` for each target; `alc check` also checks the core modules (math, rand, time, mem)
// in full, which every program includes
use std.window
use std.input
use std.audio
use std.asset
use std.os
use std.image
use std.dx12
use std.metal
use std.shaderc
use std.net
use std.gfx
use std.font

fn main() {}
