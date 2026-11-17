import Foundation

/// Every Hugging Face repository the Whisper and diarization pipelines
/// download from, pinned to a commit.
///
/// A commit on Hugging Face is immutable, so a pinned download fetches
/// exactly the files that were tested here, whatever is later pushed to the
/// repository's `main` branch (by its owner or by someone who has taken over
/// the account). The Parakeet-family models carry their own pins in
/// `ParakeetModelSpec`.
///
/// To move a pin: read the commit from `https://huggingface.co/api/models/<repo>`
/// (`sha`), update it here, download the model fresh and run the tests with
/// `RUN_MODEL_TESTS=1`. Already-downloaded models are never re-fetched.
enum ModelRevisions {
    static let pinned: [String: String] = [
        // Whisper models (WhisperKitService.modelRepo)
        "mickekringai/kb-whisper-coreml": "ab319c37d763bce71aebeeac2efba62cfb3e26df",
        "digtek/whisperkit-nb-coreml": "8a7dae425120d4c9a2256ed840048886778908f1",
        "argmaxinc/whisperkit-coreml": "0f63a7800b00dd0226abd051b906c246e1907482",

        // Tokenizers (WhisperTokenizerFiles.repoId)
        "openai/whisper-tiny": "169d4a4341b33bc18d8881c4b69c2e104e1cc0af",
        "openai/whisper-base": "e37978b90ca9030d5170a5c07aadb050351a65bb",
        "openai/whisper-small": "973afd24965f72e36ca33b3055d56a652f456b4d",
        "openai/whisper-medium": "abdf7c39ab9d0397620ccaea8974cc764cd0953e",
        "openai/whisper-large-v2": "ae4642769ce2ad8fc292556ccea8e901f1530655",
        "openai/whisper-large-v3": "06f233fe06e710322aca913c1bc4249a0d71fce1",
        "openai/whisper-tiny.en": "87c7102498dcde7456f24cfd30239ca606ed9063",
        "openai/whisper-base.en": "911407f4214e0e1d82085af863093ec0b66f9cd6",
        "openai/whisper-small.en": "e8727524f962ee844a7319d92be39ac1bd25655a",
        "openai/whisper-medium.en": "2e98eb6279edf5095af0c8dedb36bdec0acd172b",

        // Speaker diarization (DiarizationService)
        speakerKitRepo: "556fc52a13327837688f02289457cded017802e9",
    ]

    static let speakerKitRepo = "argmaxinc/speakerkit-coreml"

    struct Unpinned: LocalizedError {
        let repo: String
        var errorDescription: String? { "No pinned revision for \(repo); refusing to download from its moving main branch." }
    }

    /// The pinned commit for a repository. There is deliberately no fallback
    /// to `main`: an unlisted repository is a mistake to fix here.
    static func revision(for repo: String) throws -> String {
        guard let revision = pinned[repo] else { throw Unpinned(repo: repo) }
        return revision
    }
}
