module llm.metric.metrics;

import std.algorithm : filter, map, sort, sum, count, min, joiner;
import std.array : appender, array, empty;
import std.conv : to;
import std.format : format;
import std.string : split;
import std.typecons : Tuple, tuple;

import llm.metric.monitor;

/// Overall system metrics
struct SystemMetrics {
    double toolSuccessRate;
    double avgResponseTimeMs;
    double stddevResponseTimeMs;
    string[] topFailingTools;
    string[] topSucceedingTools;
    long totalCalls;
}

class MetricsCalculator {
    private {
        MetricMonitor monitor;
    }

    this(MetricMonitor monitor) {
        this.monitor = monitor;
    }

    /// Calculate current metrics
    SystemMetrics calculate() {
        auto events = monitor.getRecentEvents(1000);

        if (events.empty) {
            return SystemMetrics(toolSuccessRate: 1.0, avgResponseTimeMs: 0, stddevResponseTimeMs: 0,
                    topFailingTools: [], topSucceedingTools: [], totalCalls: 0);
        }

        // Calculate success rate
        long successes = events.filter!(e => e.success).count;
        double successRate = successes / cast(double) events.length;

        // Calculate response times
        auto times = events.map!(e => e.responseTimeMs).array;
        double avgTime = mean(times);
        double stdDev = sampleStdDev(times, mean(times));

        // Find top failing/succeeding tools
        auto toolStats = groupToolStats(events);

        return SystemMetrics(toolSuccessRate: successRate, avgResponseTimeMs: avgTime, stddevResponseTimeMs: stdDev, topFailingTools: getTopFailing(
                toolStats, 5), topSucceedingTools: getTopSucceeding(toolStats,
                5), totalCalls: events.length);
    }

    /// Generate human-readable report
    string generateReport() {
        auto metrics = calculate();

        return format("## Self-Monitoring Report

### Overall Performance
- **Tool Success Rate**: %.1f%%
- **Average Response Time**: %.0f ms
- **Response Time Variance**: %.0f ms
- **Total Calls Analyzed**: %d

### Top 5 Failing Tools
%s

### Top 5 Succeeding Tools
%s
)", metrics.toolSuccessRate * 100, metrics.avgResponseTimeMs, metrics.stddevResponseTimeMs,
                metrics.totalCalls, metrics.topFailingTools.map!(t => "- " ~ t)
                    .joiner("\n"), metrics.topSucceedingTools.map!(t => "- " ~ t).joiner("\n"));
    }

    /// Group events by tool name
    private Tuple!(long, long)[string] groupToolStats(ToolCallEvent[] events) {
        typeof(return) stats;
        foreach (event; events) {
            if (event.toolName !in stats) {
                stats[event.toolName] = tuple(0, 0); // failures:total
            }
            auto parts = stats[event.toolName];
            long failures = parts[0];
            long total = parts[1] + 1;
            if (!event.success) {
                failures++;
            }
            stats[event.toolName] = tuple(failures, total);
        }
        return stats;
    }

    private string[] getTopFailing(Tuple!(long, long)[string] stats, int count) {
        // Sort by failure rate (descending)
        auto sorted = stats.keys.sort!((a, b) {
            auto partsA = stats[a];
            auto partsB = stats[b];
            double rateA = partsA[0] / cast(double) partsA[1];
            double rateB = partsB[0] / cast(double) partsB[1];
            return rateA > rateB;
        }).array;
        return sorted[0 .. min(sorted.length, count)];
    }

    private string[] getTopSucceeding(Tuple!(long, long)[string] stats, int count) {
        auto sorted = stats.keys.sort!((a, b) {
            auto partsA = stats[a];
            auto partsB = stats[b];
            double rateA = 1 - (partsA[0] / cast(double) partsA[1]);
            double rateB = 1 - (partsB[0] / cast(double) partsB[1]);
            return rateA > rateB; // Descending
        }).array;
        return sorted[0 .. min(sorted.length, count)];
    }
}

private:

double mean(T)(T data) {
    const N = cast(double) data.length;
    return data.sum / N;
}

double sampleStdDev(T)(T data, double mean) {
    import std.math : sqrt, pow;

    const N = cast(double) data.length;
    const s = data.map!(a => pow(a - mean, 2.0)).sum;
    return sqrt(s / (N - 1.0));
}
