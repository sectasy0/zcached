const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
const canvas = document.querySelector("#energy-field");
const context = canvas.getContext("2d");
let particles = [];
let bursts = [];
let width = 0;
let height = 0;

function resizeCanvas() {
  const ratio = Math.min(window.devicePixelRatio || 1, 2);
  width = window.innerWidth;
  height = window.innerHeight;
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
  particles = Array.from({ length: Math.min(70, Math.floor(width / 20)) }, () => ({
    x: Math.random() * width,
    y: Math.random() * height,
    vx: (Math.random() - 0.5) * 0.16,
    vy: (Math.random() - 0.5) * 0.16,
    radius: Math.random() * 1.2 + 0.35,
  }));
}

function burst(x, y) {
  if (reducedMotion) return;
  for (let i = 0; i < 22; i += 1) {
    const angle = (Math.PI * 2 * i) / 22;
    const speed = 0.8 + Math.random() * 2.2;
    bursts.push({ x, y, vx: Math.cos(angle) * speed, vy: Math.sin(angle) * speed, life: 1 });
  }
}

function draw() {
  context.clearRect(0, 0, width, height);
  for (let i = 0; i < particles.length; i += 1) {
    const particle = particles[i];
    particle.x += particle.vx;
    particle.y += particle.vy;
    if (particle.x < 0 || particle.x > width) particle.vx *= -1;
    if (particle.y < 0 || particle.y > height) particle.vy *= -1;

    context.beginPath();
    context.fillStyle = `rgba(68, 238, 166, ${0.16 + particle.radius * 0.08})`;
    context.arc(particle.x, particle.y, particle.radius, 0, Math.PI * 2);
    context.fill();

    for (let j = i + 1; j < particles.length; j += 1) {
      const other = particles[j];
      const dx = particle.x - other.x;
      const dy = particle.y - other.y;
      const distance = Math.hypot(dx, dy);
      if (distance < 120) {
        context.strokeStyle = `rgba(45, 227, 155, ${0.025 * (1 - distance / 120)})`;
        context.beginPath();
        context.moveTo(particle.x, particle.y);
        context.lineTo(other.x, other.y);
        context.stroke();
      }
    }
  }

  bursts = bursts.filter((particle) => particle.life > 0);
  bursts.forEach((particle) => {
    particle.x += particle.vx;
    particle.y += particle.vy;
    particle.vy += 0.015;
    particle.life -= 0.018;
    context.fillStyle = `rgba(118, 255, 196, ${Math.max(particle.life, 0)})`;
    context.fillRect(particle.x, particle.y, 1.8, 1.8);
  });
  if (!reducedMotion) requestAnimationFrame(draw);
}

if (!reducedMotion) {
  resizeCanvas();
  draw();
  window.addEventListener("resize", resizeCanvas);
  window.addEventListener("pointerdown", (event) => {
    burst(event.clientX, event.clientY);
  }, { passive: true });
}

const typedCommand = document.querySelector("#typed-command");
const typedText = "zcached-cli GET session:user-42";
let commandIndex = 0;
function typeCommand() {
  if (reducedMotion) {
    typedCommand.textContent = typedText;
    return;
  }
  if (commandIndex <= typedText.length) {
    typedCommand.textContent = typedText.slice(0, commandIndex);
    commandIndex += 1;
    setTimeout(typeCommand, 48 + Math.random() * 38);
  } else {
    setTimeout(() => {
      commandIndex = 0;
      typeCommand();
    }, 4000);
  }
}
typeCommand();

const counter = document.querySelector("[data-count]");
let counterStarted = false;
const counterObserver = new IntersectionObserver((entries) => {
  if (!entries[0].isIntersecting || counterStarted) return;
  counterStarted = true;
  const target = Number(counter.dataset.count);
  const start = performance.now();
  function updateCounter(now) {
    const progress = reducedMotion ? 1 : Math.min((now - start) / 1500, 1);
    const eased = 1 - Math.pow(1 - progress, 3);
    counter.textContent = Math.round(target * eased).toLocaleString("en-US");
    if (progress < 1) requestAnimationFrame(updateCounter);
  }
  requestAnimationFrame(updateCounter);
}, { threshold: 0.5 });
counterObserver.observe(counter);

document.querySelectorAll(".code-tabs button[data-tab]").forEach((button) => {
  button.addEventListener("click", () => {
    document.querySelectorAll(".code-tabs button[data-tab]").forEach((item) => item.classList.remove("active"));
    document.querySelectorAll(".code-pane").forEach((pane) => pane.classList.remove("active"));
    button.classList.add("active");
    document.querySelector(`[data-pane="${button.dataset.tab}"]`).classList.add("active");
  });
});

const copyButton = document.querySelector(".copy-button");
copyButton.addEventListener("click", async () => {
  const activeCode = document.querySelector(".code-pane.active code").innerText;
  await navigator.clipboard.writeText(activeCode);
  copyButton.querySelector("span").textContent = "Copied";
  burst(copyButton.getBoundingClientRect().left, copyButton.getBoundingClientRect().top);
  setTimeout(() => { copyButton.querySelector("span").textContent = "Copy"; }, 1500);
});

const cards = document.querySelectorAll(".feature-card");
cards.forEach((card) => {
  card.addEventListener("pointermove", (event) => {
    const bounds = card.getBoundingClientRect();
    const x = ((event.clientX - bounds.left) / bounds.width) * 100;
    const y = ((event.clientY - bounds.top) / bounds.height) * 100;
    card.style.background = `radial-gradient(circle at ${x}% ${y}%, rgba(45, 227, 155, .09), rgba(8, 15, 11, .85) 45%)`;
  });
  card.addEventListener("pointerleave", () => { card.style.background = ""; });
});

function connectArchitecture() {
  const board = document.querySelector(".architecture-board");
  const svg = board?.querySelector(".architecture-lines");
  if (!board || !svg || window.innerWidth <= 680) return;
  const bounds = board.getBoundingClientRect();
  svg.querySelectorAll("[data-from]").forEach((line) => {
    const source = board.querySelector(line.dataset.from).getBoundingClientRect();
    const target = board.querySelector(line.dataset.to).getBoundingClientRect();
    const sx = source.left - bounds.left;
    const sy = source.top - bounds.top;
    const tx = target.left - bounds.left;
    const ty = target.top - bounds.top;
    const sourceCenterX = sx + source.width / 2;
    const sourceCenterY = sy + source.height / 2;
    const targetCenterX = tx + target.width / 2;
    const targetCenterY = ty + target.height / 2;
    const dx = targetCenterX - sourceCenterX;
    const dy = targetCenterY - sourceCenterY;
    const start = Math.abs(dx) > Math.abs(dy)
      ? { x: dx > 0 ? sx + source.width + 3 : sx - 3, y: sourceCenterY }
      : { x: sourceCenterX, y: dy > 0 ? sy + source.height + 3 : sy - 3 };
    const end = Math.abs(dx) > Math.abs(dy)
      ? { x: dx > 0 ? tx - 7 : tx + target.width + 7, y: targetCenterY }
      : { x: targetCenterX, y: dy > 0 ? ty - 7 : ty + target.height + 7 };
    const middleX = (start.x + end.x) / 2;
    const middleY = (start.y + end.y) / 2;
    const path = Math.abs(dx) > Math.abs(dy)
      ? `M ${start.x} ${start.y} L ${middleX} ${start.y} L ${middleX} ${end.y} L ${end.x} ${end.y}`
      : `M ${start.x} ${start.y} L ${start.x} ${middleY} L ${end.x} ${middleY} L ${end.x} ${end.y}`;
    line.setAttribute("d", path);
  });
  svg.setAttribute("viewBox", `0 0 ${bounds.width} ${bounds.height}`);
}

window.connectArchitecture = connectArchitecture;
requestAnimationFrame(connectArchitecture);
window.addEventListener("resize", connectArchitecture);
window.addEventListener("load", () => requestAnimationFrame(connectArchitecture));
