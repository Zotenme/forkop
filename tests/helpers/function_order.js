#!/usr/bin/env node
"use strict";

// ucode resolves names at compile time: a function body that mentions a
// top-level function declared further down the file sees an undefined global
// and fails at runtime with "left-hand side is not a function". `ucode -c` and
// `ucode -S -c` do not report this, so check the declaration order here.

const fs = require("fs");

const WORD = /(?<![.\w])([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*:(?!:))/g;
const STRINGS = /"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'/g;
const COMMENT = /\/\/.*$/;
const LOCAL_DECL = /\b(?:let|const)\s+([A-Za-z_][A-Za-z0-9_]*(?:\s*(?:=[^,;]*)?\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)/g;
const HEADER = /^function ([A-Za-z_][A-Za-z0-9_]*)\(([^)]*)\)/;

function usage() {
  console.error("Usage: function_order.js <file.uc> [...]");
  process.exit(2);
}

function clean(line) {
  return line.replace(STRINGS, '""').replace(COMMENT, "");
}

function localNames(header, bodyLines) {
  const names = new Set();
  for (const param of header[2].split(",")) {
    if (param.trim() !== "") names.add(param.trim());
  }
  for (const line of bodyLines) {
    for (const decl of clean(line).matchAll(LOCAL_DECL)) {
      for (const name of decl[1].matchAll(/(?:^|,)\s*([A-Za-z_][A-Za-z0-9_]*)/g)) names.add(name[1]);
    }
  }
  return names;
}

function forwardReferences(path) {
  const lines = fs.readFileSync(path, "utf8").split("\n");
  const declared = new Map();
  const spans = [];

  for (let i = 0; i < lines.length; i++) {
    const header = lines[i].match(HEADER);
    if (!header) continue;
    if (!declared.has(header[1])) declared.set(header[1], i);
    const start = i;
    while (i < lines.length && lines[i] !== "}") i++;
    spans.push({ start, end: i, names: localNames(header, lines.slice(start + 1, i)) });
  }

  const shadowedAt = (line) => {
    const span = spans.find((item) => item.start <= line && line <= item.end);
    return span ? span.names : new Set();
  };

  const result = [];
  lines.forEach((line, i) => {
    if ((i === 0 && line.startsWith("#!")) || HEADER.test(line)) return;
    const shadowed = shadowedAt(i);
    for (const match of clean(line).matchAll(WORD)) {
      const name = match[1];
      if (declared.has(name) && declared.get(name) > i && !shadowed.has(name)) {
        result.push(`${path}:${i + 1}: '${name}' is used before its declaration at line ${declared.get(name) + 1}`);
      }
    }
  });
  return result;
}

const files = process.argv.slice(2);
if (files.length === 0) usage();

const problems = files.flatMap(forwardReferences);
for (const problem of problems) console.log(problem);
process.exit(problems.length > 0 ? 1 : 0);
