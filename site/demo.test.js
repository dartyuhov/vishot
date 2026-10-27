'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function demo(reducedMotion = false) {
  const text = [];
  const ctx = {
    fillRect(...values) { assert.ok(values.every(Number.isFinite), 'finite pixel geometry'); },
    drawImage() {},
  };
  const canvas = { width: 192, clientWidth: 768, getContext: () => ctx };
  const sandbox = {
    matchMedia: () => ({ matches: reducedMotion }),
    ResizeObserver: class { observe() {} },
    document: {
      documentElement: { classList: { add() {} } },
      getElementById: () => canvas,
      createElement: () => ({ getContext: () => ctx }),
    },
  };
  // Exercise the real timeline and canvas renderer, before browser playback attaches listeners.
  const source = fs.readFileSync(path.join(__dirname, 'main.js'), 'utf8');
  const scene = source.slice(0, source.indexOf('  const render = setupScene();'));
  sandbox.ctxForTest = ctx;
  sandbox.textForTest = text;
  vm.runInNewContext(scene + `
    const render = setupScene();
    const p = painter(ctxForTest);
    p.text = value => textForTest.push(value);
    globalThis.demo = { EVENTS, SEG_START, segEnd, LOOP, stateAt, render,
      drawCLI: t => drawCLI(p, stateAt(t), t) };
  })();`, sandbox);
  return { ...sandbox.demo, text };
}

test('all seven guide features have a playable segment and finite canvas geometry', () => {
  const { EVENTS, SEG_START, segEnd, LOOP, render } = demo();
  assert.equal(SEG_START.length, 7);
  for (let i = 0; i < 7; i++) {
    assert.ok(segEnd(i) > SEG_START[i], `feature ${i + 1} has duration`);
    assert.equal(render(SEG_START[i]).event.seg, i);
    assert.equal(render(segEnd(i) - 1).event.seg, i);
  }
  for (const event of EVENTS) render(event.at);
  assert.equal(segEnd(6), LOOP);
  assert.equal(render(0).event.seg, 0, 'playback can wrap to the first feature');
});

test('CLI demo captures, reads, annotates and opens the same PNG', () => {
  const { EVENTS, stateAt, drawCLI, text } = demo();
  const steps = EVENTS.filter(event => event.seg === 6);
  assert.equal(steps.length, 5);
  steps.forEach((event, i) => assert.equal(stateAt(event.at).cliStep, i));
  drawCLI(steps[0].at);
  assert.ok(text.includes('> VISHOT WINDOWS'));
  assert.ok(!text.includes('CAPTURE.PNG'), 'discovery precedes capture');
  text.length = 0;
  drawCLI(steps[2].at);
  assert.ok(text.includes('> VISHOT CAPTURE --WINDOW-ID 42'));
  assert.ok(text.includes('READ PNG'));
  assert.ok(text.includes('CAPTURE.PNG'));
  text.length = 0;
  drawCLI(steps[4].at);
  assert.ok(text.includes('> VISHOT ANNOTATE --OPEN'));
  assert.ok(text.includes('EXPLAINED.PNG'));
  assert.ok(text.includes('SPIKE'));
});

test('paused and reduced-motion CLI selection shows the completed explanation', () => {
  const { segEnd, render, drawCLI, text } = demo(true);
  const finalFrame = segEnd(6) - 1;
  assert.equal(render(finalFrame).cliStep, 4);
  drawCLI(finalFrame);
  assert.ok(text.includes('EXPLAINED.PNG'));
  assert.ok(text.includes('SPIKE'));
});
