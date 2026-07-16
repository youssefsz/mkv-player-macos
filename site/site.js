(() => {
  const stage = document.querySelector("[data-video-stage]");
  const frame = document.querySelector("[data-video-frame]");
  const video = document.querySelector("[data-product-video]");
  if (!stage || !frame || !video) return;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const sourceAspectRatio = 1006 / 1920;
  let animationFrame = 0;
  let hasStarted = false;

  const clamp = (value, min = 0, max = 1) =>
    Math.min(max, Math.max(min, value));
  const mix = (from, to, amount) => from + (to - from) * amount;
  const smoothstep = (value) => value * value * (3 - 2 * value);

  const render = () => {
    animationFrame = 0;
    if (reduceMotion.matches) return;

    const viewportWidth = document.documentElement.clientWidth;
    const viewportHeight = window.innerHeight;
    const pageGutter = viewportWidth <= 760 ? 32 : 48;
    const initialWidth = Math.min(1120, viewportWidth - pageGutter);
    const initialHeight = initialWidth * sourceAspectRatio;
    const bounds = stage.getBoundingClientRect();
    const scrollRange = Math.max(stage.offsetHeight - viewportHeight, 1);
    const stageProgress = clamp(-bounds.top / scrollRange);
    const expansion = smoothstep(clamp(stageProgress / 0.58));

    frame.style.setProperty("--frame-width", `${mix(initialWidth, viewportWidth, expansion)}px`);
    frame.style.setProperty("--frame-height", `${mix(initialHeight, viewportHeight, expansion)}px`);
    frame.style.setProperty("--frame-radius", `${mix(14, 0, expansion)}px`);
    frame.style.setProperty("--frame-border-alpha", `${mix(0.2, 0, expansion)}`);
    frame.style.setProperty("--frame-shadow-alpha", `${mix(0.16, 0, expansion)}`);
    stage.style.setProperty("--cue-opacity", `${clamp(1 - expansion * 2.2)}`);

    if (!hasStarted && expansion >= 0.94 && bounds.bottom > 0) {
      hasStarted = true;
      video.play().catch(() => {
        // Native controls remain available when browser autoplay policy blocks playback.
      });
    }
  };

  const requestRender = () => {
    if (!animationFrame) animationFrame = window.requestAnimationFrame(render);
  };

  window.addEventListener("scroll", requestRender, { passive: true });
  window.addEventListener("resize", requestRender, { passive: true });
  reduceMotion.addEventListener("change", requestRender);

  const visibilityObserver = new IntersectionObserver(
    ([entry]) => {
      if (!entry.isIntersecting && !video.paused) video.pause();
    },
    { rootMargin: "0px" }
  );
  visibilityObserver.observe(stage);

  document.addEventListener("visibilitychange", () => {
    if (document.hidden && !video.paused) video.pause();
  });

  render();
})();
