/* Raw embedding sanity probes against the local nomic model.
 * - repeated-encode contamination check
 * - paraphrase / unrelated pair similarities
 * - add_special (CLS/SEP) comparison
 */
#include "llama.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static struct llama_model* g_model;
static struct llama_context* g_ctx;
static int g_dim;

static int embed_tokens(const int* toks, int ntok, float* out) {
    struct llama_batch b = llama_batch_get_one((int*)toks, ntok);
    if (llama_encode(g_ctx, b)) {
        fprintf(stderr, "encode failed\n");
        return -1;
    }
    const float* e = llama_get_embeddings_seq(g_ctx, 0);
    if (!e) {
        fprintf(stderr, "no embedding\n");
        return -1;
    }
    memcpy(out, e, sizeof(float) * g_dim);
    return 0;
}

static int encode_text(const char* text, int add_special, float* out) {
    const struct llama_vocab* vocab = llama_model_get_vocab(g_model);
    int need = -llama_tokenize(vocab, text, (int)strlen(text), NULL, 0, add_special, true);
    int* toks = malloc(sizeof(int) * (need + 2));
    int n = llama_tokenize(vocab, text, (int)strlen(text), toks, need + 2, add_special, true);
    int rc = embed_tokens(toks, n, out);
    free(toks);
    return rc;
}

static double cosine(const float* a, const float* b) {
    double dot = 0, na = 0, nb = 0;
    for (int k = 0; k < g_dim; k++) {
        dot += (double)a[k] * b[k];
        na += (double)a[k] * a[k];
        nb += (double)b[k] * b[k];
    }
    return dot / (sqrt(na) * sqrt(nb));
}

static double norm2(const float* a) {
    double n = 0;
    for (int k = 0; k < g_dim; k++)
        n += (double)a[k] * a[k];
    return sqrt(n);
}

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf\n", argv[0]);
        return 1;
    }
    ggml_backend_load_all();
    llama_backend_init();
    struct llama_model_params mp = llama_model_default_params();
    g_model = llama_model_load_from_file(argv[1], mp);
    if (!g_model) {
        fprintf(stderr, "model load failed\n");
        return 1;
    }

    struct llama_context_params cp = llama_context_default_params();
    cp.embeddings = true;
    cp.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED;
    cp.n_ctx = 512;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    g_ctx = llama_init_from_model(g_model, cp);
    if (!g_ctx) {
        fprintf(stderr, "ctx failed\n");
        return 1;
    }
    g_dim = llama_model_n_embd(g_model);
    printf("pooling_type=%d n_embd=%d\n", (int)llama_pooling_type(g_ctx), g_dim);

    static float A[8192], B[8192], A2[8192], C[8192];

    /* 1. contamination check: A, B, A again */
    encode_text("The cat sat on the mat", 0, A);
    encode_text("Quantum mechanics describes the behavior of particles", 0, B);
    encode_text("The cat sat on the mat", 0, A2);
    printf("\n[contamination] cos(A, A2)=%.6f (want 1.0)\n", cosine(A, A2));
    printf("[contamination] norm(A)=%.4f norm(A2)=%.4f (want equal)\n", norm2(A), norm2(A2));

    /* 2. semantic pairs, no special tokens */
    printf("\n[semantic pairs, add_special=false]\n");
    {
        struct {
            const char* a;
            const char* b;
        } pairs[] = {
            {"The cat sat on the mat", "A cat is sitting on a mat"},
            {"The cat sat on the mat", "Quantum mechanics describes particles"},
            {"How do I rotate the signing keys for authentication?",
             "The deployment runbook explains signing key rotation"},
            {"The token specification defines the JWT claims",
             "Authentication tokens use JWT with claims sub and exp"},
            {"Refactor the database schema for the users table",
             "Improve the table structure of the user database"},
        };
        for (int i = 0; i < 5; i++) {
            encode_text(pairs[i].a, 0, A);
            encode_text(pairs[i].b, 0, B);
            printf("  cos=%.4f  | %s <=> %s\n", cosine(A, B), pairs[i].a, pairs[i].b);
        }
    }

    /* 3. same pairs with special tokens */
    printf("\n[semantic pairs, add_special=true]\n");
    {
        struct {
            const char* a;
            const char* b;
        } pairs[] = {
            {"The cat sat on the mat", "A cat is sitting on a mat"},
            {"The cat sat on the mat", "Quantum mechanics describes particles"},
            {"How do I rotate the signing keys for authentication?",
             "The deployment runbook explains signing key rotation"},
        };
        for (int i = 0; i < 3; i++) {
            encode_text(pairs[i].a, 1, A);
            encode_text(pairs[i].b, 1, B);
            printf("  cos=%.4f  | %s <=> %s\n", cosine(A, B), pairs[i].a, pairs[i].b);
        }
    }

    /* 4. prefix comparison for the file-name query */
    printf("\n[file-name query, prefixes]\n");
    {
        const char* q0 = "search_query: I want the file auth_token_spec";
        const char* q1 = "I want the file auth_token_spec";
        const char* d0 = "search_document: File: corpus/auth_token_spec.md | This document defines "
                         "the JWT access token format used by all services. Claims: sub, exp, iat, "
                         "scp. Access tokens expire after 15 minutes.";
        const char* d1 = "File: corpus/auth_token_spec.md | This document defines the JWT access "
                         "token format used by all services. Claims: sub, exp, iat, scp. Access "
                         "tokens expire after 15 minutes.";
        const char* n0 = "search_document: File: corpus/storage_engine_design.md | This document "
                         "describes the custom append-only storage engine used by the audit log "
                         "service. It is not related to the authentication subsystem.";
        const char* n1 = "File: corpus/storage_engine_design.md | This document describes the "
                         "custom append-only storage engine used by the audit log service. It is "
                         "not related to the authentication subsystem.";
        encode_text(q0, 0, A);
        encode_text(q1, 0, B);
        encode_text(d0, 0, C);
        encode_text(n0, 0, A2);
        printf("  cos(q0,d0)=%.4f cos(q0,n0)=%.4f margin=%.4f\n", cosine(A, C), cosine(A, A2),
               cosine(A, C) - cosine(A, A2));
        encode_text(d1, 0, C);
        encode_text(n1, 0, A2);
        printf("  cos(q1,d1)=%.4f cos(q1,n1)=%.4f margin=%.4f\n", cosine(B, C), cosine(B, A2),
               cosine(B, C) - cosine(B, A2));
    }

    /* 5. file-name query WITH special tokens (recommended usage) */
    printf("\n[file-name query, add_special=true]\n");
    {
        static float M[8192];
        const char* q0 = "search_query: I want the file auth_token_spec";
        const char* q1 = "search_query: auth_token_spec";
        const char* d0 = "search_document: File: corpus/auth_token_spec.md | This document defines "
                         "the JWT access token format used by all services. Claims: sub, exp, iat, "
                         "scp. Access tokens expire after 15 minutes.";
        const char* n0 = "search_document: File: corpus/storage_engine_design.md | This document "
                         "describes the custom append-only storage engine used by the audit log "
                         "service. It is not related to the authentication subsystem.";
        const char* m0 = "search_document: File: corpus/api_reference.md | POST /auth/token issue "
                         "an access token (see auth_token_spec.md for the claims).";
        encode_text(q0, 1, A);
        encode_text(d0, 1, B);
        encode_text(n0, 1, C);
        encode_text(m0, 1, M);
        printf("  q0: target=%.4f storage=%.4f apiref=%.4f\n", cosine(A, B), cosine(A, C),
               cosine(A, M));
        encode_text(q1, 1, A);
        printf("  q1: target=%.4f storage=%.4f apiref=%.4f\n", cosine(A, B), cosine(A, C),
               cosine(A, M));
    }

    /* 6. equivalence: manual [bos]+tokens+[eos] wrap vs llama_tokenize(add_special=true) */
    printf("\n[BOS/EOS equivalence check]\n");
    {
        const struct llama_vocab* vocab = llama_model_get_vocab(g_model);
        llama_token bos = llama_vocab_bos(vocab);
        llama_token eos = llama_vocab_eos(vocab);
        printf("  bos=%d eos=%d add_bos=%d add_eos=%d\n", (int)bos, (int)eos,
               (int)llama_vocab_get_add_bos(vocab), (int)llama_vocab_get_add_eos(vocab));

        const char* texts[] = {
            "search_query: I want the file auth_token_spec",
            "File: corpus/auth_token_spec.md | This document defines the JWT access token format "
            "used by all services.",
            "short",
        };
        for (int i = 0; i < 3; i++) {
            const char* t = texts[i];
            int len = (int)strlen(t);
            int nPlain = -llama_tokenize(vocab, t, len, NULL, 0, false, true);
            int* plain = malloc(sizeof(int) * (nPlain + 2));
            nPlain = llama_tokenize(vocab, t, len, plain, nPlain, false, true);
            int nSpec = -llama_tokenize(vocab, t, len, NULL, 0, true, true);
            int* spec = malloc(sizeof(int) * (nSpec + 2));
            nSpec = llama_tokenize(vocab, t, len, spec, nSpec, true, true);

            /* manual wrap (exactly what the production embed() does) */
            int* wrap = malloc(sizeof(int) * (nPlain + 2));
            wrap[0] = bos;
            memcpy(wrap + 1, plain, sizeof(int) * nPlain);
            wrap[nPlain + 1] = eos;

            int equalLen = (nSpec == nPlain + 2);
            int equalIds = equalLen;
            if (equalLen)
                for (int k = 0; k < nSpec; k++)
                    if (wrap[k] != spec[k])
                        equalIds = 0;

            float* e1 = malloc(sizeof(float) * g_dim);
            float* e2 = malloc(sizeof(float) * g_dim);
            embed_tokens(wrap, nPlain + 2, e1);
            embed_tokens(spec, nSpec, e2);
            double c = cosine(e1, e2);
            double maxdiff = 0;
            for (int k = 0; k < g_dim; k++) {
                double d = fabs((double)e1[k] - e2[k]);
                if (d > maxdiff)
                    maxdiff = d;
            }
            printf("  text[%d] ntok=%d wrap_len=%d special_len=%d lenEq=%d idsEq=%d cos=%.6f "
                   "maxAbsDiff=%.2e\n",
                   i, nPlain, nPlain + 2, nSpec, equalLen, equalIds, c, maxdiff);
            free(plain);
            free(spec);
            free(wrap);
            free(e1);
            free(e2);
        }
    }

    return 0;
}
