#!/usr/bin/env node

/**
 * PWA Icon Generator
 *
 * Generates PWA icons from the Mydia logo SVG.
 *
 * Requirements:
 *   npm install -g sharp-cli
 *   OR
 *   npm install sharp (in assets folder)
 *
 * Usage:
 *   node scripts/generate_pwa_icons.js
 *
 * Alternative (using ImageMagick):
 *   convert -background "#1d232a" -resize 192x192 priv/static/images/logo.svg priv/static/images/icons/icon-192.png
 *   convert -background "#1d232a" -resize 512x512 priv/static/images/logo.svg priv/static/images/icons/icon-512.png
 */

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');

// Try to use sharp if available (check assets/node_modules first)
let sharp;
try {
  sharp = require(path.join(ROOT, 'assets/node_modules/sharp'));
} catch (e1) {
  try {
    sharp = require('sharp');
  } catch (e2) {
    console.log('Sharp not found. Please install it:');
    console.log('  cd assets && npm install sharp');
    console.log('');
    console.log('Or use ImageMagick:');
    console.log('  convert -background "#1d232a" -resize 192x192 priv/static/images/logo.svg priv/static/images/icons/icon-192.png');
    console.log('  convert -background "#1d232a" -resize 512x512 priv/static/images/logo.svg priv/static/images/icons/icon-512.png');
    process.exit(1);
  }
}

const SVG_PATH = path.join(ROOT, 'priv/static/images/logo.svg');
const ICONS_DIR = path.join(ROOT, 'priv/static/images/icons');

const SIZES = [192, 512];
const BG_COLOR = '#1d232a';
const BRAND_COLOR = '#3b82f6';

async function generateIcons() {
  // Ensure icons directory exists
  if (!fs.existsSync(ICONS_DIR)) {
    fs.mkdirSync(ICONS_DIR, { recursive: true });
  }

  // Read the SVG
  const svgContent = fs.readFileSync(SVG_PATH, 'utf8');

  for (const size of SIZES) {
    const padding = Math.floor(size * 0.15);
    const logoSize = size - (padding * 2);

    // Create SVG with background and centered logo
    const wrappedSvg = `
      <svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}">
        <rect width="${size}" height="${size}" fill="${BG_COLOR}" rx="${Math.floor(size * 0.1)}"/>
        <g transform="translate(${padding}, ${padding})">
          <svg width="${logoSize}" height="${logoSize}" viewBox="0 0 71 48" fill="${BRAND_COLOR}">
            ${svgContent.match(/<path[^>]+\/>/)?.[0] || ''}
          </svg>
        </g>
      </svg>
    `;

    const outputPath = path.join(ICONS_DIR, `icon-${size}.png`);

    await sharp(Buffer.from(wrappedSvg))
      .png()
      .toFile(outputPath);

    console.log(`Generated: ${outputPath}`);
  }

  console.log('PWA icons generated successfully!');
}

generateIcons().catch(console.error);
