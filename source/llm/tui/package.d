module llm.tui;

import std.algorithm : filter;
import std.array : appender, Appender, empty, array;
import std.logger;

import llmfun_tui;

String toTuiString(string s) {
    return String(s.ptr, s.length);
}

string toString(String s) {
    if (s.len == 0)
        return null;
    auto r = s.data[0 .. s.len].idup;
    while (!r.empty && r[$ - 1] == '\0') {
        r = r[0 .. $ - 1];
    }
    return r;
}

string shortSummary(string msg) {
    import std.range : take;
    import std.string : split, strip;
    import std.uni : byCodePoint, byGrapheme, isWhite;
    import std.uni : isAlphaNum, isWhite;
    import std.utf : toUTF8;

    auto tmp = msg.split('\n');
    if (!tmp.empty)
        msg = tmp[0].strip;
    return msg.byGrapheme.filter!(a => a[0].isAlphaNum || a[0].isWhite)
        .take(100).byCodePoint.toUTF8.strip;
}

class TuiLogger : Logger {
    import core.sync.mutex;
    import std.format : format;

    private {
        Appender!(string[]) entries;
        Mutex mtx;
        immutable MaxEntries = 1000;
    }

    this(const LogLevel lvl = LogLevel.warning) @safe {
        super(lvl);
        this.mtx = new Mutex;
    }

    override void writeLogMsg(ref LogEntry payload) @trusted {
        import std.datetime : Clock;

        mtx.lock_nothrow();
        scope (exit)
            mtx.unlock_nothrow();
        if (entries[].length < MaxEntries) {
            entries.put(format("%s - %s: %s [%s:%d]", Clock.currTime,
                    payload.logLevel, payload.msg, payload.funcName, payload.line));
        }
    }

    string[] drainEntries() @safe {
        mtx.lock_nothrow();
        scope (exit)
            mtx.unlock_nothrow();
        auto tmp = entries[];
        entries.clear();
        return tmp;
    }
}

struct TuiLogSwap {
    private {
        shared(Logger) prev;
        shared(TuiLogger) tui;
    }

    ~this() {
        sharedLog = prev;
    }

    string[] drainEntries() @trusted {
        return (cast() tui).drainEntries();
    }
}

TuiLogSwap swapToTuiLogger() @trusted {
    auto prev = sharedLog;
    auto n = cast(shared) new TuiLogger(LogLevel.all);
    sharedLog = n;
    return TuiLogSwap(prev, n);
}

void tuiLogToTui(ref TuiLogSwap log, TuiState* tuiState) {
    foreach (msg; log.drainEntries) {
        string summary = shortSummary(msg);
        auto s = String(summary.ptr, summary.length);
        auto q = String(msg.ptr, msg.length);
        tuiAddLogMessage(tuiState, s, q);
    }
}
