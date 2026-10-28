// Pure placement math for the inline icon and the account picker. Everything here works in
// VIEWPORT coordinates (the numbers getBoundingClientRect returns), because the overlays are
// `position:fixed`. The old document-coordinate math (rect + scrollX/Y on a `position:absolute`
// host under <body>) was only right while <body> was the initial containing block: a body with
// a margin plus `position:relative`, or a `transform`/`filter`, put the icon 8-40 px off.
//
// One var bag. A top-level const or function here would share the classic-script scope with
// the other extension scripts and can throw at load.

var mypassPlacement = (function () {
  var ICON_MAX_SIZE = 28;
  var ICON_INSET = 6;
  var ICON_MIN_SIZE = 20;
  // The icon is hidden unless this much of the field stays free for typing.
  var ICON_MIN_FREE_TEXT = 36;
  var FLOATING_GAP = 4;
  var FLOATING_MARGIN = 4;
  var FLOATING_MIN_HEIGHT = 80;

  // rect: the field's viewport rect. obstacles: viewport rects of site controls (reveal /
  // clear buttons) that overlay the same end of the field. clipRect: the intersection of the
  // field's clipping ancestors (viewport coords) or null. `fits` mirrors the old gates exactly:
  // size >= 20, at least 36 px of the field left of the icon, and the whole icon inside the clip.
  //
  // box: the visible field box around a slim input (optional). A Material-style field is a 48 px
  // box around a 22 px <input>; sized from the input alone the icon came out at 18 px and was
  // always hidden (pz.gov.pl login). The box is used only when the input is too short on its
  // own, so every field that already worked is placed exactly as before.
  function needsBox(rect) {
    return rect.height - 4 < ICON_MIN_SIZE;
  }

  function placeIcon(rect, obstacles, clipRect, box) {
    var anchor = rect;
    if (box && needsBox(rect) && box.height - 4 >= ICON_MIN_SIZE) anchor = box;
    var size = Math.min(ICON_MAX_SIZE, anchor.height - 4);
    var top = anchor.top + (anchor.height - size) / 2;
    var left = anchor.left + anchor.width - size - ICON_INSET;
    var list = Array.isArray(obstacles) ? obstacles : [];
    // Right-to-left, so adjacent controls are cleared one after another.
    list.slice().sort(function (a, b) { return b.left - a.left; }).forEach(function (obstacle) {
      if (obstacle.width <= 0 || obstacle.height <= 0) return;
      if (obstacle.top >= top + size || obstacle.top + obstacle.height <= top) return;
      if (obstacle.left < left + size + 4 && obstacle.left + obstacle.width > left - 4) {
        left = obstacle.left - size - 4;
      }
    });
    var insideClip = !clipRect || (left >= clipRect.left && top >= clipRect.top &&
      left + size <= clipRect.right && top + size <= clipRect.bottom);
    var fits = size >= ICON_MIN_SIZE && left - rect.left >= ICON_MIN_FREE_TEXT && insideClip;
    return { fits: fits, size: size, top: top, left: left };
  }

  // Places a box of `size` {width,height} next to `anchor` (the field rect): below it when it
  // fits, above it when there is more room above, clamped horizontally into the viewport, with a
  // max height so a long list scrolls inside the box instead of leaving the screen.
  function placeFloating(anchor, size, viewport) {
    var vw = viewport.innerWidth;
    var vh = viewport.innerHeight;
    var width = Math.min(size.width, Math.max(0, vw - 2 * FLOATING_MARGIN));
    var roomBelow = vh - anchor.bottom - FLOATING_GAP - FLOATING_MARGIN;
    var roomAbove = anchor.top - FLOATING_GAP - FLOATING_MARGIN;
    var below = size.height <= roomBelow || roomBelow >= roomAbove;
    var room = Math.max(FLOATING_MIN_HEIGHT, below ? roomBelow : roomAbove);
    var height = Math.min(size.height, room);
    var top = below
      ? anchor.bottom + FLOATING_GAP
      : anchor.top - FLOATING_GAP - height;
    var left = Math.min(anchor.left, vw - width - FLOATING_MARGIN);
    left = Math.max(FLOATING_MARGIN, left);
    top = Math.max(FLOATING_MARGIN, Math.min(top, vh - height - FLOATING_MARGIN));
    return { top: top, left: left, width: width, maxHeight: room, flipped: !below };
  }

  // A host can land somewhere other than where it was told (an `html` transform, CSS zoom, a
  // dialog with its own transform). Comparing the host's measured rect with the intended one and
  // shifting by the difference once is cheaper and more general than listing the CSS properties
  // that create a containing block. Returns null when within tolerance.
  function correction(intended, measured, tolerance) {
    var limit = typeof tolerance === 'number' ? tolerance : 1;
    var dx = intended.left - measured.left;
    var dy = intended.top - measured.top;
    if (Math.abs(dx) <= limit && Math.abs(dy) <= limit) return null;
    return { dx: dx, dy: dy };
  }

  return {
    needsBox: needsBox,
    placeIcon: placeIcon,
    placeFloating: placeFloating,
    correction: correction
  };
})();

if (typeof module !== 'undefined') {
  module.exports = mypassPlacement;
}
