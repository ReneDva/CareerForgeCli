#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const distCliPath = path.resolve(__dirname, 'dist', 'cli.js');

if (!fs.existsSync(distCliPath)) {
  console.error("❌ Missing build output: dist/cli.js");
  console.error("Run: npm run build");
  process.exit(1);
}

require(distCliPath);
