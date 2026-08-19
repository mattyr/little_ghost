const root = document.documentElement;
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

root.classList.add("js");

const header = document.querySelector(".site-header");
const updateHeader = () => header?.classList.toggle("is-scrolled", window.scrollY > 28);

updateHeader();
window.addEventListener("scroll", updateHeader, { passive: true });

const introGhost = document.querySelector(".intro-ghost");
let pointerFrame = 0;
let pointerX = window.innerWidth / 2;
let pointerY = window.innerHeight / 2;
let pointerType = "mouse";
window.addEventListener(
  "pointermove",
  (event) => {
    pointerX = event.clientX;
    pointerY = event.clientY;
    pointerType = event.pointerType;
    if (pointerFrame) return;

    pointerFrame = requestAnimationFrame(() => {
      pointerFrame = 0;
      root.style.setProperty("--pointer-x", `${pointerX}px`);
      root.style.setProperty("--pointer-y", `${pointerY}px`);

      if (!introGhost || reduceMotion.matches || pointerType === "touch") return;

      const bounds = introGhost.getBoundingClientRect();
      const centerX = bounds.left + bounds.width / 2;
      const centerY = bounds.top + bounds.height / 2;
      const horizontal = Math.max(-1, Math.min(1, (pointerX - centerX) / (window.innerWidth * 0.7)));
      const vertical = Math.max(-1, Math.min(1, (pointerY - centerY) / (window.innerHeight * 0.7)));
      introGhost.style.setProperty("--pupil-x", `${0.4 + horizontal * 1.8}px`);
      introGhost.style.setProperty("--pupil-y", `${vertical * 1.9}px`);
    });
  },
  { passive: true },
);

const createDemo = (section) => {
  const lineElements = [...section.querySelectorAll("[data-demo-line]")];
  const highlightedLines = lineElements.map((line) => line.innerHTML);
  const syntaxClasses = ["syntax-keyword", "syntax-constant", "syntax-method", "syntax-string"];
  const typedCharacters = lineElements.map((line) => {
    const characters = [];
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
    let textNode = walker.nextNode();

    while (textNode) {
      const syntaxParent = textNode.parentElement.closest(`.${syntaxClasses.join(", .")}`);
      const className = syntaxClasses.find((name) => syntaxParent?.classList.contains(name)) ?? "";
      [...textNode.data].forEach((character) => characters.push({character, className}));
      textNode = walker.nextNode();
    }

    return characters;
  });
  const recording = section.querySelector(".recording");
  const editor = section.querySelector(".editor");
  const ghost = section.querySelector(".typing-ghost");
  const spark = section.querySelector(".typing-spark");
  const runButton = section.querySelector(".run-button");
  const replayButton = section.querySelector(".replay-button");
  const underhood = section.querySelector(".underhood");
  const flowRequest = section.querySelector(".flow-request");
  const flowResponse = section.querySelector(".flow-response");
  const flowNodes = [...section.querySelectorAll("[data-flow-node]")];
  const flowEdges = [...section.querySelectorAll("[data-flow-edge]")];
  const command = section.querySelector(".output-command");
  const output = section.querySelector(".output-text");
  const caret = section.querySelector(".output-caret");
  const announcement = section.querySelector(".demo-announcement");
  let generation = 0;
  let lineDestinations = [];

  const wait = (duration, expectedGeneration) => new Promise((resolve) => {
    window.setTimeout(() => resolve(expectedGeneration === generation), duration);
  });

  const allowRecordingGrowth = () => {
    recording.style.minHeight = `${recording.offsetHeight}px`;
    recording.style.height = "auto";
  };

  const caretBoxFor = (line) => {
    const walker = document.createTreeWalker(line, NodeFilter.SHOW_TEXT);
    let lastTextNode;
    let textNode = walker.nextNode();

    while (textNode) {
      if (textNode.data.length > 0) lastTextNode = textNode;
      textNode = walker.nextNode();
    }
    if (!lastTextNode) return null;

    const range = document.createRange();
    range.setStart(lastTextNode, lastTextNode.data.length);
    range.collapse(true);
    return range.getBoundingClientRect();
  };

  const measureLineDestinations = () => {
    const currentMarkup = lineElements.map((line) => line.innerHTML);
    lineElements.forEach((line, index) => {
      line.innerHTML = highlightedLines[index];
    });
    const editorBox = editor.getBoundingClientRect();
    const horizontalRange = Math.min(24, editorBox.width * 0.065);
    const compact = window.matchMedia("(max-width: 470px)").matches;
    lineDestinations = lineElements.map((line, index) => {
      const lineBox = line.getBoundingClientRect();
      const horizontalDrift = Math.sin(index * 1.15) * horizontalRange;
      return {
        x: compact
          ? editorBox.width - 39
          : Math.min(editorBox.width - 48, Math.max(72, editorBox.width * 0.62 + horizontalDrift)),
        y: lineBox.top - editorBox.top + Math.max(-2, (lineBox.height - 35) / 2),
      };
    });
    lineElements.forEach((line, index) => {
      line.innerHTML = currentMarkup[index];
    });
  };

  const placeGhost = (lineIndex) => {
    const destination = lineDestinations[lineIndex];
    if (!destination) return;

    ghost.style.left = `${destination.x}px`;
    ghost.style.top = `${destination.y}px`;
  };

  const placeSparkAfterText = (lineIndex) => {
    const line = lineElements[lineIndex];
    if (!line) return;

    const editorBox = editor.getBoundingClientRect();
    const caretBox = caretBoxFor(line);
    const lineBox = line.getBoundingClientRect();
    const x = caretBox ? Math.min(editorBox.width - 22, Math.max(42, caretBox.left - editorBox.left + 4)) : 42;
    const y = (caretBox?.height ? caretBox.top : lineBox.top) - editorBox.top + 7;
    spark.style.left = `${x}px`;
    spark.style.top = `${y}px`;
  };

  const showSpark = () => {
    spark.classList.remove("is-visible");
    void spark.offsetWidth;
    spark.classList.add("is-visible");
  };

  const finishCode = () => {
    lineElements.forEach((line, index) => {
      line.innerHTML = highlightedLines[index];
    });
    placeGhost(lineElements.length - 1);
    placeSparkAfterText(lineElements.length - 1);
  };

  const resetFlow = () => {
    flowRequest.classList.remove("is-active", "is-complete");
    flowResponse.classList.remove("is-active", "is-complete");
    flowNodes.forEach((node) => node.classList.remove("is-active", "is-complete"));
    flowEdges.forEach((edge) => edge.classList.remove("is-active", "is-complete"));
  };

  const playFlow = async (expectedGeneration) => {
    flowRequest.classList.add("is-active");
    if (reduceMotion.matches) {
      flowNodes.forEach((node) => node.classList.add("is-complete"));
      flowEdges.forEach((edge) => edge.classList.add("is-complete"));
      flowResponse.classList.add("is-complete");
      return true;
    }

    if (!(await wait(900, expectedGeneration))) return false;
    flowRequest.classList.remove("is-active");
    flowRequest.classList.add("is-complete");
    const steps = [...new Set(flowNodes.map((node) => Number(node.dataset.flowStep)))].sort((a, b) => a - b);

    for (const step of steps) {
      const stepNodes = flowNodes.filter((node) => Number(node.dataset.flowStep) === step);
      const stepEdges = flowEdges.filter((edge) => Number(edge.dataset.flowStep) === step);
      stepNodes.forEach((node) => node.classList.add("is-active"));
      stepEdges.forEach((edge) => edge.classList.add("is-active"));
      if (!(await wait(1700, expectedGeneration))) return false;
      stepNodes.forEach((node) => {
        node.classList.remove("is-active");
        node.classList.add("is-complete");
      });
      stepEdges.forEach((edge) => {
        edge.classList.remove("is-active");
        edge.classList.add("is-complete");
      });
      if (step !== steps.at(-1) && !(await wait(480, expectedGeneration))) return false;
    }

    const finalStep = Math.max(...steps) + 1;
    const finalEdges = flowEdges.filter((edge) => Number(edge.dataset.flowStep) === finalStep);
    finalEdges.forEach((edge) => edge.classList.add("is-active"));
    if (!(await wait(900, expectedGeneration))) return false;
    finalEdges.forEach((edge) => {
      edge.classList.remove("is-active");
      edge.classList.add("is-complete");
    });
    flowResponse.classList.add("is-complete");
    return true;
  };

  const runTerminal = async (expectedGeneration, animateTap = true, preserveLayout = false) => {
    if (expectedGeneration !== generation) return;

    command.textContent = "";
    output.textContent = "";
    announcement.textContent = "";
    caret.style.opacity = "";
    runButton.classList.remove("is-pressed");
    resetFlow();
    underhood.classList.remove("is-open");
    underhood.setAttribute("aria-hidden", "true");
    if (!preserveLayout) recording.classList.remove("is-executing");
    finishCode();
    ghost.classList.remove("is-typing", "is-running", "is-tapping");

    if (animateTap && !reduceMotion.matches) {
      ghost.classList.add("is-running");
      const editorBox = editor.getBoundingClientRect();
      const runBox = runButton.getBoundingClientRect();
      const ghostBox = ghost.getBoundingClientRect();
      const buttonCenter = runBox.left - editorBox.left + runBox.width / 2;
      ghost.style.left = `${Math.max(18, Math.min(editorBox.width - ghostBox.width - 12, buttonCenter - ghostBox.width / 2))}px`;
      ghost.style.top = `${runBox.top - editorBox.top + runBox.height / 2 - ghostBox.height - 3}px`;
      if (!(await wait(900, expectedGeneration))) return;
      ghost.classList.add("is-tapping");
      runButton.classList.add("is-pressed");
      if (!(await wait(260, expectedGeneration))) return;
      ghost.classList.remove("is-tapping");
      runButton.classList.remove("is-pressed");
    }

    allowRecordingGrowth();
    command.textContent = section.dataset.command;
    ghost.style.opacity = "0";
    recording.classList.add("is-executing");
    underhood.classList.add("is-open");
    underhood.setAttribute("aria-hidden", "false");
    if (!(await wait(reduceMotion.matches ? 0 : 850, expectedGeneration))) return;
    if (!(await playFlow(expectedGeneration))) return;

    if (reduceMotion.matches) {
      output.textContent = section.dataset.response;
    } else {
      for (const character of section.dataset.response) {
        if (expectedGeneration !== generation) return;
        output.textContent += character;
        if (!(await wait(character === " " ? 8 : 17, expectedGeneration))) return;
      }
    }

    caret.style.opacity = "0";
    runButton.textContent = "Replay run ↻";
    announcement.textContent = `Demo complete. ${section.dataset.response}`;
  };

  const play = async () => {
    section.dataset.started = "true";
    generation += 1;
    const expectedGeneration = generation;
    recording.style.height = `${recording.offsetHeight}px`;
    recording.classList.add("is-resetting");
    recording.classList.remove("is-executing");
    underhood.classList.remove("is-open");
    underhood.setAttribute("aria-hidden", "true");
    void recording.offsetHeight;
    measureLineDestinations();
    recording.classList.remove("is-resetting");
    lineElements.forEach((line) => {
      line.textContent = "";
    });
    command.textContent = "";
    output.textContent = "";
    announcement.textContent = "";
    caret.style.opacity = "";
    runButton.textContent = section.dataset.runLabel;
    runButton.classList.remove("is-pressed");
    resetFlow();
    ghost.classList.remove("is-running", "is-tapping");
    ghost.classList.add("is-typing");
    ghost.style.opacity = "1";
    ghost.style.transform = "";
    placeGhost(0);

    if (reduceMotion.matches) {
      finishCode();
      await runTerminal(expectedGeneration, false);
      return;
    }

    if (!(await wait(380, expectedGeneration))) return;
    for (let lineIndex = 0; lineIndex < typedCharacters.length; lineIndex += 1) {
      const line = lineElements[lineIndex];
      if (typedCharacters[lineIndex].length > 0) placeGhost(lineIndex);
      let targetNode;
      let activeClass;

      for (const token of typedCharacters[lineIndex]) {
        if (expectedGeneration !== generation) return;
        if (!targetNode || token.className !== activeClass) {
          activeClass = token.className;
          if (activeClass) {
            const span = document.createElement("span");
            span.className = activeClass;
            line.append(span);
            targetNode = span;
          } else {
            targetNode = document.createTextNode("");
            line.append(targetNode);
          }
        }
        targetNode.textContent += token.character;
        placeSparkAfterText(lineIndex);
        if (token.character !== " ") showSpark();
        if (!(await wait(token.character === " " ? 5 : 13, expectedGeneration))) return;
      }
      if (!(await wait(90, expectedGeneration))) return;
    }
    finishCode();
    if (!(await wait(320, expectedGeneration))) return;
    await runTerminal(expectedGeneration);
  };

  replayButton.addEventListener("click", play);
  runButton.addEventListener("click", () => {
    generation += 1;
    const expectedGeneration = generation;
    section.dataset.started = "true";
    ghost.style.opacity = "0";
    runTerminal(expectedGeneration, false, true);
  });
  window.addEventListener("resize", () => {
    let lastLine = 0;
    lineElements.forEach((line, index) => {
      if (line.textContent.length > 0) lastLine = index;
    });
    recording.style.height = "";
    recording.style.minHeight = "";
    measureLineDestinations();
    placeGhost(lastLine);
    placeSparkAfterText(lastLine);
  });

  recording.style.height = `${recording.offsetHeight}px`;
  measureLineDestinations();
  lineElements.forEach((line) => {
    line.textContent = "";
  });
  command.textContent = "";
  output.textContent = "";
  announcement.textContent = "";
  ghost.style.opacity = "0";
  underhood.setAttribute("aria-hidden", "true");

  return { play };
};

const sections = [...document.querySelectorAll("[data-demo]")];
const controllers = new Map(sections.map((section) => [section, createDemo(section)]));

if (!("IntersectionObserver" in window)) {
  controllers.forEach((controller) => controller.play());
} else {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        const section = entry.target.closest("[data-demo]");
        if (!section.dataset.started) controllers.get(section).play();
        observer.unobserve(entry.target);
      });
    },
    { threshold: 0.25 },
  );
  sections.forEach((section) => observer.observe(section.querySelector(".editor")));
}

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
    this.colors = ["121, 246, 212", "180, 154, 255", "255, 143, 169", "247, 244, 237"];
    this.resize = this.resize.bind(this);
    this.draw = this.draw.bind(this);
    this.handlePointer = this.handlePointer.bind(this);
    this.handleVisibility = this.handleVisibility.bind(this);

    if (!this.context) return;
    this.resize();
    window.addEventListener("resize", this.resize, { passive: true });
    window.addEventListener("pointermove", this.handlePointer, { passive: true });
    window.addEventListener("pointerleave", () => {
      this.pointer.active = false;
    });
    document.addEventListener("visibilitychange", this.handleVisibility);
    if (reduceMotion.matches) this.drawStatic();
    else this.start();
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

  paint(update) {
    const context = this.context;
    context.clearRect(0, 0, this.width, this.height);
    this.particles.forEach((particle) => {
      if (update) {
        particle.x += particle.vx;
        particle.y += particle.vy;
        if (particle.x < -20) particle.x = this.width + 20;
        if (particle.x > this.width + 20) particle.x = -20;
        if (particle.y < -20) particle.y = this.height + 20;
        if (particle.y > this.height + 20) particle.y = -20;

        if (this.pointer.active) {
          const deltaX = this.pointer.x - particle.x;
          const deltaY = this.pointer.y - particle.y;
          const distance = Math.hypot(deltaX, deltaY);
          if (distance > 0 && distance < 180) {
            const force = (180 - distance) / 1800;
            particle.x -= deltaX * force * 0.08;
            particle.y -= deltaY * force * 0.08;
          }
        }
      }

      context.beginPath();
      context.fillStyle = `rgba(${particle.color}, ${particle.alpha})`;
      context.arc(particle.x, particle.y, particle.radius, 0, Math.PI * 2);
      context.fill();
    });

    for (let first = 0; first < this.particles.length; first += 1) {
      const particle = this.particles[first];

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
      const radius = 190;
      const glow = context.createRadialGradient(this.pointer.x, this.pointer.y, 0, this.pointer.x, this.pointer.y, radius);
      glow.addColorStop(0, "rgba(121, 246, 212, 0.045)");
      glow.addColorStop(1, "rgba(121, 246, 212, 0)");
      context.fillStyle = glow;
      context.fillRect(this.pointer.x - radius, this.pointer.y - radius, radius * 2, radius * 2);
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

const constellationCanvas = document.querySelector("#constellation");
const constellation = constellationCanvas ? new Constellation(constellationCanvas) : null;

reduceMotion.addEventListener("change", (event) => {
  if (!constellation) return;
  if (event.matches) {
    constellation.stop();
    constellation.drawStatic();
  } else {
    constellation.start();
  }
});
