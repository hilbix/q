#!/bin/bash
# vim: ft=bash :
#
# Shell based queuing

exec 3>&2

: 1
STDOUT()	{ local e=$?; printf '%q' "$1"; [ 1 -ge "$#" ] || printf ' %q' "${@:2}"; printf '\n'; return $e; }
STDERR()	{ local e=$?; STDOUT "$@" >&3; return $e; }
VERBOSE()	{ local e=$?; "${VERBOSE:-false}" && STDERR "$@"; return "$e"; }
DEBUG()		{ local e=$?; $DEBUG && STDOUT DEBUG: "$@" >&3; return $e; }
OOPS()		{ STDERR :Q23: OOPS: "$@"; exit 23; }
INTERNAL()	{ OOPS INTERNAL ERROR: $(caller 1): "$@"; }

: 2
x()		{ DEBUG runcmd: "$@"; "$@"; DEBUG code $?: "$@"; }
o()		{ x "$@" || OOPS fail $?: "$@"; }
v()		{ local -n __var_tmp__="$1"; shift && __var_tmp__="$("$@")"; }
i()		{ local e=$?; "$@"; return $e; }

: 3
OK()	{ VERBOSE :Q0: "${@:-ok}"; exit 0; }
KO()	{ VERBOSE :Q1: FAIL: "$@"; exit 1; }
DONE()	{ VERBOSE :Q2: done: "$@"; exit 2; }
EXISTS() { VERBOSE :Q3: exists: "$@"; exit 3; }
RUNNING() { VERBOSE :Q4: running: "$@"; exit 4; }
result() { ( "$@" ); RETVAL=$?; }

: DBM database command args..
DBM()
{
  local d="$Q/Q$1.dbm"

  [ 2 -le "$#" ] || INTERNAL
  x dbm -a-1 "$2" "$d" "${@:3}"
}

# Send a signal() through Qfifo, reviving all those who are in waitfor()
# POSIX says: all readers return after all writers are gone, and vice versa
# (This is the opposite of a lock.)
# LINUX says: open is nonblocking on R+W-fifo, but we cannot rely on that, as it's not guaranteed by POSIX.
# A bit tricky in shells as we lack the option do do some 'nonblocking open'+'nonblocking write':
# Fork a reader in background such that the writer always comes back.
# But me must make sure that we are the only writer, such that our reader does not unlock a different writer.
# Hence we must lock() out all other possible writers while we do this.
: signal
signal()
{
  {
    flock -x 6			# we are the only one here doing this
    ( read <"$Q/Qfifo" & )	# in a weird race, this might stay behind
    : >"$Q/Qfifo"		# comes back thanks to the read above
  } 6<"$Q/Qlock"
}

# We only want to call testcommand until it succeeds
# such that it is only run a single time
: waitfor testcommand args..
waitfor()
{
  local waitbg

  while	x "$@" && return
        $NOWAIT && VERBOSE :Q55: nothing todo && return 55
        read <"$Q/Qfifo" &
        waitbg="$!"
        ! x "$@"
  do
        VERBOSE waiting 'for' "$@"
        wait $waitbg
  done
  # This again is a bit tricky here
  # As there might be a race between testcommand and FiFo
  # we first must open the FiFO and then do the test
  # If we then detect, that the test succeeds
  # we want to remove the read by doing a signal.
#  signal		# needed?
#  wait $bg	# needed?
  :
}

#U init:	initialize Q directory
#U		more commands can follow
: cmd_init
cmd_init()
{
  if [ -d "$Q" ]
  then
        check
        result EXISTS "$Q"
        return
  fi

  [ -e "$Q" ] && OOPS "$Q": already exists
  x mkdir "$Q" || OOPS "$Q": cannot create directory
  for a in "${DIRS[@]}"
  do
        o mkdir "$Q/Q$a"
  done
  for a in "${FIFOS[@]}"
  do
        o mknod "$Q/Q$a" p
  done
  for a in "${LOCKS[@]}"
  do
        o touch "$Q/Q$a"
  done
  for a in "${DBMS[@]}"
  do
        o DBM "$a" create
  done
  result OK created: "$Q"
}

: check N M message: check argument count etc.
check()
{
  local n m
  [ -e "$Q" ] || STDERR perhaps missing: "$0" "$Q" init || OOPS "$Q": does not exist
  [ -d "$Q" ] || OOPS "$Q": not a directory
  for a in "${DIRS[@]}"
  do
        [ -d "$Q/Q$a" ] || OOPS "$Q/Q$a": missing directory
  done
  for a in "${FIFOS[@]}"
  do
        [ -p "$Q/Q$a" ] || OOPS "$Q/Q$a": missing FIFO
  done
  for a in "${LOCKS[@]}"
  do
        [ -f "$Q/Q$a" ] || OOPS "$Q/Q$a": missing lockfile
        if	[ -s "$Q/Q$a" ]
        then
                cat "$Q/Q$a"
                VERBOSE :Q69: locked: "$a"
                exit 69		# Yin-Yang
        fi
  done
  for a in "${DBMS[@]}"
  do
        [ -s "$Q/Q$a.dbm" ] || OOPS "$Q": not a Q directory: missing "$a.dbm"
  done

  [ $ARGS -ge "${1:-0}" ]     || OOPS missing arguments: need $[$1-$ARGS] more arguments
  [ $ARGS -le "${2:-$ARGS}" ] || OOPS too many arguments: not more than "$2" allowed
}

locked()
{
  [ 0 = $# ] || check "$@"
  exec 7<"$Q/Qwait"
  flock 7
}

unlock()
{
  exec 7<&-
}


#U verbose:	enable verbose mode
cmd_verbose()	{ VERBOSE=:; }
#U quiet:	disable verbose mode
cmd_quiet()	{ VERBOSE=false; }
cmd_debug()	{ DEBUG=:; }
cmd_nowait()	{ NOWAIT=:; }
DEFAULT()	{ [ -n "$VERBOSE" ] || case "$1" in (1|true|:|x) VERBOSE=:;; (0|false|-) VERBOSE=false;; (*) INTERNAL "$@";; esac; }

#U set k v:	set key to value
: cmd_set
cmd_set()
{
  locked 2	# we only allow one writer
  printf -vk 'k%q' "$1"
  printf -vv ' %q' "${@:2}"
  DBM data insert "$k" "$v" && OK inserted: "$@"
  o v d DBM data get "$k"
  [ ".$d" = ".$v" ] && EXISTS "$@"
  KO conflict: "$@"
}

#U get key..:	get first set key
: cmd_get
cmd_get()
{
  check 1
  for a
  do
        printf -vk 'k%q' "$a"
        v v DBM data get "$k" || continue
        echo "$v"
        OK found: "$a"
  done
  KO none found: "$@"
}

: cmd_kick values..
cmd_kick()
{
  locked 1
  printf -vd ' %q' "$@"
  o DBM todo delete "$d"
  OK deleted: "$@"
}

: cmd_push values..
cmd_push()
{
  locked 1
  printf -vd ' %q' "$@"
  v k DBM done get "$d" && DONE "$@"
  v k DBM todo get "$d" && EXISTS "$@"
  v k DBM fail get "$d" && KO "$@"
  v k DBM pids get "$d" && RUNNING "$@"
  o DBM todo insert "$d" 0
  signal
  OK added: "$@"
}

something_todo()
{
  v k DBM todo list 2>/dev/null
}

livepid()
{
  local lock= "$Q/Qpids/$1.lock"
  : T.B.D.
#  rm -f "$lock"
}

: cmd_run
cmd_run()
{
  check 1
  DEFAULT true

  lastret=55	# hack
  while	unlock
        waitfor something_todo
  do
        do_run "$@"
        lastret=$?
  done

  exit $lastret
}

: cmd_one
cmd_one()
{
  check 1
  DEFAULT true
  waitfor something_todo && do_run "$@"
  exit
}

do_run()
{
  # assumes something_todo has filled $k
  locked
  v v DBM todo get "$k" || return
  if	v p DBM pids get "$k"
  then
          livepid "${p%% *}" && OOPS stale TODO found 'for' life PID $p	# should not happen, we are locked!  o DBM todo delete "$k" "$v" && continue
          VERBOSE stale PID $p
          o DBM pids delete "$k" "$p"	# stale old (interrupted) entry (normal case)
  fi

  LOCK="$Q/Qpids/$$.pid"
  touch "$LOCK"
  exec 8<"$LOCK"
  flock -nx 8 || OOPS cannot lock "$LOCK"
  {
    o let v1=v+1
    o DBM pids insert "$k" "$$ $v1"
    o DBM todo delete "$k" "$v"
    unlock

    # We now keep the lock given in DBM pids
    # execute processing
    eval "PARAMS=(\"\$@\" $k)"
    VERBOSE run: "${PARAMS[@]}"
    ( Q="$Q" exec -- "${PARAMS[@]}" )
    ret=$?
    VERBOSE result $ret: "${PARAMS[@]}"

    case "$ret" in
    (0)	o DBM done insert "$k" "$[v1]";;
    (*)	o DBM fail insert "$k" "$ret $[v1]";;
    esac
    o DBM pids delete "$k" "$$ $v1"
  } 8<&-
  rm -f "$LOCK"
  exec 8<&-
  return $ret
}

: cmd_list
cmd_list()
{
  RETVAL=2	# empty everything
  do_list done && result OK $cnt successful
  do_list pids && result RUNNING $cnt running
  do_list todo && result EXISTS $cnt queued
  do_list fail && result KO $cnt failed
}

: do_list
do_list()
{
  # dbm is lacking an list0 command to dump k+v, sorry
  cnt=0
  while	IFS=$'\t' read -ru6 k v
  do
        let ++cnt
        printf '%s\t%s\t%s\n'  "$1" "$v" "$k"
  done 6< <({ x DBM "$1" list 0 '' 2>/dev/null && printf '\0'; } | o DBM "$1" bget0 $'\t')
  [ 0 -lt "$cnt" ]
}

: cmd_retry
cmd_retry()
{
  locked 1
  printf -vk ' %q' "$@"
  if	v v DBM fail get "$k"
  then
        o DBM todo insert "$k" "${v#* }"
        o DBM fail delete "$k" "$v"
        signal
        OK retrying: "$@"
  fi
  if	v v DBM 'done' get "$k"
  then
        o DBM  todo  insert "$k" "$v"
        o DBM 'done' delete "$k" "$v"
        signal
        OK redoing: "$@"
  fi
}

: main
main()
{
  local RETVAL= DBMS=(main todo done fail data pids) LOCKS=(lock wait) FIFOS=(fifo) DIRS=(pids)

  v Q readlink -f "$1" || OOPS "$1": invalid or missing path
  shift
  while	CMD="$1"
        shift
  do
        case "$CMD" in
        (*[^a-z]*)	OOPS illegal command: "$CMD";;
        esac
        declare -F "cmd_$CMD" >/dev/null || OOPS unknown command: "$CMD"
        SHIFT=0
        ARGS=$#
        "cmd_$CMD" "$@"
        [ 0 = $SHIFT ] || shift "$SHIFT" || INTERNAL: $SHIFT
  done

  [ -n "$RETVAL" ] || OOPS missing command: try: "$0" help
  exit $RETVAL
}

#U help:	output usage
: cmd_help
cmd_help()
{
  VERBOSE :Q42: help
  case "$0" in
  (*/*.sh)	STDERR perhaps do: ln -s --relative "$0" ~/bin/Q;;
  esac
  cat <<EOF >&3
Usage:	$0 /path/to/Q cmd args..

Examples:

 tty1	Q /some/Q init
 tty1	Q /some/Q push something
 tty2	Q /some/Q run echo hello world

Future:

 tty1	Q /some/Q run cat
 tty2	producer | Q /some/Q pipe | consumer

 tty1	Q /some/Q run cat
 tty2	Q /some/Q in <file

 tty1	Q /some/Q run cat file
 tty2	Q /some/Q out
EOF
  exit 42
}

[ 0 = "$#" ] && cmd_help

VERBOSE=	# default: unspec
DEBUG=false
NOWAIT=false
main "$@"

