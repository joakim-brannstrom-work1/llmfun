/**
Copyright: Copyright (c) Joakim Brännström. All rights reserved.
License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt, Boost Software License 1.0)
Author: Joakim Brännström (joakim.brannstrom@gmx.com)

Allocators used by system.
*/
module my.actor.memory;

import my.actor.actor : ActorShell, ActorState;
import my.actor.mailbox : StrongAddress, makeAddress;

/** Assumes that the `System` instance ensures that only actors created with
 * this allocator are deallocated through it; in the normal flow an actor
 * reaches `shutdown` and is then disposed of by the `System`. */
struct ActorAlloc {
    import core.memory : GC;
    import std.experimental.allocator.mallocator : Mallocator;

    // lazy for now and just use the global allocator.
    alias allocator_ = Mallocator.instance;

    enum Sz = ActorShell.sizeof;

    ActorShell* make(StrongAddress addr) @trusted {
        import std.experimental.allocator : make;

        auto rval = make!ActorShell(allocator_, addr);
        GC.addRange(rval, Sz);

        return rval;
    }

    void dispose(ActorShell* a) @trusted
    in (a.state_ == ActorState.stopped, "actors must be stopped before disposed") {
        static import my.alloc.dispose_;

        my.alloc.dispose_.dispose(allocator_, a);
        GC.removeRange(a);
    }
}

@("shall allocate and dellacate an actor")
unittest {
    import core.memory : GC;
    import std.variant;
    import std.typecons;
    import std.datetime : Clock;
    import my.actor.mailbox;

    ActorAlloc aa;
    foreach (_1; 0 .. 10) {
        auto addr = makeAddress;
        auto a = aa.make(addr);

        // adding a StrongAddress is normally blocked by the user BUT the
        // teardown of messages should release it such that it is no longer on
        // the GC.
        auto smurf = tuple(addr.weakRef);
        auto b = smurf;
        addr.get.put!Msg(Msg(42, MsgType(MsgOneShot(Variant(smurf)))));

        foreach (_2; 0 .. 5)
            a.process(Clock.currTime);

        a.shutdown;
        while (a.isAlive)
            a.process(Clock.currTime);

        aa.dispose(a);
        GC.collect;
    }
}
