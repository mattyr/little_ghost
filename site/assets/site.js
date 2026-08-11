const root = document.documentElement;
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

root.classList.add("js");

const revealElements = [...document.querySelectorAll(".reveal")];

if (reduceMotion.matches || !("IntersectionObserver" in window)) {
  revealElements.forEach((element) => element.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;

        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { rootMargin: "0px 0px -8%", threshold: 0.12 },
  );

  revealElements.forEach((element) => revealObserver.observe(element));
}

const header = document.querySelector(".site-header");

const updateHeader = () => {
  header?.classList.toggle("is-scrolled", window.scrollY > 28);
};

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

let pointerFrame = 0;
let pointerX = window.innerWidth / 2;
let pointerY = window.innerHeight / 2;

const updatePointerEffects = () => {
  pointerFrame = 0;
  root.style.setProperty("--pointer-x", `${pointerX}px`);
  root.style.setProperty("--pointer-y", `${pointerY}px`);

  const ghost = document.querySelector(".ghost-button");
  if (!ghost || reduceMotion.matches) return;

  const bounds = ghost.getBoundingClientRect();
  const centerX = bounds.left + bounds.width / 2;
  const centerY = bounds.top + bounds.height / 2;
  const deltaX = Math.max(-1, Math.min(1, (pointerX - centerX) / window.innerWidth));
  const deltaY = Math.max(-1, Math.min(1, (pointerY - centerY) / window.innerHeight));

  ghost.style.setProperty("--ghost-x", `${deltaX * 13}px`);
  ghost.style.setProperty("--ghost-y", `${deltaY * 10}px`);
  ghost.style.setProperty("--ghost-rotate", `${deltaX * 3}deg`);
  ghost.style.setProperty("--pupil-x", `${deltaX * 8}px`);
  ghost.style.setProperty("--pupil-y", `${deltaY * 7}px`);
};

window.addEventListener(
  "pointermove",
  (event) => {
    pointerX = event.clientX;
    pointerY = event.clientY;
    if (!pointerFrame) pointerFrame = requestAnimationFrame(updatePointerEffects);
  },
  { passive: true },
);

document.querySelectorAll(".magnetic").forEach((element) => {
  element.addEventListener("pointermove", (event) => {
    if (reduceMotion.matches || event.pointerType === "touch") return;

    const bounds = element.getBoundingClientRect();
    const x = event.clientX - bounds.left;
    const y = event.clientY - bounds.top;
    const offsetX = (x / bounds.width - 0.5) * 9;
    const offsetY = (y / bounds.height - 0.5) * 7;

    element.style.setProperty("--magnetic-x", `${offsetX}px`);
    element.style.setProperty("--magnetic-y", `${offsetY}px`);
    element.style.setProperty("--button-x", `${x}px`);
    element.style.setProperty("--button-y", `${y}px`);
  });

  element.addEventListener("pointerleave", () => {
    element.style.setProperty("--magnetic-x", "0px");
    element.style.setProperty("--magnetic-y", "0px");
  });
});

document.querySelectorAll(".interactive-card").forEach((card) => {
  card.addEventListener("pointermove", (event) => {
    const bounds = card.getBoundingClientRect();
    card.style.setProperty("--card-x", `${event.clientX - bounds.left}px`);
    card.style.setProperty("--card-y", `${event.clientY - bounds.top}px`);
  });
});

const ghostButton = document.querySelector(".ghost-button");
const ghostWorld = document.querySelector(".hero-world");
const ghostMessage = document.querySelector(".ghost-message");
const ghostMessages = ["hello, Ruby", "tools ready", "let's build", "still floating"];
let ghostMessageIndex = 0;
let ghostMessageTimer;

const showGhostMessage = () => {
  if (!ghostMessage) return;

  ghostMessage.textContent = ghostMessages[ghostMessageIndex % ghostMessages.length];
  ghostMessageIndex += 1;
  ghostMessage.classList.add("is-visible");
  window.clearTimeout(ghostMessageTimer);
  ghostMessageTimer = window.setTimeout(() => ghostMessage.classList.remove("is-visible"), 1700);
};

const releaseSparks = () => {
  if (!ghostWorld || reduceMotion.matches) return;

  const colors = ["#76f7d2", "#a98aff", "#ff829c", "#fffdf7"];

  for (let index = 0; index < 15; index += 1) {
    const spark = document.createElement("span");
    const angle = (Math.PI * 2 * index) / 15 + Math.random() * 0.25;
    const distance = 70 + Math.random() * 95;

    spark.className = "ghost-spark";
    spark.style.setProperty("--spark-x", `${Math.cos(angle) * distance}px`);
    spark.style.setProperty("--spark-y", `${Math.sin(angle) * distance}px`);
    spark.style.setProperty("--spark-size", `${3 + Math.random() * 5}px`);
    spark.style.setProperty("--spark-color", colors[index % colors.length]);
    ghostWorld.append(spark);
    spark.addEventListener("animationend", () => spark.remove(), { once: true });
  }
};

ghostButton?.addEventListener("click", () => {
  showGhostMessage();
  releaseSparks();
});

const orbitLabels = [...document.querySelectorAll(".orbit-node")];
const orbitTracks = [...document.querySelectorAll(".orbit-anchor-track")];
const orbitLayer = document.querySelector(".orbit-labels");
let orbitFrame = 0;
let orbitElapsed = 0;
let orbitResumedAt = 0;

const clearOrbitLabelStyles = () => {
  orbitLayer?.classList.remove("is-orbiting");
  orbitLabels.forEach((label) => {
    ["opacity", "transform"].forEach((property) => label.style.removeProperty(property));
  });
};

const updateOrbitLabels = (timestamp) => {
  orbitFrame = 0;
  if (reduceMotion.matches || document.hidden) return;

  const elapsed = ((orbitElapsed + timestamp - orbitResumedAt) / 110_000) * Math.PI * 2;
  const angles = orbitTracks.map((track, index) => {
    const angle = elapsed + (index * Math.PI * 2) / orbitTracks.length;
    track.style.transform = `rotate(${angle}rad)`;
    return angle;
  });
  const bounds = orbitLayer.getBoundingClientRect();
  const anchors = orbitTracks.map((track) => track.firstElementChild.getBoundingClientRect());

  orbitLabels.forEach((label, index) => {
    const angle = angles[index];
    const anchor = anchors[index];
    const x = anchor.left + anchor.width / 2 - bounds.left;
    const y = anchor.top + anchor.height / 2 - bounds.top;
    const depth = (Math.sin(angle) + 1) / 2;
    const scale = 0.76 + depth * 0.14;

    label.style.opacity = `${0.4 + depth * 0.24}`;
    label.style.transform = `translate(calc(-50% + ${x}px), calc(-50% + ${y}px)) rotate(-8deg) skewX(-7deg) scale(${scale}, ${scale * 0.9})`;
  });

  orbitFrame = requestAnimationFrame(updateOrbitLabels);
};

const startOrbitLabels = () => {
  if (!orbitLabels.length || orbitLabels.length !== orbitTracks.length || orbitFrame || reduceMotion.matches || document.hidden) return;

  orbitLayer?.classList.add("is-orbiting");
  orbitResumedAt = performance.now();
  orbitFrame = requestAnimationFrame(updateOrbitLabels);
};

const stopOrbitLabels = (reset = false) => {
  if (orbitFrame && !reset) orbitElapsed += performance.now() - orbitResumedAt;
  cancelAnimationFrame(orbitFrame);
  orbitFrame = 0;
  orbitResumedAt = 0;
  if (reset) {
    orbitElapsed = 0;
    clearOrbitLabelStyles();
  }
};

startOrbitLabels();

document.addEventListener("visibilitychange", () => {
  if (document.hidden) stopOrbitLabels();
  else startOrbitLabels();
});

reduceMotion.addEventListener("change", (event) => {
  if (event.matches) stopOrbitLabels(true);
  else startOrbitLabels();
});

const tracePanel = document.querySelector(".trace-panel");
const traceReplay = document.querySelector(".trace-replay");

const playTrace = () => {
  if (!tracePanel || reduceMotion.matches) return;

  tracePanel.classList.remove("is-playing");
  requestAnimationFrame(() => {
    requestAnimationFrame(() => tracePanel.classList.add("is-playing"));
  });
};

if (tracePanel && !reduceMotion.matches && "IntersectionObserver" in window) {
  const traceObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        tracePanel.classList.toggle("is-playing", entry.isIntersecting);
      });
    },
    { threshold: 0.45 },
  );

  traceObserver.observe(tracePanel);
}

traceReplay?.addEventListener("click", playTrace);

class Constellation {
  constructor(canvas) {
    this.canvas = canvas;
    this.context = canvas.getContext("2d");
    this.particles = [];
    this.width = 0;
    this.height = 0;
    this.ratio = 1;
    this.frame = 0;
    this.running = false;
    this.pointer = { x: window.innerWidth / 2, y: window.innerHeight / 2, active: false };
    this.colors = ["118, 247, 210", "169, 138, 255", "255, 130, 156", "247, 244, 237"];

    this.resize = this.resize.bind(this);
    this.draw = this.draw.bind(this);
    this.handlePointer = this.handlePointer.bind(this);
    this.handleVisibility = this.handleVisibility.bind(this);

    this.resize();
    window.addEventListener("resize", this.resize, { passive: true });
    window.addEventListener("pointermove", this.handlePointer, { passive: true });
    window.addEventListener("pointerleave", () => {
      this.pointer.active = false;
    });
    document.addEventListener("visibilitychange", this.handleVisibility);

    if (!reduceMotion.matches) this.start();
    else this.drawStatic();
  }

  resize() {
    const oldWidth = this.width || window.innerWidth;
    const oldHeight = this.height || window.innerHeight;
    this.width = window.innerWidth;
    this.height = window.innerHeight;
    this.ratio = Math.min(window.devicePixelRatio || 1, 1.75);
    this.canvas.width = Math.round(this.width * this.ratio);
    this.canvas.height = Math.round(this.height * this.ratio);
    this.canvas.style.width = `${this.width}px`;
    this.canvas.style.height = `${this.height}px`;
    this.context.setTransform(this.ratio, 0, 0, this.ratio, 0, 0);

    const desiredCount = Math.max(28, Math.min(72, Math.round((this.width * this.height) / 24000)));

    if (!this.particles.length) {
      this.particles = Array.from({ length: desiredCount }, (_, index) => this.makeParticle(index));
    } else {
      this.particles.forEach((particle) => {
        particle.x = (particle.x / oldWidth) * this.width;
        particle.y = (particle.y / oldHeight) * this.height;
      });

      while (this.particles.length < desiredCount) this.particles.push(this.makeParticle(this.particles.length));
      this.particles.length = desiredCount;
    }

    if (reduceMotion.matches) this.drawStatic();
  }

  makeParticle(index) {
    return {
      x: Math.random() * this.width,
      y: Math.random() * this.height,
      baseX: Math.random() * this.width,
      baseY: Math.random() * this.height,
      vx: (Math.random() - 0.5) * 0.14,
      vy: (Math.random() - 0.5) * 0.14,
      radius: 0.65 + Math.random() * 1.45,
      alpha: 0.16 + Math.random() * 0.42,
      color: this.colors[index % this.colors.length],
    };
  }

  handlePointer(event) {
    this.pointer.x = event.clientX;
    this.pointer.y = event.clientY;
    this.pointer.active = event.pointerType !== "touch";
  }

  handleVisibility() {
    if (document.hidden) this.stop();
    else if (!reduceMotion.matches) this.start();
  }

  start() {
    if (this.running) return;

    this.running = true;
    this.frame = requestAnimationFrame(this.draw);
  }

  stop() {
    this.running = false;
    cancelAnimationFrame(this.frame);
  }

  updateParticle(particle) {
    particle.x += particle.vx;
    particle.y += particle.vy;

    if (particle.x < -20) particle.x = this.width + 20;
    if (particle.x > this.width + 20) particle.x = -20;
    if (particle.y < -20) particle.y = this.height + 20;
    if (particle.y > this.height + 20) particle.y = -20;

    if (!this.pointer.active) return;

    const deltaX = this.pointer.x - particle.x;
    const deltaY = this.pointer.y - particle.y;
    const distance = Math.hypot(deltaX, deltaY);

    if (distance > 0 && distance < 190) {
      const force = (190 - distance) / 1900;
      particle.x -= deltaX * force * 0.09;
      particle.y -= deltaY * force * 0.09;
    }
  }

  paint(update) {
    const context = this.context;
    context.clearRect(0, 0, this.width, this.height);

    if (update) this.particles.forEach((particle) => this.updateParticle(particle));

    for (let first = 0; first < this.particles.length; first += 1) {
      const particle = this.particles[first];

      context.beginPath();
      context.arc(particle.x, particle.y, particle.radius, 0, Math.PI * 2);
      context.fillStyle = `rgba(${particle.color}, ${particle.alpha})`;
      context.fill();

      for (let second = first + 1; second < this.particles.length; second += 1) {
        const neighbor = this.particles[second];
        const distance = Math.hypot(particle.x - neighbor.x, particle.y - neighbor.y);
        const linkDistance = this.width < 600 ? 95 : 140;
        if (distance > linkDistance) continue;

        context.beginPath();
        context.moveTo(particle.x, particle.y);
        context.lineTo(neighbor.x, neighbor.y);
        context.strokeStyle = `rgba(194, 180, 245, ${(1 - distance / linkDistance) * 0.075})`;
        context.lineWidth = 0.6;
        context.stroke();
      }
    }

    if (this.pointer.active) {
      const glow = context.createRadialGradient(this.pointer.x, this.pointer.y, 0, this.pointer.x, this.pointer.y, 190);
      glow.addColorStop(0, "rgba(118, 247, 210, 0.045)");
      glow.addColorStop(1, "rgba(118, 247, 210, 0)");
      context.fillStyle = glow;
      context.fillRect(this.pointer.x - 190, this.pointer.y - 190, 380, 380);
    }
  }

  draw() {
    if (!this.running) return;

    this.paint(true);
    this.frame = requestAnimationFrame(this.draw);
  }

  drawStatic() {
    this.paint(false);
  }
}

const canvas = document.querySelector("#constellation");
let constellation;

if (canvas?.getContext) constellation = new Constellation(canvas);

reduceMotion.addEventListener("change", (event) => {
  revealElements.forEach((element) => element.classList.add("is-visible"));

  if (!constellation) return;
  if (event.matches) {
    constellation.stop();
    constellation.drawStatic();
    tracePanel?.classList.remove("is-playing");
  } else {
    constellation.start();
  }
});
