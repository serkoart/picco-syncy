// Runs inside the Safari page when you choose Share → Send to Picco.
// Hands over the page exactly as you see it (logged-in and paywalled content included),
// so the Mac converts what you were reading rather than fetching the address again.
var Preprocess = function () {};
Preprocess.prototype = {
  run: function (args) {
    args.completionFunction({
      url: document.URL,
      title: document.title,
      html: document.documentElement.outerHTML
    });
  }
};
var ExtensionPreprocessingJS = new Preprocess();
