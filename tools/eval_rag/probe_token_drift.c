/* Measure how the chunker's incremental per-word token counting compares to
 * full-string tokenization with add_special=true.
 *
 * The RAG token chunker counts tokens word-by-word (add_special=false, the
 * counting API) and currently embeds the concatenation of those per-word
 * tokens. The proposed design re-tokenizes the whole chunk text
 * (add_special=true) at embed time. This probe quantifies the difference so
 * we know how much budget slack (or halving) is needed.
 */
#include "llama.h"
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct llama_model* g_model;
static const struct llama_vocab* g_vocab;

static int tok_count(const char* t, int add_special) {
    return -llama_tokenize(g_vocab, t, (int)strlen(t), NULL, 0, add_special, true);
}

/* Sum of per-word counts, whitespace kept attached to the preceding word
 * (mirrors the chunker's currentWord including the trailing white grapheme). */
static int word_sum(const char* text) {
    int total = 0;
    size_t len = strlen(text);
    size_t start = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)text[i];
        if (c == ' ' || c == '\n' || c == '\t' || c == '\r') {
            if (i + 1 > start) {
                char buf[4096];
                size_t n = i + 1 - start;
                if (n >= sizeof(buf))
                    n = sizeof(buf) - 1;
                memcpy(buf, text + start, n);
                buf[n] = 0;
                total += tok_count(buf, 0);
            }
            start = i + 1;
        }
    }
    if (start < len) {
        char buf[4096];
        size_t n = len - start;
        if (n >= sizeof(buf))
            n = sizeof(buf) - 1;
        memcpy(buf, text + start, n);
        buf[n] = 0;
        total += tok_count(buf, 0);
    }
    return total;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf [corpusdir]\n", argv[0]);
        return 1;
    }
    ggml_backend_load_all();
    llama_backend_init();
    g_model = llama_model_load_from_file(argv[1], llama_model_default_params());
    if (!g_model) {
        fprintf(stderr, "model load failed\n");
        return 1;
    }
    g_vocab = llama_model_get_vocab(g_model);

    printf("specials: tokenize(\"\", add_special=true).n = %d\n", tok_count("", 1));

    /* synthetic boundary cases */
    const char* cases[] = {
        "hello world foo bar",
        "auth_token_spec.md claims sub exp iat scp",
        "multi  spaces   and\nnewlines\tand tabs",
        "punctuation, semicolons; colons: dashes- and_underscores",
        "1234567890 3.14159 0xDEADBEEF",
        "unicode: naive cafe resume emoji",
        "a b c d e f g h i j k l m n o p q r s t u v w x y z",
        "supercalifragilisticexpialidocious antidisestablishmentarianism",
    };
    const char* prefix = "File: corpus/test.md | ";
    printf("\nSynthetic cases (prefix=\"%s\"):\n", prefix);
    for (int i = 0; i < (int)(sizeof(cases) / sizeof(cases[0])); i++) {
        char full[8192];
        snprintf(full, sizeof(full), "%s%s", prefix, cases[i]);
        int sum = tok_count(prefix, 0) + tok_count("", 1) + word_sum(cases[i]);
        int fullN = tok_count(full, 1);
        printf("  delta=%+d  (sum=%d full=%d)  '%s'\n", fullN - sum, sum, fullN, cases[i]);
    }

    if (argc >= 3) {
        printf("\nCorpus files (whole file, prefix=\"File: corpus/<name> | \"):\n");
        DIR* d = opendir(argv[2]);
        if (!d) {
            fprintf(stderr, "cannot open %s\n", argv[2]);
            return 1;
        }
        struct dirent* e;
        int max_delta = -1000, min_delta = 1000;
        while ((e = readdir(d))) {
            size_t n = strlen(e->d_name);
            if (n < 4 || strcmp(e->d_name + n - 3, ".md") != 0)
                continue;
            char path[4096], buf[65536], full[65536];
            snprintf(path, sizeof(path), "%s/%s", argv[2], e->d_name);
            FILE* f = fopen(path, "rb");
            if (!f)
                continue;
            size_t got = fread(buf, 1, sizeof(buf) - 1, f);
            fclose(f);
            buf[got] = 0;
            char pr[512];
            snprintf(pr, sizeof(pr), "File: corpus/%s | ", e->d_name);
            snprintf(full, sizeof(full), "%s%s", pr, buf);
            int sum = tok_count(pr, 0) + tok_count("", 1) + word_sum(buf);
            int fullN = tok_count(full, 1);
            int delta = fullN - sum;
            if (delta > max_delta)
                max_delta = delta;
            if (delta < min_delta)
                min_delta = delta;
            printf("  delta=%+d  (sum=%d full=%d)  %s\n", delta, sum, fullN, e->d_name);
        }
        closedir(d);
        printf("corpus delta range: [%d, %+d]\n", min_delta, max_delta);
    }

    return 0;
}
