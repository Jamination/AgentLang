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
1. Loading: AL executables are relocatable (ASLR, high entropy; preferred base 0x140000000).
   They load with the "Mandatory ASLR" exploit-protection setting forced on as well as with
   the defaults; section 8 has the checks.
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

## 7. Threads (`std.os`, atomics)
Build and run each `tests\run\thread_*.al` (output must equal the matching `.out`; tests with a
`.code` file exit with that status and print the `.err` lines).
1. `thread_sum`, `thread_cas`, `thread_spin`, `thread_map`, `thread_cond`, `thread_alloc`,
   `thread_region`, `thread_nested`, `thread_print`: correct output; run each about 20 times
   (races show up rarely).
2. `thread_cond` uses `wait` with a timeout (SRWLOCK + CONDITION_VARIABLE): it finishes and
   prints the expected lines.
3. The failure tests `thread_panic`, `thread_overflow`, `thread_nil`, `thread_join_twice`,
   `thread_unlock`, `thread_region_other`: the message names the thread (`panic in thread N: ...`), shows its stack
   trace, and the exit status is 1. The stack overflow in a thread is reported, not a silent
   crash (this checks `SetThreadStackGuarantee` on new threads).
4. Executables carry a TLS directory with an empty template: they load and per-thread data works
   (every thread test exercises it).

## 8. The executable file: ASLR, manifest, icon, version information
Wine relocates images and applies the manifest (tests/pe/run.sh), and the file format is
checked on Linux (tests/driver/pe.sh); what only Windows can show:
Build `tests\pe\res.al` twice: plain as `res_plain.exe`, and as `res_full.exe` with
`--icon examples\starter\game.ico --version-info "FileDescription=AL resource test"
--version-info ProductName=Starter --version-info "CompanyName=Example Ltd"
--version-info FileVersion=1.2.3 --version-info "LegalCopyright=(c) 2026 Example Ltd"`.
1. `res_plain.exe` prints exactly `tests\pe\res_plain.out`, `res_full.exe`
   `tests\pe\res_full.out` (the first line says the image was moved from its preferred base;
   `active code page: 65001` needs Windows 10 1903 or later: note the number on older ones).
2. `res_plain.exe --verbose`: the `base` line is an address above `7ff000000000`, not
   `140000000`. Windows may reuse the placement while the image stays cached, so the base can
   repeat from run to run; it changes after a restart or when the file is rebuilt or copied.
3. With "Force randomization for images (Mandatory ASLR)" switched on (Windows Security, App &
   browser control, Exploit protection, system settings; restart): `hello.exe`, the compiler
   (`alc.exe build examples\hello.al`) and a game start and work.
4. Process Explorer (column "ASLR") or `Get-ProcessMitigation -Name res_plain.exe` /
   `dumpbin /headers`: the image has "Dynamic base", "High entropy VA" and "NX compatible".
5. Explorer shows the icon of `res_full.exe` in every view (small list, large and extra
   large icons: the 16, 32, 48 and 256 pixel images), on a desktop shortcut and, while it
   runs, a std.window game built with `--icon` shows it in the title bar, the taskbar and
   Alt+Tab. `res_plain.exe` has the system's default icon.
6. Properties of `res_full.exe`, tab Details: File description, Product name, File version
   1.2.3.0, Product version 1.2.3, Copyright, Language "English (United States)"; Task
   Manager shows the description as the process name.
7. Manifest: `mt.exe -inputresource:res_plain.exe;#1 -out:m.xml` (or Resource Hacker)
   extracts well-formed XML; `sigcheck -m res_plain.exe` prints it. An executable named
   `setup.exe` or `install.exe` built by `alc` starts without an elevation prompt.
8. Long paths: with `LongPathsEnabled` set to 1 in
   `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem`, a program reads and writes a file
   whose full path is longer than 260 characters without the `\\?\` prefix.
9. On a 150 % or 200 % monitor, a GUI program that opens a window with its own `user32.dll`
   calls (not std.window) is sharp and sized in physical pixels; the panic message box of a
   `--gui` program is sharp, not blurred.
10. A program that declares `extern "user32.dll" fn MessageBoxA(...)` and passes UTF-8 text
    with non-ASCII characters (`"Grüße, 世界"`) shows it correctly (Windows 10 1903+).
11. Windows Defender and SmartScreen: note any warning for a fresh `alc` executable, with and
    without `--icon` / `--version-info` (relocatable images with a manifest and version
    information look less unusual to scanners than the earlier fixed-base ones).

## 9. Files and processes (`std.asset`, `std.os`)
Under Wine the library tests run as on Linux; Wine's file system and process layer are not
those of Windows. From the repository root (the tests work in directories under `tmp\`), for
each test `T` below: `alc.exe build tests\std\T.al -o t.exe`, `t.exe a1 b2 > out.txt`, and
`out.txt` must equal `tests\std\T.out` byte for byte (the programs write `"\n"` line ends: if
git converted the `.out` files to `"\r\n"`, compare ignoring line ends).
1. The tests that run on both systems: `os_files`, `os_run`, `os_spawn`, `os_spawn_threads`,
   `portable_process`, `asset`, `asset_data`, `asset_io_error`, `asset_user_dirs`, `image_ops`,
   `audio_wav`, `time_huge`, and `portable_files` with `< tests\std\portable_files.in`. The
   lines about paths below a file (`not a directory`) and about `rename` between a file and a
   directory check error codes that Wine reports differently from Windows.
2. `tests\sys\win_files.al` (output: `tests\sys\win_files.out`). Note the line it writes to
   standard error: `long paths without \\?\: work` or `fail (...)`. With `LongPathsEnabled` = 1
   in `HKLM\SYSTEM\CurrentControlSet\Control\FileSystem` and a long-path-aware manifest it must
   say `work`; the `\\?\` lines must pass either way.
3. In that test, the lines `hidden` and `hidden system`: `write_file` replaces a hidden file
   (Windows refuses it without the file's attributes; Wine never refuses, so the retry in the
   library has never run).
4. In that test, `open with full sharing`: `rename` over a file that is open fails (`false`),
   deleting it works; and `the running program`: deleting the program's own file fails with
   `permission denied`, renaming it works.
5. Not in the tests (Wine cannot do them): on a network share, `list_dir("\\\\server\\share\\dir")`,
   `read_bytes` / `write_bytes` there, `path_join("\\\\server\\share", "x")` gives
   `\\server\share/x`; the same share as `\\?\UNC\server\share\dir`.
6. Not in the tests: `rename(d + "/a.txt", d + "/A.txt")` changes the case that `list_dir`
   shows (Wine keeps the old name); a file whose name has an unpaired UTF-16 surrogate
   (`write_file(d + "/x\xed\xa0\x80y", "")`) can be created and `list_dir` returns the same
   bytes; `write_file("nul.txt", "x")` on Windows 10 (a device) and 11 (a file).
7. A file open in another program that locks it (a document open in Excel, a running
   installer's log): `read_bytes` fails with `device or resource busy`, not a hang or a crash.
8. Antivirus: run `os_files` and `asset` 20 times in a row; a scanner that holds a fresh file
   for a moment can make `remove_file` or `rename` fail with `device or resource busy` or
   `permission denied`. Note how often.
9. `tests\sys\win_process.al` (output: `tests\sys\win_process.out`): the first two lines compare
   `args()` with the argument splitting of the real `msvcrt.dll`; `a batch file` must print
   `-1 exec format error` four times; `through cmd` runs the batch file.
10. A command line of more than 32767 characters (`run` with one argument of 40000
    characters): `-1` and an error in `io_error()` (Wine starts the program).
11. `os_spawn_threads` 20 times: always `no capture waited for a sleeper: true`.
12. End a running child from Task Manager while its parent is in `wait` (`os_spawn` with the
    sleep made longer): `wait` returns 1, the exit code Task Manager gives. Ctrl+C in the
    console while `run` waits for a child ends both.

## 10. The C library (`std.libc`, `msvcrt.dll`)
Wine's `msvcrt.dll` is a reimplementation: these check the real one. Build and run as in 9,
with `tests\sys\T.al` and `tests\sys\T.out`; tests with `T.windows.err` must also print those
lines on standard error (run with `2> err.txt`) and exit with the status in `T.code`.
1. `libc`: all lines equal. The line after the long `sprintf` line checks `%p`, the three-digit
   exponent of `%e`, the 32-bit `long` and `%I64d`; the next one `_snprintf` (no NUL, -1).
2. `nested_fn_callback`, `thread_libc` (20 times: `8 true`), `extern_data`. In `extern_data`,
   line 1 reads `_environ` and `_iob` without the C start-up code having run; line 3 relies on
   `_fmode` deciding how `fopen` opens a file.
3. `backtrace_qsort` (status 1): the trace has at least one `  at msvcrt.dll` line between
   `by_value` and `sort`. `backtrace_strlen` (status 1): `panic: memory fault ...`, then
   `  at msvcrt.dll`, `measure`, `main` (the fault is inside the DLL: this goes through the
   unhandled exception filter).
4. Formats that Wine accepts and Windows should not: `printf(ptr("%zu|%hhd|\n"), u64(5), 300)`.
   Note what it prints (documented as unsupported in `docs\std\libc.md`).
5. A program that ends without `fflush`: `printf(ptr("c\n"))` then `print("al")`, output
   redirected to a file: under Wine the file holds `al`, then `c` with `"\r\n"`. Note what
   Windows writes (documented: msvcrt.dll writes its buffer when the process ends).
6. The same program in a console window: `c` appears (C's standard output is not buffered
   there); with `flush()` before each `printf` and `fflush(nil)` after, the lines of
   `print` and `printf` alternate in program order, in a console and in a file.
7. `printf(ptr("gr\xc3\xbc\xc3\x9fe\n"))` and `print("gr\xc3\xbc\xc3\x9fe")` in a console:
   `print` shows the umlauts; `printf` shows them only after `chcp 65001`.
8. On the oldest Windows you care about: `msvcrt.dll` exports `_snprintf`, `__iob_func`,
   `_fileno`, `_setmode`, `cosf` (a program using `std.libc` starts at all).
