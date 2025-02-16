// Embedding backend abstraction for RAG.
// Provides an interface that decouples RAG from specific model implementations,
// allowing both local (llama.cpp) and remote (HTTP API) backends.

module llm.rag.embedder;

import std.array : empty;
import std.sumtype : SumType;

alias EmbedResult = SumType!(float[], string);

/// Produce an embedding vector for the given text.
/// Returns float[] of fixed dimension (e.g. 384, 768, 1536).
/// Throws Exception on failure (model error, network error).
interface Embedder {
    /// Produce an embedding vector for the given text.
    EmbedResult embed(string text);

    /// Tokenize text into token IDs for chunking purposes.
    int[] tokenize(string text);

    /// Convert token IDs back to text.
    string detokenize(int[] tokens);

    /// Maximum number of tokens that can be processed in one batch.
    /// Used by RAG.add() to determine chunk size.
    int batchSize();

    /// Destroy all critical resources.
    void destroy();
}

/// Configuration for a remote embedding backend.
struct RemoteEmbedderConfig {
    string baseUrl; // e.g. "http://localhost:8080/v1"
    string modelName; // e.g. "text-embedding-3-small"
    string apiKey; // optional, for authentication
    int timeoutSeconds = 30; // HTTP timeout
    int dimensions = 1536; // embedding vector dimension
    int maxRetries = 3; // maximum number of retries for transient failures
    long backoffMs = 500; // initial backoff in milliseconds (exponential)
}

// Pull in implementations
import llm.rag.embedder_llama;
import llm.rag.embedder_http;

import std.sumtype : match;
import llm.config : EmbedConfig, LocalEmbedConfig, RemoteEmbedConfig;

/// Factory function to create an Embedder from an EmbedConfig sum type.
Embedder createEmbedder(EmbedConfig config) {
    return config.match!((LocalEmbedConfig local) {
        version (llm_fun_llama_backend) {
            import llm.llama.model : Model, LlamaParams, contextEmbedding;

            auto params = LlamaParams.make();
            params = contextEmbedding(params, cast(uint) local.nBatch);
            params.ctx.n_ctx = cast(uint) local.context;
            auto model = new Model(local.modelPath, params);
            Embedder e = new LlamaEmbedder(model);
            return e;
        } else {
            throw new Exception("llm_fun_llama_backend not compiled");
            return null;
        }
    }, (RemoteEmbedConfig remote) {
        Embedder e = new RemoteEmbedder(RemoteEmbedderConfig(remote.baseUrl,
            remote.modelName, remote.apiKey, remote.timeoutSeconds, remote.dimensions));
        return e;
    });
}
