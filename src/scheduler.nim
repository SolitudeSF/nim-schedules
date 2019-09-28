##
## Basic Concepts
##
##
import threadpool
import asyncdispatch
import asyncfutures
import times
import options

type
  BeaterKind* {.pure.} = enum
    bkInterval
    bkCron

  Beater* = ref object of RootObj ## Beater generates beats for the next runs.
    startTime: DateTime
    endTime: Option[DateTime]
    case kind*: BeaterKind
    of bkInterval:
      interval*: TimeInterval
    of bkCron:
      expr*: string # TODO, parse `* * * * *`

proc `$`*(beater: Beater): string =
  case beater.kind
  of bkInterval:
    "Beater(" & $beater.kind & "," & $beater.interval & ")"
  of bkCron:
    "Beater(" & $beater.kind & "," & beater.expr & ")"

proc initBeater*(
  interval: TimeInterval,
  startTime: Option[DateTime] = none(DateTime),
  endTime: Option[DateTime] = none(DateTime),
): Beater =
  ## Initialize a Beater, which kind is bkInterval.
  ##
  ## startTime and endTime are optional.
  Beater(
    kind: bkInterval,
    interval: interval,
    startTime: if startTime.isSome: startTime.get() else: now(),
    endTime: endTime,
  )

proc fireTime*(
  self: Beater,
  prev: Option[DateTime],
  now: DateTime
): Option[DateTime] =
  ## Returns the next fire time of a task execution.
  ##
  ## For bkInterval, it has below rules:
  ##
  ## * For the 1st run,
  ##   * Choose `startTime` if it hasn't come.
  ##   * Choose the next `startTime + N * interval` that hasn't come.
  ## * For the rest of runs,
  ##   * Choose `prev + interval`.
  result = some(
    if prev.isNone:
      if self.startTime >= now:
        self.startTime
      else:
        let passed = cast[int](now.toTime.toUnix - self.startTime.toTime.toUnix)
        let intervalLen = cast[int]((0.fromUnix + self.interval).toUnix)
        let leftSec = intervalLen - passed mod intervalLen
        now + initTimeInterval(seconds=leftSec)
    else:
      prev.get() + self.interval
  )

  if self.endTime.isSome and result.get() > self.endTime.get():
    result = none(DateTime)

type
  RunnerKind* = enum
    rkAsync,
    rkThread

  RunnerBase* = ref object of RootObj ## Untyped runner.

  Runner*[TArg] = ref object of RunnerBase
    case kind*: RunnerKind
    of rkAsync:
      when TArg is void:
        asyncFn: proc (): Future[void] {.nimcall.}
      else:
        asyncFn: proc (arg: TArg): Future[void] {.nimcall.}
        asyncArg: TArg
    of rkThread:
      when TArg is void:
        threadFn: proc () {.nimcall, gcsafe.}
      else:
        threadFn: proc (arg: TArg) {.nimcall, gcsafe.}
        threadArg: TArg

proc initThreadRunner*(
  fn: proc() {.thread, nimcall.},
): Runner[void] =
  Runner[void](kind: rkThread, threadFn: fn)

proc initThreadRunner*[TArg](
  fn: proc(arg: TArg) {.thread, nimcall.},
  arg: TArg,
): Runner[TArg] =
  Runner[TArg](kind: rkThread, threadFn: fn, threadArg: arg)

proc initAsyncRunner*(
  fn: proc(): Future[void] {.nimcall.},
): Runner[void] =
  Runner[void](kind: rkAsync, asyncFn: fn)

proc initAsyncRunner*[TArg](
  fn: proc(): Future[TArg] {.nimcall.},
  arg: TArg,
): Runner[TArg] =
  Runner[TArg](kind: rkAsync, asyncFn: fn, asyncArg: arg)

#proc run*[TArg](runner: Runner[TArg]) =
  #when TArg is void:
    #createThread(runner.thread, runner.fn)
  #else:
    #createThread(runner.thread, runner.fn, runner.arg)

#proc run*[TArg](runner: AsyncRunner[TArg]) {.async.} =
  #var fut = when TArg is void:
    #fut = runner.fn()
  #else:
    #fut = runner.fn(runner.arg)
  #runner.future = fut
  #yield fut

#proc running*[TArg](runner: ThreadRunner[TArg]) =
  #runner.thread.running

#proc running*[TArg](runner: AsyncRunner[TArg]) =
  #not (runner.future.finished or runner.future.failed)

type
  TaskBase* = ref object of RootObj ## Untyped Task.
    id: string # The unique identity of the task.
    description: string # The description of the task.
    beater: Beater # The schedule of the task.
    runner: RunnerBase # The runner of the task.
    ignoreDue: bool # Whether to ignore due task executions.
    maxDue: Duration # The max duration the task is allowed to due.
    parallel: int # The maximum number of parallel running task executions.
    fireTime: Option[DateTime] # The next scheduled run time.

  ThreadedTask*[TArg] = ref object of TaskBase
    thread: Thread[TArg] # deprecated
    when TArg is void:
      fn: proc () {.nimcall, gcsafe.}
    else:
      fn: proc (arg: TArg) {.nimcall, gcsafe.}
      arg: TArg

  AsyncTask*[TArg] = ref object of TaskBase
    future: Future[void]
    when TArg is void:
      fn: proc (): Future[void] {.nimcall.}
    else:
      fn: proc (arg: TArg): Future[void] {.nimcall.}
      arg: TArg

proc newThreadedTask*(fn: proc() {.thread, nimcall.}, beater: Beater, id=""): ThreadedTask[void] =
  var thread: Thread[void]
  return ThreadedTask[void](
    id: id,
    thread: thread,
    fn: fn,
    beater: beater,
    fireTime: none(DateTime),
  )

proc newThreadedTask*[TArg](
  fn: proc(arg: TArg) {.thread, nimcall.},
  arg: TArg,
  beater: Beater,
  id=""
): ThreadedTask[TArg] =
  var thread: Thread[TArg]
  return ThreadedTask[TArg](
    id: id,
    thread: thread,
    fn: fn,
    arg: arg,
    beater: beater,
    fireTime: none(DateTime),
  )

proc newAsyncTask*(
  fn: proc(): Future[void] {.nimcall.},
  beater: Beater,
  id=""
): AsyncTask[void] =
  var future = newFuture[void](id)
  result = AsyncTask[void](
    id: id,
    future: future,
    fn: fn,
    beater: beater,
    fireTime: none(DateTime),
  )

proc newAsyncTask*[TArg](
  fn: proc(arg: TArg): Future[void] {.nimcall.},
  arg: TArg,
  beater: Beater,
  id=""
): AsyncTask[TArg] =
  var future = newFuture[void](id)
  result = AsyncTask[TArg](
    id: id,
    future: future,
    fn: fn,
    arg: arg,
    beater: beater,
    fireTime: none(DateTime),
  )

proc fire*(task: ThreadedTask[void]) =
  createThread(task.thread, task.fn)

proc fire*[TArg](task: ThreadedTask[TArg]) =
  createThread(task.thread, task.fn, task.arg)

proc fire*(task: AsyncTask[void]) {.async.} =
  var fut = task.fn()
  task.future = fut
  yield fut
  if fut.failed:
    echo("AsyncTask " & task.id & " fire failed.")

proc fire*[TArg](task: AsyncTask[TArg]) {.async.} =
  var fut = task.fn(task.arg)
  task.future = fut
  yield fut
  if fut.failed:
    echo("AsyncTask " & task.id & " fire failed.")

type
  Scheduler* = ref object of RootObj ## Scheduler acts as an event loop and schedules all the tasks.

type
  AsyncScheduler* = ref object of Scheduler

proc tick(since: DateTime) {.thread.} =
  echo(now() - since)

proc tick2() {.thread.} =
  echo(now())

proc atick() {.async.} =
  await sleepAsync(1000)
  echo("async tick")

proc start(self: AsyncScheduler) {.async.} =
  let beater = initBeater(interval=TimeInterval(seconds: 1))
  let task = newThreadedTask[DateTime](tick, now(), beater=beater)
  let atask = newAsyncTask(atick, beater=beater)
  #let task = newThreadedTask(tick2, beater)
  var prev = now()
  while true:
    asyncCheck atask.fire()
    task.fire()
    await sleepAsync(1000)
    prev = now()

#let sched = AsyncScheduler()
#asyncCheck sched.start()
#runForever()
