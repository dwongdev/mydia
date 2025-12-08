const MusicPlayer = {
  mounted() {
    this.audio = this.el.querySelector("audio");
    if (!this.audio) return;
    
    this.queue = [];
    this.currentIndex = -1;
    
    // Server events
    this.handleEvent("music:play", ({ tracks, start_index }) => {
      this.queue = tracks;
      this.currentIndex = start_index || 0;
      this.playCurrent();
    });
    
    this.handleEvent("music:queue_next", ({ tracks }) => {
      this.queue.splice(this.currentIndex + 1, 0, ...tracks);
    });
    
    this.handleEvent("music:queue_end", ({ tracks }) => {
      this.queue.push(...tracks);
    });
    
    this.handleEvent("music:toggle", () => {
      if (this.audio.paused) this.audio.play();
      else this.audio.pause();
    });
    
    this.handleEvent("music:next", () => this.next());
    this.handleEvent("music:prev", () => this.prev());

    // DOM events from UI buttons
    this.el.addEventListener("music:prev", () => this.prev());
    this.el.addEventListener("music:next", () => this.next());
    this.el.addEventListener("music:toggle", () => {
      if (this.audio.paused) this.audio.play();
      else this.audio.pause();
    });

    // Audio events
    this.audio.addEventListener("ended", () => this.next());
    
    this.audio.addEventListener("play", () => {
      this.pushEvent("music:state_sync", { is_playing: true });
    });
    
    this.audio.addEventListener("pause", () => {
      this.pushEvent("music:state_sync", { is_playing: false });
    });
    
    this.audio.addEventListener("timeupdate", () => {
       // Dispatch event for local UI updates (e.g. Alpine)
       window.dispatchEvent(new CustomEvent("music:timeupdate", { 
         detail: { 
           currentTime: this.audio.currentTime,
           duration: this.audio.duration
         } 
       }));
    });
  },
  
  playCurrent() {
    if (this.currentIndex >= 0 && this.currentIndex < this.queue.length) {
      const track = this.queue[this.currentIndex];
      // Assume track object has .url property provided by server
      if (track.url) {
        this.audio.src = track.url;
        this.audio.play();
        
        this.pushEvent("music:track_changed", { 
          track: track, 
          index: this.currentIndex,
          queue_length: this.queue.length
        });
      }
    }
  },
  
  next() {
    if (this.currentIndex < this.queue.length - 1) {
      this.currentIndex++;
      this.playCurrent();
    }
  },
  
  prev() {
    if (this.audio.currentTime > 3) {
      this.audio.currentTime = 0;
    } else if (this.currentIndex > 0) {
      this.currentIndex--;
      this.playCurrent();
    }
  }
};

export default MusicPlayer;
