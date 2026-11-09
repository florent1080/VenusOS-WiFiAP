#!/bin/sh
# VenusOS-WiFiAP - bench for the channel follower, to run ON THE GX, as root.
#
#   sh tests/follow_bench.sh [path-to-wifi-ap-run]
#
# The engine is run by hand on the real radio, with a pretended "iw" in front
# of the real one: it answers "iw dev wlan0 link" from a file, so the bench
# decides which channel the WiFi client is "associated" on. Everything else
# is real: wpa_supplicant moves the real AP, and the result is read back from
# the radio. What it cannot show is a real client getting its address after
# a move - that takes a real network on another channel.
#
# It stops the AP service and the watchdog for about five minutes and puts
# them back. The WiFi client must not be connected (the pretended channel
# would contradict the real one). wifi-ap.conf is edited for one step and
# restored.

ENGINE=${1:-$(dirname "$(dirname "$(realpath "$0")")")/files/wifi-ap-run}
T=/run/wifi-ap-bench
LOG=$T/engine.log
CONF=/data/wifi-ap/wifi-ap.conf
CTRL=/run/wifi-ap/ctrl
STA=wlan0
AP=ap0

[ -f /etc/profile.d/profile.sh ] && . /etc/profile.d/profile.sh
REAL_IW=$(command -v iw)

pass=0
fail=0
ok()  { pass=$((pass + 1)); echo "  ok    $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $*"; }
check() {   # check "what" command...
    what=$1; shift
    if "$@" > /dev/null 2>&1; then ok "$what"; else bad "$what"; fi
}

ap_freq()    { wpa_cli -p $CTRL -i $AP status 2>/dev/null | sed -n 's/^freq=//p'; }
ap_state()   { wpa_cli -p $CTRL -i $AP status 2>/dev/null | sed -n 's/^wpa_state=//p'; }
radio_freq() { $REAL_IW dev $AP info 2>/dev/null | sed -n 's/.*channel [0-9]* (\([0-9]*\) MHz.*/\1/p'; }
wpa_running() { ps | grep "wpa_supplicant -i $AP" | grep -v grep > /dev/null; }
nat_rules()  { iptables -t nat -S POSTROUTING | grep -c -- "-s .* ! -d .* -j MASQUERADE"; }
moves()      { grep -c "moving the AP" $LOG; }
uptime_s()   { cut -d. -f1 /proc/uptime; }
station()    { printf %s "$1" > $T/freq; }     # "" = not associated

wait_log() {    # wait_log PATTERN SECONDS
    w=0
    while [ $w -lt "$2" ]; do
        grep -q "$1" $LOG 2>/dev/null && return 0
        sleep 1
        w=$((w + 1))
    done
    return 1
}

epid=""
start_engine() {
    : > $LOG
    PATH="$T/bin:$PATH" "$ENGINE" >> $LOG 2>&1 &
    epid=$!
}
stop_engine() {     # TERM, as supervise does; 0 when it is gone within 15 s
    [ -n "$epid" ] || return 0
    kill "$epid" 2>/dev/null
    w=0
    while kill -0 "$epid" 2>/dev/null; do
        [ $w -ge 15 ] && return 1
        sleep 1
        w=$((w + 1))
    done
    wait "$epid" 2>/dev/null
    epid=""
    return 0
}

ap_was_up=0
wd_was_up=0
cleanup() {
    [ -n "$epid" ] && kill "$epid" 2>/dev/null && sleep 3
    [ -f $T/conf.orig ] && cat $T/conf.orig > $CONF
    rm -rf $T
    [ $wd_was_up -eq 1 ] && svc -u /service/wifi-watchdog 2>/dev/null
    [ $ap_was_up -eq 1 ] && svc -u /service/hostapd 2>/dev/null
}

# --- prerequisites ------------------------------------------------------------
[ "$(id -u)" = "0" ] || { echo "run as root"; exit 2; }
[ -x "$ENGINE" ] || { echo "no engine at $ENGINE"; exit 2; }
[ -n "$REAL_IW" ] || { echo "no iw"; exit 2; }
if $REAL_IW dev $STA link 2>/dev/null | grep -q Connected; then
    echo "the WiFi client ($STA) is connected: disconnect it first"
    exit 2
fi

mkdir -p $T/bin
cat > $T/bin/iw <<EOF
#!/bin/sh
# pretended station, see tests/follow_bench.sh
if [ "\$1" = dev ] && [ "\$2" = "$STA" ] && [ "\$3" = link ]; then
    f=\$(cat $T/freq 2>/dev/null)
    if [ -n "\$f" ]; then
        printf 'Connected to 02:00:00:00:00:01 (on $STA)\n\tSSID: bench\n\tfreq: %s\n' "\$f"
    else
        echo "Not connected."
    fi
    exit 0
fi
exec $REAL_IW "\$@"
EOF
chmod +x $T/bin/iw

trap cleanup EXIT
trap 'exit 130' INT TERM

svstat /service/wifi-watchdog 2>/dev/null | grep -q ": up" && wd_was_up=1
svstat /service/hostapd 2>/dev/null | grep -q ": up" && ap_was_up=1
svc -d /service/wifi-watchdog 2>/dev/null
svc -d /service/hostapd 2>/dev/null
w=0
while wpa_running && [ $w -lt 20 ]; do sleep 1; w=$((w + 1)); done
echo "engine: $ENGINE"
echo "AP service was $([ $ap_was_up -eq 1 ] && echo up || echo down), stopped for the bench"

# --- 1. FOLLOW_STATION=0: the channel chosen at start is kept -----------------
echo "1. FOLLOW_STATION=0"
cat $CONF > $T/conf.orig
{ grep -v '^FOLLOW_STATION=' $T/conf.orig; echo "FOLLOW_STATION=0"; } > $CONF
station 2462
start_engine
check "starts on the station's channel (2462)" wait_log "AP up on 2462 MHz" 30
station 2412
sleep 25
check "station on 2412 for 25 s: no move" [ "$(moves)" = "0" ]
check "AP still on 2462" [ "$(ap_freq)" = "2462" ]
check "engine stops on TERM" stop_engine
check "teardown logged" grep -q "AP stopped" $LOG
check "no wpa_supplicant left on $AP" [ "$(wpa_running && echo y)" = "" ]
check "NAT rule removed" [ "$(nat_rules)" = "0" ]
cat $T/conf.orig > $CONF
rm -f $T/conf.orig

# --- 2. follower --------------------------------------------------------------
echo "2. follower (FOLLOW_STATION absent or 1)"
if grep -q '^FOLLOW_STATION=0' $CONF; then
    echo "  $CONF says FOLLOW_STATION=0: follower steps skipped"
    exit 1
fi
station 2462
start_engine
check "starts on the station's channel (2462)" wait_log "AP up on 2462 MHz" 30
sleep 2
dhcp_pid=$(cat /run/wifi-ap/dnsmasq.pid 2>/dev/null)
check "DHCP server running" kill -0 "$dhcp_pid"

station 2412
t_set=$(uptime_s)
check "station on 2412: AP moves" wait_log "AP up on 2412 MHz (moved from 2462 MHz)" 30
t_move1=$(uptime_s)
echo "        moved $((t_move1 - t_set)) s after the station changed channel"
sleep 2
check "wpa_supplicant reports 2412" [ "$(ap_freq)" = "2412" ]
check "radio reports 2412" [ "$(radio_freq)" = "2412" ]
check "AP state COMPLETED" [ "$(ap_state)" = "COMPLETED" ]
check "$AP kept its address" sh -c "ip -4 addr show $AP | grep -q 'inet '"
check "same DHCP server still running" [ "$(cat /run/wifi-ap/dnsmasq.pid 2>/dev/null)" = "$dhcp_pid" ]
check "DHCP server alive" kill -0 "$dhcp_pid"
check "one NAT rule" [ "$(nat_rules)" = "1" ]

station 2437
sleep 30
check "second change within a minute: held back" [ "$(moves)" = "1" ]
check "then moved to 2437" wait_log "AP up on 2437 MHz (moved from 2412 MHz)" 50
t_move2=$(uptime_s)
check "two moves at least 55 s apart ($((t_move2 - t_move1)) s)" [ $((t_move2 - t_move1)) -ge 55 ]

station 5500
check "DFS channel: said so" wait_log "station on DFS channel (5500 MHz)" 20
sleep 6
check "DFS channel: AP stays on 2437" [ "$(ap_freq)" = "2437" ]
check "DFS channel: no move" [ "$(moves)" = "2" ]

station 5220
if wait_log "5220 MHz (moved from 2437 MHz)\|AP refused on 5220 MHz" 100; then
    sleep 3
    if grep -q "AP refused on 5220 MHz" $LOG; then
        echo "        5 GHz: the AP is REFUSED on 5220 MHz on this radio/regulatory domain"
        check "refused: AP back on 2437" [ "$(ap_freq)" = "2437" ]
        check "refused: AP state COMPLETED" [ "$(ap_state)" = "COMPLETED" ]
        sleep 75
        check "refused: 5220 not tried again" [ "$(grep -c 'AP on 2437 MHz: moving' $LOG)" = "1" ]
        last=2437
    else
        echo "        5 GHz: the AP runs on 5220 MHz"
        check "5 GHz: wpa_supplicant reports 5220" [ "$(ap_freq)" = "5220" ]
        check "5 GHz: radio reports 5220" [ "$(radio_freq)" = "5220" ]
        check "5 GHz: AP state COMPLETED" [ "$(ap_state)" = "COMPLETED" ]
        last=5220
    fi
else
    bad "5220: neither moved nor refused within 100 s"
    last=$(ap_freq)
fi
check "$AP still has its address" sh -c "ip -4 addr show $AP | grep -q 'inet '"
check "DHCP server alive" kill -0 "$(cat /run/wifi-ap/dnsmasq.pid 2>/dev/null)"

n_moves=$(moves)
station ""
sleep 15
check "station gone: AP stays on $last" [ "$(ap_freq)" = "$last" ]
check "station gone: no move" [ "$(moves)" = "$n_moves" ]

kill $(ps | grep "wpa_supplicant -i $AP" | grep -v grep | awk '{print $1}') 2>/dev/null
check "wpa_supplicant killed: engine notices" wait_log "wpa_supplicant exited" 15
w=0
while kill -0 "$epid" 2>/dev/null && [ $w -lt 15 ]; do sleep 1; w=$((w + 1)); done
check "... and exits (supervise would restart it)" [ "$(kill -0 "$epid" 2>/dev/null && echo y)" = "" ]
epid=""
check "teardown logged" grep -q "AP stopped" $LOG
check "NAT rule removed" [ "$(nat_rules)" = "0" ]

echo "--- engine log of the follower run"
cat $LOG
echo "---"
echo "passed: $pass   failed: $fail"
[ $fail -eq 0 ]
