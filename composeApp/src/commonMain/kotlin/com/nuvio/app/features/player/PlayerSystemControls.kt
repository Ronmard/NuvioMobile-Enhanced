package com.nuvio.app.features.player

/** Handles playback requests from system controls (PiP, Now Playing). False keeps the local path. */
interface PlayerSystemControlHandler {
    fun handleSetPlaying(playing: Boolean): Boolean
    fun handleSeekTo(positionMs: Long): Boolean
    fun handleSeekBy(offsetMs: Long): Boolean

    /** The player's skip step, for system skip commands (lock screen, headset, AirPods). */
    fun systemSkipStepMs(forward: Boolean): Long = DEFAULT_SYSTEM_SKIP_STEP_MS
}

private const val DEFAULT_SYSTEM_SKIP_STEP_MS = 10_000L

/** Optional platform capability of a player instance. */
interface PlayerSystemControlSource {
    val keepsPlaybackInBackground: Boolean
    fun setSystemControlHandler(handler: PlayerSystemControlHandler?)
}
