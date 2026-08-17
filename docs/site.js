(() => {
  if (!window.gsap) {
    document.documentElement.classList.add("no-gsap");
    return;
  }

  const ScrollTrigger = window.ScrollTrigger;
  const hasScrollTrigger = Boolean(ScrollTrigger);
  if (hasScrollTrigger) gsap.registerPlugin(ScrollTrigger);

  const mm = gsap.matchMedia();
  mm.add(
    {
      desktop: "(min-width: 941px)",
      reduceMotion: "(prefers-reduced-motion: reduce)"
    },
    (context) => {
      const { desktop, reduceMotion } = context.conditions;
      const cleanups = [];

      if (reduceMotion) {
        gsap.set([".hero-reveal", ".reveal", ".story-step"], {
          autoAlpha: 1,
          x: 0,
          y: 0,
          scale: 1
        });
        document.querySelector(".focus-process")?.classList.add("is-active");
        return;
      }

      const intro = gsap.timeline({ defaults: { ease: "power3.out" } });
      intro
        .from(".site-header", { autoAlpha: 0, y: -18, duration: 0.65 })
        .from(".hero-copy > .hero-reveal", {
          autoAlpha: 0,
          y: 28,
          duration: 0.72,
          stagger: 0.085
        }, "-=0.28")
        .from(".app-window", {
          autoAlpha: 0,
          y: 42,
          scale: 0.94,
          rotationY: -7,
          duration: 0.95
        }, "-=0.72")
        .from(".icon-pedestal", {
          autoAlpha: 0,
          y: -24,
          scale: 0.82,
          rotation: 4,
          duration: 0.8
        }, "-=0.62")
        .from(".stage-status", {
          autoAlpha: 0,
          x: -18,
          duration: 0.55
        }, "-=0.35");

      gsap.to(".aurora-one", {
        x: -38,
        scale: 1.08,
        duration: 7.5,
        repeat: -1,
        yoyo: true,
        ease: "sine.inOut"
      });
      gsap.to(".aurora-two", {
        x: 30,
        scale: 1.12,
        duration: 9,
        repeat: -1,
        yoyo: true,
        ease: "sine.inOut"
      });
      gsap.to(".aurora-three", {
        x: 24,
        scale: 1.06,
        duration: 8.2,
        repeat: -1,
        yoyo: true,
        ease: "sine.inOut"
      });
      gsap.to(".hero-signals i", {
        y: -14,
        autoAlpha: 0.32,
        duration: 2.8,
        repeat: -1,
        yoyo: true,
        stagger: { each: 0.28, from: "random" },
        ease: "sine.inOut"
      });

      if (desktop) {
        const hero = document.querySelector(".hero");
        const cursorGlow = document.querySelector(".hero-cursor-glow");
        const appWindow = document.querySelector(".app-window");
        const icon = document.querySelector(".icon-pedestal");

        if (hero && cursorGlow && appWindow && icon) {
          const glowX = gsap.quickTo(cursorGlow, "x", { duration: 0.8, ease: "power3.out" });
          const glowY = gsap.quickTo(cursorGlow, "y", { duration: 0.8, ease: "power3.out" });
          const appX = gsap.quickTo(appWindow, "x", { duration: 0.75, ease: "power3.out" });
          const appY = gsap.quickTo(appWindow, "y", { duration: 0.75, ease: "power3.out" });
          const iconX = gsap.quickTo(icon, "x", { duration: 0.65, ease: "power3.out" });
          const iconY = gsap.quickTo(icon, "y", { duration: 0.65, ease: "power3.out" });

          const move = (event) => {
            const bounds = hero.getBoundingClientRect();
            const nx = (event.clientX - bounds.left) / bounds.width - 0.5;
            const ny = (event.clientY - bounds.top) / bounds.height - 0.5;
            glowX(nx * 110);
            glowY(ny * 80);
            appX(nx * 8);
            appY(ny * 7);
            iconX(nx * 15);
            iconY(ny * 12);
          };
          const reset = () => {
            glowX(0); glowY(0);
            appX(0); appY(0);
            iconX(0); iconY(0);
          };

          hero.addEventListener("pointermove", move);
          hero.addEventListener("pointerleave", reset);
          cleanups.push(() => {
            hero.removeEventListener("pointermove", move);
            hero.removeEventListener("pointerleave", reset);
          });
        }
      }

      if (hasScrollTrigger) {
        if (desktop) {
          gsap.timeline({
            scrollTrigger: {
              trigger: ".hero",
              start: "top top",
              end: "bottom top",
              scrub: 0.8
            }
          })
            .to(".hero-copy", { y: -58, autoAlpha: 0.2, ease: "none" }, 0)
            .to(".hero-stage", { y: -28, scale: 0.96, autoAlpha: 0.45, ease: "none" }, 0)
            .to(".hero-grid", { y: 72, autoAlpha: 0.18, ease: "none" }, 0)
            .to(".hero-aurora", { yPercent: 16, autoAlpha: 0.28, ease: "none" }, 0);

          const storySteps = [...document.querySelectorAll(".story-step")];
          const focusRings = [...document.querySelectorAll(".focus-ring")];
          const activateStory = (step) => {
            const focus = step.dataset.focus;
            storySteps.forEach((item) => item.classList.toggle("is-active", item === step));
            gsap.killTweensOf(focusRings);
            focusRings.forEach((ring) => {
              ring.classList.remove("is-active");
              gsap.set(ring, { autoAlpha: 0, scale: 1 });
            });
            const activeRing = document.querySelector(`.focus-${focus}`);
            if (activeRing) {
              activeRing.classList.add("is-active");
              gsap.fromTo(activeRing,
                { autoAlpha: 0, scale: 0.985 },
                { autoAlpha: 1, scale: 1, duration: 0.45, ease: "power2.out", overwrite: true }
              );
            }
            gsap.to(step, { y: 0, duration: 0.45, ease: "power2.out", overwrite: true });
          };

          storySteps.forEach((step) => {
            ScrollTrigger.create({
              trigger: step,
              start: "top 58%",
              end: "bottom 42%",
              onEnter: () => activateStory(step),
              onEnterBack: () => activateStory(step)
            });
          });
          if (storySteps[0]) activateStory(storySteps[0]);
        } else {
          gsap.set(".story-step", { autoAlpha: 1, y: 0 });
        }

        ScrollTrigger.batch(".reveal", {
          start: "top 88%",
          once: true,
          interval: 0.08,
          batchMax: desktop ? 4 : 2,
          onEnter: (elements) => gsap.from(elements, {
            autoAlpha: 0,
            y: 30,
            scale: 0.985,
            duration: 0.72,
            stagger: 0.08,
            ease: "power2.out",
            clearProps: "transform,opacity,visibility"
          })
        });

        const refresh = () => ScrollTrigger.refresh();
        if (document.readyState === "complete") refresh();
        else {
          window.addEventListener("load", refresh, { once: true });
          cleanups.push(() => window.removeEventListener("load", refresh));
        }
      } else {
        gsap.from(".reveal", {
          autoAlpha: 0,
          y: 24,
          duration: 0.65,
          stagger: 0.06,
          ease: "power2.out"
        });
        gsap.set(".story-step", { autoAlpha: 1, y: 0 });
      }

      return () => cleanups.forEach((cleanup) => cleanup());
    }
  );
})();
