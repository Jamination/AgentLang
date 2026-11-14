# Testing AL on a real Windows machine

Everything Windows-specific was developed on Linux and tested under Wine 11.21. These are the
checks Wine cannot prove. Run them on Windows 10 or 11 (x64) and note any that fail, with the
exact output.

## Setup
1. Copy the repository, including `build/alc.exe` (built by `./build.sh` on Linux), or build it
   on Linux with `./build/alc build --target windows src/main.al -o alc.exe`.
2. In a terminal (cmd or PowerShell) at the repository root:
   `alc.exe build examples\hello.al` then `hello.exe`: prints a greeting.

## 1. The compiler on Windows
1. `alc.exe build src/main.al -o alc2.exe`, then `fc /b alc.exe alc2.exe`: no differences
   (the compiler reproduces itself on Windows).
2. `alc.exe build --target linux src/main.al -o alc-linux`: byte-identical to the Linux
   `build/alc` built from the same sources.
3. The compiler runs on a thread with a 1 GB stack: compiling `src/main.al` (above) already
   exercises deep recursion; a file with blocks nested 1,500 deep also compiles.
4. `alc.exe run examples\hello.al` and `alc.exe test` on a unit test file: output and exit
   codes as on Linux; `alc.exe run` of a program that exits with 300 reports 44, a panic 1.
5. Paths with drive letters, backslashes, a network share (`\\server\share\x.al`) and long
   paths (over 260 characters) work.
6. Antivirus: building and immediately running a fresh `.exe` repeatedly works (no "file in use"
   failures); note if Windows Defender flags any AL executable.
7. On the oldest Windows version you care about: `GetCurrentThreadStackLimits` and
   `GetActiveProcessorCount` exist (Windows 8+ / 7+); the compiler starts.

## 2. Executables (any program)
1. Loading: AL executables have a fixed base address and no relocations. They load unless the
   "Mandatory ASLR" exploit-protection setting is forced on; note if it is on and they fail.
2. Stack probes: a program with a large local array (e.g. `x: [1000000]u8` in a function,
   called recursively a few times) runs; deep recursion ends with the stack-overflow panic
   message, not a silent crash.
3. Console output: UTF-8 text including characters outside the basic plane (e.g. an emoji)
   displays in conhost and in Windows Terminal; output redirected to a file is exact bytes.
4. Exit codes above 255 and panics: as above (low 8 bits, panic = 1).
5. A program whose output pipe is closed (`prog | more`, then quit `more`) ends with
   "cannot write to standard output: broken pipe".

## 3. Window and input (`std.window`, `std.input`)
Use `examples\starter\game.al` and `examples\win32_input.al` (prints every event).
1. Starter game: window 960x540, picture correct; arrows/WASD move, Space fires, Escape quits;
   `game.exe --headless` prints `frame e846fd27f05bc404`.
2. Dragging the title bar and resizing the frame: the game keeps animating.
3. Alt+Space menu open: the game keeps running; Alt alone and F10 do not freeze it; Alt+F4
   closes.
4. AltGr on a German or French layout: exactly one right-Alt event, no Ctrl in the modifiers.
5. Right Shift alone shows no modifier; releasing two held Shifts in either order leaves both
   released.
6. Other layouts: QWERTZ, AZERTY (the digit row gives `KEY_1`...), dead keys (`^` then `e`
   gives `ê`), an IME.
7. Print Screen gives one press and one release.
8. On a 150 % or 200 % monitor: the window is exactly its size in physical pixels and sharp;
   moving it to a monitor with another scale causes no resize.
9. F11 in `win32_input` on each monitor covers that monitor including the taskbar; F11 again
   restores position and size.
10. F2 hides and shows the pointer over the window only.
11. Mouse: X1/X2 buttons, wheel notches, touchpad and horizontal scrolling, dragging outside
    the window.
12. Alt-Tab while holding a key releases it; minimise and restore cause no 0x0 resize.
13. Xbox controller in `win32_input`: button and axis numbers as documented; the guide button
    only with `xinput1_4`; unplugging is reported.

## 4. Audio (`std.audio`, WASAPI)
Build `examples\audio_tone.al` and `tests\winaudio\tone.al`.
1. `audio_tone.exe` plays the melody cleanly, panning left to right, `underruns: 0`.
2. `tone.exe default 48000 2 pump`: 440 Hz left, 880 Hz right, 1000 Hz both. Repeat with
   `write` instead of `pump`.
3. `tone.exe default 44100 2 pump` and `tone.exe default 22050 1 write`: same pitches.
4. On a 5.1/7.1 device or with a 16/24-bit format set in the device's Advanced settings:
   tones correct. Report the printed `device format ... kind` line (0 = float, 1 = 16-bit,
   2 = 24-bit, 3 = 32-bit integer).
5. Playing on a device chosen by name (`audio_devices()` lists them):
   `tone.exe "<friendly name>" 48000 2 pump`.
6. Unplug USB or Bluetooth headphones that are the default while playing: playback continues
   on the new default after a short gap; switching the default in Sound settings moves
   playback within about a second.
7. Disabling the device while playing: no crash; playback resumes when it is enabled.
8. Changing the device's default format while playing: playback continues at the same pitch.
9. `audio_open("default", 48000, 2, 20)` in a 60 Hz loop: no underruns on an idle machine.
10. Audio together with a window and DX12 in one program on the same thread.
11. No audio device, or the Windows Audio service stopped: `audio_open` fails with the
    documented message and the program keeps running.

## 5. Direct3D 12
Build `tests\sys\dx12_offscreen.al` and `examples\dx12_triangle.al` (both include the examples'
Direct3D 12 set-up code, `examples\gamekit\dx12_gpu.al`, by relative path: keep the folders as
they are in the repository).
1. `dx12_offscreen.exe`: stdout equals `tests\sys\dx12_offscreen.out`, exit 0; stderr names the
   real GPU and then "Microsoft Basic Render Driver" (first test of real WARP).
2. The same built with `-O0` and with `--unchecked`.
3. `dx12_triangle.exe`: resizing by dragging and by maximise (no stretching, the swapchain
   follows while dragging); minimise and restore; F11 / Alt+Enter fullscreen; Escape and the
   close button print `frames: ...` and exit 0.
4. `--no-vsync`: fps well above the refresh rate; without it about the refresh rate.
5. `--debug` with the Graphics Tools installed: no debug-layer errors.
6. `--remove-device 100`: "the GPU device was lost ...", the `DXGI_ERROR_DEVICE_REMOVED` line
   and the removal reason, exit status 2.
7. `--warp`: runs on the Microsoft Basic Render Driver.
8. On a machine with two GPUs: note which adapter is picked (the first in `EnumAdapters1`
   order).

## 6. The games (`--gui`)
Build each with `--target windows --gui` (on Windows `--target windows` is the default):
`examples\dx12_starter\game.al`, `examples\dx12_breakout\game.al`, `examples\dx12_triangle.al`.
1. Double-click each from Explorer: no console window appears.
2. Starter: move, shoot, M toggles music, die, fire to restart.
3. Breakout: start, launch, steer with keys, D-pad and stick.
4. Breakout pause menu: change both volumes, toggle fullscreen, quit to title, Escape quits.
5. Alt+Tab away pauses both games.
6. F11 and Alt+Enter toggle fullscreen; dragging the edge keeps the picture letterboxed.
7. Unplug headphones: "SOUND DEVICE LOST, RECONNECTING" shows and sound comes back.
8. Plug in a gamepad mid-game: picked up within about 2 seconds.
9. From cmd: `breakout.exe --headless` prints the 1800-frame checksums
   (`0f8df097329c76c3`, audio `955e5eef407531e7`); `breakout.exe > log.txt` writes the final line
   to the file.
10. A `--gui` program that panics, started from Explorer, shows a message box naming the panic.
11. Closing with the window's X exits cleanly.
