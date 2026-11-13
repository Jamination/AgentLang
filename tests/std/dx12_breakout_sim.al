// The game logic and sound of the Direct3D 12 breakout (examples/dx12_breakout/headless.al):
// 3600 frames of a scripted player on keyboard and gamepad, the pause menu and a focus loss;
// the checksums of the state and of the mixed sound are the same on Linux and Windows
// (tests/sys/dx12_breakout runs the game itself).
use "../../examples/dx12_breakout/headless.al"

fn main() {
    breakout_headless(3600)
}
