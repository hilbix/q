> This currently is terribly incomplete!
>
> Many commands noted below are missing today!
> For implemented commands see:
>
>     sed -n 's/^cmd_\([^(]*\)(.*$/\1/p' Q.sh | sort

Currently following commands work:

- `Q .Q init`
- `Q .Q push params..`
  - `Q .Q verbose push params..`
- `Q .Q run script args..`
  - `Q .Q debug run script args..`

So basically everything important works.

Not yet implemented:

- Management commands (like `list`)
- Resume/Retry/Restart of interrupted/failed commands


# Shell Queuing

**Warning!** .Q data must not be shared over different nodes!


## Usage

	git clone https://github.com/hilbix/dbm.git
	cd dbm
	make
	sudo make install
	cd ..
	git clone https://github.com/hilbix/Q.git
	ln -s --relative Q/Q.sh ~/bin/Q

then

	cd scratchdir
	Q .Q init
	Q .Q run echo

in another terminal:

	Q scratchdir/.Q 1
	Q scratchdir/.Q 2

> **Many commands below are planned only!**

Other commands/options:

- `help` gives helps (and terminates)
- `verbose` switch on verbose
- `quiet` be quiet (opposite of verbose)
- `debug` enables debug (cannot be disabled later on)

General:

- Everything is shell quoted
  - see `printf %q` (from `bash`)
  - hence `eval` is your friend
- `Q .Q list` lists all jobs
  - `Q .Q todo` lists all pending jobs
  - `Q .Q done` lists all successful jobs
  - `Q .Q fail` lists all failed jobs
  - `Q .Q held` lists all held jobs

Jobs:

- `Q .Q run` can be run more than once in parallel
  - The command gets the current `Q` in the environment
- `Q .Q one` same as `Q .Q run` but only runs the command a single time
  - returns the return code of the command run
  - use `nowait` to inhibit waiting
- Processing of jobs is done in random order
- Already existing jobs cannot be pushed again
  - So you can only push data a single time
  - If this is a problem, add some garbage like the current time (milliseconds) + PID and ignore this arg
- `Q .Q retry` retries a job
  - You can also retry a successful job!
  - Without argument, a single failed job is retried
- `Q .Q kill` removes jobs
  - `Q .Q pull` removes only successful jobs
  - `Q .Q pull` without job pulls just one successful job
- `echo cause | Q hold` to hold back a job
  - Note that you can update the information this way, too
  - `Q .Q make` to reverse the hold

Setting/Getting values:

- `Q .Q set key value..` sets some key
  - A key cannot be accidentally be changed by this
- `Q .Q get key..` reads the value of the first available key
- `del key value..` deletes a key
  - `Q .Q value..` must match from `set`
- `Q .Q get key | Q .Q upd key value..` updates a key
  - data passed from stdin must match current value
  - this is atomic (after stdin was read)

Q management:

- `Q .Q lock cause` locks the entire Q
  - Everything fails on a locked Q
- `Q .Q unlock cause` unlocks the Q
  - `cause` must match from `Q .Q lock`

