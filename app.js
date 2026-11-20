(function () {
  "use strict";

  // Keep the footer year current without a rebuild.
  var yearElements = document.querySelectorAll("[data-year]");
  for (var index = 0; index < yearElements.length; index++) {
    yearElements[index].textContent = String(new Date().getFullYear());
  }

  // The CSS cube's faces sit half its width away from the centre; measure it so
  // the cube stays a cube at every screen size.
  var cubeStages = document.querySelectorAll(".cube-stage");
  function sizeCubes() {
    for (var cubeIndex = 0; cubeIndex < cubeStages.length; cubeIndex++) {
      var cubeStage = cubeStages[cubeIndex];
      cubeStage.style.setProperty("--half", cubeStage.offsetWidth / 2 + "px");
    }
  }
  if (cubeStages.length) {
    sizeCubes();
    window.addEventListener("resize", sizeCubes);
  }

  // Chat bubbles drop in once when their section scrolls into view.
  var chatThreads = Array.prototype.slice.call(document.querySelectorAll(".chat"));
  if (!chatThreads.length) return;

  function revealChatThread(chatThread) {
    chatThread.classList.add("is-in");
  }

  if (!("IntersectionObserver" in window)) {
    chatThreads.forEach(revealChatThread);
    return;
  }

  var chatThreadObserver = new IntersectionObserver(
    function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          revealChatThread(entry.target);
          chatThreadObserver.unobserve(entry.target);
        }
      });
    },
    { threshold: 0.2 }
  );
  chatThreads.forEach(function (chatThread) {
    chatThreadObserver.observe(chatThread);
  });

})();
