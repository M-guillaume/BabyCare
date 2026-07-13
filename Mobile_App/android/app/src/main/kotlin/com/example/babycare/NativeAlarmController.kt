package com.example.babycare

import android.content.Context
import android.media.AudioManager
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Build
import android.util.Log

object NativeAlarmController {
    private const val TAG = "NativeAlarmController"
    private var mediaPlayer: MediaPlayer? = null
    private var ringtone: Ringtone? = null

    fun start(context: Context): Boolean {
        if (isPlaying()) {
            Log.i(TAG, "Alarm already playing")
            return true
        }

        val appContext = context.applicationContext
        val alarmUri =
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

        if (alarmUri == null) {
            Log.e(TAG, "No default alarm/notification URI available")
            return false
        }

        // Try Ringtone first: it is generally more reliable on OEM devices for alarm usage.
        try {
            val alarmRingtone = RingtoneManager.getRingtone(appContext, alarmUri)
            if (alarmRingtone != null) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    alarmRingtone.audioAttributes =
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                } else {
                    @Suppress("DEPRECATION")
                    alarmRingtone.streamType = AudioManager.STREAM_ALARM
                }

                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    alarmRingtone.isLooping = true
                }

                alarmRingtone.play()
                if (alarmRingtone.isPlaying) {
                    ringtone = alarmRingtone
                    Log.i(TAG, "Native alarm started via Ringtone")
                    return true
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Ringtone path failed, fallback to MediaPlayer", e)
            ringtone = null
        }

        return try {
            val player = MediaPlayer().apply {
                setDataSource(appContext, alarmUri)
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build(),
                )
                isLooping = true
                prepare()
                start()
            }

            mediaPlayer = player
            Log.i(TAG, "Native alarm started via MediaPlayer")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start native alarm", e)
            stop()
            false
        }
    }

    fun stop(): Boolean {
        return try {
            try {
                ringtone?.stop()
            } catch (_: Exception) {
            }
            ringtone = null

            mediaPlayer?.let { player ->
                if (player.isPlaying) {
                    player.stop()
                }
                player.reset()
                player.release()
            }
            mediaPlayer = null
            Log.i(TAG, "Native alarm stopped")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to stop native alarm", e)
            mediaPlayer = null
            false
        }
    }

    fun isPlaying(): Boolean {
        return try {
            (ringtone?.isPlaying == true) || (mediaPlayer?.isPlaying == true)
        } catch (_: Exception) {
            false
        }
    }
}
