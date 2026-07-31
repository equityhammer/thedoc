[← Android Manifesto index](./ANDROID_MANIFESTO.md)

## `dist/serve_<app>.py` requirements (write your own; stdlib only)

The dist server should be standard-library only (`http.server`, `glob`, `os`, `datetime`, `re`). No Flask, no FastAPI. This makes it run anywhere Python 3 runs without a venv.

It must implement the endpoints listed under "Server endpoints" above, plus:

- **APK discovery:** a `find_newest_apk()` function that globs `app/build/outputs/apk/debug/<slug>-*.apk` and picks the newest by mtime.
- **`PROD_VERSION` constant:** the version officially "promoted" to prod. Updated whenever a build is promoted.
- **Print on every event:** startup banner (`<app> server on http://0.0.0.0:<port>`), every `/crash` POST as a single block ending in a flush, and any failure mode (port conflict, IO error). The Monitor tool relies on these prints to surface activity in chat.
- **Sprint stubs:** if the app doesn't use the sprint workflow, keep `/sprint` and `/sprint/items` stubbed (returning `0/0` and empty) so the in-app poller doesn't 404 noisily.
- **Wrap every `self.wfile.write` in a `BrokenPipeError` guard.** Phones that move between WiFi / cellular / Tailscale-asleep states routinely drop connections mid-response. The default `http.server` traceback for a broken pipe is ~15 noisy lines that drown the Monitor stream and look like a server fault. Hide them behind a one-line `[BENIGN] client disconnected mid-response (N bytes pending)` log. **Return `bool` from the helper** so streaming callers can detect the disconnect + bail (see "Streaming-write helpers" below: without the bool return, a chunked stream that disconnects mid-flight logs one `[BENIGN]` line PER chunk that can't go anywhere, flooding the Monitor stream with hundreds of identical lines per failed download):

  ```python
  def _safe_write(self, data: bytes) -> bool:
      """Returns True on success, False on disconnect.
      Streaming callers MUST check the return value + break on False.
      """
      try:
          self.wfile.write(data)
          return True
      except (BrokenPipeError, ConnectionResetError):
          sys.stderr.write(f"[BENIGN] client disconnected mid-response ({len(data)} bytes pending)\n")
          return False
  ```

  Use `_safe_write` at every write site (the JSON / text response sender, the APK download stream, any static asset path). Originating changes: Transfer Checklist `v1.0.76` (DIST-01, initial guard); `v1.0.92` Sprint 30 mid-sprint hotfix (added bool return after DIST-05's chunked streaming flooded the Monitor with hundreds of `[BENIGN]` lines per failed sideload). Pattern captured as memory `feedback-socket-write-in-loop-must-return-signal`.

- **Streaming-write helpers must return a bail signal.** Any per-chunk write helper that catches its own disconnect exceptions MUST surface a signal to the caller (return `bool`, or re-raise after logging) so streaming loops bail on first disconnect. Otherwise the helper logs once per chunk-that-can't-actually-go-anywhere: a 64MB download with 64KB chunks produces up to 1024 identical `[BENIGN]` lines on a single mid-stream disconnect. Symptom: Monitor stream floods with disconnect messages all from the same client connection, byte count in the log matches the chunk size exactly:

  ```python
  # WRONG: caller has no way to know writes are failing; logs N times
  with open(apk_path, "rb") as f:
      while True:
          chunk = f.read(64 * 1024)
          if not chunk: break
          self._safe_write(chunk)   # logs [BENIGN] every iteration post-disconnect

  # RIGHT: caller bails on first False
  with open(apk_path, "rb") as f:
      while True:
          chunk = f.read(64 * 1024)
          if not chunk: break
          if not self._safe_write(chunk):
              return   # Client disconnected; stop instead of flooding logs.
  ```

  Codify the rule in the helper's docstring: "Streaming callers MUST check the return value + break on False." Tripwire: assert ≤1 `[BENIGN]` line per forced-disconnect smoke test.

- **HTTP Range support for APK downloads (resumable transfers over flaky connections).** Phones on real Tailscale connections routinely disconnect mid-download: an observed pattern on a foldable test device over a Tailnet was 64MB APK downloads failing at the same byte every retry. Support `Range: bytes=N-M` headers so the phone resumes from byte N instead of restarting from 0. Stdlib-only (`re`-parse the header, `seek()` + chunked write, 206 Partial Content + `Content-Range` header). Also include `Accept-Ranges: bytes` on plain 200 responses so clients know to retry with Range on disconnect:

  ```python
  def _serve_apk(self, apk_path: str, name: str) -> None:
      file_size = os.path.getsize(apk_path)
      range_header = self.headers.get("Range", "")
      if range_header:
          match = re.match(r"^bytes=(\d+)-(\d*)$", range_header.strip())
          if match:
              start = int(match.group(1))
              end = int(match.group(2)) if match.group(2) else file_size - 1
              if start >= file_size or end >= file_size or start > end:
                  self.send_response(416)  # Range Not Satisfiable per RFC 7233
                  self.send_header("Content-Range", f"bytes */{file_size}")
                  self.end_headers()
                  return
              self.send_response(206)
              self.send_header("Content-Type", "application/vnd.android.package-archive")
              self.send_header("Content-Length", str(end - start + 1))
              self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
              self.send_header("Accept-Ranges", "bytes")
              self.end_headers()
              with open(apk_path, "rb") as f:
                  f.seek(start)
                  remaining = end - start + 1
                  while remaining > 0:
                      chunk = f.read(min(64 * 1024, remaining))
                      if not chunk: break
                      if not self._safe_write(chunk): return  # bail per the rule above
                      remaining -= len(chunk)
              return
      # No Range header: 200 OK + chunked streaming (bounded memory on 100MB+ APKs).
      self.send_response(200)
      self.send_header("Content-Type", "application/vnd.android.package-archive")
      self.send_header("Content-Length", str(file_size))
      self.send_header("Accept-Ranges", "bytes")
      self.end_headers()
      with open(apk_path, "rb") as f:
          while True:
              chunk = f.read(64 * 1024)
              if not chunk: break
              if not self._safe_write(chunk): return
  ```

  Smoke-test assertions to add: `GET → 200 + Accept-Ranges: bytes`, `Range bytes=0-99 → 206 + 100-byte body + Content-Range: bytes 0-99/<total>`, `Range bytes=999999999999- → 416 + Content-Range: bytes */<total>`. Use `curl -D <file> -o /dev/null` for header inspection on GET (not `curl -I` which sends HEAD; most do_GET-only handlers ignore HEAD). Originating change: Transfer Checklist `v1.0.92` Sprint 30 (DIST-05).

- **Suppress socket-layer ConnectionResetError tracebacks at the socketserver `handle_error` layer.** DIST-01's `_safe_write` catches disconnects that happen INSIDE the response-write path. But if the client disconnects during the request READ (before your `do_GET` runs) OR during socketserver's own framing, the `ConnectionResetError` propagates up to `BaseServer.handle_error`, which by default prints the full traceback to stderr. Override `handle_error` on your server class to catch the 3 known-benign disconnect exceptions there too:

  ```python
  class ReusableTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
      allow_reuse_address = True
      daemon_threads = True

      def handle_error(self, request, client_address):
          exc_type, exc_value, _ = sys.exc_info()
          if isinstance(exc_value, (BrokenPipeError, ConnectionResetError, ConnectionAbortedError)):
              sys.stderr.write(f"[BENIGN] socket disconnect from {client_address}: {exc_type.__name__}\n")
              return
          # Anything else (real errors): defer to the default handler.
          super().handle_error(request, client_address)
  ```

  Companion to DIST-01's per-write guard: catches the disconnect class DIST-01 misses (mid-request-READ, mid-framing). Smoke test: `curl --max-time 0.05 <endpoint>` forces an immediate client-side abort; verify a subsequent normal request still succeeds (server thread didn't crash). Originating change: Transfer Checklist `v1.0.92` Sprint 30 (DIST-06).
- **Smoke-test the WHOLE server, not just the endpoint you most recently changed.** A sibling `dist/test_<app>_server.sh` should curl every endpoint + jq-assert basic shape + run a cross-endpoint consistency check (e.g., `/sprint` numeric ratio matches the implemented/total derived from `/sprint/status` items). Bash + jq + curl + grep, no new deps. Catches the dist-server-serving-stale-page bug when an APK changes but the HTML root references the old filename; catches the parser drifting from the counter; catches the `/version` regex breaking after a `versionName` typo. Runs in <1s against the live server. Rename when scope grows, e.g. `test_sprint_status.sh` (DIST-03) → `test_dist_server.sh` (DIST-04), and leave the old name as an `exec`-forwarding stub for back-compat with cached local invocations:

  ```bash
  #!/usr/bin/env bash
  exec "$(dirname "$0")/test_dist_server.sh" "$@"
  ```

  Originating change: Transfer Checklist `v1.0.83` (DIST-04). Memory: `feedback-test-dist-server-with-curl-jq` captures the curl+jq-over-pytest discipline.

---

## `dist/sprint.md` template

```markdown
# Current Sprint

## Next Version (0/5 implemented)

1. (open)
2. (open)
3. (open)
4. (open)
5. (open)

## Workflow
1. Debug log with user message → implement immediately
2. Track here under "Next Version"
3. At 5/5 → code review pass, conflict review pass, build, deploy
4. Critical bugs ship immediately
```
