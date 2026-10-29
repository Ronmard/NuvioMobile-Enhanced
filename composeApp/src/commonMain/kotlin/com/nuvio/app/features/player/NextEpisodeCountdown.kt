package com.nuvio.app.features.player

import com.nuvio.app.features.player.skip.PlayerNextEpisodeRules
import com.nuvio.app.features.watching.domain.isShortPlaceholderDuration

/** Precision of the switch-point search below; finer than one position update. */
private const val AUTO_START_SEARCH_PRECISION_MS = 100L

/**
 * The countdown on the card before a prepared next episode starts: the length picked in "Countdown
 * Before Next Episode", ending exactly where the next episode starts on its own. It follows the
 * playback position, so it pauses with playback and follows seeks.
 */
internal data class NextEpisodeLeadCountdown(
    val remainingMs: Long,
    val totalMs: Long,
    val sourceName: String,
) {
    val remainingSeconds: Int get() = ((remainingMs + 999) / 1_000).toInt()
    val remainingFraction: Float get() = (remainingMs.toFloat() / totalMs).coerceIn(0f, 1f)
}

/**
 * Where the next episode starts on its own (see [isNextEpisodeAutoStartPoint]): the end of the
 * episode without outro data, otherwise the first position from the outro start on where the card
 * rule agrees, which is the outro start itself unless the rule holds back over a post-credits scene.
 * The rule only ever asks "position >= some point", so a binary search finds that position.
 */
internal fun PlayerScreenRuntime.nextEpisodeAutoStartPositionMs(): Long? {
    val durationMs = playbackSnapshot.durationMs
    if (durationMs <= 0L || isShortPlaceholderDuration(durationMs)) return null
    val outroStartMs = skipIntervals
        .filter { it.type in PlayerNextEpisodeRules.OUTRO_SEGMENT_TYPES }
        .minOfOrNull { (it.startTime * 1_000.0).toLong() }
        ?: return durationMs
    val settings = playerSettingsUiState
    fun cardRuleAt(positionMs: Long) = PlayerNextEpisodeRules.shouldShowNextEpisodeCard(
        positionMs = positionMs,
        durationMs = durationMs,
        skipIntervals = skipIntervals,
        thresholdMode = settings.nextEpisodeThresholdMode,
        thresholdPercent = settings.nextEpisodeThresholdPercent,
        thresholdMinutesBeforeEnd = settings.nextEpisodeThresholdMinutesBeforeEnd,
    )
    var low = outroStartMs.coerceIn(0L, durationMs)
    if (cardRuleAt(low)) return low
    var high = durationMs
    if (!cardRuleAt(high)) return durationMs
    while (high - low > AUTO_START_SEARCH_PRECISION_MS) {
        val mid = (low + high) / 2
        if (cardRuleAt(mid)) high = mid else low = mid
    }
    return high
}

/** The countdown to show now, or null: only for a ready preparation, inside the picked lead time. */
internal fun PlayerScreenRuntime.nextEpisodeLeadCountdown(): NextEpisodeLeadCountdown? {
    val totalMs = playerSettingsUiState.nextEpisodeCountdownSeconds * 1_000L
    if (totalMs <= 0L) return null
    if (!playerSettingsUiState.streamAutoPlayNextEpisodeEnabled || nextEpisodeCardDismissed || isPartyControlLocked) return null
    if (playbackSnapshotKey != activePlaybackKey || !initialLoadCompleted || isScrubbingTimeline ||
        errorMessage != null || playbackSnapshot.isEnded
    ) return null
    // A run in progress (the switch itself, or today's flow) owns the card.
    if (nextEpisodeAutoPlayJob?.isActive == true) return null
    val next = nextEpisodeInfo?.takeIf { it.hasAired } ?: return null
    val prepared = nextEpisodePrepare.prepared?.takeIf { it.videoId == next.videoId } ?: return null
    val startMs = nextEpisodeAutoStartPositionMs() ?: return null
    val remainingMs = startMs - playbackSnapshot.positionMs
    if (remainingMs <= 0L || remainingMs > totalMs) return null
    return NextEpisodeLeadCountdown(
        remainingMs = remainingMs,
        totalMs = totalMs,
        sourceName = (prepared.stream.name?.takeIf { it.isNotBlank() } ?: prepared.stream.addonName).trim(),
    )
}
