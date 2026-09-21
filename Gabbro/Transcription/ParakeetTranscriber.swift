import CoreML
import Foundation
import OSLog

// NOTE ON THIS FILE
// =================
// This is deliberately NOT a working FluidAudio integration.
//
// The source spec says, in its own words: "FluidAudio is pre-1.0. Verify exact
// API surface (AsrManager, ModelRegistry) against the current release rather
// than trusting this document." The design doc repeats it three times. Writing
// plausible-looking `AsrManager(...)` call signatures from memory and shipping
// them as working code is exactly the failure that warning exists to prevent —
// it would look finished and fail on the first build, on a Mac, away from the
// source that could correct it.
//
// So: the type, the boundary, the compute-unit pinning and the M0 checklist are
// real. The three call sites marked TODO are yours to fill from the FluidAudio
// source once you can read it. Each one names exactly what to look for.
//
// M0 STEP 1 CHECKLIST — answer all of these before writing the calls:
//   [ ] Real artifact size at the pinned SHA. The spec says ~460 MB, but 0.6B
//       params is ~1.2 GB at FP16 and ~600 MB at INT8. If it is FP16-sized,
//       M0 step 1 is authorized to FAIL THE DESIGN, not just record the number.
//   [ ] Does FluidAudio expose a way to set MLModelConfiguration.computeUnits?
//       If it does not, that is a design-level finding. See `computeUnits` below.
//   [ ] Does it return a detected language code? Decides whether the
//       frontmatter `language` field exists at all.
//   [ ] Does it apply its own internal windowing regardless of input length?
//       If yes, success criterion 4's single-pass baseline cannot exist and the
//       criterion becomes "our chunking adds no artefacts beyond the library's".
//   [ ] Does Silero VAD actually ship with the package, as the spec asserts?
//   [ ] Exact HF repo id and the commit SHA you are pinning.

/// Parakeet TDT 0.6B v3 on the Apple Neural Engine, via FluidAudio.
public final class ParakeetTranscriber: Transcriber, @unchecked Sendable {
    private let log = Logger(subsystem: "com.pmelander.gabbro", category: "Parakeet")

    /// Pinned. Do not track a default branch — the source spec is explicit
    /// about this and it is the difference between a reproducible build and a
    /// model that silently changes under you.
    public static let modelRepo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"
    public static let modelRevision = "TODO-PIN-COMMIT-SHA"

    /// **Pin to `.cpuAndNeuralEngine`. This is not a preference.**
    ///
    /// `MLModelConfiguration.computeUnits` defaults to `.all`, which includes
    /// the GPU — and iPhone apps cannot use the GPU in the background. If
    /// CoreML schedules any part of the encoder or the TDT decode loop on the
    /// GPU, inference fails on exactly the locked-screen path this entire
    /// architecture depends on.
    ///
    /// "Zero GPU work scheduled while locked" is an M0 pass condition.
    public static var modelConfiguration: MLModelConfiguration {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        config.allowLowPrecisionAccumulationOnGPU = false
        return config
    }

    private var isPrepared = false

    public init() {}

    /// Set from the M0 check. Until then the renderer omits the frontmatter
    /// `language` field rather than emitting a guess.
    public private(set) var reportsDetectedLanguage = false

    public func prepare() async throws {
        guard !isPrepared else { return }

        // TODO(M0): load the model through FluidAudio's own API.
        //
        // Look for: the manager type that owns model lifecycle (the spec calls
        // it AsrManager), and whatever registry type lets you pin a repo
        // revision (the spec calls it ModelRegistry.repoOverrides). Confirm
        // both names against the 0.15.6 source — the spec is a year of
        // releases behind.
        //
        // Whatever the API is, it MUST accept `Self.modelConfiguration` or an
        // equivalent compute-units setting. If there is no way to keep CoreML
        // off the GPU, stop and re-read the design doc: background inference
        // on a locked phone is the whole product.
        //
        // Store the model in Application Support with
        // isExcludedFromBackupKey = true. 460 MB (or 1.2 GB) in the user's
        // iCloud backup is hostile.

        throw TranscriberError.notImplemented(
            "FluidAudio model load. Complete the M0 step 1 checklist at the top of "
            + "ParakeetTranscriber.swift first — the API surface must be read from "
            + "the 0.15.6 source, not recalled."
        )
    }

    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        guard isPrepared else {
            throw TranscriberError.modelUnavailable("prepare() has not completed")
        }

        // TODO(M0): call FluidAudio's transcribe entry point.
        //
        // Input contract from the design: 16 kHz mono Float32, already
        // converted. WAVWriter.readFloat32 produces exactly this.
        //
        // What we need back, in order of importance:
        //   1. Token text.
        //   2. Per-token timings. Without these the overlap merge has nothing
        //      to align on and success criterion 4 is untestable. They are also
        //      what makes timestamp-linked audio playback possible later.
        //   3. Detected language, if it offers one. Set
        //      `reportsDetectedLanguage` accordingly rather than assuming.

        throw TranscriberError.notImplemented("FluidAudio transcribe call")
    }
}

/// A transcriber that returns fixed text, for wiring the pipeline end to end
/// before the model is real.
///
/// This is the one thing the design says is safe to fake early: "bundled
/// fixtures before microphone integration, a pre-installed model before the
/// downloader UX". It is NOT a fallback ASR — never ship a path that reaches
/// this in a release build.
public final class StubTranscriber: Transcriber, @unchecked Sendable {
    private let fixture: String
    public let reportsDetectedLanguage = false

    public init(fixture: String = "Det här är en testinspelning. This is a test recording.") {
        self.fixture = fixture
    }

    public func prepare() async throws {}

    public func transcribe(samples: [Float]) async throws -> TranscriptionResult {
        let duration = Double(samples.count) / Double(WAVWriter.sampleRate)
        let words = fixture.split(separator: " ").map(String.init)
        let step = words.isEmpty ? 0 : duration / Double(words.count)
        let tokens = words.enumerated().map { i, w in
            Token(text: i == 0 ? w : " " + w, start: Double(i) * step, end: Double(i + 1) * step)
        }
        return TranscriptionResult(tokens: tokens)
    }
}
