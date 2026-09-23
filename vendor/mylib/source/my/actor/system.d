/**
Copyright: Copyright (c) 2021, Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)
*/
module my.actor.system;

import core.sync.condition : Condition;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import logger = std.experimental.logger;
import std.algorithm : min, max, clamp;
import std.datetime : dur, Clock, Duration;
import std.parallelism : Task, TaskPool, task;

import my.optional;

public import my.actor.actor : ActorShell, makePromise, Promise, scopedActor, ErrorMsg;
public import my.actor.mailbox : Address, makeAddress, StrongAddress, TypedAddress, WeakAddress;
public import my.actor.msg;
import my.actor.common;
import my.actor.memory : ActorAlloc;
import my.actor.registration : implActor;

System makeSystem(TaskPool pool) @safe {
    return System(pool, false);
}

System makeSystem() @safe {
    return System(new TaskPool, true);
}

struct SystemConfig {
    static struct Scheduler {
        // number of messages each actor is allowed to consume per scheduled run.
        Optional!ulong maxThroughput;
        // how long a worker sleeps before polling the actor queue.
        Optional!Duration pollInterval;
    }

    Scheduler scheduler;
}

struct System {
    private {
        bool running;
        bool ownsPool;
        TaskPool pool;
        Backend bg;
    }

    @disable this(this);

    this(TaskPool pool, bool ownsPool) @safe {
        this(SystemConfig.init, pool, ownsPool);
    }

    /**
     * Params:
     *  pool = thread pool to use for scheduling actors.
     */
    this(SystemConfig conf, TaskPool pool, bool ownsPool) @safe {
        this.pool = pool;
        this.ownsPool = ownsPool;
        this.bg = Backend(new Scheduler(conf.scheduler, pool));

        this.running = true;
        this.bg.start(pool, pool.size);
    }

    ~this() @safe {
        shutdown;
    }

    /// Shutdown all actors as fast as possible.
    void shutdown() @safe {
        if (!running)
            return;

        bg.shutdown;
        if (ownsPool)
            pool.finish(true);
        pool = null;

        running = false;
    }

    /// Wait for all actors to finish (terminate) before returning.
    void wait() @safe {
        if (!running)
            return;

        bg.shutdown;
        if (ownsPool)
            pool.finish(true);
        pool = null;

        running = false;
    }

    /// spawn a plain-class actor; the ctor runs first (on the calling thread),
    /// then wiring, then the launch (onSpawn) on first execution.
    /// If the ctor or wiring throws, the allocated shell is disposed and the
    /// exception propagates. Returns the typed address, which pairs with
    /// `Channel!I` at compile time.
    TypedAddress!T spawn(T, Args...)(auto ref Args args) if (is(T == class)) {
        auto actor = bg.alloc.make(makeAddress);
        T instance;
        try {
            instance = () @trusted { return new T(args); }();
            implActor(instance, actor);
            schedule(actor);
        } catch (Throwable e) {
            // the ctor or wiring threw before the actor entered the scheduler:
            // run the shell down to stopped and dispose it through the
            // scheduler's own path so nothing leaks.
            actor.forceShutdown;
            while (actor.isAlive)
                actor.process(Clock.currTime);
            bg.alloc.dispose(actor);
            throw e;
        }
        return TypedAddress!T(actor.addr);
    }

    // schedule an actor for execution in the thread pool.
    // Returns: the address of the actor.
    private WeakAddress schedule(ActorShell* actor) @safe {
        assert(bg.scheduler.isActive);
        setHomeSystem(actor);
        bg.scheduler.putWaiting(actor);
        return actor.address;
    }

    // set the homesystem of the actor. this is safe on the assumption that the
    // actor system is the last to terminate.
    private void setHomeSystem(ActorShell* actor) @trusted {
        actor.setHomeSystem(&this);
    }
}

@("shall start an actor system, execute an actor and shutdown")
@system unittest {
    import my.actor.channel : dynSend;
    import my.gc.refc : RefCounted, refCounted;

    static class RunCounter {
        RefCounted!int executed42;

        this(RefCounted!int counter) {
            executed42 = counter;
        }

        void run(int x) {
            if (x == 42)
                executed42.get++;
        }
    }

    auto sys = makeSystem;

    auto counter = refCounted(0);
    auto addr = sys.spawn!RunCounter(counter);
    dynSend(addr.weakRef, "run", 42);
    dynSend(addr.weakRef, "run", 43);

    const failAfter = Clock.currTime + 3.dur!"seconds";
    const start = Clock.currTime;
    while (counter.get == 0 && Clock.currTime < failAfter) {
    }
    const td = Clock.currTime - start;

    assert(counter.get == 1);
    assert(td < 3.dur!"seconds");
}

@("shall be possible to send a message to self during construction")
@system unittest {
    import my.actor.behavior : ActorRef;
    import my.actor.channel : dynSend;
    import my.gc.refc : RefCounted, refCounted;

    static class SelfSender {
        private ActorRef self_;
        private RefCounted!int executed42;

        this(RefCounted!int counter) {
            executed42 = counter;
        }

        void onSpawn(ActorRef self) @safe {
            self_ = self;
            // send a message to self while the actor is starting up.
            dynSend(self_.address, "run", 42);
        }

        void run(int x) {
            if (x == 42)
                executed42.get++;
        }
    }

    auto sys = makeSystem;

    auto counter = refCounted(0);
    auto addr = sys.spawn!SelfSender(counter);
    dynSend(addr.weakRef, "run", 42);
    dynSend(addr.weakRef, "run", 43);

    const failAfter = Clock.currTime + 3.dur!"seconds";
    while (counter.get < 2 && Clock.currTime < failAfter) {
    }

    assert(counter.get == 2);
}

@("shall spawn two typed actors which are connected, execute and shutdow")
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.typecons : Tuple;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : dynRequest;

    static class A1 {
        int plus10(int a) {
            return a + 10;
        }
    }

    static class A2 {
        private ActorRef self_;
        private WeakAddress a1_;

        this(WeakAddress a1) @safe {
            a1_ = a1;
        }

        void onSpawn(ActorRef self) @safe {
            self_ = self;
        }

        static void deliverPromise(ref Tuple!(Promise!int, "p") ctx, int a) {
            ctx.p.deliver(a);
        }

        Promise!int chain(int x) {
            auto p = makePromise!int;
            dynRequest(self_, a1_, infTimeout(), "plus10", x + 10).capture(p)
                .then(&deliverPromise);
            return p;
        }
    }

    auto sys = makeSystem;

    auto a1 = sys.spawn!A1();
    auto a2 = sys.spawn!A2(a1.weakRef);

    // a manually driven client kernel; the reply handler runs on this thread.
    auto client = ActorShell(makeAddress);
    int ok = 0;
    // start msg to a2 which pass it on to a1.
    static void onOk(ref Tuple!(int*, "ok") ctx, int x) {
        *ctx[0] = x;
    }

    dynRequest(ActorRef(&client), a2.weakRef, infTimeout(), "chain", 10).capture(&ok).then(&onOk);

    auto sw = StopWatch(AutoStart.yes);
    while (ok != 30 && sw.peek < 3.dur!"seconds") {
        client.process(Clock.currTime);
        Thread.sleep(1.dur!"msecs");
    }

    assert(ok == 30);
}

@("shall spawn actor using user provided context and keep the values")
@system unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.typecons : Tuple;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : Channel;

    class AClassWithInnerPtr {
        int* v;
        this(int v) {
            this.v = new int;
            *this.v = v;
        }
    }

    static void onTick(ref Tuple!(bool*, "isCalled") ctx, int x) {
        assert(x == 42);
        *ctx[0] = true;
    }

    static class A1 {
        AClassWithInnerPtr inner;

        this(AClassWithInnerPtr c) @safe {
            inner = c;
        }

        int tick(int s) @safe {
            assert(inner !is null);
            assert(inner.v !is null);
            assert(*inner.v == s);
            return *inner.v;
        }
    }

    auto sys = makeSystem;

    auto inner = new AClassWithInnerPtr(42);
    // the spawn handle is stored typed; the channel pairs with it at compile time.
    TypedAddress!A1[] actors;
    foreach (_; 0 .. 10)
        actors ~= sys.spawn!A1(inner);

    foreach (a1; actors) {
        // a fresh, manually driven client kernel per request.
        auto client = ActorShell(makeAddress);
        bool isCalled = false;
        Channel!A1(a1, ActorRef(&client), infTimeout()).tick(42).capture(&isCalled).then(&onTick);

        auto sw = StopWatch(AutoStart.yes);
        while (!isCalled && sw.peek < 3.dur!"seconds") {
            client.process(Clock.currTime);
            Thread.sleep(1.dur!"msecs");
        }
        assert(isCalled);
    }

    foreach (a; actors)
        sendExit(a, ExitReason.userShutdown);
}

@("plain-class actor shall run the onExit hook on the system shutdown message")
@system unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import my.actor.system_msg : ExitMsg;
    import my.gc.refc : RefCounted, refCounted;

    static class ExitProbe {
        private RefCounted!bool exited;

        this(RefCounted!bool e) {
            exited = e;
        }

        void onExit(ExitMsg msg) {
            exited.get = true;
        }
    }

    auto sys = makeSystem;

    auto exited = refCounted(false);
    auto addr = sys.spawn!ExitProbe(exited);
    sendExit(addr, ExitReason.userShutdown);

    auto sw = StopWatch(AutoStart.yes);
    while (!exited.get && sw.peek < 3.dur!"seconds")
        Thread.sleep(1.dur!"msecs");

    assert(exited.get, "onExit ran when the shutdown message arrived");
    sys.shutdown;
}

@("plain-class actor ctor runs inside spawn! and onSpawn before the first message")
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.string : startsWith;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : dynSend;
    import my.gc.refc : RefCounted, refCounted;

    // The log is shared through RefCounted so the test thread can read what
    // the actor's context appends. The ctor runs on the spawning thread
    // inside spawn! and records "ctor;" first; the launch hook and the first
    // message then append, in order, on the actor's context, so the final
    // "ctor;onSpawn;msg;" is only reachable if all three ran in that order.
    static class LifecycleLog {
        private RefCounted!string log;

        this(RefCounted!string log) {
            this.log = log;
            this.log.get ~= "ctor;"; // runs on the spawning thread, inside spawn!
        }

        void onSpawn(ActorRef self) {
            log.get ~= "onSpawn;"; // first execution, on the actor's own context
        }

        void ping() {
            log.get ~= "msg;"; // first message, after onSpawn
        }
    }

    auto sys = makeSystem;

    auto log = refCounted("");
    auto addr = sys.spawn!LifecycleLog(log);

    // the ctor ran synchronously on this thread, inside spawn!. onSpawn may
    // already have appended by now (it launches on the worker's first
    // execution), but the ctor's prefix is always first.
    assert(startsWith(log.get, "ctor;"), "ctor runs inside spawn!: " ~ log.get);

    dynSend(addr.weakRef, "ping");

    const expect = "ctor;onSpawn;msg;";
    auto sw = StopWatch(AutoStart.yes);
    while (log.get != expect && sw.peek < 3.dur!"seconds")
        Thread.sleep(1.dur!"msecs");

    assert(log.get == expect, "onSpawn ran before the first message was processed: " ~ log.get);
    sys.shutdown;
}

@("spawn a plain-class actor and talk to it")
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import std.typecons : Tuple;
    import my.actor.behavior : ActorRef;
    import my.actor.channel : Channel;

    auto sys = makeSystem;

    static class Counter {
        int value;
        void add(int v) @safe {
            value += v;
        }

        int total() @safe {
            return value;
        }
    }

    static class CtorProbe {
        static int ctors;
        this() @safe {
            ctors++;
        }

        void noop() @safe {
        }
    }

    CtorProbe.ctors = 0;
    auto addr = sys.spawn!Counter();
    static assert(is(typeof(addr) == TypedAddress!Counter));
    auto probe = sys.spawn!CtorProbe();
    assert(CtorProbe.ctors == 1, "ctor runs inside spawn!, on the calling thread");
    assert(!addr.empty && !probe.empty, "spawn returns a non-empty typed address");

    // the spawn handle pairs with Channel at compile time; one-shots and
    // request/reply both go through the checked channel (the client kernel is
    // manually driven — no pool needed for the requester).
    auto client = ActorShell(makeAddress);
    auto chan = Channel!Counter(addr, ActorRef(&client), infTimeout());
    chan.add(5);
    chan.add(7);

    int total = -1;
    static void onTotal(ref Tuple!(int*) ctx, int v) {
        *ctx[0] = v;
    }

    chan.total().capture(&total).then(&onTotal);

    // an unrelated interface cannot be paired with the spawn handle
    interface IUnrelated {
        void nope();
    }

    static assert(!__traits(compiles, Channel!IUnrelated(addr, ActorRef(&client))));

    auto sw = StopWatch(AutoStart.yes);
    while (total == -1 && sw.peek < 2.dur!"seconds") {
        client.process(Clock.currTime);
        Thread.sleep(1.dur!"msecs");
    }
    assert(total == 12, "spawned class actor processed messages and replied");
    sys.shutdown;
}

@("a throwing ctor shall propagate out of spawn and the system shall stay usable")
unittest {
    import std.datetime.stopwatch : StopWatch, AutoStart;
    import my.actor.channel : dynSend;
    import my.gc.refc : RefCounted, refCounted;

    static class Throwing {
        this() {
            throw new Exception("ctor failed");
        }
    }

    static class ThrowErr {
        this() {
            throw new Error("ctor error");
        }
    }

    static class Healthy {
        RefCounted!int hits;

        this(RefCounted!int h) {
            hits = h;
        }

        void ping() {
            hits.get++;
        }
    }

    auto sys = makeSystem;

    bool caught = false;
    string got;
    try {
        sys.spawn!Throwing();
    } catch (Exception e) {
        caught = true;
        got = e.msg;
    }
    assert(caught, "the ctor exception propagates out of spawn");
    assert(got == "ctor failed", "the original exception is rethrown");

    // Errors (e.g. OOM inside the user ctor) must be cleaned up and
    // rethrown just the same — the cleanup path catches Throwable,
    // not just Exception.
    bool caughtErr = false;
    string gotErr;
    try {
        sys.spawn!ThrowErr();
    } catch (Throwable e) {
        caughtErr = true;
        gotErr = e.msg;
    }
    assert(caughtErr, "the ctor Error propagates out of spawn");
    assert(gotErr == "ctor error", "the original Error is rethrown");

    // the system must still be fully usable after a failed spawn.
    auto hits = refCounted(0);
    auto addr = sys.spawn!Healthy(hits);
    dynSend(addr.weakRef, "ping");

    auto sw = StopWatch(AutoStart.yes);
    while (hits.get == 0 && sw.peek < 3.dur!"seconds")
        Thread.sleep(1.dur!"msecs");
    assert(hits.get == 1);
    sys.shutdown;
}

private:
@safe:

struct Backend {
    Scheduler scheduler;
    ActorAlloc alloc;

    // trusted: the ref to alloc on the assumption that the actor system is the
    // last to terminate. the backend is owned by the system and correctly
    // shutdown.
    void start(TaskPool pool, ulong workers) @trusted {
        scheduler.start(pool, workers, &alloc);
    }

    void shutdown() {
        import core.memory : GC;
        import my.libc : malloc_trim;

        scheduler.shutdown;
        scheduler = null;
        () @trusted { .destroy(scheduler); }();
        () @trusted { GC.collect; }();
        () @trusted { malloc_trim(0); }();
    }
}

/** Schedule actors for execution.
 *
 * A worker pops an actor, executes it, and then puts it back for later scheduling.
 *
 * A watcher monitors inactive actors for either messages to have arrived or
 * timeouts to trigger. They are then moved back to the waiting queue. The
 * workers are notified that there are actors waiting to be executed.
 */
class Scheduler {
    import core.atomic : atomicOp, atomicLoad;

    SystemConfig.Scheduler conf;

    ActorAlloc* alloc;

    /// Workers will shutdown cleanly if it is false.
    bool isActive;

    /// Watcher will shutdown cleanly if this is false.
    bool isWatcher;

    /// Shutdowner will shutdown cleanly if false;
    bool isShutdown;

    // Workers waiting to be activated
    Mutex waitingWorkerMtx;
    Condition waitingWorker;

    // actors waiting to be executed by a worker.
    Queue!(ActorShell*) waiting;

    // Actors waiting for messages to arrive thus they are inactive.
    Queue!(ActorShell*) inactive;

    // Actors that are shutting down.
    Queue!(ActorShell*) inShutdown;

    Task!(worker, Scheduler, const ulong)*[] workers;
    Task!(watchInactive, Scheduler)* watcher;
    Task!(watchShutdown, Scheduler)* shutdowner;

    this(SystemConfig.Scheduler conf, TaskPool pool) {
        this.conf = conf;
        this.isActive = true;
        this.isWatcher = true;
        this.isShutdown = true;
        this.waiting = typeof(waiting)(new Mutex);
        this.inactive = typeof(inactive)(new Mutex);
        this.inShutdown = typeof(inShutdown)(new Mutex);

        this.waitingWorkerMtx = new Mutex;
        this.waitingWorker = new Condition(this.waitingWorkerMtx);
    }

    void wakeup() @trusted {
        synchronized (waitingWorkerMtx) {
            waitingWorker.notify;
        }
    }

    void wait(Duration w) @trusted {
        synchronized (waitingWorkerMtx) {
            waitingWorker.wait(w);
        }
    }

    /// check the inactive actors for activity.
    private static void watchInactive(Scheduler sched) {
        const maxThroughput = sched.conf.maxThroughput.orElse(50UL);
        const shutdownPoll = sched.conf.pollInterval.orElse(20.dur!"msecs");

        const minPoll = 100.dur!"usecs";
        const stepPoll = minPoll;
        const maxPoll = sched.conf.pollInterval.orElse(10.dur!"msecs");

        Duration pollInterval = minPoll;

        while (sched.isActive) {
            const runActors = sched.inactive.length;
            ulong inactive;
            Duration nextPoll = pollInterval;

            foreach (_; 0 .. runActors) {
                if (auto a = sched.inactive.pop.unsafeMove) {
                    if (a.hasMessage) {
                        sched.putWaiting(a);
                    } else {
                        const t = a.nextTimeout(Clock.currTime, maxPoll);

                        if (t < minPoll) {
                            sched.putWaiting(a);
                        } else {
                            sched.putInactive(a);
                            nextPoll = inactive == 0 ? t : min(nextPoll, t);
                            inactive++;
                        }
                    }
                }
            }

            if (inactive != 0) {
                pollInterval = clamp(nextPoll, minPoll, maxPoll);
            }

            if (inactive == runActors) {
                () @trusted { Thread.sleep(pollInterval); }();
                pollInterval = min(maxPoll, pollInterval);
            } else {
                sched.wakeup;
                pollInterval = minPoll;
            }
        }

        while (sched.isWatcher || !sched.inactive.empty) {
            if (auto a = sched.inactive.pop.unsafeMove) {
                sched.inShutdown.put(a);
            }
        }
    }

    /// finish shutdown of actors that are shutting down.
    private static void watchShutdown(Scheduler sched) {
        import my.actor.msg : sendSystemMsgIfEmpty;
        import my.actor.common : ExitReason;
        import my.actor.mailbox : SystemExitMsg;

        const shutdownPoll = sched.conf.pollInterval.orElse(20.dur!"msecs");

        const minPoll = 100.dur!"usecs";
        const stepPoll = minPoll;
        const maxPoll = sched.conf.pollInterval.orElse(10.dur!"msecs");

        Duration pollInterval = minPoll;

        while (sched.isActive) {
            const runActors = sched.inShutdown.length;
            ulong alive;

            foreach (_; 0 .. runActors) {
                if (auto a = sched.inShutdown.pop.unsafeMove) {
                    if (a.isAlive) {
                        alive++;
                        a.process(Clock.currTime);
                        sched.inShutdown.put(a);
                    } else {
                        sched.alloc.dispose(a);
                    }
                }
            }

            if (alive == 0) {
                () @trusted { Thread.sleep(pollInterval); }();
                pollInterval = max(minPoll, pollInterval + stepPoll);
            } else {
                pollInterval = minPoll;
            }
        }

        while (sched.isShutdown || !sched.inShutdown.empty) {
            if (auto a = sched.inShutdown.pop.unsafeMove) {
                if (a.isAlive) {
                    sendSystemMsgIfEmpty(a.address, SystemExitMsg(ExitReason.kill));
                    a.process(Clock.currTime);
                    sched.inShutdown.put(a);
                } else {
                    sched.alloc.dispose(a);
                }
            }
        }
    }

    private static void worker(Scheduler sched, const ulong id) {
        import my.actor.msg : sendSystemMsgIfEmpty;
        import my.actor.common : ExitReason;
        import my.actor.mailbox : SystemExitMsg;

        const maxThroughput = sched.conf.maxThroughput.orElse(50UL);
        const pollInterval = sched.conf.pollInterval.orElse(50.dur!"msecs");
        const inactiveLimit = min(500.dur!"msecs", pollInterval * 3);

        while (sched.isActive) {
            const runActors = sched.waiting.length;
            ulong consecutiveInactive;

            foreach (_; 0 .. runActors) {
                if (auto ctx = sched.pop) {
                    ulong msgs;
                    ulong prevMsgs;
                    ulong totalMsgs;
                    do {
                        // reduce clock polling
                        const now = Clock.currTime;
                        ctx.process(now);
                        prevMsgs = msgs;
                        msgs = ctx.messages;
                        totalMsgs += msgs;
                    }
                    while (totalMsgs < maxThroughput && msgs != prevMsgs);

                    if (totalMsgs == 0) {
                        sched.putInactive(ctx);
                        consecutiveInactive++;
                    } else {
                        consecutiveInactive = 0;
                        sched.putWaiting(ctx);
                    }
                } else {
                    sched.wait(pollInterval);
                }
            }

            // sleep if it is detected that actors are not sending messages
            if (consecutiveInactive == runActors) {
                sched.wait(inactiveLimit);
            }
        }

        while (!sched.waiting.empty) {
            const sleepAfter = 1 + sched.waiting.length;
            for (size_t i; i < sleepAfter; ++i) {
                if (auto ctx = sched.pop) {
                    sendSystemMsgIfEmpty(ctx.address, SystemExitMsg(ExitReason.kill));
                    ctx.process(Clock.currTime);
                    sched.putWaiting(ctx);
                }
            }

            () @trusted { Thread.sleep(pollInterval); }();
        }
    }

    /// Start the workers.
    void start(TaskPool pool, const ulong nr, ActorAlloc* alloc) {
        this.alloc = alloc;
        foreach (const id; 0 .. nr) {
            auto t = task!worker(this, id);
            workers ~= t;
            pool.put(t);
        }
        watcher = task!watchInactive(this);
        watcher.executeInNewThread(Thread.PRIORITY_MIN);

        shutdowner = task!watchShutdown(this);
        shutdowner.executeInNewThread(Thread.PRIORITY_MIN);
    }

    void shutdown() {
        isActive = false;
        foreach (a; workers) {
            try {
                a.yieldForce;
            } catch (Exception e) {
                // TODO: log exceptions?
            }
        }

        isWatcher = false;
        try {
            watcher.yieldForce;
        } catch (Exception e) {
        }

        isShutdown = false;
        try {
            shutdowner.yieldForce;
        } catch (Exception e) {
        }
    }

    ActorShell* pop() {
        return waiting.pop.unsafeMove;
    }

    void putWaiting(ActorShell* a) @safe {
        if (a.isAccepting) {
            waiting.put(a);
        } else if (a.isAlive) {
            inShutdown.put(a);
        } else {
            // TODO: should terminated actors be logged?
            alloc.dispose(a);
        }
    }

    void putInactive(ActorShell* a) @safe {
        if (a.isAccepting) {
            inactive.put(a);
        } else if (a.isAlive) {
            inShutdown.put(a);
        } else {
            // TODO: should terminated actors be logged?
            alloc.dispose(a);
        }
    }
}
