package com.nuvio.app.features.player

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import com.nuvio.app.features.debrid.DirectDebridPlayableResult
import com.nuvio.app.features.debrid.DirectDebridPlaybackResolver
import com.nuvio.app.features.downloads.DownloadsRepository
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.minutes
import kotlin.time.TimeSource

/** A sample this close after the previous one (and not before it) is normal playback, not a seek. */
private const val PREPARE_CONTINUITY_MS = 3_000L

/** After a seek or resume lands past the mark, this much uninterrupted playback also prepares. */
private const val PREPARE_SETTLE_MS = 10_000L

/** Debrid links are cached for 15 minutes (DirectDebridResolver); re-resolve a prepared pick after that. */
private val PREPARED_STREAM_MAX_AGE = 15.minutes

/** The next episode's source, selected with the usual auto-play rules while the current one plays. */
internal class PreparedNextEpisode(
    val videoId: String,
    val season: Int?,
    val episode: Int?,
    /** Playable (debrid-resolved) stream. */
    val stream: StreamItem,
    /** The selector's pick, kept for re-resolving an expired link. */
    val sourceStream: StreamItem,
) {
    private val preparedAt = TimeSource.Monotonic.markNow()

    /** The prepared stream, re-resolved when its link may have expired; null when that fails. */
    suspend fun playableStream(): StreamItem? {
        if (preparedAt.elapsedNow() < PREPARED_STREAM_MAX_AGE) return stream
        NextEpisodeDiagnostics.log { "prepared link is ${preparedAt.elapsedNow().inWholeMinutes} min old, re-resolving" }
        return when (val result = DirectDebridPlaybackResolver.resolveToPlayableStream(sourceStream, season, episode)) {
            is DirectDebridPlayableResult.Success -> result.stream
            else -> {
                NextEpisodeDiagnostics.log { "re-resolve failed (${result::class.simpleName}), falling back" }
                null
            }
        }
    }
}

/**
 * Prepare-next-episode bookkeeping for one player screen: which episode it tracks, the previous
 * position sample (to tell playback from seeks), and the prepare job and its result.
 */
internal class NextEpisodePrepareState {
    var episodeVideoId: String? = null
    var playbackKey: PlaybackKey? = null
    var lastPositionMs: Long? = null
    var settleAnchorMs: Long? = null
    var fired = false
    var job: Job? = null
    var prepared: PreparedNextEpisode? = null
}

@Composable
internal fun PlayerScreenRuntime.BindNextEpisodePrepareEffects() {
    LaunchedEffect(
        activePlaybackKey,
        playbackSnapshotKey,
        playbackSnapshot.positionMs,
        playbackSnapshot.durationMs,
        initialLoadCompleted,
        isScrubbingTimeline,
        nextEpisodeInfo,
        playerSettingsUiState.prepareNextEpisodeEnabled,
        playerSettingsUiState.prepareNextEpisodePercent,
        playerSettingsUiState.streamAutoPlayNextEpisodeEnabled,
    ) {
        onNextEpisodePrepareTick()
    }

    DisposableEffect(Unit) {
        onDispose { discardPreparedNextEpisode("left player") }
    }
}

private fun PlayerScreenRuntime.onNextEpisodePrepareTick() {
    val state = nextEpisodePrepare
    val videoId = activeVideoId
    if (state.episodeVideoId != videoId) {
        discardPreparedNextEpisode("episode changed", rearm = true)
        state.episodeVideoId = videoId
        state.playbackKey = activePlaybackKey
        state.lastPositionMs = null
    } else if (state.playbackKey != activePlaybackKey) {
        discardPreparedNextEpisode("source changed", rearm = true)
        state.playbackKey = activePlaybackKey
        state.lastPositionMs = null
    }

    val settings = playerSettingsUiState
    val next = nextEpisodeInfo
    // Series only: movies, live TV and finales (no next episode) have nothing to prepare.
    if (!settings.prepareNextEpisodeEnabled || !settings.streamAutoPlayNextEpisodeEnabled ||
        isMoviePlayback || isLiveTvPlayback || next == null || next.hasAired != true
    ) {
        if (state.fired) discardPreparedNextEpisode("prepare no longer applies", rearm = true)
        return
    }

    val durationMs = playbackSnapshot.durationMs
    if (playbackSnapshotKey != activePlaybackKey || !initialLoadCompleted || isScrubbingTimeline ||
        errorMessage != null || durationMs <= 0L || isShortPlaceholderDuration(durationMs)
    ) return

    val positionMs = playbackSnapshot.positionMs
    val triggerMs = (durationMs * settings.prepareNextEpisodePercent.coerceIn(1f, 99f) / 100f).toLong()
    val lastMs = state.lastPositionMs
    state.lastPositionMs = positionMs
    val continuous = lastMs != null && positionMs - lastMs in 0..PREPARE_CONTINUITY_MS
    if (!continuous) state.settleAnchorMs = positionMs

    if (positionMs < triggerMs) {
        if (state.fired) discardPreparedNextEpisode("seeked back below the trigger", rearm = true)
        return
    }
    if (state.fired || lastMs == null) return

    // Fires when normal playback crosses the mark. A seek or resume that lands past it waits until
    // playback has run on for PREPARE_SETTLE_MS, so scrubbing around the end opens no connections.
    val crossed = continuous && lastMs < triggerMs
    val settled = continuous && positionMs - maxOf(state.settleAnchorMs ?: positionMs, triggerMs) >= PREPARE_SETTLE_MS
    if (crossed || settled) {
        startNextEpisodePrepare(cause = if (crossed) "playback crossed" else "settled after seek")
    }
}

private fun PlayerScreenRuntime.startNextEpisodePrepare(cause: String) {
    val state = nextEpisodePrepare
    val next = nextEpisodeInfo ?: return
    val nextVideo = playerMetaVideos.firstOrNull { it.id == next.videoId } ?: return
    state.fired = true
    NextEpisodeDiagnostics.markTrigger(
        cause = "prepare at ${playerSettingsUiState.prepareNextEpisodePercent}% ($cause)",
        videoId = nextVideo.id,
    )

    val downloaded = DownloadsRepository.findPlayableDownload(
        parentMetaId = parentMetaId,
        seasonNumber = nextVideo.season,
        episodeNumber = nextVideo.episode,
        videoId = nextVideo.id,
    )
    if (downloaded != null) {
        NextEpisodeDiagnostics.log { "prepare skipped: next episode is downloaded" }
        return
    }

    val type = contentType ?: parentMetaType
    val settings = playerSettingsUiState
    val bingeGroup = currentStreamBingeGroup
    state.job = scope.launch {
        when (val result = searchNextEpisodeStream(nextVideo, type, settings, bingeGroup, background = true)) {
            is NextEpisodeSearchResult.Selected -> {
                state.prepared = PreparedNextEpisode(
                    videoId = nextVideo.id,
                    season = nextVideo.season,
                    episode = nextVideo.episode,
                    stream = result.stream,
                    sourceStream = result.sourceStream,
                )
                NextEpisodeDiagnostics.log {
                    "prepared next=${nextVideo.id} source=${result.stream.name ?: result.stream.addonName}"
                }
            }
            is NextEpisodeSearchResult.NoSelection ->
                NextEpisodeDiagnostics.log { "prepare found no auto-select stream: ${result.reason}" }
        }
    }
}

/** Hands over the prepared stream for [nextVideoId], if one is ready; any other preparation is dropped. */
internal fun PlayerScreenRuntime.takePreparedNextEpisode(nextVideoId: String): PreparedNextEpisode? {
    val prepared = nextEpisodePrepare.prepared?.takeIf { it.videoId == nextVideoId }
    if (prepared == null) {
        if (nextEpisodePrepare.job?.isActive == true) {
            NextEpisodeDiagnostics.log { "prepare still running at the transition, using today's flow" }
        }
        discardPreparedNextEpisode("not ready at the transition")
        return null
    }
    nextEpisodePrepare.prepared = null
    nextEpisodePrepare.job = null
    return prepared
}

/** [rearm] lets the trigger fire again for this episode (a seek back below it, a new source). */
internal fun PlayerScreenRuntime.discardPreparedNextEpisode(reason: String, rearm: Boolean = false) {
    val state = nextEpisodePrepare
    if (state.job?.isActive == true || state.prepared != null) {
        NextEpisodeDiagnostics.log { "prepared next episode discarded: $reason" }
    }
    state.job?.cancel()
    state.job = null
    state.prepared = null
    if (rearm) state.fired = false
}
