# in-game test helpers: source this
HW="/c/Program Files (x86)/Steam/steamapps/common/SurrounDead/SurrounDead/Binaries/Win64"
GW="/c/Program Files (x86)/Steam/steamapps/common/SurrounDead_Guest/SurrounDead/Binaries/Win64"
HL="$HW/ue4ss/UE4SS.log"; GL="$GW/ue4ss/UE4SS.log"
SD="$LOCALAPPDATA/SurrounDead"
# cmd host|guest "<command>"
cmd() { local f; [ "$1" = host ] && f="$SD/mirror_dev_Saved.txt" || f="$SD/mirror_dev_Saved_Guest.txt"; printf '%s\n' "$2" > "$f"; }
# waitlog host|guest <regex> <secs>  -> prints the matching line or TIMEOUT
waitlog() { local l; [ "$1" = host ] && l="$HL" || l="$GL"; for i in $(seq 1 $3); do m=$(grep -a -E "$2" "$l" 2>/dev/null | tail -1); [ -n "$m" ] && { echo "$1: ${m:0:220}"; return 0; }; sleep 1; done; echo "$1: TIMEOUT waiting for $2"; return 1; }
# since <host|guest> <regex>: matching lines (trimmed)
lines() { local l; [ "$1" = host ] && l="$HL" || l="$GL"; grep -a -E "$2" "$l" | cut -c30-260 | tail -${3:-15}; }
# launch <dir> <extra args> [left|right]: windowed, no splash, then placed on that half of the screen
launch() {
  local pid=$(powershell -NoProfile -Command "(Start-Process -PassThru -FilePath '$(cygpath -w "$1")\SurrounDead-Win64-Shipping.exe' -WorkingDirectory '$(cygpath -w "$1")' -ArgumentList @($2'-windowed','-nosplash','-ResX=960','-ResY=1000')).Id" | tr -dc '0-9')
  [ -n "$3" ] && powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$(dirname "${BASH_SOURCE[0]}")/place.ps1")" "${pid:-0}" "$3" > "$SD/place_$3.log" 2>&1 &
}
# free commit (GB) - two games need ~15 GB: the commit limit (RAM + pagefile) hangs a loading game when hit
commit_free() { powershell -NoProfile -Command "\$m=Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory; [math]::Floor((\$m.CommitLimit-\$m.CommittedBytes)/1GB)"; }
# refuse to start when memory is short: prints the biggest programs to close instead
preflight() {
  local need=${1:-15} free=$(commit_free | tr -d '\r ')
  if [ "$free" -lt "$need" ]; then
    echo "PREFLIGHT: only $free GB commit free (need $need). Close some of these or enlarge the pagefile:"
    powershell -NoProfile -Command "Get-Process | sort PagedMemorySize64 -desc | select -first 8 ProcessName,@{n='GB';e={[math]::Round(\$_.PagedMemorySize64/1GB,1)}} | ft -auto | Out-String"
    return 1
  fi
  echo "preflight: $free GB commit free"
}
# FAST: wait for events, not fixed sleeps.  mark host|guest = remember where its log ends now;
# waitnew host|guest <regex> <secs> = first match written after the mark (prints it, or TIMEOUT)
mark() { local l; [ "$1" = host ] && l="$HL" || l="$GL"; eval "M_$1=$(wc -l < "$l" 2>/dev/null || echo 0)"; }
waitnew() {
  local l n; [ "$1" = host ] && l="$HL" || l="$GL"; eval "n=\${M_$1:-0}"
  for i in $(seq 1 $(( $3 * 4 ))); do
    m=$(tail -n +$((n + 1)) "$l" 2>/dev/null | grep -a -E -m1 "$2"); [ -n "$m" ] && { echo "$1: ${m:60:200}"; return 0; }
    sleep 0.25
  done; echo "$1: TIMEOUT waiting for $2"; return 1
}
# do <host|guest> "<cmd>" <regex> [secs]: send a dev command and wait for its result line
do_() { mark "$1"; cmd "$1" "$2"; waitnew "$1" "$3" "${4:-30}"; }
# start_one host|guest: launch that game, load its test save, god on. 0 = loaded. A load sometimes hangs on the
# title screen: no player 45 s after the load started -> that game is killed and started once more.
start_one() {
  local r=$1 dir args slot side pid
  if [ "$r" = host ]; then dir="$HW"; args=""; slot=QuickSave110649_26Jul2026; side=left
  else dir="$GW"; args="'-saveddirsuffix=Guest',"; slot=QuickSave111214_22Jul2026; side=right; fi
  for try in 1 2; do
    mark $r; launch "$dir" "$args" $side
    waitnew $r "devtest: watching" 90 >/dev/null && cmd $r "continue $slot"
    waitnew $r "devtest: load " 60 >/dev/null
    if waitnew $r "real player is|new real player" 45 >/dev/null; then do_ $r god "devtest: god" 20; return 0; fi
    echo "SETUP: $r load hung - restarting it"
    powershell -NoProfile -Command "Get-Process SurrounDead-Win64-Shipping -ea 0 | ? { (\$_.Path -like '*_Guest*') -eq ('$r' -eq 'guest') } | Stop-Process -Force" >/dev/null 2>&1
    sleep 3
  done
  echo "SETUP: $r never loaded"; return 1
}
# fresh games in their saves, immune, host hosting (~30 s; a hung load costs one restart of that game)
setup() {
  taskkill //IM SurrounDead-Win64-Shipping.exe //F >/dev/null 2>&1
  taskkill //IM SurrounSyncBridge.exe //F >/dev/null 2>&1      # orphaned connectors (one PC: they never see their game go)
  preflight ${NEED_GB:-15} || return 1
  rm -f "$SD/mirror_dev_Saved.txt" "$SD/mirror_dev_Saved_Guest.txt"
  : > "$HL" 2>/dev/null; : > "$GL" 2>/dev/null; M_host=0; M_guest=0
  start_one host & local hp=$!
  sleep 2; start_one guest; wait $hp
  do_ host host "phase1: told the other game I'm host|devtest: 'host'" 20
}
# guest joins the host and is in its world
# (the guest's home spot blocks saving - zombies: it moves 40 m first and drops in; god mode keeps it alive)
join() {
  do_ guest "tp 40 0" "devtest: tp" 10 >/dev/null; sleep 6
  do_ guest clearz "clearz removed" 10 >/dev/null
  # (connector security: the host answers the join request - like clicking ACCEPT in the CO-OP tab)
  ( for i in $(seq 1 120); do
      id=$(grep -a -o "^request [0-9]*" "$SD/Link_Host/mirror_lobby.txt" 2>/dev/null | head -1 | cut -d' ' -f2)
      [ -n "$id" ] && { cmd host "accept $id"; echo "host: accepted join request $id (through the menu)"; break; }
      sleep 0.5
    done ) &
  do_ guest join "session: joined|session: .*fail|couldn't" 150
}
# restart the host into its save, god on
host_up() {
  taskkill //IM SurrounDead-Win64-Shipping.exe //F >/dev/null 2>&1; taskkill //IM SurrounSyncBridge.exe //F >/dev/null 2>&1; sleep 3
  launch "$HW" "" left; sleep 8; until grep -a "devtest: watching" "$HL" | tail -1 | grep -q "$(date +%H:%M)"; do sleep 2; done
  cmd host "god"; sleep 28; local n0=$(wc -l < "$HL"); cmd host "continue QuickSave110649_26Jul2026"
  until tail -n +$n0 "$HL" | grep -aq "real player is"; do sleep 2; done; sleep 6
}
