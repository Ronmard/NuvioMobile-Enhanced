package com.nuvio.app.features.player

import com.nuvio.app.core.logging.InAppLogger
import com.nuvio.app.features.streams.StreamsUiState
import kotlin.time.TimeSource

/**
 * Next-episode diagnostics: `[NextEp]` lines on stdout (Xcode console, `devicectl --console`) and in
 * Settings -> Advanced -> Debug Logs. Off by default; set [enabled] to trace when the next-episode
 * search starts, when the auto-select decides, why the manual picker opened instead, and what
 * cancelled a run. Timings are relative to the last trigger ([markTrigger]).
 */
internal object NextEpisodeDiagnostics {
    var enabled = false

    private var triggerMark: TimeSource.Monotonic.ValueTimeMark? = null

    fun markTrigger(cause: String, videoId: String?) {
        if (!enabled) return
        triggerMark = TimeSource.Monotonic.markNow()
        log { "trigger cause=$cause next=$videoId" }
    }

    fun log(message: () -> String) {
        if (!enabled) return
        val elapsed = triggerMark?.elapsedNow()?.inWholeMilliseconds
        val line = if (elapsed != null) "+${elapsed}ms ${message()}" else message()
        println("[NextEp] $line")
        InAppLogger.info("NextEp", line)
    }

    /** "N of M addons answered" plus stream and error counts for the shared episode stream state. */
    fun describe(state: StreamsUiState): String {
        val answered = state.groups.count { !it.isLoading }
        val errors = state.groups.count { it.error != null }
        val streams = state.groups.sumOf { it.streams.size }
        return "$answered of ${state.groups.size} addons answered, streams=$streams errors=$errors " +
            "loading=${state.isAnyLoading} empty=${state.emptyStateReason}"
    }
}

/** Why the threshold check failed, for cancellation logs. */
internal fun PlayerScreenRuntime.nextEpisodeThresholdBlockers(): String = buildList {
    if (playbackSnapshotKey != activePlaybackKey) add("snapshotKeyMismatch")
    if (playbackSnapshot.isLoading && !initialLoadCompleted) add("initialLoading")
    if (!initialSeekApplied) add("initialSeekPending")
    if (isScrubbingTimeline) add("scrubbing")
    if (errorMessage != null) add("error")
    if (nextEpisodeCardDismissed) add("cardDismissed")
}.joinToString(",").ifEmpty { "belowThreshold" } +
    " pos=${playbackSnapshot.positionMs} dur=${playbackSnapshot.durationMs} ended=${playbackSnapshot.isEnded}"
