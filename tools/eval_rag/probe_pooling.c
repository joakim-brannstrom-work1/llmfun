#include "llama.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s model.gguf\n", argv[0]);
        return 1;
    }
    ggml_backend_load_all();
    llama_backend_init();
    struct llama_model_params mp = llama_model_default_params();
    struct llama_model* m = llama_model_load_from_file(argv[1], mp);
    if (!m) {
        fprintf(stderr, "model load failed\n");
        return 1;
    }

    struct llama_context_params cp = llama_context_default_params();
    cp.embeddings = true;
    cp.pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED;
    cp.n_ctx = 512;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    struct llama_context* ctx = llama_init_from_model(m, cp);
    if (!ctx) {
        fprintf(stderr, "ctx failed\n");
        return 1;
    }

    enum llama_pooling_type pt = llama_pooling_type(ctx);
    printf("pooling_type=%d (0=NONE,1=MEAN,2=CLS,3=LAST,4=RANK)\n", (int)pt);
    printf("n_embd=%d\n", llama_model_n_embd(m));

    const char* texts[] = {
        "search_query: I want the file auth_token_spec",
        "search_query: auth_token_spec",
        "search_document: File: corpus/auth_token_spec.md | This document defines the JWT access "
        "token format. Claims: sub, exp, iat, scp. Access tokens expire after 15 minutes.",
        "search_document: File: corpus/storage_engine_design.md | This document describes the "
        "custom append-only storage engine used by the audit log service.",
        "search_document: File: corpus/api_reference.md | POST /auth/token issue an access token "
        "(see auth_token_spec.md for the claims).",
    };
    int n = 5;
    float* vecs[8];
    int dim = llama_model_n_embd(m);

    for (int i = 0; i < n; i++) {
        const char* t = texts[i];
        int ntok =
            -llama_tokenize(llama_model_get_vocab(m), t, (int)strlen(t), NULL, 0, false, true);
        int* toks = malloc(sizeof(int) * ntok);
        llama_tokenize(llama_model_get_vocab(m), t, (int)strlen(t), toks, ntok, false, true);
        struct llama_batch b = llama_batch_get_one(toks, ntok);
        if (llama_encode(ctx, b)) {
            fprintf(stderr, "encode failed %d\n", i);
            return 1;
        }
        const float* e = llama_get_embeddings_seq(ctx, 0);
        double norm = 0;
        for (int j = 0; j < dim; j++)
            norm += (double)e[j] * e[j];
        norm = sqrt(norm);
        vecs[i] = malloc(sizeof(float) * dim);
        memcpy(vecs[i], e, sizeof(float) * dim);
        printf("text[%d] ntok=%d norm=%.4f\n", i, ntok, norm);
        free(toks);
    }

    printf("\ncosine matrix:\n");
    for (int i = 0; i < n; i++) {
        for (int j = 0; j < n; j++) {
            double dot = 0, na = 0, nb = 0;
            for (int k = 0; k < dim; k++) {
                dot += (double)vecs[i][k] * vecs[j][k];
                na += (double)vecs[i][k] * vecs[i][k];
                nb += (double)vecs[j][k] * vecs[j][k];
            }
            printf("  %d-%d: %.4f", i, j, dot / (sqrt(na) * sqrt(nb)));
        }
        printf("\n");
    }
    return 0;
}
