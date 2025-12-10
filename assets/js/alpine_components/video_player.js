/**
 * Alpine.js Video Player Component
 *
 * Handles reactive UI state and declarative DOM updates for the video player.
 * Works in conjunction with the VideoPlayer Phoenix hook which manages:
 * - Server communication (fetch/save progress)
 * - HLS.js lifecycle
 * - Video source initialization
 * - Keyboard shortcuts and touch gestures
 */

export function videoPlayer() {
  return {
    // === Reactive State ===

    // Playback state
    playing: false,
    muted: false,
    volume: 100,
    currentTime: 0,
    duration: 0,
    buffering: false,
    hasMetadata: false,

    // Playback speed
    playbackRate: 1.0,

    // UI visibility state
    controlsVisible: true,
    settingsOpen: false,
    speedMenuOpen: false,
    qualityMenuOpen: false,
    isFullscreen: false,

    // TV show features visibility
    skipIntroVisible: false,
    skipCreditsVisible: false,
    nextEpisodeVisible: false,
    countdownVisible: false,
    countdownSeconds: 15,
    countdownProgress: 100,

    // Loading and error states
    loading: false,
    loadingMessage: "Loading...",
    error: null,

    // Transcoding progress
    isTranscoding: false,
    retryAttempt: 0,
    maxRetries: 0,

    // Known duration from FFprobe (prevents browser from overriding with progressive duration)
    hasKnownDuration: false,

    // HLS quality levels (populated by hook)
    hlsLevels: [],
    currentHlsLevel: -1, // -1 = auto

    // === Initialization ===

    init() {
      // Alpine's init runs when component is mounted
      // The Phoenix hook will handle the actual video setup and call
      // methods on this Alpine component to update state
    },

    // === Computed Properties (Getters) ===

    get formattedCurrentTime() {
      return this.formatTime(this.currentTime);
    },

    get formattedDuration() {
      return this.formatTime(this.duration);
    },

    get progressPercent() {
      if (!this.duration || this.duration === 0) return 0;
      return (this.currentTime / this.duration) * 100;
    },

    get speedDisplay() {
      return this.playbackRate === 1.0 ? "Normal" : `${this.playbackRate}x`;
    },

    get qualityDisplay() {
      if (this.currentHlsLevel === -1) return "Auto";
      if (this.hlsLevels[this.currentHlsLevel]) {
        return `${this.hlsLevels[this.currentHlsLevel].height}p`;
      }
      return "Auto";
    },

    // === UI Event Handlers ===

    togglePlay() {
      const video = this.$refs.video;

      // Unmute on first user interaction if video was auto-muted
      if (this.muted && !video.paused) {
        video.muted = false;
        this.muted = false;
      }

      if (video.paused) {
        video.play();
      } else {
        video.pause();
      }
    },

    toggleMute() {
      const video = this.$refs.video;
      video.muted = !video.muted;
    },

    toggleFullscreen() {
      if (!document.fullscreenElement) {
        this.$el.requestFullscreen().catch((err) => {
          console.error("Error enabling fullscreen:", err);
        });
      } else {
        document.exitFullscreen();
      }
    },

    skipForward(seconds = 10) {
      const video = this.$refs.video;
      if (video && this.hasMetadata) {
        video.currentTime = Math.min(video.currentTime + seconds, this.duration);
      }
    },

    skipBackward(seconds = 10) {
      const video = this.$refs.video;
      if (video) {
        video.currentTime = Math.max(video.currentTime - seconds, 0);
      }
    },

    toggleSettings() {
      this.settingsOpen = !this.settingsOpen;
      if (!this.settingsOpen) {
        this.speedMenuOpen = false;
        this.qualityMenuOpen = false;
      }
    },

    toggleSpeedMenu() {
      this.speedMenuOpen = !this.speedMenuOpen;
      this.qualityMenuOpen = false;
    },

    toggleQualityMenu() {
      this.qualityMenuOpen = !this.qualityMenuOpen;
      this.speedMenuOpen = false;
    },

    closeSettings() {
      this.settingsOpen = false;
      this.speedMenuOpen = false;
      this.qualityMenuOpen = false;
    },

    // === Playback Controls ===

    setVolume(value) {
      const video = this.$refs.video;
      this.volume = value;
      video.volume = value / 100;
      video.muted = value === 0;

      // Save to localStorage
      localStorage.setItem("videoPlayerVolume", value);
    },

    setProgress(percent) {
      const video = this.$refs.video;
      if (this.hasMetadata && this.duration) {
        video.currentTime = (percent / 100) * this.duration;
      }
    },

    setSpeed(speed) {
      const video = this.$refs.video;
      video.playbackRate = speed;
      this.playbackRate = speed;
      localStorage.setItem("videoPlayerSpeed", speed.toString());
      this.closeSettings();
    },

    setQuality(level) {
      // This will be called by the template, but the actual HLS level
      // switching is handled by the Phoenix hook which has access to hls.js
      this.$dispatch("set-quality", { level });
      this.closeSettings();
    },

    // === Video Event Handlers ===

    onPlay() {
      this.playing = true;
      this.buffering = false;
    },

    onPause() {
      this.playing = false;
    },

    onTimeUpdate(event) {
      this.currentTime = event.target.currentTime;
    },

    onLoadedMetadata(event) {
      this.hasMetadata = true;
      const browserDuration = event.target.duration;
      console.log("[Alpine] onLoadedMetadata - browser duration:", browserDuration, "hasKnownDuration:", this.hasKnownDuration, "current duration:", this.duration);
      // Only update duration from browser if we don't have a known duration from FFprobe
      // AND the browser duration is valid (not Infinity, which happens with fMP4 streaming)
      if (!this.hasKnownDuration && isFinite(browserDuration) && browserDuration > 0) {
        console.log("[Alpine] onLoadedMetadata - updating duration to browser value:", browserDuration);
        this.duration = browserDuration;
      } else if (!this.hasKnownDuration) {
        console.log("[Alpine] onLoadedMetadata - invalid browser duration, keeping current:", this.duration);
      } else {
        console.log("[Alpine] onLoadedMetadata - keeping known duration, ignoring browser value");
      }
      this.loading = false;
    },

    onDurationChange(event) {
      // Update duration when it changes (important for HLS streams)
      const newDuration = event.target.duration;
      console.log("[Alpine] onDurationChange - browser duration:", newDuration, "hasKnownDuration:", this.hasKnownDuration, "current duration:", this.duration);
      if (isFinite(newDuration) && newDuration > 0) {
        // If we have a known duration from FFprobe metadata, don't let the browser
        // override it. This is critical for:
        // - HLS transcoding (duration grows as segments are added)
        // - fMP4 remuxing (fragmented MP4 with empty_moov reports progressive duration)
        if (this.hasKnownDuration) {
          // Only update if the new duration is very close to known (within 1%)
          // This allows for minor corrections while preventing confusing updates
          const diff = Math.abs(newDuration - this.duration) / this.duration;
          console.log("[Alpine] onDurationChange - hasKnownDuration=true, diff:", diff);
          if (diff < 0.01) {
            console.log("[Alpine] onDurationChange - diff < 1%, updating to:", newDuration);
            this.duration = newDuration;
          } else {
            console.log("[Alpine] onDurationChange - diff >= 1%, keeping known duration:", this.duration);
          }
        } else {
          // No known duration - accept browser updates
          // For fMP4 remuxing without known duration, this will progressively update
          // (not ideal, but better than showing 0 or Infinity)
          console.log("[Alpine] onDurationChange - no known duration, updating to:", newDuration);
          this.duration = newDuration;
        }
      } else {
        console.log("[Alpine] onDurationChange - invalid duration, ignoring:", newDuration);
      }
    },

    onVolumeChange(event) {
      this.muted = event.target.muted;
      this.volume = event.target.volume * 100;
    },

    onWaiting() {
      this.buffering = true;
      // Show loading indicator with appropriate message
      this.loading = true;
      if (this.isTranscoding) {
        this.loadingMessage = "Buffering... (transcoding in progress)";
      } else {
        this.loadingMessage = "Buffering...";
      }
    },

    onPlaying() {
      this.buffering = false;
      this.loading = false;
    },

    onRateChange(event) {
      this.playbackRate = event.target.playbackRate;
    },

    onFullscreenChange() {
      this.isFullscreen = !!document.fullscreenElement;
    },

    // === TV Show Features ===

    skipIntro() {
      // Hook will handle the actual seeking
      this.$dispatch("skip-intro");
    },

    skipCredits() {
      // Hook will handle the actual seeking or navigation
      this.$dispatch("skip-credits");
    },

    playNextEpisode() {
      this.$dispatch("play-next-episode");
    },

    cancelNextEpisode() {
      this.$dispatch("cancel-next-episode");
      this.nextEpisodeVisible = false;
      this.countdownVisible = false;
    },

    // === Utility Methods ===

    formatTime(seconds) {
      if (!isFinite(seconds)) return "0:00";

      const hours = Math.floor(seconds / 3600);
      const minutes = Math.floor((seconds % 3600) / 60);
      const secs = Math.floor(seconds % 60);

      if (hours > 0) {
        return `${hours}:${minutes.toString().padStart(2, "0")}:${secs.toString().padStart(2, "0")}`;
      } else {
        return `${minutes}:${secs.toString().padStart(2, "0")}`;
      }
    },

    // === Methods for Hook to Call ===

    // These methods allow the Phoenix hook to update Alpine state

    showLoading() {
      this.loading = true;
    },

    hideLoading() {
      this.loading = false;
    },

    showError(message) {
      this.error = message;
      this.loading = false;
    },

    hideError() {
      this.error = null;
    },

    updateHlsLevels(levels) {
      this.hlsLevels = levels;
    },

    updateHlsLevel(level) {
      this.currentHlsLevel = level;
    },

    showSkipIntro() {
      this.skipIntroVisible = true;
    },

    hideSkipIntro() {
      this.skipIntroVisible = false;
    },

    showSkipCredits() {
      this.skipCreditsVisible = true;
    },

    hideSkipCredits() {
      this.skipCreditsVisible = false;
    },

    showNextEpisode() {
      this.nextEpisodeVisible = true;
    },

    hideNextEpisode() {
      this.nextEpisodeVisible = false;
      this.countdownVisible = false;
    },

    startCountdown() {
      this.countdownVisible = true;
    },

    updateCountdown(seconds, progressPercent) {
      this.countdownSeconds = seconds;
      this.countdownProgress = progressPercent;
    },

    stopCountdown() {
      this.countdownVisible = false;
      this.countdownSeconds = 15;
      this.countdownProgress = 100;
    },

    // === Transcoding Progress ===

    showTranscodingLoading() {
      this.loading = true;
      this.isTranscoding = true;
      this.loadingMessage = "Preparing video for playback...";
      this.retryAttempt = 0;
      this.maxRetries = 0;
    },

    updateTranscodingProgress(attempt, maxAttempts) {
      this.retryAttempt = attempt;
      this.maxRetries = maxAttempts;
      if (attempt > 1) {
        this.loadingMessage = `Preparing video... (attempt ${attempt} of ${maxAttempts})`;
      } else {
        this.loadingMessage = "Preparing video for playback...";
      }
    },

    showDirectPlayLoading() {
      this.loading = true;
      this.isTranscoding = false;
      this.loadingMessage = "Loading video...";
    },
  };
}
