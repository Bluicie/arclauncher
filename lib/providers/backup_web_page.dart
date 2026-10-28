import 'dart:convert';

/// The page served at `http://<device>:47474/` when "Download & upload in a browser" is on:
/// download this device's settings file, or upload one (which has to be confirmed on the TV).
String backupWebPage(String deviceName) => _page.replaceAll("{{name}}", const HtmlEscape().convert(deviceName));

const String _page = r'''<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{name}} - Arc Launcher settings</title>
<style>
  :root { color-scheme: light dark; --accent: #2979ff; }
  body { font-family: system-ui, sans-serif; max-width: 34rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; }
  h1 { font-size: 1.4rem; margin-bottom: .25rem; }
  p.sub { margin-top: 0; opacity: .7; }
  section { border: 1px solid #8884; border-radius: .75rem; padding: 1rem 1.25rem; margin: 1rem 0; }
  h2 { font-size: 1.05rem; margin: 0 0 .5rem; }
  a.button, label.button { display: inline-block; background: var(--accent); color: #fff; text-decoration: none;
    padding: .55rem 1rem; border-radius: .5rem; cursor: pointer; }
  input[type=file] { display: none; }
  #status { min-height: 1.5rem; font-weight: 600; }
</style>
</head>
<body>
<h1>{{name}}</h1>
<p class="sub">Arc Launcher settings</p>
<section>
  <h2>Download</h2>
  <p>Save this TV's sections, app order and settings as a file, as a backup or to copy them to another TV.</p>
  <a class="button" href="/arc-launcher/web/backup.json">Download settings file</a>
</section>
<section>
  <h2>Upload</h2>
  <p>Restore a settings file on this TV. Confirm it on the TV when asked; it replaces the current sections, app order and settings.</p>
  <label class="button" for="file">Choose settings file…</label>
  <input id="file" type="file" accept=".json,application/json">
  <p id="status" role="status"></p>
</section>
<script>
  const status = (text) => { document.getElementById('status').textContent = text; };
  document.getElementById('file').addEventListener('change', async (event) => {
    const file = event.target.files[0];
    event.target.value = '';
    if (!file) return;
    status('Confirm the restore on the TV…');
    try {
      const response = await fetch('/arc-launcher/web/restore', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: await file.text(),
      });
      const data = await response.json();
      if (!response.ok) {
        status(data.error || 'Restore failed');
        return;
      }
      let text = `Restored ${data.categories} sections with ${data.placedApps} apps.`;
      if (data.missingApps.length) text += ` ${data.missingApps.length} apps from the file are not installed on this TV.`;
      status(text);
    } catch (error) {
      status('Upload failed: ' + error);
    }
  });
</script>
</body>
</html>
''';
