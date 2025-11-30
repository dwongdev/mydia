// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/mydia";
import topbar from "../vendor/topbar";
import VideoPlayer from "./hooks/video_player";
// Alpine.js for reactive UI components
import Alpine from "alpinejs";
import { videoPlayer } from "./alpine_components/video_player";

// Theme toggle hook
const ThemeToggle = {
  mounted() {
    // Update indicator position based on current theme
    const updateIndicator = () => {
      const preference = window.mydiaTheme.getTheme();
      const indicator = this.el.querySelector(".theme-indicator");

      if (!indicator) return;

      // Calculate position based on preference
      let position = "0%"; // system (left)
      if (preference === window.mydiaTheme.THEMES.LIGHT) {
        position = "33.333%"; // light (middle)
      } else if (preference === window.mydiaTheme.THEMES.DARK) {
        position = "66.666%"; // dark (right)
      }

      indicator.style.left = position;
    };

    // Update on mount
    updateIndicator();

    // Watch for theme changes
    const observer = new MutationObserver(updateIndicator);
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-theme"],
    });

    // Store observer to disconnect on unmount
    this.observer = observer;
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

// Path autocomplete hook with keyboard navigation
const PathAutocomplete = {
  mounted() {
    this.selectedIndex = -1;

    this.el.addEventListener("keydown", (e) => {
      const suggestions = document.getElementById("path-suggestions");
      if (!suggestions) return;

      const buttons = suggestions.querySelectorAll("button");
      if (buttons.length === 0) return;

      switch (e.key) {
        case "ArrowDown":
          e.preventDefault();
          this.selectedIndex = Math.min(
            this.selectedIndex + 1,
            buttons.length - 1,
          );
          this.highlightSelected(buttons);
          break;
        case "ArrowUp":
          e.preventDefault();
          this.selectedIndex = Math.max(this.selectedIndex - 1, -1);
          this.highlightSelected(buttons);
          break;
        case "Enter":
          if (this.selectedIndex >= 0 && this.selectedIndex < buttons.length) {
            e.preventDefault();
            buttons[this.selectedIndex].click();
            this.selectedIndex = -1;
          }
          break;
        case "Escape":
          e.preventDefault();
          this.pushEvent("hide_path_suggestions");
          this.selectedIndex = -1;
          break;
      }
    });
  },

  highlightSelected(buttons) {
    buttons.forEach((btn, idx) => {
      if (idx === this.selectedIndex) {
        btn.classList.add("bg-base-200");
        btn.scrollIntoView({ block: "nearest" });
      } else {
        btn.classList.remove("bg-base-200");
      }
    });
  },

  updated() {
    // Reset selected index when suggestions update
    this.selectedIndex = -1;
  },
};

// File download hook for quality profile exports
const DownloadFile = {
  mounted() {
    this.handleEvent("download_file", ({ content, filename, mime_type }) => {
      const blob = new Blob([content], { type: mime_type });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(url);
    });
  },
};

// Sticky toolbar hook - shows fixed toolbar when original scrolls out of view
const StickyToolbar = {
  mounted() {
    this.fixedToolbarId = this.el.dataset.fixedId;
    this.isSticky = false;

    this.setupObserver();
  },

  updated() {
    // Re-apply visibility state after LiveView updates the DOM
    this.applyVisibility();
  },

  setupObserver() {
    const fixedToolbar = document.getElementById(this.fixedToolbarId);
    if (!fixedToolbar) {
      console.warn("StickyToolbar: fixed toolbar not found:", this.fixedToolbarId);
      return;
    }

    // Use viewport as root (null) for simpler intersection detection
    this.observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          this.isSticky = !entry.isIntersecting;
          this.applyVisibility();
        });
      },
      {
        root: null, // viewport
        threshold: 0,
        rootMargin: "-50px 0px 0px 0px", // trigger slightly before fully out of view
      }
    );

    this.observer.observe(this.el);
  },

  applyVisibility() {
    const fixedToolbar = document.getElementById(this.fixedToolbarId);
    if (!fixedToolbar) return;

    if (this.isSticky) {
      fixedToolbar.classList.remove("hidden");
    } else {
      fixedToolbar.classList.add("hidden");
    }
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },
};

// Initialize Alpine.js FIRST (before LiveView)
window.Alpine = Alpine;

// Register Alpine components
Alpine.data("videoPlayer", videoPlayer);

// Start Alpine before LiveView connects (critical for x-cloak and x-show to work)
Alpine.start();

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    ...colocatedHooks,
    ThemeToggle,
    VideoPlayer,
    PathAutocomplete,
    DownloadFile,
    StickyToolbar,
  },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Handle download exports
window.addEventListener("phx:download_export", (e) => {
  const { filename, content, mime_type } = e.detail;
  const blob = new Blob([content], { type: mime_type });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  URL.revokeObjectURL(url);
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// Register service worker for PWA support
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker
      .register("/service-worker.js")
      .then((registration) => {
        console.log("ServiceWorker registered:", registration.scope);
      })
      .catch((error) => {
        console.log("ServiceWorker registration failed:", error);
      });
  });
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}
