package com.nuvio.app.features.player.skip

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.dismiss
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil3.compose.AsyncImage
import com.nuvio.app.core.ui.PlatformBackHandler
import com.nuvio.app.features.player.NEXT_EPISODE_COUNTDOWN_SECONDS
import nuvio.composeapp.generated.resources.Res
import nuvio.composeapp.generated.resources.compose_player_episode_title_format
import nuvio.composeapp.generated.resources.detail_btn_play
import nuvio.composeapp.generated.resources.player_next_episode
import nuvio.composeapp.generated.resources.player_next_episode_finding_source
import nuvio.composeapp.generated.resources.player_next_episode_playing_via_countdown
import nuvio.composeapp.generated.resources.player_next_episode_thumbnail
import nuvio.composeapp.generated.resources.player_next_episode_unaired
import org.jetbrains.compose.resources.stringResource
import com.nuvio.app.core.ui.glass.ambientLiquidGlass

@Composable
fun NextEpisodeCard(
    nextEpisode: NextEpisodeInfo?,
    visible: Boolean,
    isAutoPlaySearching: Boolean,
    autoPlaySourceName: String?,
    autoPlayCountdownSec: Int?,
    /** Set for the lead countdown before a prepared episode: the share of it still left. */
    autoPlayCountdownFraction: Float? = null,
    blurred: Boolean,
    onPlayNext: () -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    if (nextEpisode == null) return

    PlatformBackHandler(enabled = visible, onBack = onDismiss)
    val isPlayable = nextEpisode.hasAired
    var dragOffsetX by remember(nextEpisode.videoId) { mutableFloatStateOf(0f) }
    var dragging by remember(nextEpisode.videoId) { mutableStateOf(false) }
    val animatedOffsetX by animateFloatAsState(
        targetValue = dragOffsetX,
        animationSpec = if (dragging) snap() else tween(160),
        label = "next_episode_swipe",
    )
    val dismissThreshold = with(LocalDensity.current) { 60.dp.toPx() }
    val currentOnDismiss by rememberUpdatedState(onDismiss)

    LaunchedEffect(nextEpisode.videoId, visible) {
        if (visible) {
            dragging = false
            dragOffsetX = 0f
        }
    }
    // The countdown and the card's visibility drop in the same frame at the switch; the ring keeps its
    // last value while the card animates out instead of the Play badge flashing in.
    var exitCountdownSec by remember(nextEpisode.videoId) { mutableStateOf<Int?>(null) }
    var exitCountdownFraction by remember(nextEpisode.videoId) { mutableStateOf<Float?>(null) }
    LaunchedEffect(autoPlayCountdownSec, autoPlayCountdownFraction, visible) {
        if (visible) {
            exitCountdownSec = autoPlayCountdownSec
            exitCountdownFraction = autoPlayCountdownFraction
        }
    }
    val ringCountdownSec = if (visible) autoPlayCountdownSec else exitCountdownSec
    val ringCountdownFraction = if (visible) autoPlayCountdownFraction else exitCountdownFraction

    AnimatedVisibility(
        visible = visible,
        enter = slideInHorizontally(animationSpec = tween(260), initialOffsetX = { it / 2 }) +
            fadeIn(animationSpec = tween(220)),
        exit = slideOutHorizontally(animationSpec = tween(200), targetOffsetX = { it / 2 }) +
            fadeOut(animationSpec = tween(160)),
        modifier = modifier,
    ) {
        val shape = RoundedCornerShape(16.dp)
        Row(
            modifier = Modifier
                .widthIn(max = 292.dp)
                .graphicsLayer { translationX = animatedOffsetX }
                .clip(shape)
                .ambientLiquidGlass(
                    shape = shape,
                    tint = Color(0xFF191919).copy(alpha = 0.64f),
                    fallback = Color(0xFF191919).copy(alpha = 0.89f),
                    blurRadius = 20.dp,
                    refractionHeight = 10.dp,
                    refractionAmount = 14.dp,
                )
                .border(1.dp, Color.White.copy(alpha = 0.12f), shape)
                .pointerInput(nextEpisode.videoId, visible, dismissThreshold) {
                    if (!visible) return@pointerInput
                    detectHorizontalDragGestures(
                        onDragStart = {
                            dragOffsetX = animatedOffsetX
                            dragging = true
                        },
                        onHorizontalDrag = { change, amount ->
                            change.consume()
                            dragOffsetX = (dragOffsetX + amount).coerceAtLeast(0f)
                        },
                        onDragEnd = {
                            dragging = false
                            if (dragOffsetX >= dismissThreshold) {
                                currentOnDismiss()
                            } else {
                                dragOffsetX = 0f
                            }
                        },
                        onDragCancel = {
                            dragging = false
                            dragOffsetX = 0f
                        },
                    )
                }
                .semantics {
                    if (visible) dismiss { currentOnDismiss(); true }
                }
                .clickable(enabled = visible) { if (isPlayable) onPlayNext() }
                .padding(horizontal = 9.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Thumbnail
            Box(
                modifier = Modifier
                    .size(width = 78.dp, height = 44.dp)
                    .clip(RoundedCornerShape(9.dp)),
            ) {
                AsyncImage(
                    model = nextEpisode.thumbnail,
                    contentDescription = stringResource(Res.string.player_next_episode_thumbnail),
                    modifier = Modifier
                        .fillMaxSize()
                        .then(if (blurred) Modifier.blur(18.dp) else Modifier),
                    contentScale = ContentScale.Crop,
                )
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .background(
                            Brush.verticalGradient(
                                colors = listOf(
                                    Color.Transparent,
                                    Color.Black.copy(alpha = 0.32f),
                                ),
                            ),
                        ),
                )
            }

            Spacer(modifier = Modifier.width(8.dp))

            // Info
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    text = stringResource(Res.string.player_next_episode),
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                )
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = stringResource(
                        Res.string.compose_player_episode_title_format,
                        nextEpisode.season,
                        nextEpisode.episode,
                        nextEpisode.title,
                    ),
                    color = Color.White,
                    fontSize = 12.sp,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    fontWeight = FontWeight.SemiBold,
                )
                val autoPlayStatus = when {
                    !isPlayable && !nextEpisode.unairedMessage.isNullOrBlank() -> nextEpisode.unairedMessage
                    isAutoPlaySearching -> stringResource(Res.string.player_next_episode_finding_source)
                    !autoPlaySourceName.isNullOrBlank() && autoPlayCountdownSec != null ->
                        stringResource(
                            Res.string.player_next_episode_playing_via_countdown,
                            autoPlaySourceName,
                            autoPlayCountdownSec,
                        )
                    else -> null
                }
                if (autoPlayStatus != null) {
                    Spacer(modifier = Modifier.height(2.dp))
                    Text(
                        text = autoPlayStatus,
                        color = Color.White.copy(alpha = 0.78f),
                        fontSize = 10.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }

            if (ringCountdownSec != null) {
                NextEpisodeCountdownRing(
                    countdownSec = ringCountdownSec,
                    remainingFraction = ringCountdownFraction,
                    resetKey = nextEpisode.videoId,
                    modifier = Modifier.padding(start = 4.dp),
                )
            } else {
                // Play badge
                Row(
                    modifier = Modifier
                        .padding(start = 4.dp)
                        .clip(CircleShape)
                        .border(1.dp, Color.White.copy(alpha = 0.2f), CircleShape)
                        .padding(horizontal = 8.dp, vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        imageVector = Icons.Default.PlayArrow,
                        contentDescription = null,
                        tint = if (isPlayable) Color.White else Color.White.copy(alpha = 0.65f),
                        modifier = Modifier.size(13.dp),
                    )
                    Text(
                        text = if (isPlayable) {
                            stringResource(Res.string.detail_btn_play)
                        } else {
                            stringResource(Res.string.player_next_episode_unaired)
                        },
                        color = if (isPlayable) Color.White else Color.White.copy(alpha = 0.72f),
                        fontSize = 11.sp,
                        modifier = Modifier.padding(start = 3.dp),
                    )
                }
            }
        }
    }
}

/**
 * The countdown as a ring that empties clockwise, with the remaining seconds in the middle. It keeps
 * no time of its own but follows one of the two existing countdowns:
 * - [remainingFraction] set (the lead countdown before a prepared episode, which follows the playback
 *   position): the ring glides to each new value over about one position update, and snaps when the
 *   value jumps (a seek, a restart).
 * - otherwise today's 3-2-1: each value animates the ring linearly from that value's share to the next
 *   one over the second the launcher waits on it; a value that does not continue the previous one
 *   snaps to where it starts.
 * A new episode ([resetKey]) starts from a full ring.
 */
/** About one playback position update (the player reports every 250 ms). */
private const val POSITION_RING_GLIDE_MS = 250

/** A step this large is a seek or a restart rather than playback, and is not animated. */
private const val POSITION_RING_SNAP_FRACTION = 0.2f

@Composable
private fun NextEpisodeCountdownRing(
    countdownSec: Int,
    remainingFraction: Float?,
    resetKey: String,
    modifier: Modifier = Modifier,
) {
    val progress = remember(resetKey) { Animatable(1f) }
    if (remainingFraction != null) {
        LaunchedEffect(resetKey, remainingFraction) {
            if (kotlin.math.abs(progress.value - remainingFraction) > POSITION_RING_SNAP_FRACTION) {
                progress.snapTo(remainingFraction)
            } else {
                progress.animateTo(
                    targetValue = remainingFraction,
                    animationSpec = tween(durationMillis = POSITION_RING_GLIDE_MS, easing = LinearEasing),
                )
            }
        }
    } else {
        val total = NEXT_EPISODE_COUNTDOWN_SECONDS.toFloat()
        LaunchedEffect(resetKey, countdownSec) {
            val start = (countdownSec / total).coerceIn(0f, 1f)
            if (kotlin.math.abs(progress.value - start) > 0.02f) progress.snapTo(start)
            progress.animateTo(
                targetValue = ((countdownSec - 1) / total).coerceIn(0f, 1f),
                animationSpec = tween(durationMillis = 1_000, easing = LinearEasing),
            )
        }
    }
    val accent = MaterialTheme.colorScheme.primary
    val track = Color.White.copy(alpha = 0.2f)
    Box(
        modifier = modifier.size(28.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val strokeWidth = 2.5.dp.toPx()
            val inset = strokeWidth / 2f
            val arcSize = Size(size.width - strokeWidth, size.height - strokeWidth)
            val topLeft = Offset(inset, inset)
            drawArc(
                color = track,
                startAngle = 0f,
                sweepAngle = 360f,
                useCenter = false,
                topLeft = topLeft,
                size = arcSize,
                style = Stroke(width = strokeWidth),
            )
            val remaining = progress.value
            if (remaining > 0f) {
                // The leading edge moves clockwise from 12 o'clock as the time runs out.
                drawArc(
                    color = accent,
                    startAngle = -90f + 360f * (1f - remaining),
                    sweepAngle = 360f * remaining,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = strokeWidth, cap = StrokeCap.Round),
                )
            }
        }
        Text(
            text = countdownSec.toString(),
            color = Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}
