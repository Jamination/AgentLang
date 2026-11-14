// every bundled module that exists on every target, so that `alc check --all-targets` (see
// tests/run.sh) type-checks the OS layers that std.window, std.input and std.audio include
// with `when` for each target
use std.window
use std.input
use std.audio
use std.asset
use std.os
use std.image
use std.dx12
use std.metal

fn main() {}
