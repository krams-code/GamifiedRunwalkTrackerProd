{{flutter_js}}
{{flutter_build_config}}

// Ship the rendering engine on the same Hosting origin as the app, including
// the full CanvasKit variant selected automatically for Safari.
const flutterConfig = { canvasKitBaseUrl: new URL('canvaskit/', document.baseURI).href };
_flutter.loader.load({
  config: flutterConfig,
  onEntrypointLoaded: async function (initializer) {
    try {
      const app = await initializer.initializeEngine(flutterConfig);
      await app.runApp();
    } catch (error) {
      console.error('HakbangHero startup could not complete.', error);
      window.hakbangStartupError();
    }
  },
}).catch(window.hakbangStartupError);
