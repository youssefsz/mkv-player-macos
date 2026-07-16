(() => {
  const root = document.documentElement;
  const stage = document.querySelector("[data-video-stage]");
  const positioner = document.querySelector("[data-video-positioner]");
  const frame = document.querySelector("[data-video-frame]");
  const video = document.querySelector("[data-product-video]");
  if (!stage || !positioner || !frame || !video) return;

  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const supportsNativeScroll =
    CSS.supports("animation-timeline: scroll()") &&
    CSS.supports("animation-range-start: 1px");
  const sourceWidth = 1920;
  const sourceHeight = 1006;
  const sourceAspectRatio = sourceHeight / sourceWidth;
  let animationFrame = 0;
  let hasStarted = false;
  let metrics;

  const clamp = (value, min = 0, max = 1) =>
    Math.min(max, Math.max(min, value));
  const mix = (from, to, amount) => from + (to - from) * amount;

  const setMetric = (name, value) =>
    stage.style.setProperty(name, `${value}px`);

  const measure = () => {
    const motionEnabled = !reduceMotion.matches;
    root.classList.toggle("scroll-animations-ready", motionEnabled);
    stage.classList.toggle(
      "uses-native-scroll-animation",
      motionEnabled && supportsNativeScroll
    );
    if (!motionEnabled) return;

    const viewportWidth = document.documentElement.clientWidth;
    const viewportHeight = window.innerHeight;
    const pageGutter = viewportWidth <= 760 ? 32 : 48;
    const containedScale = Math.min(
      viewportWidth / sourceWidth,
      viewportHeight / sourceHeight
    );
    const containedWidth = sourceWidth * containedScale;
    const containedHeight = sourceHeight * containedScale;
    const initialWidth = Math.min(
      1120,
      viewportWidth - pageGutter,
      containedWidth
    );
    const initialHeight = initialWidth * sourceAspectRatio;
    const initialScale = initialWidth / containedWidth;
    const centerOffset = Math.max((viewportHeight - initialHeight) / 2, 0);
    const stageTop = stage.getBoundingClientRect().top + window.scrollY;
    const parallaxStart = Math.max(stageTop - centerOffset, 0);
    const positionEnd = Math.max(stageTop, parallaxStart + 1);
    const availablePinnedDistance = Math.max(
      stage.offsetHeight - viewportHeight + centerOffset,
      1
    );
    const idealExpansionDistance = clamp(viewportHeight * 0.65, 420, 720);
    const expansionDistance = Math.min(
      idealExpansionDistance,
      availablePinnedDistance * 0.72
    );
    const parallaxEnd = parallaxStart + expansionDistance;

    metrics = {
      initialOffsetY: -centerOffset,
      initialScale,
      initialClipX: Math.max((viewportWidth - containedWidth) / 2, 0),
      initialClipY: Math.max((viewportHeight - containedHeight) / 2, 0),
      initialRadius: 14 / initialScale,
      parallaxStart,
      positionEnd,
      parallaxEnd,
    };

    setMetric("--initial-offset-y", metrics.initialOffsetY);
    stage.style.setProperty("--initial-scale", `${metrics.initialScale}`);
    setMetric("--initial-clip-x", metrics.initialClipX);
    setMetric("--initial-clip-y", metrics.initialClipY);
    setMetric("--initial-radius", metrics.initialRadius);
    setMetric("--parallax-start", metrics.parallaxStart);
    setMetric("--position-end", metrics.positionEnd);
    setMetric("--parallax-end", metrics.parallaxEnd);

    requestRender();
  };

  const render = () => {
    animationFrame = 0;
    if (reduceMotion.matches || !metrics) return;

    const scrollPosition = window.scrollY;
    const expansion = clamp(
      (scrollPosition - metrics.parallaxStart) /
        Math.max(metrics.parallaxEnd - metrics.parallaxStart, 1)
    );

    if (!supportsNativeScroll) {
      const positionProgress = clamp(
        (scrollPosition - metrics.parallaxStart) /
          Math.max(metrics.positionEnd - metrics.parallaxStart, 1)
      );
      const clipX = mix(metrics.initialClipX, 0, expansion);
      const clipY = mix(metrics.initialClipY, 0, expansion);
      const radius = mix(metrics.initialRadius, 0, expansion);

      positioner.style.setProperty(
        "--position-y",
        `${mix(metrics.initialOffsetY, 0, positionProgress)}px`
      );
      frame.style.setProperty(
        "--frame-scale",
        `${mix(metrics.initialScale, 1, expansion)}`
      );
      frame.style.setProperty("--frame-clip-x", `${clipX}px`);
      frame.style.setProperty("--frame-clip-y", `${clipY}px`);
      frame.style.setProperty("--frame-radius", `${radius}px`);
      stage.style.setProperty("--cue-opacity", `${clamp(1 - expansion * 3)}`);
    }

    if (!hasStarted && expansion >= 0.9) {
      hasStarted = true;
      if (supportsNativeScroll) {
        window.removeEventListener("scroll", requestRender);
      }
      video.play().catch(() => {
        // Native controls remain available when browser autoplay policy blocks playback.
      });
    }
  };

  const requestRender = () => {
    if (!animationFrame) animationFrame = window.requestAnimationFrame(render);
  };

  window.addEventListener("scroll", requestRender, { passive: true });
  window.addEventListener("resize", measure, { passive: true });
  window.addEventListener("load", measure, { once: true });
  reduceMotion.addEventListener("change", measure);

  const visibilityObserver = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting && !video.paused) video.pause();
  });
  visibilityObserver.observe(stage);

  document.addEventListener("visibilitychange", () => {
    if (document.hidden && !video.paused) video.pause();
  });

  measure();
})();
