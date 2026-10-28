// SPDX-License-Identifier: MIT
// MB-scale JSON parse + template benchmark used by the W3-PROBES JIT probe.
// The same source runs in a bare JavaScriptCore JSContext and in a WKWebView;
// the test reports the ratio it measured (the PLAN calls the JSContext the
// non-WKWebView baseline). `Date.now()` is used because a bare JSContext does
// not expose `performance`.
(function () {
  var itemCount = 10000;
  var items = new Array(itemCount);
  for (var index = 0; index < itemCount; index += 1) {
    items[index] = {
      id: index,
      name: 'item-' + index,
      value: index * 3.14159,
      tags: ['alpha', 'beta', 'gamma'],
      nested: { x: index, y: index + 1, label: 'n-' + index },
    };
  }
  var text = JSON.stringify(items);
  var parseRounds = 8;
  var templateRounds = 8;
  var parseStart = Date.now();
  var parsed = null;
  for (var round = 0; round < parseRounds; round += 1) {
    parsed = JSON.parse(text);
  }
  var parseEnd = Date.now();
  var template = '';
  for (var pass = 0; pass < templateRounds; pass += 1) {
    template = parsed.map(function (item) {
      return '<li data-id="' + item.id + '">' + item.name + ': ' +
        item.value.toFixed(2) + '</li>';
    }).join('');
  }
  var templateEnd = Date.now();
  return JSON.stringify({
    bytes: text.length,
    items: itemCount,
    parse_rounds: parseRounds,
    template_rounds: templateRounds,
    json_ms: parseEnd - parseStart,
    template_ms: templateEnd - parseEnd,
    total_ms: templateEnd - parseStart,
    template_bytes: template.length,
  });
})()
