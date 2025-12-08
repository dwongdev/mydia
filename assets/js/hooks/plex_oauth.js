/**
 * PlexOAuth Hook - Manages the Plex OAuth popup flow and communicates with LiveView
 *
 * This hook handles:
 * 1. Opening a popup window for Plex authentication
 * 2. Polling the backend to check if the user has authorized
 * 3. Detecting when the user closes the popup manually
 * 4. Communicating auth status back to the LiveView
 */
const PlexOAuth = {
  mounted() {
    this.popup = null;
    this.pollInterval = null;
    this.popupCheckInterval = null;

    // Listen for the event to start the OAuth flow
    this.handleEvent("open_plex_auth", ({ url, pin_id }) => {
      this.openPopup(url);
      this.startPolling(pin_id);
    });

    // Listen for auth completion/failure events from LiveView
    this.handleEvent("plex_auth_complete", () => {
      this.cleanup();
    });

    this.handleEvent("plex_auth_failed", () => {
      this.cleanup();
    });

    // Listen for cancel event
    this.handleEvent("plex_auth_cancelled", () => {
      this.cleanup();
    });
  },

  /**
   * Opens a centered popup window for Plex authentication
   */
  openPopup(url) {
    // Close any existing popup first
    if (this.popup && !this.popup.closed) {
      this.popup.close();
    }

    // Calculate center position for the popup
    const width = 800;
    const height = 700;
    const left = Math.max(0, (window.screen.width - width) / 2);
    const top = Math.max(0, (window.screen.height - height) / 2);

    const features = `width=${width},height=${height},left=${left},top=${top},toolbar=no,menubar=no,scrollbars=yes,resizable=yes`;

    this.popup = window.open(url, "plex_auth", features);

    // Start checking if the popup is closed by the user
    this.startPopupCheck();
  },

  /**
   * Polls the backend every 2 seconds to check if the PIN has been authorized
   */
  startPolling(pinId) {
    // Clear any existing interval
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
    }

    this.pollInterval = setInterval(() => {
      this.pushEvent("check_plex_pin", { pin_id: pinId });
    }, 2000);
  },

  /**
   * Checks if the popup was closed manually by the user
   */
  startPopupCheck() {
    // Clear any existing interval
    if (this.popupCheckInterval) {
      clearInterval(this.popupCheckInterval);
    }

    this.popupCheckInterval = setInterval(() => {
      if (this.popup && this.popup.closed) {
        // Popup was closed by the user - notify LiveView
        this.pushEvent("plex_popup_closed", {});
        this.cleanup();
      }
    }, 500);
  },

  /**
   * Cleans up popup, intervals, and state
   */
  cleanup() {
    // Close popup if still open
    if (this.popup && !this.popup.closed) {
      this.popup.close();
    }
    this.popup = null;

    // Clear polling intervals
    if (this.pollInterval) {
      clearInterval(this.pollInterval);
      this.pollInterval = null;
    }

    if (this.popupCheckInterval) {
      clearInterval(this.popupCheckInterval);
      this.popupCheckInterval = null;
    }
  },

  /**
   * Cleanup when the hook element is removed from the DOM
   */
  destroyed() {
    this.cleanup();
  },
};

export default PlexOAuth;
