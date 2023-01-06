> This still is a bit incomplete, but it works.

Currently following commands work:

- `Q` to list all (documented) commands
  - `Q . help` is similar
- `Q .Q init`
- `Q .Q push params..`
  - `Q .Q verbose push params..`
- `Q .Q run script args..`
  - `Q .Q debug run script args..`
- `Q list`


# Shell Queuing

**Warning!** the `.Q` directory must not be shared over different nodes!


## Usage

	git clone https://github.com/hilbix/dbm.git
	cd dbm
	make
	sudo make install
	cd ..
	git clone --branch=bash https://github.com/hilbix/Q.git
	ln -s --relative Q/Q.sh ~/bin/Q

then

	cd scratchdir
	Q .Q init
	Q .Q run echo

in another terminal:

	Q scratchdir/.Q 1
	Q scratchdir/.Q 2

> **TO SEE THE REALLY IMPLEMENTED FEATURES USE `Q . help`**

Other commands/options:

- `Q . help` gives helps (and terminates)
- `verbose` switch on verbose
- `quiet` be quiet (opposite of verbose)
- `debug` enables debug (cannot be disabled later on)
- `nowait` makes `run` and `one` nonwaiting for entries

General:

- Everything is shell quoted
  - see `printf %q` (from `bash`)
  - hence `eval` is your friend
- `Q .Q list` lists jobs
  - `Q .Q list all` lists all entries in any state
  - `Q .Q list todo` lists all jobs to do
  - `Q .Q list done` lists all successful jobs
  - `Q .Q list fail` lists all failed jobs

Jobs:

- `Q .Q run cmd..` can be run more than once in parallel
  - ENV `Q` is the current queue
  - ENV `Qn` is the retry count
  - ~~ENV `Qd` is associated run-data~~
- `Q .Q one cmd..` same as `Q .Q run` but only runs the `cmd` a single time
  - returns the return code of the `cmd`
  - use `nowait` to inhibit waiting (returns 55 if nothing done)
- Processing of jobs is done in random order
- Already existing jobs cannot be pushed again
  - So you can only push data a single time
  - If this is a problem, add some garbage like the current time (milliseconds) + PID and ignore this additional argument
  - But: Existing jobs can only be retried/rerun of course
- `Q .Q retry val..` retries a job
  - You can also retry a successful job!
  - You can also retry a died job
  - ~~Without argument, a single failed job is retried~~
- `Q .Q kick val..` removes jobs from the todo queue
  - It is the opposite of `push`
- ~~`echo cause | Q hold` to hold back a job~~
  - ~~Note that you can update the information this way, too~~
  - ~~`Q .Q make` to reverse the hold~~
- `Q .Q rm q match val..` removes jobs from queue `q`
  - `q` must one of the existing queues
  - `match` must match the entry of the value (see list q)
  - `match` can contain shell globs, so use `'*'` to ignore that

Setting/Getting values:

- `Q .Q set key val..` sets some key
  - A key cannot be accidentally be changed by this
- `Q .Q get key..` reads the value of the first available key
- ~~`del key val..` deletes a key~~
  ~~- `Q .Q val..` must match from `set`~~
- ~~`Q .Q get key | Q .Q upd key value..` updates a key~~
  - ~~data passed from stdin must match current value~~
  - ~~this is atomic (after stdin was read)~~

Q management:

- ~~`Q .Q lock cause` locks the entire Q~~
  - ~~Everything fails on a locked Q~~
- ~~`Q .Q unlock cause` unlocks the Q~~
  - ~~`cause` must match from `Q .Q lock`~~


## FAQ

WTF why?

- Because I need it

`dbm`?

- Because I do not have anything better yet

License?

- Free as free beer, free speech, free baby
- Must not be covered by any Copyright, though.

