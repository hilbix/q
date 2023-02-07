#!/bin/bash
#
# Shell based queuing
#
# vim: ft=bash :

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
WAIT()	{ VERBOSE :Q5: waiting: "$@"; exit 5; }
HOLD()	{ VERBOSE :Q6: on-hold: "$@"; exit 6; }
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
    ( exec 6<&- 0<&- 1<&- 2<&-; read <"$Q/Qfifo" & )	# in a weird race, this might stay behind
    sleep .1			# allow the above shell to run
    : >"$Q/Qfifo"		# comes back thanks to the read above
    flock -u 6
    exec 6<&-
  } 6<"$Q/Qlock"
}

# We only want to call testcommand until it succeeds
# such that it is only run a single time
# BE SURE TO NOT CALL THIS WHILE KEEPING A LOCK
: waitfor testcommand args..
waitfor()
{
  local waitbg

  while	x "$@" && return
        $NOWAIT && VERBOSE :Q55: nothing todo && RETVAL=55 && return 55
        # global Qfifo already created in check()
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
  # (see above, read -t does not help here as execution is done after IO redirection)
  # If we then detect, that the test succeeds
  # we want to remove the read by doing a signal.
  # (It works without, the read terminates on the next signal or cmd_stale)
#  signal		# needed?
  # (wait is not needed as modern bash cleans up zombies even without wait)
#  wait $waitbg		# needed?
  :
}

#U init:	initialize or update Q directory
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
        [ -s "$Q/Q$a.dbm" ] && continue
        [ main = "$a" ] && OOPS "$Q": not a Q directory: missing "$a.dbm"
        [ 0 = $# ] || OOPS "$Q": missing "$a.dbm": try cmd init to upgrade
        # Upgrade
        o DBM "$a" create
  done

  SHIFT="${2:-$ARGS}"
  [ $ARGS -ge "${1:-0}" ] || OOPS missing arguments: need $[$1-$ARGS] more arguments
  [ $ARGS -le "$SHIFT"  ] || OOPS too many arguments: not more than "$2" allowed
  COUNT=0
}

# counts up.  return false if LIMIT reached
: count [N]
count()
{
  let COUNT+="${1:-1}" || :
  [ 0 = "$LIMIT" ] || [ "$COUNT" -lt "$LIMIT" ]
}

ISLOCKED=false
: locked [checkargs]
locked()
{
  [ 0 = $# ] || check "$@"
  exec 7<"$Q/Qwait"
  o flock -x 7
  ISLOCKED=true
}

# Allow others to operate
# this keeps the current exit code unchanged
: unlock
unlock()
{
  local e=$?
  $ISLOCKED || INTERNAL unlock without locked
  ISLOCKED=false
  o flock -u 7
  exec 7<&-
  return $e
}

# must be run after 'locked'
: livepid PID
livepid()
{
  local LOCK="$Q/Qpids/$1.lock"

  $ISLOCKED || INTERNAL livepid without locked
  kill -0 "$1" 2>/dev/null && VERBOSE running PID: "$1" && return		# this check can create false positives
  [ -f "$LOCK" ] || VERBOSE missing PID lock: "$1" || return	# this can happen if PID is reused
  {
        flock -nx 8 || VERBOSE locked PID: "$1" || return 0	# still running
        # stale lock
        VERBOSE stale PID lock: "$1"
        o rm -f "$LOCK"
  } 8<"$LOCK"
  return 1	# PID not live
}


#U verbose:	enable verbose
#U		more commands can follow
cmd_verbose()	{ VERBOSE=:; }
#U quiet:	disable verbose
#U		more commands can follow
cmd_quiet()	{ VERBOSE=false; }
#U debug:	debug output
#U		more commands can follow
cmd_debug()	{ DEBUG=:; }
#U wait:	wait for work to arrive (default)
#U		affected cmds: run one
cmd_wait()     { NOWAIT=false; }
#U nowait:	do not wait for work to arrive (nowait mode)
#U		affected cmds: run one
#U		returns Q55 in case we do not wait
#U		more commands can follow
cmd_nowait()	{ NOWAIT=:; }
#U one:		same as 'limit 1'
cmd_one()	{ LIMIT=1; }
#U all:		same as 'limit 0'
cmd_all()	{ LIMIT=0; }
#U limit N:	limit number of entries to process max
cmd_limit()	{ check 1 1; numeric "$1"; LIMIT="$1"; }
DEFAULT()	{ [ -n "$VERBOSE" ] || case "$1" in (1|true|:|x) VERBOSE=:;; (0|false|-) VERBOSE=false;; (*) INTERNAL "$@";; esac; }

#U set k v..:	set key to values
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

#U get key..:	get values of first set key
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
        count || break
  done
  KO none found: "$@"
}

#U kick val..:	remove single entry (opposite of push)
: cmd_kick entry
cmd_kick()
{
  locked 1
  printf -vd ' %q' "$@"
  o DBM todo delete "$d"
  OK deleted: "$@"
}

#U rm queue match val..:	remove entry from queue
#U	match must match the entry in the db
#U	match can contain shellglobs
#U	Example (the 3 values are separated by TAB):
#U	# Q .Q list fail
#U	fail	127 1	test 123
#U	# Q .Q verbose rm fail '127 1' test 123
: cmd_rm entry
cmd_rm()
{
  VALID=(done todo fail pids post hold oops)

  locked 1

  isvalid "$1" "${VALID[@]}" || VERBOSE :Q23: valid DBs: "${VALID[@]}" || OOPS not a valid DB: "$1"

  printf -vk ' %q' "${@:3}"
  v v DBM "$1" get "$k"	|| KO missing: "${@:3}"
  cmpval "$2" "$v"	|| KO no match: "$v"
  o DBM "$1" delete "$k" "$v"
  OK removed: "$1" "$v" "${@:3}"
}

: numeric value..
numeric()
{
  local a
  for a in "${@:2}"
  do
        case "$a" in
        (*[^0-9]*)	OOPS not numeric: "$a";;
        (0)		;;
        ([1-9]*)	;;
        (*)		OOPS numerics must not start with 0: "$a";;
        esac
  done
}

: not0
not0()
{
  local a

  for a
  do
        [ 0 = "$a" ] && OOPS cannot be 0: "$a"
  done
  numeric "$@"
}

: isvalid value choices..
isvalid()
{
  local a
  for a in "${@:2}"
  do
        [ ".$a" = ".$1" ] && return
  done
  return 1
}


#U push val..:	add values as single entry
#U		fails if entry already known
: cmd_push values..
cmd_push()
{
  locked 1
  printf -vd ' %q' "$@"
  v k DBM done get "$d" && DONE "$@"
  v k DBM todo get "$d" && EXISTS "$@"
  v k DBM fail get "$d" && KO "$@"
  v k DBM pids get "$d" && RUNNING "$@"
  v k DBM post get "$d" && WAIT "$@"
  v k DBM hold get "$d" && HOLD "$@"
  v k DBM oops get "$d" && OOPS "$@"
  o DBM todo insert "$d" 0
  signal
  OK added: "$@"
}

: something_todo
something_todo()
{
  v k DBM todo list 2>/dev/null
}

# output lines of database
# while	IFS=$'\t' read -ru6 k v
# do
#	{
#	..
#	} 6<&-
# done 6< <(feed DATABASE)
: feed DB
feed()
{
  { x DBM "$1" list 0 '' 2>/dev/null && printf '\0'; } | o DBM "$1" bget0 $'\t'
}

#U run cmd args..
#U	- waits for work to arive
#U	- runs: runs cmd args.. val..
#U	Environment:
#U	- Q: the Q name
#U	- Qn: the run count
#U	- Qd: entry associated data (not yet implemented)
: cmd_run
cmd_run()
{
  check 1
  DEFAULT true

  RET=55
  while	waitfor something_todo
  do
        do_run "$@"
        RET=$?
        count || break
  done

  exit $RET
}

# Retired.  Use one run or limit 1 run
##U one cmd args..
##U	like run, but only runs one single entry
#: cmd_one
#cmd_one()
#{
#  check 1
#  DEFAULT true
#  waitfor something_todo && do_run "$@"
#  exit
#}

do_run()
{
  # assumes something_todo has filled $k
  locked
  v v DBM todo get "$k" || unlock || return
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
    # It is correct to run the child without lock
    # as the lock must fall in case we (the parent)
    # get killed.  If the child is not aborted,
    # we have no way to process the result anyway,
    # hence the full processing must be done again.
    # see: cmd_stale
    eval "PARAMS=(\"\$@\" $k)"
    VERBOSE running: "${PARAMS[@]}"
    ( Q="$Q" Qn="$v1" exec -- "${PARAMS[@]}" )
    ret=$?
    VERBOSE finish $ret: "${PARAMS[@]}"

    locked
    #v t DBM next get "$k" || t=''
    # XXX TODO XXX implement next processing
    #[ ".$t" = ".$s" ]

    case "$ret" in
    (0)	o DBM done insert "$k" "$[v1]";;
    # XXX TODO XXX not exactly sure what to do if it already exists
    # This can happen if you interrupt this script at this point
    # and then run "stale" afterwards
    # (which reruns pids, this is moves pids to todo)
    (*)	o DBM fail replace "$k" "$ret $[v1]";;
    esac
    o DBM pids delete "$k" "$$ $v1"
    unlock
  } 8<&-
  rm -f "$LOCK"
  flock -u 8
  exec 8<&-
  return $ret
}

#U list [done pids todo fail post hold oops]
#U	list the entries in the given state
#U	default: done pids todo fail
: cmd_list
cmd_list()
{
  check
  TODO=(pids todo fail)
  DONE=(done "${TODO[@]}")
  OTHER=(wait hold oops)
  MISC=(main data)
  ALL=("${DONE[@]}" "${OTHER[@]}" "${MISC[@]}")
  [ 0 -lt $# ] || set -- "${DONE[@]}"
  RETVAL=2	# nothing listed
  for a
  do
#U	returns Q2 if nothing listed, else:
        case "$a" in
#U	all	list all known states
        (all)	cmd_list "${ALL[@]}";;
#U	undone	list 
        (undone)	cmd_list "${TODO[@]}" "${OTHER[@]}";;
#U	done	Q0 successful
        (done)	do_list done && result OK	$cnt successful;;
#U	pids	Q4 running
        (pids)	do_list pids && result RUNNING	$cnt running;;
#U	todo	Q3 queued
        (todo)	do_list todo && result EXISTS	$cnt queued;;
#U	fail	Q1 failed
        (fail)	do_list fail && result KO	$cnt failed;;
#U	wait	Q5 waiting
        (wait)	do_list post && result WAIT	$cnt waiting;;
#U	hold	Q6 on-hold
        (hold)	do_list hold && result HOLD	$cnt on-hold;;
#U	oops	Q23 oopsed
        (oops)	do_list oops && result OOPS	$cnt oopsed;;
#U	main	(has no return value)
        (main)	do_list main;;
#U	data	(has no return value)
        (data)	do_list data;;
        (*)	OOPS can only list: "${ALL[@]}";;
        esac
        count 0 || break
  done
  exit $RETVAL
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
        count || break
  done 6< <(feed "$1")
  [ 0 -lt "$cnt" ]
}

#U retry val..
#U	retry given entry
#U	see: list fail
#U	see: list done
#U	see: list pids
: cmd_retry entry..
cmd_retry()
{
  locked 1
  printf -vk ' %q' "$@"

  v v DBM fail   get "$k" && retry "$k" "$v"
  v v DBM 'done' get "$k" && redo  "$k" "$v"
  v v DBM pids   get "$1" && rerun "$k" "$v"

  KO not found: "$@"
}

: retry k v
retry()
{
  local k="$1" v="$2" r="${2#* }"
  eval "set -- $k"

  o DBM todo insert "$k" "$r"
  o DBM fail delete "$k" "$v"
  signal
  OK retry "$r:" "$@"
}

: redo k v
redo()
{
  local k="$1" v="$2"
  eval "set -- $k"

  o DBM  todo  insert "$k" "$v"
  o DBM 'done' delete "$k" "$v"
  signal
  OK redo "$v:" "$@"
}

: rerun k v
rerun()
{
  local k="$1" v="$2" p="${2%% *}" r="${2#* }"
  eval "set -- $k"

  livepid "$p" && RUNNING PID "$p:" "$@"
  o DBM todo insert "$k" "$r"
  o DBM pids delete "$k" "$v"
  OK rerun "$r:" "$@"
}

#U stale
#U	requeue stale (killed) processes
#U	more commands can follow
#U	return Q0: no stale entries
#U	return Q2: some stale entries rerun
#U	see: list pids
#U	as a sideffect this signals
: cmd_stale
cmd_stale()
{
  locked

  RETVAL=0
  cnt=0
  stale=0
  while	IFS=$'\t' read -ru6 k v
  do
        let ++cnt
        ( rerun "$k" "$v" ) && RETVAL=2 && let ++stale
        count || break
  done 6< <(feed pids)
  signal
  VERBOSE ":Q$RETVAL:" running=$cnt requeued=$stale
}

#U failed rc count
#U	retry failed entries with the given value
#U	You can give (quoted!) shell globs in rc and count
#U	see: list fail
#U	more commands can follow
: cmd_failed
cmd_failed()
{
  locked 2 2

  RETVAL=0
  cnt=0
  redo=0
  while	IFS=$'\t' read -ru6 k v
  do
        let ++cnt
        r="${v##* }"
        cmpval "$1" "${v%% *}" || continue
        cmpval "$2" "${v##* }" || continue
        ( retry "$k" "$v" )
        RETVAL=2
        let ++redo
        count || break
  done 6< <(feed fail)
  [ 0 = $redo ] || signal
  VERBOSE ":Q$RETVAL:" fail=$cnt retry=$redo
}

# compare value against arg
# arg can contain shell globs
: cmpval arg val
cmpval()
{
  case "$2" in ($1) return 0;; esac
  return 1
}

: main
main()
{
  local RETVAL= DBMS=(main todo done fail data pids next info file post hold oops) LOCKS=(lock wait) FIFOS=(fifo) DIRS=(pids)

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
        [ 0 = $SHIFT ] || shift "$SHIFT" || INTERNAL $SHIFT
  done

  [ -n "$RETVAL" ] || OOPS missing command: try: "$0" . help
  exit $RETVAL
}

#U help:	output usage
: cmd_help
cmd_help()
{
  VERBOSE :Q42: help
  STDERR Usage: $0 /path/to/Q cmd args..
  printf '\n' >&3
  sed -n 's/^#U/# /p' "$0" >&3
  printf '\n' >&3
  case "$0" in
  (*/*.sh)	STDERR perhaps do: ln -s --relative "$0" ~/bin/Q;;
  esac
  exit 42
}


[ 0 = "$#" ] && cmd_help

VERBOSE=	# default: unspec
DEBUG=false
NOWAIT=false
LIMIT=0
main "$@"

# Databases:
#
# Entry is in only one of following:
# todo:		k=entry v=CNT		# CNT initially == 0
# pids:		k=entry v=PID CNT	# CNT incremented from todo
# done:		k=entry v=CNT		# done entries
# fail:		k=entry v=RC CNT	# failed entries
# Not yet implemented:
# post:		k=entry v=CNT		# postprocessing
# hold:		k=entry v=RC CNT	# entries on hold
#
# Entry can be additionally in:
# next:		k=entry v=post		# processing
# data:		k=entry v=data		# associated data
# info:		k=entry v=data		# associated info
# file:		k=entry v=files..	# associated files
# oops:		k=entry v=oops		# permanent fail marker
#
# Processing queue:
# todo =run=> pids =OK=> done
# todo =run=> pids =KO=> fail
#
# done+next => post
# fail+next => hold
#
# Other data:
# data:		k=KEY v=VAL		# set KEY VAL..
# main:		placeholder for now (just an empty database)
#
# CNT is the number how often entry was processed
# PID is the PID of the process which is processing the entry
# RC is the RC from the running command
# KEY is the KEY from set KEY VAL..
# VAL is the list of VALs from set KEY VAL..
#
# Prefixes:
#
# ' ' (SPC)	prefix of "entry" and "VAL"
# k		prefix of KEY from cmds "set"/"get"

