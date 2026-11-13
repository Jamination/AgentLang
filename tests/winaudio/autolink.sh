#!/bin/bash
# Stands in for a session manager on the private server of run.sh: links every playback
# stream to the null sink $SINK and every capture stream to the monitor of $SINK (ports are
# matched by channel: output_FL -> playback_FL, a mono stream to FL and FR).
SINK=${SINK:-al-null-sink}
while true; do
  while IFS= read -r p; do
    [[ -z $p || $p == al-null-* ]] && continue
    ch=${p##*_}
    if [[ $ch == MONO ]]; then t=(FL FR); else t=("$ch"); fi
    for c in "${t[@]}"; do pw-link "$p" "$SINK:playback_$c" 2>/dev/null; done
  done < <(pw-link -o)
  while IFS= read -r p; do
    [[ -z $p || $p == al-null-* ]] && continue
    ch=${p##*_}
    [[ $ch == MONO ]] && ch=FL
    pw-link "$SINK:monitor_$ch" "$p" 2>/dev/null
  done < <(pw-link -i)
  sleep 0.05
done
