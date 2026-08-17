## Embedded HTMX library for the Doot HTTP runtime.
## HTMX is embedded as a const string in the binary and served from
## /__doot/htmx.min.js with long cache headers.

import std/tables
import ./response
import ./gzip

const HtmxContent* = """// HTMX v1.9.12 - htmx.org - embedded in Doot binary
// Minimal HTMX stub for development and testing
(function(){
  var htmx = {
    version: "1.9.12",
    config: {
      historyEnabled: true,
      historyCacheSize: 10,
      defaultSwapStyle: "innerHTML",
      defaultSwapDelay: 0,
      defaultSettleDelay: 20,
      includeIndicatorStyles: true,
      indicatorClass: "htmx-indicator",
      requestClass: "htmx-request",
      addedClass: "htmx-added",
      settlingClass: "htmx-settling",
      swappingClass: "htmx-swapping"
    },
    _: {},
    process: function(elt) {
      var attrs = ['hx-get','hx-post','hx-put','hx-delete','hx-patch',
                   'hx-trigger','hx-target','hx-swap','hx-push-url',
                   'hx-select','hx-include','hx-vals','hx-confirm'];
      attrs.forEach(function(attr) {
        var elts = elt.querySelectorAll('[' + attr + ']');
        elts.forEach(function(e) { htmx._.initElement(e); });
      });
    }
  };

  htmx._.initElement = function(elt) {
    if (elt.htmxInit) return;
    elt.htmxInit = true;
    var trigger = elt.getAttribute('hx-trigger') || htmx._.defaultTrigger(elt);
    elt.addEventListener(trigger.split(' ')[0], function(evt) {
      var method = null, url = null;
      if (elt.getAttribute('hx-get')) { method = 'GET'; url = elt.getAttribute('hx-get'); }
      else if (elt.getAttribute('hx-post')) { method = 'POST'; url = elt.getAttribute('hx-post'); }
      else if (elt.getAttribute('hx-put')) { method = 'PUT'; url = elt.getAttribute('hx-put'); }
      else if (elt.getAttribute('hx-delete')) { method = 'DELETE'; url = elt.getAttribute('hx-delete'); }
      else if (elt.getAttribute('hx-patch')) { method = 'PATCH'; url = elt.getAttribute('hx-patch'); }
      if (!method) return;
      if (elt.getAttribute('hx-confirm') && !confirm(elt.getAttribute('hx-confirm'))) return;
      evt.preventDefault();
      var target = elt.getAttribute('hx-target') ?
        document.querySelector(elt.getAttribute('hx-target')) : elt;
      var swap = elt.getAttribute('hx-swap') || 'innerHTML';
      var xhr = new XMLHttpRequest();
      xhr.open(method, url);
      xhr.setRequestHeader('HX-Request', 'true');
      xhr.setRequestHeader('HX-Trigger', elt.id || '');
      xhr.setRequestHeader('HX-Target', target ? target.id || '' : '');
      elt.classList.add(htmx.config.requestClass);
      xhr.onload = function() {
        elt.classList.remove(htmx.config.requestClass);
        if (target) {
          if (swap === 'innerHTML') target.innerHTML = xhr.responseText;
          else if (swap === 'outerHTML') target.outerHTML = xhr.responseText;
          else if (swap === 'beforebegin') target.insertAdjacentHTML('beforebegin', xhr.responseText);
          else if (swap === 'afterbegin') target.insertAdjacentHTML('afterbegin', xhr.responseText);
          else if (swap === 'beforeend') target.insertAdjacentHTML('beforeend', xhr.responseText);
          else if (swap === 'afterend') target.insertAdjacentHTML('afterend', xhr.responseText);
          else if (swap === 'delete') target.remove();
          else if (swap === 'none') {}
          else target.innerHTML = xhr.responseText;
          htmx.process(target);
        }
        if (elt.getAttribute('hx-push-url') === 'true') {
          history.pushState({}, '', url);
        }
      };
      xhr.onerror = function() { elt.classList.remove(htmx.config.requestClass); };
      if (method === 'POST' || method === 'PUT' || method === 'PATCH') {
        var form = elt.closest('form');
        if (form) {
          xhr.send(new FormData(form));
        } else {
          xhr.send();
        }
      } else {
        xhr.send();
      }
    });
  };

  htmx._.defaultTrigger = function(elt) {
    if (elt.tagName === 'FORM') return 'submit';
    if (elt.tagName === 'INPUT' || elt.tagName === 'SELECT' || elt.tagName === 'TEXTAREA') return 'change';
    return 'click';
  };

  // Initialize on DOMContentLoaded
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function() { htmx.process(document.body); });
  } else {
    htmx.process(document.body);
  }

  // Expose globally
  window.htmx = htmx;
})();
"""

# Serve HTMX - compress on demand since the content is a const
proc serveHtmx*(acceptsGzip: bool = false): DootResponse =
  ## Serve the embedded HTMX library with proper headers.
  var headers = initTable[string, string]()
  headers["Content-Type"] = "application/javascript; charset=utf-8"
  headers["Cache-Control"] = "public, max-age=31536000, immutable"

  if acceptsGzip:
    let compressed = gzipCompress(HtmxContent)
    if compressed.len > 0:
      headers["Content-Encoding"] = "gzip"
      return DootResponse(status: 200, headers: headers, body: compressed)

  return DootResponse(status: 200, headers: headers, body: HtmxContent)
