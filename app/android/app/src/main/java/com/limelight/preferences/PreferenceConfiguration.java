package com.limelight.preferences;

/**
 * The few stream settings Moonlight's decoder reads. Baya sets them per
 * stream instead of from Android preferences.
 */
public class PreferenceConfiguration {
    public enum FormatOption {
        AUTO,
        FORCE_AV1,
        FORCE_HEVC,
        FORCE_H264,
    }

    public static final int FRAME_PACING_MIN_LATENCY = 0;
    public static final int FRAME_PACING_BALANCED = 1;
    public static final int FRAME_PACING_CAP_FPS = 2;
    public static final int FRAME_PACING_MAX_SMOOTHNESS = 3;

    public int width = 1920;
    public int height = 1080;
    public int fps = 60;
    /** Kbps. */
    public int bitrate = 20000;
    public FormatOption videoFormat = FormatOption.AUTO;
    public boolean fullRange = false;
    public int framePacing = FRAME_PACING_MIN_LATENCY;
    public boolean enablePerfOverlay = false;
}
