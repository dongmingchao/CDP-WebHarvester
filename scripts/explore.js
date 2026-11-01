// explore.js — page-structure dumper for web-trending-cdp's -Explore mode.
// Reads as a single Runtime.evaluate expression (returns a JSON string).
// Zero regex literals: Lightpanda's V8 rejects some regex flags and throws
// "Invalid regular expression flags". Use charCodeAt + fromCharCode only.
// Keep the returned JSON small (<~4KB): large returnByValue results hang
// Lightpanda at ~4KB+. link/text counts and slice lengths are capped below.

(function () {
  function esc(s) {
    // Escape for safe embedding in a JSON string literal (manual, no regex).
    var str = String(s || '');
    var r = '';
    for (var i = 0; i < str.length; i++) {
      var ch = str.charCodeAt(i);
      if (ch === 34) r += '\\"';       // "
      else if (ch === 92) r += '\\\\'; // \
      else if (ch === 13) { /* drop CR */ }
      else if (ch === 10) r += ' ';
      else if (ch === 9) r += ' ';
      else r += String.fromCharCode(ch);
    }
    return r.slice(0, 120);
  }
  function norm(s) {
    // Collapse whitespace to single spaces (numeric codes), truncate.
    if (!s) return '';
    var r = '';
    for (var k = 0; k < s.length; k++) {
      var c = s.charCodeAt(k);
      if (c === 32 || c === 9 || c === 10 || c === 13) {
        if (r.length > 0 && r.charCodeAt(r.length - 1) !== 32) r += ' ';
      } else r += String.fromCharCode(c);
    }
    return r.trim().slice(0, 70);
  }
  // Strip scheme + host from an href so we get a site-relative path we can
  // reconstruct into a full target URL (indexOf/split, no regex).
  function relPath(raw) {
    var idx = raw.indexOf('://');
    if (idx < 0) return raw;                     // already relative
    var hostEnd = raw.indexOf('/', idx + 3);
    return hostEnd < 0 ? '' : raw.slice(hostEnd);
  }

  var out = { url: location.href, links: [], tags: {}, selectors: [], controls: [] };

  // ---- site-relative links (reconstruct target URLs from these) ----
  var anchors = document.querySelectorAll('a[href]');
  for (var i = 0; i < anchors.length; i++) {
    var a = anchors[i];
    var h = relPath(a.getAttribute('href') || '');
    if (h.indexOf('//') >= 0 || h.indexOf('http') >= 0 || h.indexOf('#') === 0) continue; // drop external/anchor
    out.links.push({ href: esc(h), text: norm(a.textContent) });
  }

  // ---- tag histogram (see the page skeleton) ----
  // Keep small: only report the 15 most frequent tags.
  var all = document.getElementsByTagName('*');
  var tally = {};
  for (var j = 0; j < all.length; j++) {
    var t = all[j].tagName;
    if (t) tally[t] = (tally[t] || 0) + 1;
  }
  var top = Object.keys(tally).sort(function (x, y) { return tally[y] - tally[x]; });
  for (var j2 = 0; j2 < top.length && j2 < 15; j2++) { out.tags[top[j2]] = tally[top[j2]]; }

  // ---- candidate selectors (count hits for each) ----
  // NOTE: NO attribute-wildcard selectors like [class*="card"] — Lightpanda
  // HANGS on those. Use pure tag selectors or ^-anchored attribute matches.
  var cands = ['a[href^="/"]', 'article', 'li', 'ul li', 'section', 'main', 'div'];
  for (var k = 0; k < cands.length; k++) {
    var sel = cands[k];
    var cnt = 0;
    try { cnt = document.querySelectorAll(sel).length; } catch (e) { cnt = -1; }
    out.selectors.push({ selector: sel, count: cnt });
  }

  // ---- form controls (to build query params) ----
  // Capped so the returned JSON stays small.
  var ctrls = document.querySelectorAll('select, input[type=checkbox], input[type=radio]');
  for (var p = 0; p < ctrls.length && p < 10; p++) {
    var c = ctrls[p];
    if (c.tagName === 'SELECT') {
      var opts = [];
      for (var o = 0; o < c.options.length && o < 8; o++) opts.push(c.options[o].value + ':' + esc(c.options[o].text));
      out.controls.push({ tag: 'select', id: c.id, name: c.name, options: opts });
    } else {
      out.controls.push({ tag: c.tagName.toLowerCase(), id: c.id, name: c.name, type: c.type, checked: !!c.checked });
    }
  }

  return JSON.stringify(out);
})();
