/// Installs the unittest-build stderr logger (F1).
///
/// The whole install lives in its own module instead of a shared static
/// constructor in llm.test_util because a module constructor there closes a
/// cycle: test_util is imported by llm.skill (imported by llm.config), and
/// test_util reaches llm.rag (struct-level `import llm.rag : RAG;` in
/// TestArea), whose constructor chain runs back through llm.utility, llm.chat
/// and llm.skill - adding a test_util constructor died at startup with
/// "Cyclic dependency between module constructors/destructors of llm.rag and
/// llm.test_util" (I2, verified empirically). Nothing imports this module
/// except dub's generated test root, so this constructor is a sink: it runs
/// once, before any unittest, for the whole test binary.
module llm.test_log_install;

version (unittest) shared static this() {
    import core.sys.posix.signal : SIGPIPE, SIG_IGN, signal;
    import llm.test_util : EagainTolerantLogger;
    import std.logger : LogLevel, logf, sharedLog;

    // A write to a closed pipe raises SIGPIPE first: with the default
    // disposition that kills the process BEFORE the writeLogMsg guard can
    // catch the underlying EPIPE ErrnoException (I1, verified empirically),
    // while EAGAIN - the reproduced failure mode - surfaces as a catchable
    // ErrnoException with no signal involved. Ignoring SIGPIPE is scoped to
    // the unittest build; production keeps its current behavior (F5's real
    // fix lives in colorlog, task 5).
    signal(SIGPIPE, SIG_IGN);

    sharedLog = cast(shared EagainTolerantLogger) new EagainTolerantLogger;
}
