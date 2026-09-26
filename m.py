import os
import sys
import time
import subprocess
import threading
from collections import deque
from flask import Flask, render_template_string, Response, jsonify, request
import psutil

app = Flask(__name__)

# Script you want to control
TARGET_SCRIPT = "node.py"

# State management
process_lock = threading.Lock()
current_process = None
reader_thread = None
is_running = False

# Keep last 500 lines of console output in memory
log_buffer = deque(maxlen=500)
log_listeners = []  # queues for active SSE log streams


def read_process_output(proc):
    """Worker thread that continuously reads child stdout and broadcasts it."""
    global is_running, current_process

    for line in iter(proc.stdout.readline, ''):
        if not line:
            break
        text = line.rstrip()
        log_buffer.append(text)

        # Broadcast line to all active browser SSE streams
        for q in list(log_listeners):
            try:
                q.append(text)
            except Exception:
                pass

    proc.stdout.close()
    proc.wait()

    with process_lock:
        if current_process and current_process.pid == proc.pid:
            is_running = False
            current_process = None
            exit_msg = f"[SYSTEM] Process exited with code {proc.returncode}"
            log_buffer.append(exit_msg)
            for q in list(log_listeners):
                try:
                    q.append(exit_msg)
                except Exception:
                    pass


def kill_proc_tree(pid):
    """Safely terminate the process and any spawned child subprocesses."""
    try:
        parent = psutil.Process(pid)
        for child in parent.children(recursive=True):
            try:
                child.terminate()
            except psutil.NoSuchProcess:
                pass
        parent.terminate()
        parent.wait(timeout=3)
    except (psutil.NoSuchProcess, psutil.TimeoutExpired):
        try:
            parent.kill()
        except Exception:
            pass
    except Exception:
        pass


@app.route("/")
def index():
    return render_template_string(HTML_TEMPLATE)


@app.route("/api/status")
def get_status():
    with process_lock:
        return jsonify({
            "running": is_running,
            "pid": current_process.pid if current_process else None
        })


@app.route("/api/start", methods=["POST"])
def start_process():
    global current_process, is_running, reader_thread

    with process_lock:
        if is_running and current_process and current_process.poll() is None:
            return jsonify({"status": "error", "message": "Already running"}), 400

        try:
            # -u flag is critical to prevent Python from buffering stdout
            cmd = [sys.executable, "-u", TARGET_SCRIPT]
            current_process = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,  # merge stderr into stdout
                text=True,
                bufsize=1
            )
            is_running = True

            log_buffer.append(f"[SYSTEM] Started {TARGET_SCRIPT} (PID: {current_process.pid})")

            reader_thread = threading.Thread(
                target=read_process_output,
                args=(current_process,),
                daemon=True
            )
            reader_thread.start()

            return jsonify({"status": "ok", "pid": current_process.pid})
        except Exception as e:
            return jsonify({"status": "error", "message": str(e)}), 500


@app.route("/api/stop", methods=["POST"])
def stop_process():
    global current_process, is_running

    with process_lock:
        if not is_running or not current_process:
            return jsonify({"status": "error", "message": "Not running"}), 400

        pid = current_process.pid
        kill_proc_tree(pid)
        is_running = False
        current_process = None
        log_buffer.append(f"[SYSTEM] Process {pid} stopped by user.")

        return jsonify({"status": "ok"})


@app.route("/api/logs/stream")
def stream_logs():
    """Server-Sent Events (SSE) endpoint to push real-time terminal output."""
    def event_generator():
        q = deque()
        # Immediately dump recent buffer to newly connected browser
        for line in list(log_buffer)[-80:]:
            yield f"data: {line}\n\n"

        log_listeners.append(q)
        try:
            while True:
                if q:
                    line = q.popleft()
                    yield f"data: {line}\n\n"
                else:
                    time.sleep(0.1)
        except GeneratorExit:
            if q in log_listeners:
                log_listeners.remove(q)

    return Response(event_generator(), mimetype="text/event-stream")


HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Script Controller</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace; }
    body { background: #0f172a; color: #f8fafc; padding: 24px; }
    .container { max-width: 900px; margin: 0 auto; }
    .header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 20px; }
    .badge { padding: 4px 12px; border-radius: 999px; font-size: 0.85rem; font-weight: bold; }
    .badge.stopped { background: #334155; color: #94a3b8; }
    .badge.running { background: #166534; color: #4ade80; }
    .controls { display: flex; gap: 12px; margin-bottom: 20px; }
    button {
      padding: 10px 24px; font-size: 1rem; font-weight: 600; border: none;
      border-radius: 8px; cursor: pointer; transition: opacity 0.2s;
    }
    button:disabled { opacity: 0.4; cursor: not-allowed; }
    .btn-start { background: #22c55e; color: #000; }
    .btn-stop { background: #ef4444; color: #fff; }
    .btn-clear { background: #334155; color: #cbd5e1; margin-left: auto; }
    .terminal {
      background: #020617; border: 1px solid #1e293b; border-radius: 8px;
      padding: 16px; height: 480px; overflow-y: auto; font-size: 0.85rem;
      line-height: 1.4; white-space: pre-wrap; word-break: break-all;
    }
    .line { margin-bottom: 2px; }
    .line.system { color: #38bdf8; }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h2>Script Controller</h2>
      <span id="status-badge" class="badge stopped">STOPPED</span>
    </div>

    <div class="controls">
      <button id="btn-start" class="btn-start" onclick="startWorker()">Start Script</button>
      <button id="btn-stop" class="btn-stop" onclick="stopWorker()" disabled>Stop Script</button>
      <button class="btn-clear" onclick="clearLogs()">Clear Console</button>
    </div>

    <div id="terminal" class="terminal"></div>
  </div>

  <script>
    const term = document.getElementById('terminal');
    const badge = document.getElementById('status-badge');
    const btnStart = document.getElementById('btn-start');
    const btnStop = document.getElementById('btn-stop');

    function appendLine(text) {
      const div = document.createElement('div');
      div.className = 'line' + (text.startsWith('[SYSTEM]') ? ' system' : '');
      div.textContent = text;
      term.appendChild(div);
      term.scrollTop = term.scrollHeight;
    }

    function clearLogs() {
      term.innerHTML = '';
    }

    function updateUi(running) {
      if (running) {
        badge.textContent = 'RUNNING';
        badge.className = 'badge running';
        btnStart.disabled = true;
        btnStop.disabled = false;
      } else {
        badge.textContent = 'STOPPED';
        badge.className = 'badge stopped';
        btnStart.disabled = false;
        btnStop.disabled = true;
      }
    }

    async function checkStatus() {
      try {
        const res = await fetch('/api/status');
        const data = await res.json();
        updateUi(data.running);
      } catch (err) {
        console.error(err);
      }
    }

    async function startWorker() {
      btnStart.disabled = true;
      await fetch('/api/start', { method: 'POST' });
      checkStatus();
    }

    async function stopWorker() {
      btnStop.disabled = true;
      await fetch('/api/stop', { method: 'POST' });
      checkStatus();
    }

    // Connect SSE for streaming logs
    const evtSource = new EventSource('/api/logs/stream');
    evtSource.onmessage = (e) => {
      appendLine(e.data);
      if (e.data.includes('[SYSTEM] Process exited') || e.data.includes('[SYSTEM] Process')) {
        checkStatus();
      }
    };

    // Check status periodically
    setInterval(checkStatus, 3000);
    checkStatus();
  </script>
</body>
</html>
"""

if __name__ == "__main__":
    # threaded=True is required for SSE streaming to work concurrently with other routes
    app.run(host="0.0.0.0", port=5000, threaded=True, debug=False)
