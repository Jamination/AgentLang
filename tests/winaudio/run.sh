#!/bin/bash
# The WASAPI back end of std.audio (std/audio_windows.al) under Wine, end to end, without ever
# reaching this machine's sound hardware:
#
# - a PRIVATE sound server: pipewire (pw-null.conf: two null sinks and nothing else) and
#   pipewire-pulse (pw-pulse.conf), with their own XDG_RUNTIME_DIR under tmp/winaudio;
# - every program of the test (the servers, pactl, pw-record, Wine) runs with `env -i` and only
#   the private sockets in its environment; Wine's prefix (tmp/win/prefix-winaudio, or
#   $WINEPREFIX) is limited to its PulseAudio driver, and ALSA gets an empty configuration;
# - before anything plays, the server is checked: its sinks must be exactly the two null sinks,
#   with no device objects and no other nodes; otherwise the test stops;
# - tone.al plays a known signal through audio_open / audio_pump / audio_write; pw-record
#   records the null sink's monitor and check.al verifies frequency, amplitude, channel
#   order, continuity and length; loss.al checks device loss (the server goes away and comes
#   back); a run without a server checks the documented error.
#
# Usage: tests/winaudio/run.sh [path/to/alc]       (exit status 0: everything passed)
set -u
cd "$(dirname "$0")/../.." || exit 2
ALC=$(realpath "${1:-./build/alc}") || exit 2
D=$PWD/tests/winaudio
for t in wine wineserver pipewire pw-record pw-link pw-cli pactl; do
  command -v $t >/dev/null || { echo "winaudio: needs $t"; exit 2; }
done
W=$PWD/tmp/winaudio
RT=$W/rt
rm -rf "$W"
mkdir -p "$RT" && chmod 700 "$RT" || exit 2
: >"$W/alsa-none.conf"
PREFIX=${WINEPREFIX:-$PWD/tmp/win/prefix-winaudio}
# the whole environment of every program started below
ENVP=(env -i PATH=/usr/bin:/bin HOME="$HOME" USER="$USER" LANG=C.UTF-8
  XDG_RUNTIME_DIR="$RT" PIPEWIRE_RUNTIME_DIR="$RT" PIPEWIRE_REMOTE="$RT/pipewire-0"
  PULSE_SERVER="unix:$RT/pulse/native" PULSE_RUNTIME_PATH="$RT/pulse" ALSA_CONFIG_PATH="$W/alsa-none.conf")
WINE=("${ENVP[@]}" WINEPREFIX="$PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="mscoree=;mshtml=")
PW=
PULSE=
LINKER=
cleanup() {
  [[ -n $LINKER ]] && kill $LINKER 2>/dev/null
  [[ -n $PULSE ]] && kill $PULSE 2>/dev/null
  [[ -n $PW ]] && kill $PW 2>/dev/null
  "${WINE[@]}" wineserver -k 2>/dev/null
  wait 2>/dev/null
}
trap cleanup EXIT
pass=0; fail=0
result() { # ok name
  if [[ $1 == 1 ]]; then echo "PASS $2"; pass=$((pass+1)); else echo "FAIL $2"; fail=$((fail+1)); fi
}
wait_for() { # path: a socket to appear
  for _ in $(seq 100); do [[ -S $1 ]] && return 0; sleep 0.05; done
  return 1
}
start_pulse() {
  "${ENVP[@]}" pipewire -c "$D/pw-pulse.conf" >"$W/pipewire-pulse.log" 2>&1 &
  PULSE=$!
  wait_for "$RT/pulse/native" || { echo "winaudio: pipewire-pulse did not start"; cat "$W/pipewire-pulse.log"; exit 1; }
}
# the stand-in for a session manager: Wine's streams (also the one winepulse opens to probe
# a device while it enumerates them) only start once they are linked to a sink
LINKED=
link_to() { # sink
  [[ $LINKED == "$1" ]] && return
  [[ -n $LINKER ]] && { kill $LINKER 2>/dev/null; wait $LINKER 2>/dev/null; }
  "${ENVP[@]}" SINK="$1" bash "$D/autolink.sh" &
  LINKER=$!
  LINKED=$1
}

# ---- build ----
"$ALC" build --target windows "$D/tone.al" -o "$W/tone.exe" || exit 1
"$ALC" build --target windows "$D/loss.al" -o "$W/loss.exe" || exit 1
"$ALC" build "$D/check.al" -o "$W/check" || exit 1

# ---- Wine prefix: PulseAudio is the only audio driver ----
if [[ ! -d $PREFIX ]]; then
  mkdir -p "$PREFIX" && "${WINE[@]}" wineboot -i >/dev/null 2>&1
fi
"${WINE[@]}" wineserver -p
"${WINE[@]}" wine reg add 'HKCU\Software\Wine\Drivers' /v Audio /d pulse /f >/dev/null 2>&1 || { echo "winaudio: cannot configure the prefix"; exit 1; }

# ---- no sound server: the documented error ----
out=$("${WINE[@]}" timeout 60 wine "$W/tone.exe" default 48000 2 pump 2>/dev/null); code=$?
echo "$out"
[[ $code == 1 && $out == "audio_open failed: WASAPI: no playback device (GetDefaultAudioEndpoint: HRESULT 0x80070490, E_NOTFOUND)" ]]
result $((! $?)) "no sound server: audio_open fails with E_NOTFOUND"

# ---- the private server, and the proof that it has no real output ----
"${ENVP[@]}" pipewire -c "$D/pw-null.conf" >"$W/pipewire.log" 2>&1 &
PW=$!
wait_for "$RT/pipewire-0" || { echo "winaudio: pipewire did not start"; cat "$W/pipewire.log"; exit 1; }
start_pulse
sinks=$("${ENVP[@]}" pactl list short sinks | cut -f2 | sort | tr '\n' ' ')
sources=$("${ENVP[@]}" pactl list short sources | cut -f2 | sort | tr '\n' ' ')
cards=$("${ENVP[@]}" pactl list short cards | wc -l)
devices=$("${ENVP[@]}" pw-cli ls Device | grep -c "^\s*id ")
nodes=$("${ENVP[@]}" pw-cli ls Node | sed -n 's/^\s*node.name = "\(.*\)"/\1/p' | sort | tr '\n' ' ')
echo "private server: sinks: $sinks| sources: $sources| cards: $cards | devices: $devices | nodes: $nodes"
if [[ $sinks != "al-null-51 al-null-sink " || $sources != "al-null-51.monitor al-null-sink.monitor " ||
      $cards != 0 || $devices != 0 || $nodes != "Dummy-Driver al-null-51 al-null-sink " ]]; then
  echo "winaudio: the private server has more than the null sinks; nothing is played"
  exit 1
fi
result 1 "private server has only the two null sinks"
link_to al-null-sink

# ---- a named device that does not exist ----
out=$("${WINE[@]}" timeout 60 wine "$W/tone.exe" "Speakers (none)" 48000 2 pump 2>/dev/null); code=$?
echo "$out"
[[ $code == 1 && $out == *'no playback device named "Speakers (none)"'* ]]
result $((! $?)) "unknown device name: audio_open fails"

# ---- the signal through each path, recorded and checked ----
n=0
play() { # sink device rate channels mode
  n=$((n+1))
  local sink=$1 rec=$W/rec$n.wav what="$2 $3 Hz $4 ch $5"
  local fmt=(--rate 48000 --channels 2)
  [[ $sink == al-null-51 ]] && fmt=(--rate 44100 --channels 6 --channel-map FL,FR,FC,LFE,RL,RR)
  link_to "$sink"
  "${ENVP[@]}" pw-record -P '{ adapter.auto-port-config = { mode = dsp } }' --format f32 "${fmt[@]}" "$rec" 2>/dev/null &
  local rec_pid=$!
  sleep 0.5
  "${WINE[@]}" timeout 60 wine "$W/tone.exe" "$2" "$3" "$4" "$5" >"$W/tone$n.txt" 2>/dev/null; local code=$?
  sleep 0.3
  kill -INT $rec_pid; wait $rec_pid
  sed 's/^/    /' "$W/tone$n.txt"
  if [[ $code != 0 ]]; then result 0 "$what: tone.exe exit $code"; return; fi
  if [[ $5 == stall ]]; then
    grep -q "underruns: [1-9]" "$W/tone$n.txt"
    result $((! $?)) "$what: underruns counted"
    return
  fi
  if "$W/check" "$rec" "$4" >"$W/check$n.txt"; then
    result 1 "$what: $(grep -c '^ok' "$W/check$n.txt") checks"
  else
    grep -v '^ok' "$W/check$n.txt" | sed 's/^/    /'
    result 0 "$what"
  fi
}
play al-null-sink default 48000 2 pump
play al-null-sink default 48000 2 write
play al-null-sink default 44100 2 pump
play al-null-sink default 22050 1 write
play al-null-51 "Speakers (AL null 5.1)" 48000 2 write
play al-null-51 "Speakers (AL null 5.1)" 32000 1 pump
play al-null-sink default 48000 2 stall

# ---- device loss: the server goes away and comes back ----
link_to al-null-sink
"${WINE[@]}" timeout 60 wine "$W/loss.exe" >"$W/loss.txt" 2>/dev/null &
loss_pid=$!
for _ in $(seq 200); do grep -q playing "$W/loss.txt" && break; sleep 0.05; done
sleep 0.5
kill $PULSE; wait $PULSE 2>/dev/null
sleep 2
start_pulse
wait $loss_pid
sed 's/^/    /' "$W/loss.txt"
grep -qx "lost seen: true frames while lost: 0 reopened: 1 frames in the second after: true" "$W/loss.txt"
result $((! $?)) "device loss: reported, recovered by itself"

echo "winaudio: $pass passed, $fail failed"
[[ $fail == 0 ]]
