// The intro's MacBook Pro 14" in WebGL, customized with the Tjuv shield+pulse sticker and menu bar icon.
import * as THREE from "./vendor/three/three.module.min.js";
import { RoomEnvironment } from "./vendor/three/RoomEnvironment.js";

const W = 31.26;
const D = 22.12;
const BASE_T = 1.1;
const LID_T = 0.45;
const CORNER = 1.25;
const OPEN_ANGLE = THREE.MathUtils.degToRad(108);
const DISPLAY = { side: 0.55, top: 0.55, chin: 1.95 };
const DISPLAY_W = W - 2 * DISPLAY.side;
const DISPLAY_D = D - DISPLAY.top - DISPLAY.chin;
const FOV = 28;
const LAPTOP_RADIUS = 30;
const APPLE_OS = /mac|iphone|ipad/i.test(navigator.userAgentData?.platform || navigator.platform || "");
const APPLE_GLYPH = "\uF8FF";
const SYSTEM_FONT = "-apple-system, system-ui, sans-serif";

// The Tjuv domino thief eye mask (24-unit grid, matching TjuvMark.swift and favicon.svg).
const MASK_OUTER = "M12 7.8C14.2 7.8 15.8 6.2 18.2 6.2C20.8 6.2 22.4 8 22.4 11.4C22.4 15 20.2 17.6 17.2 17.6C14.8 17.6 13.6 14.2 12 14.2C10.4 14.2 9.2 17.6 6.8 17.6C3.8 17.6 1.6 15 1.6 11.4C1.6 8 3.2 6.2 5.8 6.2C8.2 6.2 9.8 7.8 12 7.8Z";
const LEFT_EYE = "M4.4 11.3C5.2 9.5 8.2 9.7 9.8 11.8C8.6 13.5 5.4 13.4 4.4 11.3Z";
const RIGHT_EYE = "M19.6 11.3C18.8 9.5 15.8 9.7 14.2 11.8C15.4 13.5 18.6 13.4 19.6 11.3Z";

export function createLaptopView(canvas) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true });
  try {
    return setUpView(renderer);
  } catch (error) {
    dispose(renderer);
    throw error;
  }
}

function dispose(renderer) {
  renderer.dispose();
  renderer.forceContextLoss();
}

function setUpView(renderer) {
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.05;

  const scene = new THREE.Scene();
  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;
  const key = new THREE.DirectionalLight(0xffffff, 1.2);
  key.position.set(-20, 40, 30);
  scene.add(key);

  const camera = new THREE.PerspectiveCamera(FOV, 1, 4, 400);
  const laptop = buildLaptop(renderer, scene.environment);
  scene.add(laptop.group);

  let layout = null;
  let drawn = null;

  function resize({ width, height, copyBottom }) {
    const pixelRatio = Math.min(window.devicePixelRatio, 2);
    const size = renderer.getSize(new THREE.Vector2());
    if (renderer.getPixelRatio() !== pixelRatio || size.x !== width || size.y !== height) {
      renderer.setPixelRatio(pixelRatio);
      renderer.setSize(width, height, false);
    }
    camera.aspect = width / height;
    camera.updateProjectionMatrix();
    layout = computeLayout(width, height, copyBottom);
    drawn = null;
  }

  function update({ open, zoom }) {
    if (!layout || (drawn && drawn.open === open && drawn.zoom === zoom)) return;
    drawn = { open, zoom };
    laptop.pivot.rotation.x = -OPEN_ANGLE * open;
    laptop.updateFaces(open);

    const closed = layout.closed;
    const opened = layout.opened;
    const target = new THREE.Vector3().lerpVectors(closed.target, opened.target, open);
    const position = new THREE.Vector3().lerpVectors(closed.position, opened.position, open);
    if (zoom > 0) {
      const screen = displayPose(laptop);
      position.lerp(screen.position, zoom);
      target.lerp(screen.target, zoom);
    }
    camera.position.copy(position);
    camera.lookAt(target);
    const distance = position.distanceTo(target);
    camera.near = Math.max(1, distance - LAPTOP_RADIUS);
    camera.far = distance + LAPTOP_RADIUS;
    camera.updateProjectionMatrix();
    renderer.render(scene, camera);
  }

  function computeLayout(width, height, copyBottom) {
    const tanHalf = Math.tan(THREE.MathUtils.degToRad(FOV / 2));
    const aspect = width / height;

    const available = Math.max(height - copyBottom - 24, height * 0.28);
    const closedWidthPx = Math.min(width * (width < 760 ? 0.86 : 0.46), available / 0.62, 640);
    const closedDistance = (W / closedWidthPx) * (width / (2 * tanHalf * aspect));
    const closedCenter = new THREE.Vector3(0, BASE_T, 0);
    const elevation = 0.6;
    const closedDirection = new THREE.Vector3(0, Math.sin(elevation), Math.cos(elevation));
    const wantY = copyBottom + available / 2 + 8;
    const shift = ((wantY - height / 2) / height) * 2 * closedDistance * tanHalf;
    const closedUp = new THREE.Vector3(0, Math.cos(elevation), -Math.sin(elevation));
    const closed = {
      position: closedCenter.clone().addScaledVector(closedDirection, closedDistance).addScaledVector(closedUp, shift),
      target: closedCenter.clone().addScaledVector(closedUp, shift),
    };

    const openCenter = new THREE.Vector3(0, 10, -4);
    const openHeight = 30;
    const openDistance = Math.max(openHeight / (2 * tanHalf * 0.78), W / (2 * tanHalf * aspect * 0.8));
    const openDirection = new THREE.Vector3(0, Math.sin(0.2), Math.cos(0.2));
    const opened = { position: openCenter.clone().addScaledVector(openDirection, openDistance), target: openCenter };

    return { closed, opened, tanHalf, aspect };
  }

  function displayPose(view) {
    view.group.updateMatrixWorld(true);
    const center = view.displayCenter.clone().applyMatrix4(view.pivot.matrixWorld);
    const normal = new THREE.Vector3(0, -1, 0).transformDirection(view.pivot.matrixWorld);
    const { tanHalf, aspect } = layout;
    const distance = Math.min(DISPLAY_D / (2 * tanHalf), DISPLAY_W / (2 * tanHalf * aspect)) * 0.97;
    return { position: center.clone().addScaledVector(normal, distance), target: center };
  }

  return { resize, update, dispose: () => dispose(renderer) };
}

function buildLaptop(renderer, environment) {
  const group = new THREE.Group();
  const aluminium = new THREE.MeshPhysicalMaterial({ color: 0xc9ccd1, metalness: 1, roughness: 0.36 });
  const anisotropy = renderer.capabilities.getMaxAnisotropy();

  const base = new THREE.Mesh(slab(W, D, BASE_T, CORNER, 0.22), aluminium);
  group.add(base);

  const deck = new THREE.Mesh(
    new THREE.PlaneGeometry(W - 0.6, D - 0.6).rotateX(-Math.PI / 2),
    overlay(new THREE.MeshStandardMaterial({ map: canvasTexture(drawDeck, 2048, Math.round(2048 * (D - 0.6) / (W - 0.6)), anisotropy), transparent: true, roughness: 0.55, metalness: 0.3 })),
  );
  deck.position.y = BASE_T + 0.02;
  group.add(deck);

  const pivot = new THREE.Group();
  pivot.position.set(0, BASE_T + 0.02, -D / 2);
  group.add(pivot);

  const lid = new THREE.Mesh(slab(W, D, LID_T, CORNER, 0.12), aluminium);
  lid.position.z = D / 2;
  pivot.add(lid);

  const glass = new THREE.Mesh(
    new THREE.ShapeGeometry(roundedRect(W - 0.16, D - 0.16, CORNER - 0.08), 12).rotateX(Math.PI / 2),
    overlay(new THREE.MeshPhysicalMaterial({ color: 0x050506, roughness: 0.2, metalness: 0, clearcoat: 0.4, clearcoatRoughness: 0.2, envMap: environment, envMapIntensity: 0.07 }), 1),
  );
  glass.position.set(0, -0.015, D / 2);
  pivot.add(glass);

  const displayCenter = new THREE.Vector3(0, -0.04, DISPLAY.chin + DISPLAY_D / 2);
  const display = new THREE.Mesh(
    displayGeometry(),
    overlay(new THREE.MeshBasicMaterial({ map: canvasTexture(drawScreen, 2048, Math.round(2048 * DISPLAY_D / DISPLAY_W), anisotropy), toneMapped: false })),
  );
  display.position.copy(displayCenter);
  pivot.add(display);

  const sticker = new THREE.Mesh(
    new THREE.PlaneGeometry(5.4, 5.4).rotateX(-Math.PI / 2).rotateY(THREE.MathUtils.degToRad(-8)),
    overlay(new THREE.MeshStandardMaterial({ map: canvasTexture(drawSticker, 512, 512, anisotropy), transparent: true, roughness: 0.4 })),
  );
  sticker.position.set(6.6, LID_T + 0.03, D * 0.38);
  pivot.add(sticker);

  if (APPLE_OS) {
    const logo = new THREE.Mesh(
      new THREE.PlaneGeometry(5.2, 5.2).rotateX(-Math.PI / 2).rotateY(Math.PI),
      overlay(new THREE.MeshPhysicalMaterial({ map: canvasTexture(drawLogo, 512, 512, anisotropy), transparent: true, color: 0xa9adb3, metalness: 1, roughness: 0.1 })),
    );
    logo.position.set(0, LID_T + 0.03, D / 2);
    pivot.add(logo);
  }

  const shadow = new THREE.Mesh(
    new THREE.PlaneGeometry(W * 1.5, D * 1.6).rotateX(-Math.PI / 2),
    new THREE.MeshBasicMaterial({ map: canvasTexture(drawShadow, 256, 256), transparent: true, depthWrite: false, toneMapped: false }),
  );
  shadow.position.y = -0.02;
  group.add(shadow);

  return {
    group, pivot, displayCenter,
    updateFaces(open) {
      display.material.color.setScalar(THREE.MathUtils.clamp(open * 1.6, 0, 1));
    },
  };
}

function overlay(material, level = 2) {
  material.polygonOffset = true;
  material.polygonOffsetFactor = -level;
  material.polygonOffsetUnits = -4 * level;
  return material;
}

function displayGeometry() {
  const geometry = new THREE.ShapeGeometry(roundedRect(DISPLAY_W, DISPLAY_D, CORNER - DISPLAY.side, 0.3), 12);
  const uv = geometry.attributes.uv;
  for (let i = 0; i < uv.count; i++) uv.setXY(i, uv.getX(i) / DISPLAY_W + 0.5, uv.getY(i) / DISPLAY_D + 0.5);
  return geometry.rotateX(Math.PI / 2);
}

function slab(width, depth, thickness, radius, bevel) {
  const geometry = new THREE.ExtrudeGeometry(roundedRect(width - 2 * bevel, depth - 2 * bevel, radius - bevel), {
    depth: thickness - 2 * bevel, bevelEnabled: true, bevelThickness: bevel, bevelSize: bevel,
    bevelSegments: 5, curveSegments: 24,
  });
  geometry.rotateX(-Math.PI / 2);
  geometry.translate(0, bevel, 0);
  geometry.computeVertexNormals();
  return geometry;
}

function roundedRect(width, depth, radius, bottomRadius = radius) {
  const x = -width / 2;
  const y = -depth / 2;
  const shape = new THREE.Shape();
  shape.moveTo(x + bottomRadius, y);
  shape.lineTo(x + width - bottomRadius, y);
  shape.quadraticCurveTo(x + width, y, x + width, y + bottomRadius);
  shape.lineTo(x + width, y + depth - radius);
  shape.quadraticCurveTo(x + width, y + depth, x + width - radius, y + depth);
  shape.lineTo(x + radius, y + depth);
  shape.quadraticCurveTo(x, y + depth, x, y + depth - radius);
  shape.lineTo(x, y + bottomRadius);
  shape.quadraticCurveTo(x, y, x + bottomRadius, y);
  return shape;
}

function canvasTexture(draw, width, height, anisotropy = 1) {
  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;
  draw(canvas.getContext("2d"), width, height);
  const texture = new THREE.CanvasTexture(canvas);
  texture.colorSpace = THREE.SRGBColorSpace;
  texture.anisotropy = anisotropy;
  return texture;
}

function roundRect(ctx, x, y, width, height, radius) {
  ctx.beginPath();
  ctx.roundRect(x, y, width, height, radius);
}

function drawScreen(ctx, width, height) {
  const wallpaper = ctx.createRadialGradient(width * 0.7, 0, 0, width * 0.7, 0, width * 0.9);
  wallpaper.addColorStop(0, "#351E33");
  wallpaper.addColorStop(0.58, "#15142B");
  wallpaper.addColorStop(1, "#15142B");
  ctx.fillStyle = wallpaper;
  ctx.fillRect(0, 0, width, height);

  const bar = height * 0.036;
  ctx.fillStyle = "rgba(255,255,255,0.1)";
  ctx.fillRect(0, 0, width, bar);
  ctx.fillStyle = "rgba(255,255,255,0.92)";
  ctx.textBaseline = "middle";

  let x = width * 0.014;
  if (APPLE_OS) {
    ctx.font = `${bar * 0.6}px ${SYSTEM_FONT}`;
    ctx.fillText(APPLE_GLYPH, x, bar / 2);
    x += ctx.measureText(APPLE_GLYPH).width;
  } else {
    ctx.beginPath();
    ctx.ellipse(x + bar * 0.2, bar / 2, bar * 0.2, bar * 0.24, 0, 0, Math.PI * 2);
    ctx.fill();
    x += bar * 0.4;
  }
  const gap = bar * 0.75;
  [["Tjuv", 700], ...["File", "Edit", "View", "Go", "Window", "Help"].map((label) => [label, 400])].forEach(([label, weight]) => {
    x += gap;
    ctx.font = `${weight} ${bar * 0.5}px ${SYSTEM_FONT}`;
    ctx.fillText(label, x, bar / 2);
    x += ctx.measureText(label).width;
  });
  ctx.font = `400 ${bar * 0.5}px ${SYSTEM_FONT}`;
  ctx.fillText("Wed 13:15", width * 0.93, bar / 2);

  // The Tjuv thief mask in the menu bar.
  ctx.save();
  ctx.translate(width * 0.885, bar * 0.14);
  const scale = (bar * 0.72) / 21;
  ctx.scale(scale, scale);
  ctx.translate(-1.5, -1.5);
  ctx.strokeStyle = "#fff";
  ctx.lineWidth = 1.9;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.stroke(new Path2D(MASK_OUTER));
  ctx.stroke(new Path2D(LEFT_EYE));
  ctx.stroke(new Path2D(RIGHT_EYE));
  ctx.restore();

  ctx.fillStyle = "#000";
  roundRect(ctx, width * 0.4525, -bar, width * 0.095, bar * 2, bar * 0.45);
  ctx.fill();
}

function drawDeck(ctx, width, height) {
  const u = width / 30.66;
  ctx.fillStyle = "rgba(20,20,22,0.55)";
  roundRect(ctx, 3.2 * u, 0, width - 6.4 * u, 0.55 * u, 0.3 * u);
  ctx.fill();

  ctx.fillStyle = "rgba(30,30,34,0.85)";
  for (const left of [0.75, width / u - 2.85]) {
    for (let y = 1.2; y < 11.4; y += 0.32) {
      for (let x = left; x < left + 2.1; x += 0.32) {
        ctx.beginPath();
        ctx.arc(x * u, y * u, 0.07 * u, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  const kx = 3.25 * u;
  const ky = 1.1 * u;
  const kw = width - 6.5 * u;
  const kh = 10.3 * u;
  ctx.fillStyle = "rgba(26,26,29,0.9)";
  roundRect(ctx, kx, ky, kw, kh, 0.35 * u);
  ctx.fill();
  const rows = [
    [1.5, ...Array(12).fill(1), 1],
    [...Array(13).fill(1), 1.5],
    [1.5, ...Array(13).fill(1)],
    [1.8, ...Array(11).fill(1), 1.7],
    [2.3, ...Array(10).fill(1), 2.2],
    [1, 1, 1, 1.25, 5, 1.25, 1, 1, 1, 1],
  ];
  const gap = 0.16 * u;
  const pad = 0.18 * u;
  const unit = (kw - 2 * pad) / 14.5;
  const heights = [0.62, 1, 1, 1, 1, 1];
  const rowUnit = (kh - 2 * pad - gap * 5) / heights.reduce((a, b) => a + b, 0);
  let y = ky + pad;
  rows.forEach((row, rowIndex) => {
    let x = kx + pad;
    const rowHeight = rowUnit * heights[rowIndex];
    row.forEach((keyWidth, index) => {
      const w = keyWidth * unit - gap;
      const gradient = ctx.createLinearGradient(0, y, 0, y + rowHeight);
      gradient.addColorStop(0, "#121214");
      gradient.addColorStop(1, "#08080A");
      ctx.fillStyle = gradient;
      roundRect(ctx, x, y, w, rowHeight, 0.12 * u);
      ctx.fill();
      if (rowIndex === 0 && index === row.length - 1) {
        ctx.strokeStyle = "rgba(255,255,255,0.12)";
        ctx.lineWidth = 0.04 * u;
        ctx.beginPath();
        ctx.arc(x + w / 2, y + rowHeight / 2, rowHeight * 0.32, 0, Math.PI * 2);
        ctx.stroke();
      }
      x += keyWidth * unit;
    });
    y += rowHeight + gap;
  });

  const tw = 15.2 * u;
  const th = 9.4 * u;
  const tx = (width - tw) / 2;
  const ty = height - th - 0.9 * u;
  ctx.fillStyle = "rgba(0,0,0,0.05)";
  roundRect(ctx, tx, ty, tw, th, 0.6 * u);
  ctx.fill();
  ctx.strokeStyle = "rgba(0,0,0,0.22)";
  ctx.lineWidth = 0.035 * u;
  ctx.stroke();
}

function drawSticker(ctx, width) {
  const s = width;
  ctx.fillStyle = "#fff";
  roundRect(ctx, s * 0.02, s * 0.02, s * 0.96, s * 0.96, s * 0.25);
  ctx.fill();
  ctx.fillStyle = "#15142B";
  roundRect(ctx, s * 0.08, s * 0.08, s * 0.84, s * 0.84, s * 0.2);
  ctx.fill();
  ctx.save();
  const scale = (s * 0.84 * 0.68) / 20.8;
  ctx.translate(s / 2 - 12.0 * scale, s / 2 - 11.9 * scale);
  ctx.scale(scale, scale);
  ctx.strokeStyle = "#FF4D42";
  ctx.lineWidth = 1.65;
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.stroke(new Path2D(MASK_OUTER));
  ctx.stroke(new Path2D(LEFT_EYE));
  ctx.stroke(new Path2D(RIGHT_EYE));
  ctx.restore();
}

function drawLogo(ctx, width) {
  ctx.fillStyle = "#fff";
  ctx.font = `${width * 0.9}px ${SYSTEM_FONT}`;
  const box = ctx.measureText(APPLE_GLYPH);
  const glyphWidth = box.actualBoundingBoxLeft + box.actualBoundingBoxRight;
  const glyphHeight = box.actualBoundingBoxAscent + box.actualBoundingBoxDescent;
  ctx.fillText(
    APPLE_GLYPH,
    (width - glyphWidth) / 2 + box.actualBoundingBoxLeft,
    (width - glyphHeight) / 2 + box.actualBoundingBoxAscent,
  );
}

function drawShadow(ctx, width, height) {
  const gradient = ctx.createRadialGradient(width / 2, height / 2, 0, width / 2, height / 2, width / 2);
  gradient.addColorStop(0, "rgba(21,20,43,0.32)");
  gradient.addColorStop(0.55, "rgba(21,20,43,0.16)");
  gradient.addColorStop(1, "rgba(21,20,43,0)");
  ctx.fillStyle = gradient;
  ctx.fillRect(0, 0, width, height);
}
