package com.nuvio.app.features.player

import com.nuvio.app.core.ui.NuvioToastController
import com.nuvio.app.features.addons.AddonRepository
import com.nuvio.app.features.addons.enabledAddons
import com.nuvio.app.features.debrid.DebridSettingsRepository
import com.nuvio.app.features.debrid.DirectDebridPlayableResult
import com.nuvio.app.features.debrid.DirectDebridPlaybackResolver
import com.nuvio.app.features.debrid.toastMessage
import com.nuvio.app.features.details.MetaVideo
import com.nuvio.app.features.downloads.DownloadItem
import com.nuvio.app.features.downloads.DownloadsRepository
import com.nuvio.app.features.player.skip.NextEpisodeInfo
import com.nuvio.app.features.player.skip.PlayerNextEpisodeRules
import com.nuvio.app.features.streams.StreamAutoPlayMode
import com.nuvio.app.features.streams.StreamAutoPlaySelector
import com.nuvio.app.features.streams.StreamAutoPlaySource
import com.nuvio.app.features.streams.StreamItem
import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

internal fun PlayerScreenRuntime.isAtNextEpisodeThreshold(): Boolean {
    // Loading only blocks until the first load completes. After that it is a seek, rebuffer or stall
    // (AetherEngine reports all three as loading), which must not hide the card or cancel a running
    // auto-play; a seek back below the threshold still does, through the position.
    if (playbackSnapshotKey != activePlaybackKey || (playbackSnapshot.isLoading && !initialLoadCompleted) ||
        !initialSeekApplied || isScrubbingTimeline || errorMessage != null ||
        isShortPlaceholderDuration(playbackSnapshot.durationMs)
    ) return false
    // Preload: trigger source fetch before the button appears
    if (playerSettingsUiState.preloadNextEpisodeSources && !nextEpisodePreloadTriggered && nextEpisodeInfo != null) {
        val preloadLeadMs = maxOf(playerSettingsUiState.streamAutoPlayTimeoutSeconds.toLong() * 1_000L, 10_000L)
            .coerceAtMost(30_000L)
        val shouldPreloadByCard = PlayerNextEpisodeRules.shouldShowNextEpisodeCard(
            positionMs = playbackSnapshot.positionMs + preloadLeadMs,
            durationMs = playbackSnapshot.durationMs,
            skipIntervals = skipIntervals,
            thresholdMode = playerSettingsUiState.nextEpisodeThresholdMode,
            thresholdPercent = playerSettingsUiState.nextEpisodeThresholdPercent,
            thresholdMinutesBeforeEnd = playerSettingsUiState.nextEpisodeThresholdMinutesBeforeEnd,
        )
        val shouldPreloadByEnd = playbackSnapshot.durationMs > 0L &&
            (playbackSnapshot.durationMs - playbackSnapshot.positionMs) <= preloadLeadMs
        if (shouldPreloadByCard || shouldPreloadByEnd) {
            preloadNextEpisodeSources()
        }
    }
    return playbackSnapshot.isEnded || PlayerNextEpisodeRules.shouldShowNextEpisodeCard(
        positionMs = playbackSnapshot.positionMs,
        durationMs = playbackSnapshot.durationMs,
        skipIntervals = skipIntervals,
        thresholdMode = playerSettingsUiState.nextEpisodeThresholdMode,
        thresholdPercent = playerSettingsUiState.nextEpisodeThresholdPercent,
        thresholdMinutesBeforeEnd = playerSettingsUiState.nextEpisodeThresholdMinutesBeforeEnd,
    )
}

/**
 * The only points where the next episode may start on its own: the episode has ended, or playback has
 * reached the IntroDB/outro segment (and the card rule, which holds the card back over a post-credits
 * scene, agrees). Without outro data the card's threshold only shows the card, for a manual Next.
 */
internal fun PlayerScreenRuntime.isNextEpisodeAutoStartPoint(): Boolean {
    if (playbackSnapshot.isEnded) return true
    val outroStartMs = skipIntervals
        .filter { it.type in PlayerNextEpisodeRules.OUTRO_SEGMENT_TYPES }
        .minOfOrNull { (it.startTime * 1_000.0).toLong() }
        ?: return false
    return playbackSnapshot.positionMs >= outroStartMs && isAtNextEpisodeThreshold()
}

internal fun PlayerScreenRuntime.cancelNextEpisodeAutoPlay(reason: String = "reset") {
    if (nextEpisodeAutoPlayJob?.isActive == true) {
        NextEpisodeDiagnostics.log {
            "run cancelled: reason=$reason searching=$nextEpisodeAutoPlaySearching countdown=$nextEpisodeAutoPlayCountdown"
        }
    }
    nextEpisodeAutoPlayJob?.cancel()
    nextEpisodeAutoPlayJob = null
    nextEpisodeAutoPlayAutomatic = false
    nextEpisodeAutoPlaySearching = false
    nextEpisodeAutoPlaySourceName = null
    nextEpisodeAutoPlayCountdown = null
}

internal fun CoroutineScope.launchPlayerNextEpisodeAutoPlay(
    previousJob: Job?,
    nextEpisodeInfo: NextEpisodeInfo?,
    allEpisodes: List<MetaVideo>,
    parentMetaId: String,
    parentMetaType: String,
    contentType: String?,
    settings: PlayerSettingsUiState,
    currentStreamBingeGroup: String?,
    onDownloadedEpisodeSelected: (DownloadItem, MetaVideo) -> Unit,
    onEpisodeStreamSelected: (StreamItem, MetaVideo) -> Unit,
    onManualSelectionRequired: (MetaVideo) -> Unit,
    onSearchingChanged: (Boolean) -> Unit,
    onSourceNameChanged: (String?) -> Unit,
    onCountdownChanged: (Int?) -> Unit,
    onNextEpisodeCardVisibleChanged: (Boolean) -> Unit,
    prepared: PreparedNextEpisode? = null,
    /** [cancelled]: the run stopped before switching, so the preparation is still good for a later run. */
    onPreparedUnused: (prepared: PreparedNextEpisode, cancelled: Boolean) -> Unit = { _, _ -> },
    /** True while the run may wait past the auto-play timeout (addons still answering, episode not over). */
    keepWaitingAfterTimeout: () -> Boolean = { false },
): Job? {
    val nextVideoId = nextEpisodeInfo?.videoId ?: return null
    val nextVideo = allEpisodes.firstOrNull { video -> video.id == nextVideoId } ?: return null
    if (nextEpisodeInfo.hasAired != true) return null

    val downloadedNextEpisode = DownloadsRepository.findPlayableDownload(
        parentMetaId = parentMetaId,
        seasonNumber = nextVideo.season,
        episodeNumber = nextVideo.episode,
        videoId = nextVideo.id,
    )
    if (downloadedNextEpisode != null) {
        onDownloadedEpisodeSelected(downloadedNextEpisode, nextVideo)
        return null
    }

    previousJob?.cancel()
    onSearchingChanged(true)
    onSourceNameChanged(null)
    onCountdownChanged(null)

    val type = contentType ?: parentMetaType
    return launch {
        var preparedUsed = false
        try {
            val preparedStream = prepared?.takeIf { it.videoId == nextVideo.id }?.playableStream()
            val result = if (preparedStream != null) {
                NextEpisodeDiagnostics.log { "using prepared stream source=${preparedStream.name ?: preparedStream.addonName}" }
                NextEpisodeSearchResult.Selected(stream = preparedStream, sourceStream = prepared?.sourceStream ?: preparedStream)
            } else {
                searchNextEpisodeStream(
                    nextVideo, type, settings, currentStreamBingeGroup,
                    background = false,
                    keepWaitingAfterTimeout = keepWaitingAfterTimeout,
                )
            }
            onSearchingChanged(false)
            when (result) {
                is NextEpisodeSearchResult.Selected -> {
                    val selected = result.stream
                    onSourceNameChanged((selected.name?.takeIf { it.isNotBlank() } ?: selected.addonName).trim())
                    // A prepared episode switches at once: its countdown (if one is picked) already ran on
                    // the card up to this point (NextEpisodeLeadCountdown). Without one, today's countdown
                    // runs here.
                    val skipCountdown = preparedStream != null
                    if (skipCountdown) {
                        NextEpisodeDiagnostics.log { "switching at once: prepared episode ready" }
                    } else {
                        for (i in NEXT_EPISODE_COUNTDOWN_SECONDS downTo 1) {
                            onCountdownChanged(i)
                            delay(1000)
                        }
                    }
                    preparedUsed = preparedStream != null && selected === preparedStream
                    onEpisodeStreamSelected(selected, nextVideo)
                    onNextEpisodeCardVisibleChanged(false)
                    onCountdownChanged(null)
                    onSourceNameChanged(null)
                }
                is NextEpisodeSearchResult.NoSelection -> {
                    NextEpisodeDiagnostics.log {
                        "picker opened: reason=${result.reason} " +
                            "state=${NextEpisodeDiagnostics.describe(PlayerStreamsRepository.episodeStreamsState.value)}"
                    }
                    onManualSelectionRequired(nextVideo)
                    onNextEpisodeCardVisibleChanged(false)
                }
            }
        } finally {
            // Cancelled, re-resolved to a new link, or no selection: the preparation goes unused.
            if (prepared != null && !preparedUsed) onPreparedUnused(prepared, !isActive)
        }
    }
}

/** How often a search waiting past its timeout re-checks whether it should keep waiting. */
private const val KEEP_WAITING_POLL_MS = 250L

internal sealed interface NextEpisodeSearchResult {
    /** [stream] is playable (debrid-resolved); [sourceStream] is what the selector picked, for re-resolving. */
    data class Selected(val stream: StreamItem, val sourceStream: StreamItem) : NextEpisodeSearchResult
    data class NoSelection(val reason: String) : NextEpisodeSearchResult
}

/**
 * Searches the next episode's sources and applies the auto-play rules (including Prefer Binge Group),
 * then resolves the pick to a playable stream. [background] suppresses the debrid failure toast and
 * refresh, for a prepare that runs while the current episode plays.
 */
internal suspend fun searchNextEpisodeStream(
    nextVideo: MetaVideo,
    type: String,
    settings: PlayerSettingsUiState,
    currentStreamBingeGroup: String?,
    background: Boolean,
    keepWaitingAfterTimeout: () -> Boolean = { false },
): NextEpisodeSearchResult = coroutineScope {
    // Mirrors StreamAutoPlayPolicy.isEffectivelyEnabled: a user whose initial-playback source
    // gets auto-picked via "reuse last link" (or a reused binge group) shouldn't be prompted to
    // choose a source again just because they hit Next Episode instead of starting fresh.
    val shouldAutoSelectInManualMode =
        settings.streamAutoPlayMode == StreamAutoPlayMode.MANUAL &&
            (
                settings.streamAutoPlayNextEpisodeEnabled ||
                    settings.streamAutoPlayPreferBingeGroup ||
                    settings.streamReuseLastLinkEnabled
                )

    val bingeGroupOnlyManualMode =
        shouldAutoSelectInManualMode &&
            (!settings.streamAutoPlayNextEpisodeEnabled ||
                !settings.streamAutoPlayNextEpisodeFallbackEnabled) &&
            settings.streamAutoPlayPreferBingeGroup

    val effectiveMode = if (shouldAutoSelectInManualMode) {
        StreamAutoPlayMode.FIRST_STREAM
    } else {
        settings.streamAutoPlayMode
    }
    val effectiveSource = if (shouldAutoSelectInManualMode) {
        StreamAutoPlaySource.ALL_SOURCES
    } else {
        settings.streamAutoPlaySource
    }
    val effectiveSelectedAddons = if (shouldAutoSelectInManualMode) {
        emptySet()
    } else {
        settings.streamAutoPlaySelectedAddons
    }
    val effectiveSelectedPlugins = if (shouldAutoSelectInManualMode) {
        emptySet()
    } else {
        settings.streamAutoPlaySelectedPlugins
    }
    val effectiveRegex = if (shouldAutoSelectInManualMode) {
        ""
    } else {
        settings.streamAutoPlayRegex
    }
    val preferredBingeGroup = if (settings.streamAutoPlayPreferBingeGroup) {
        currentStreamBingeGroup
    } else {
        null
    }

    PlayerStreamsRepository.loadEpisodeStreams(
        type = type,
        videoId = nextVideo.id,
        season = nextVideo.season,
        episode = nextVideo.episode,
    )
    NextEpisodeDiagnostics.log {
        "search start next=${nextVideo.id} mode=$effectiveMode timeout=${settings.streamAutoPlayTimeoutSeconds}s " +
            "bingeGroup=$preferredBingeGroup bingeOnly=$bingeGroupOnlyManualMode " +
            "state=${NextEpisodeDiagnostics.describe(PlayerStreamsRepository.episodeStreamsState.value)}"
    }

    if (effectiveMode == StreamAutoPlayMode.MANUAL) {
        return@coroutineScope NextEpisodeSearchResult.NoSelection("manual mode (no auto-select rule enabled)")
    }

    val installedAddonNames = AddonRepository.uiState.value.addons
        .enabledAddons()
        .map { it.displayTitle }
        .toSet()
    val debridSettings = DebridSettingsRepository.snapshot()

    val timeoutSeconds = settings.streamAutoPlayTimeoutSeconds
    var autoSelectTriggered = false
    var timeoutElapsed = false
    var selectedStream: StreamItem? = null
    var selectedVia: String? = null
    val autoSelectSettled = CompletableDeferred<Unit>()

    fun settleAutoSelect() {
        if (!autoSelectSettled.isCompleted) {
            autoSelectSettled.complete(Unit)
        }
    }

    fun selectStream(stream: StreamItem, via: String) {
        selectedVia = via
        autoSelectTriggered = true
        selectedStream = stream
        settleAutoSelect()
    }

    fun finishWithoutSelection() {
        autoSelectTriggered = true
        settleAutoSelect()
    }

    fun trySelectStream(streams: List<StreamItem>): StreamItem? =
        StreamAutoPlaySelector.selectAutoPlayStream(
            streams = streams,
            mode = effectiveMode,
            regexPattern = effectiveRegex,
            source = effectiveSource,
            installedAddonNames = installedAddonNames,
            selectedAddons = effectiveSelectedAddons,
            selectedPlugins = effectiveSelectedPlugins,
            preferredBingeGroup = preferredBingeGroup,
            preferBingeGroupInSelection = settings.streamAutoPlayPreferBingeGroup,
            bingeGroupOnly = bingeGroupOnlyManualMode,
            debridEnabled = debridSettings.canResolvePlayableLinks,
            activeResolverProviderId = debridSettings.activeResolverProviderId,
        )

    fun tryBingeGroupOnly(streams: List<StreamItem>): StreamItem? {
        if (preferredBingeGroup == null || !settings.streamAutoPlayPreferBingeGroup) return null
        return StreamAutoPlaySelector.selectAutoPlayStream(
            streams = streams,
            mode = effectiveMode,
            regexPattern = effectiveRegex,
            source = effectiveSource,
            installedAddonNames = installedAddonNames,
            selectedAddons = effectiveSelectedAddons,
            selectedPlugins = effectiveSelectedPlugins,
            preferredBingeGroup = preferredBingeGroup,
            preferBingeGroupInSelection = true,
            bingeGroupOnly = true,
            debridEnabled = debridSettings.canResolvePlayableLinks,
            activeResolverProviderId = debridSettings.activeResolverProviderId,
        )
    }

    val innerJob = launch {
        PlayerStreamsRepository.episodeStreamsState.collectLatest { state ->
            if (state.groups.isEmpty() && state.isAnyLoading) return@collectLatest

            val allStreams = state.groups.flatMap { it.streams }

            if (autoSelectTriggered) {
                // Already resolved.
            } else if (timeoutElapsed) {
                if (allStreams.isNotEmpty()) {
                    val candidate = trySelectStream(allStreams)
                    if (candidate != null) {
                        selectStream(candidate, "after timeout")
                    }
                }
            } else if (allStreams.isNotEmpty()) {
                val earlyMatch = tryBingeGroupOnly(allStreams)
                if (earlyMatch != null) {
                    selectStream(earlyMatch, "early binge-group match")
                }
            }

            if (!autoSelectTriggered && !state.isAnyLoading) {
                if (allStreams.isNotEmpty()) {
                    val candidate = trySelectStream(allStreams)
                    if (candidate != null) {
                        selectStream(candidate, "all addons answered")
                    }
                }
                if (!autoSelectTriggered) {
                    finishWithoutSelection()
                }
                return@collectLatest
            }

            if (autoSelectTriggered) return@collectLatest
        }
    }

    val timeoutMs = timeoutSeconds * 1_000L
    val isBoundedTimeout = timeoutSeconds in 1..30

    if (isBoundedTimeout) {
        // If streams are already cached (preload), autoSelectSettled
        // completes immediately. Don't wait the full timeout in that case.
        val settled = kotlinx.coroutines.withTimeoutOrNull(timeoutMs) { autoSelectSettled.await() }
        if (settled == null) {
            timeoutElapsed = true
            NextEpisodeDiagnostics.log {
                "search timeout ${timeoutSeconds}s: ${NextEpisodeDiagnostics.describe(PlayerStreamsRepository.episodeStreamsState.value)}"
            }
            if (!autoSelectTriggered) {
                val allStreams = PlayerStreamsRepository.episodeStreamsState.value.groups.flatMap { it.streams }
                if (allStreams.isNotEmpty()) {
                    val candidate = trySelectStream(allStreams)
                    if (candidate != null) {
                        selectStream(candidate, "at timeout")
                    }
                }
            }
            if (!autoSelectTriggered && keepWaitingAfterTimeout()) {
                // Addons still answering and the episode not over: wait for them instead of opening the
                // picker. The collector above (now past the timeout) selects the first stream that passes
                // the filters, or settles when every addon has answered; the wait ends early when the
                // episode ends.
                NextEpisodeDiagnostics.log { "timeout before the end: waiting for the remaining addons" }
                withTimeoutOrNull(NEXT_EPISODE_HARD_TIMEOUT_MS) {
                    while (!autoSelectSettled.isCompleted && keepWaitingAfterTimeout()) {
                        withTimeoutOrNull(KEEP_WAITING_POLL_MS) { autoSelectSettled.await() }
                    }
                }
                NextEpisodeDiagnostics.log {
                    "wait ended: selected=${selectedStream != null} settled=${autoSelectSettled.isCompleted} " +
                        "stillWaiting=${keepWaitingAfterTimeout()} ${NextEpisodeDiagnostics.describe(PlayerStreamsRepository.episodeStreamsState.value)}"
                }
            }
        }
        innerJob.cancel()
        if (selectedStream == null && !autoSelectTriggered) {
            finishWithoutSelection()
        }
    } else {
        timeoutElapsed = true
        if (!autoSelectTriggered) {
            val allStreams = PlayerStreamsRepository.episodeStreamsState.value.groups.flatMap { it.streams }
            if (allStreams.isNotEmpty()) {
                trySelectStream(allStreams)?.let { selectStream(it, "cached before wait") }
            }
        }
        val completed = withTimeoutOrNull(NEXT_EPISODE_HARD_TIMEOUT_MS) { autoSelectSettled.await() }
        innerJob.cancel()
        if (completed == null && !autoSelectTriggered) {
            val allStreams = PlayerStreamsRepository.episodeStreamsState.value.groups.flatMap { it.streams }
            if (allStreams.isNotEmpty()) {
                selectedStream = trySelectStream(allStreams)
                if (selectedStream != null) selectedVia = "at hard timeout"
            }
            finishWithoutSelection()
        }
    }

    val decisionState = PlayerStreamsRepository.episodeStreamsState.value
    NextEpisodeDiagnostics.log {
        val stream = selectedStream
        if (stream != null) {
            "auto-select decided via=$selectedVia source=${stream.name ?: stream.addonName} " +
                "addon=${stream.addonName} bingeGroup=${stream.behaviorHints.bingeGroup} " +
                "state=${NextEpisodeDiagnostics.describe(decisionState)}"
        } else {
            "auto-select decided: no stream state=${NextEpisodeDiagnostics.describe(decisionState)}"
        }
    }
    var debridFailure: String? = null
    val selected = selectedStream?.let { stream ->
        when (val result = DirectDebridPlaybackResolver.resolveToPlayableStream(stream, nextVideo.season, nextVideo.episode)) {
            is DirectDebridPlayableResult.Success -> result.stream
            else -> {
                debridFailure = result::class.simpleName ?: "unknown"
                // A background prepare stays silent; the transition retries through today's flow.
                if (!background) {
                    result.toastMessage()?.let { NuvioToastController.show(it) }
                    PlayerStreamsRepository.loadEpisodeStreams(
                        type = type,
                        videoId = nextVideo.id,
                        season = nextVideo.season,
                        episode = nextVideo.episode,
                        forceRefresh = true,
                    )
                }
                null
            }
        }
    }
    val source = selectedStream
    if (selected != null && source != null) {
        NextEpisodeSearchResult.Selected(stream = selected, sourceStream = source)
    } else {
        val streams = decisionState.groups.flatMap { it.streams }
        NextEpisodeSearchResult.NoSelection(
            when {
                debridFailure != null -> "debrid resolve failed ($debridFailure)"
                streams.isEmpty() && decisionState.isAnyLoading -> "search timed out with no streams yet"
                streams.isEmpty() -> "no sources"
                preferredBingeGroup != null && tryBingeGroupOnly(streams) == null ->
                    if (bingeGroupOnlyManualMode) {
                        "binge-group miss (group=$preferredBingeGroup), fallback not allowed"
                    } else {
                        "binge-group miss (group=$preferredBingeGroup) then fallback failed: nothing passed the auto-play filters"
                    }
                decisionState.isAnyLoading -> "search timed out: nothing passed the auto-play filters so far"
                else -> "nothing passed the auto-play filters"
            },
        )
    }
}

internal fun PlayerScreenRuntime.preloadNextEpisodeSources() {
    if (nextEpisodePreloadTriggered) return
    val nextEp = nextEpisodeInfo ?: return
    if (nextEp.hasAired != true) return
    val type = contentType ?: return

    nextEpisodePreloadTriggered = true
    NextEpisodeDiagnostics.log { "preload start next=${nextEp.videoId} pos=${playbackSnapshot.positionMs} dur=${playbackSnapshot.durationMs}" }
    nextEpisodePreloadJob?.cancel()
    nextEpisodePreloadJob = scope.launch {
        PlayerStreamsRepository.loadEpisodeStreams(
            type = type,
            videoId = nextEp.videoId,
            season = nextEp.season,
            episode = nextEp.episode
        )
    }
}

internal fun PlayerScreenRuntime.cancelNextEpisodePreload() {
    nextEpisodePreloadJob?.cancel()
    nextEpisodePreloadJob = null
    nextEpisodePreloadTriggered = false
}
