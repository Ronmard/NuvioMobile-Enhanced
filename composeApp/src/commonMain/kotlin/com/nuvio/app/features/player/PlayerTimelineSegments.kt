package com.nuvio.app.features.player

import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipPath
import com.nuvio.app.core.ui.themePalette
import com.nuvio.app.features.player.skip.AutoSkipSegmentType
import com.nuvio.app.features.player.skip.SkipInterval

/** The kinds of skip segment the seek bar marks, each in its own color. */
internal enum class PlayerTimelineSegmentKind { INTRO, RECAP, OUTRO, POST_CREDITS }

/** A skip segment as a band on the seek bar, in fractions of the duration; [source] is its interval's index. */
@Immutable
internal data class PlayerTimelineSegment(
    val start: Float,
    val end: Float,
    val kind: PlayerTimelineSegmentKind,
    val source: Int,
)

internal fun SkipInterval.timelineSegmentKind(): PlayerTimelineSegmentKind? =
    if (type.trim().equals("post-credits", ignoreCase = true)) {
        PlayerTimelineSegmentKind.POST_CREDITS
    } else {
        when (AutoSkipSegmentType.fromSkipIntervalType(type)) {
            AutoSkipSegmentType.INTRO -> PlayerTimelineSegmentKind.INTRO
            AutoSkipSegmentType.RECAP -> PlayerTimelineSegmentKind.RECAP
            AutoSkipSegmentType.OUTRO, AutoSkipSegmentType.MOVIE_CREDITS -> PlayerTimelineSegmentKind.OUTRO
            null -> null
        }
    }

/** The bands for these intervals, clamped to the duration; none until the duration is known. */
internal fun List<SkipInterval>.timelineSegments(durationMs: Long): List<PlayerTimelineSegment> {
    if (isEmpty() || durationMs <= 0L) return emptyList()
    val durationSec = durationMs / 1000.0
    return mapIndexedNotNull { index, interval ->
        val kind = interval.timelineSegmentKind() ?: return@mapIndexedNotNull null
        if (interval.startTime.isNaN() || interval.endTime.isNaN()) return@mapIndexedNotNull null
        val start = (interval.startTime / durationSec).coerceIn(0.0, 1.0).toFloat()
        val end = (interval.endTime / durationSec).coerceIn(0.0, 1.0).toFloat()
        if (end > start) PlayerTimelineSegment(start, end, kind, index) else null
    }
}

@Immutable
internal class PlayerTimelineSegmentColors(
    private val intro: Color,
    private val recap: Color,
    private val outro: Color,
    private val postCredits: Color,
) {
    fun of(kind: PlayerTimelineSegmentKind): Color = when (kind) {
        PlayerTimelineSegmentKind.INTRO -> intro
        PlayerTimelineSegmentKind.RECAP -> recap
        PlayerTimelineSegmentKind.OUTRO -> outro
        PlayerTimelineSegmentKind.POST_CREDITS -> postCredits
    }
}

@Composable
internal fun rememberPlayerTimelineSegmentColors(): PlayerTimelineSegmentColors {
    val palette = MaterialTheme.themePalette
    return remember(palette) {
        PlayerTimelineSegmentColors(
            intro = palette.secondary,
            recap = palette.secondaryVariant,
            outro = palette.focusRing,
            postCredits = Color.White,
        )
    }
}

private const val PlayerTimelineSegmentAlpha = 0.45f

private const val PlayerTimelineCurrentSegmentAlpha = 0.8f

/**
 * Draws [segments] across the track at [top], [height] high, from [fromX] on, with the one under
 * [positionFraction] stronger. Bands are clipped to the track's rounded caps through [clip], a
 * reused path. Draw them under the progress fill: the played part stays the plain fill.
 */
internal fun DrawScope.drawTimelineSegments(
    segments: List<PlayerTimelineSegment>,
    colors: PlayerTimelineSegmentColors,
    positionFraction: Float,
    top: Float,
    height: Float,
    clip: Path,
    fromX: Float = 0f,
) {
    if (segments.isEmpty()) return
    var current = -1
    for (segment in segments) {
        if (positionFraction >= segment.start && positionFraction < segment.end) {
            current = segment.source
            break
        }
    }
    clip.reset()
    clip.addRoundRect(RoundRect(0f, top, size.width, top + height, CornerRadius(height / 2f)))
    clipPath(clip) {
        for (segment in segments) {
            val left = maxOf(size.width * segment.start, fromX)
            val right = size.width * segment.end
            if (right <= left) continue
            drawRect(
                color = colors.of(segment.kind),
                topLeft = Offset(left, top),
                size = Size(right - left, height),
                alpha = if (segment.source == current) PlayerTimelineCurrentSegmentAlpha else PlayerTimelineSegmentAlpha,
            )
        }
    }
}
