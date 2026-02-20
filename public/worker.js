self.onmessage = function(e) {
  if (e.data === "start") {
    if (self.intervalId) clearInterval(self.intervalId);
    self.intervalId = setInterval(() => {
      self.postMessage("tick");
    }, 100); // 100ms interval for 10Hz updates
  } else if (e.data === "stop") {
    if (self.intervalId) {
      clearInterval(self.intervalId);
      self.intervalId = null;
    }
  }
};
