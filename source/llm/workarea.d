module llm.workarea;

import std.algorithm;
import std.file;
import std.stdio : File;

import my.path;

struct Workarea {
    AbsolutePath root;

    // Temporary files that are removed when the workarea is terminated.
    AbsolutePath[] tmpFiles;

    this(AbsolutePath root) {
        this.root = root;
        if (!root.exists) {
            mkdirRecurse(root);
        }
    }

    ~this() {
        cleanTmp;
    }

    void addTmp(Path p) {
        tmpFiles ~= (root ~ p).AbsolutePath;
    }

    File openTmp(Path p, string mode) {
        auto f = File(p, mode);
        addTmp(p);
        return f;
    }

    void cleanTmp() {
        foreach (a; tmpFiles.filter!(a => a.toString.startsWith(root.toString))
                .filter!(a => a.exists)) {
            remove(a.toString);
        }
        tmpFiles = null;
    }
}
