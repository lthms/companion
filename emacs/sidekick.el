;;; sidekick.el --- Claude Code sidekick for Emacs -*- lexical-binding: t; -*-

;; Maintainer: Sylvain Ribstein <sylvain.ribstein@gmail.com>

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;; Emacs counterpart of nvim/init.lua. `sidekick-setup' registers this Emacs
;; session with the sidekick server, spawns a `claude' terminal wired to the
;; session's MCP endpoint, and `sidekick-notify' pings Claude about the
;; current buffer. The server drives this session back through emacsclient,
;; calling `sidekick--rpc' with a base64-encoded JSON request.

;;; Code:

(require 'json)
(require 'let-alist)
(require 'pulse)
(require 'seq)
(require 'server)
(require 'subr-x)
(require 'term)
(require 'xref)

;; `sidekick-render' (the native stream-json renderer) lives beside this file;
;; put its directory on `load-path' so a bare `require' finds it however
;; sidekick.el itself was loaded.
(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'sidekick-render)

;; Diagnostics come from whichever checker the user runs; declare the accessors
;; so byte-compilation stays quiet without loading flymake or the third-party
;; flycheck. They are only ever called behind a `bound-and-true-p' mode guard.
(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-text "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flycheck-current-errors "flycheck")
(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-column "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-message "flycheck")

(defgroup sidekick nil
  "Claude Code sidekick for Emacs."
  :group 'tools
  :prefix "sidekick-")

(defvar sidekick-server-url "http://127.0.0.1:8000"
  "Base URL of the sidekick server.")

(defcustom sidekick-use-terminal nil
  "Where to render the spawned claude session.
When nil (the default), the session runs headless -- `claude -p' with
stream-json I/O -- and its output is rendered natively into a
`sidekick-conversation-mode' buffer (thinking folded, answer inline). When
non-nil, the legacy path is used: the interactive claude TUI runs in a
read-only `term' buffer. The two behave the same for `sidekick-notify' and
the editor RPCs; they differ only in how claude is presented and prompted."
  :type 'boolean
  :group 'sidekick)

(defcustom sidekick-permission-mode "bypassPermissions"
  "Permission mode passed to headless claude (native sessions only).
The monitor needs to run its background `curl .../listen/PID' loop
non-interactively, which headless claude cannot get approved on the fly,
so the default lets it run unattended. Narrower modes (edit-only, or the
classifier-based one) leave that loop unapproved and the monitor never
starts. Ignored when `sidekick-use-terminal' is non-nil; the TUI approves
interactively instead."
  :type '(choice (const "bypassPermissions") (const "acceptEdits")
                 (const "auto") (const "plan") (const "dontAsk")
                 (const "manual"))
  :group 'sidekick)

(defcustom sidekick-extra-args nil
  "Extra command-line arguments appended to headless claude.
For example (\"--allowedTools\" \"Bash(git status),Read\"). Ignored when
`sidekick-use-terminal' is non-nil."
  :type '(repeat string)
  :group 'sidekick)

(defvar sidekick-root nil
  "Project root of the most recently started session.
Kept only as a fallback: each session now reports its own root to the
server at registration time (see `sidekick--sessions'), so relative
paths in MCP tool calls resolve per project rather than against this
single global.")

(defvar sidekick--sessions (make-hash-table :test 'equal)
  "Map from a project root (string) to that project's session plist.
Each value is a plist with `:id' (the integer key identifying the
session to the sidekick server), `:id-proc' (the process whose OS pid IS
that key — see `sidekick--spawn-id-holder'), `:root', and `:buffer' (the
claude terminal buffer). One Emacs — in particular a daemon shared by
several emacsclients — hosts one project-scoped claude session per
project.")

(defvar sidekick--rpc-id 0)

(defun sidekick--rpc-request (method params)
  "POST a JSON-RPC METHOD call with PARAMS to the sidekick server."
  (setq sidekick--rpc-id (1+ sidekick--rpc-id))
  (let ((body (json-serialize
               `((jsonrpc . "2.0")
                 (id . ,sidekick--rpc-id)
                 (method . ,method)
                 (params . ,params)))))
    (make-process
     :name (concat "sidekick-" method)
     :buffer nil
     :command (list "curl" "-sS" "-X" "POST"
                    "-H" "Content-Type: application/json"
                    "-d" body
                    sidekick-server-url)
     :sentinel (lambda (_proc event)
                 (unless (string-prefix-p "finished" event)
                   (message "sidekick: %s failed: %s" method (string-trim event)))))))

(defun sidekick--project-root (&optional dir)
  "Absolute root of the project containing DIR (default `default-directory').
Uses project.el when available, then the enclosing Git checkout, then
DIR itself. The returned string is what scopes a session — buffers and
relative paths in that session resolve against it."
  (let ((dir (or dir default-directory)))
    (expand-file-name
     (or (when (and (fboundp 'project-current) (fboundp 'project-root))
           (when-let ((proj (project-current nil dir)))
             (project-root proj)))
         (locate-dominating-file dir ".git")
         dir))))

(defun sidekick--project-name (root)
  "The last path component of ROOT, used to name its `*claude:NAME*' buffer."
  (file-name-nondirectory (directory-file-name root)))

(defun sidekick--spawn-id-holder ()
  "Spawn a tiny long-lived process whose OS pid anchors a session's id.
A live process's pid is unique among every live process by construction,
so using it as the server key rules out collisions with other sessions —
or with a real editor pid — for as long as the process, and thus the
session, lives.  The process merely sleeps (it holds no resources) and
lives for the whole session; `:noquery' keeps it from ever blocking Emacs
exit.  Stable across `sidekick-reset', which reuses the holder."
  (make-process :name "sidekick-id" :command '("sleep" "infinity")
                :noquery t))

(defun sidekick--ensure-server ()
  "Make sure an Emacs server is listening for the sidekick server to call.
An already-running server (e.g. a daemon's) is reused as-is; only when
none exists is a per-pid one started, so `server-name' is never touched
for daemon users."
  (require 'server)
  (unless (and server-process (process-live-p server-process))
    (setq server-name (format "sidekick-%d" (emacs-pid)))
    (server-start)))

(defun sidekick--start (root session &optional resume-id)
  "Register a session for project ROOT and spawn its claude.
Reuses SESSION's identity — its `:id' and its id-holder process — when
restarting, or mints a fresh one (via `sidekick--spawn-id-holder') when
SESSION is nil.  Records the session in `sidekick--sessions' and returns
its buffer.  RESUME-ID, when non-nil, resumes that past claude session."
  (sidekick--ensure-server)
  (setq sidekick-root root)
  (let* ((holder (let ((p (plist-get session :id-proc)))
                   (if (process-live-p p) p (sidekick--spawn-id-holder))))
         (id (process-id holder)))
    (sidekick--rpc-request
     "register"
     `((pid . ,id)
       (socket . ,(expand-file-name server-name server-socket-dir))
       (app . "emacs")
       (root . ,root)))
    (let ((buffer (sidekick--spawn-claude root id resume-id)))
      (puthash root
               (list :id id :id-proc holder :root root :buffer buffer
                     :terminal sidekick-use-terminal)
               sidekick--sessions)
      (sidekick-mode-line-mode 1)
      (sidekick-report-mode 1)
      buffer)))

;;;###autoload
(defun sidekick-setup ()
  "Start a project-scoped claude session for the current project.

Registers with the sidekick server and spawns claude in a background
`*claude:NAME*' buffer, NAME being the current project's directory name.
Run it once per project: a single Emacs — notably a daemon shared by
several emacsclients — hosts one session per project. Re-running it for a
project that already has a live session is a no-op; use `sidekick-reset'
to restart that session."
  (interactive)
  (let* ((root (sidekick--project-root))
         (session (gethash root sidekick--sessions)))
    (if (and session (buffer-live-p (plist-get session :buffer)))
        (message "sidekick: session already running for %s (M-x sidekick-reset to restart)"
                 (sidekick--project-name root))
      (sidekick--start root session)
      (message "sidekick: started claude for %s" (sidekick--project-name root)))))

;;;###autoload
(defun sidekick-reset ()
  "Restart the claude session for the current project.
Kills the project's `*claude:NAME*' buffer and its claude process, then
spawns a fresh claude under the same server key, so the conversation
starts over while the buffer name and MCP endpoint stay stable. With no
session for the current project yet, behaves like `sidekick-setup'."
  (interactive)
  (let* ((root (sidekick--project-root))
         (session (gethash root sidekick--sessions)))
    (when session
      (sidekick--kill-session session))
    (sidekick--start root session)
    (message "sidekick: restarted claude for %s" (sidekick--project-name root))))

;;;###autoload
(defalias 'sidekick-clear 'sidekick-reset
  "Alias for `sidekick-reset': restart the current project's claude session.")

;;; Resuming past sessions -----------------------------------------------------

(defun sidekick--claude-projects-dir (root)
  "Directory where claude stores ROOT's session transcripts.
Claude derives it from the project path by replacing each `/' and `.'
with `-' under `~/.claude/projects'."
  (expand-file-name
   (replace-regexp-in-string
    "[/.]" "-" (directory-file-name (expand-file-name root)))
   (expand-file-name "projects" "~/.claude")))

(defun sidekick--session-summary (file)
  "A short one-line label for the claude transcript FILE.
Prefers a `summary' event, else the first user message, truncated."
  (with-temp-buffer
    (insert-file-contents file nil 0 65536)
    (goto-char (point-min))
    (let (summary first-user)
      (while (and (not summary) (not (eobp)))
        (let ((obj (ignore-errors
                     (json-parse-string
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))
                      :object-type 'alist :array-type 'list :null-object nil))))
          (when obj
            (let-alist obj
              (cond
               ((and (equal .type "summary") (stringp .summary))
                (setq summary .summary))
               ((and (not first-user) (equal .type "user"))
                (setq first-user
                      (let ((c .message.content))
                        (cond
                         ((stringp c) c)
                         ((listp c)
                          (let ((tb (seq-find
                                     (lambda (b) (equal (alist-get 'type b) "text"))
                                     c)))
                            (and tb (alist-get 'text tb))))))))))))
        (forward-line 1))
      (let ((label (string-trim (or summary first-user "(no summary)"))))
        (truncate-string-to-width (replace-regexp-in-string "\n" " " label) 70)))))

(defconst sidekick--entrypoint-terminal "cli"
  "Transcript `entrypoint' of a session the user typed into directly.
That is what `sidekick--spawn-claude-terminal' produces.")

(defconst sidekick--entrypoint-dispatcher "sdk-cli"
  "Transcript `entrypoint' of a headless dispatcher session.
That is what `sidekick--spawn-claude-native' produces: the claude
`sidekick--start' spawns on its own, whose whole job is to run the
monitor bootstrap and delegate to workers.")

(defun sidekick--session-entrypoint (file)
  "The `entrypoint' recorded in the claude transcript FILE, or nil.
Claude writes it on the session's first user record.  See
`sidekick--entrypoint-terminal' and `sidekick--entrypoint-dispatcher'
for the two values sidekick produces."
  (with-temp-buffer
    (insert-file-contents file nil 0 65536)
    (goto-char (point-min))
    (let (entrypoint)
      (while (and (not entrypoint) (not (eobp)))
        (let ((obj (ignore-errors
                     (json-parse-string
                      (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))
                      :object-type 'alist :array-type 'list :null-object nil))))
          (let-alist obj
            (when (stringp .entrypoint)
              (setq entrypoint .entrypoint))))
        (forward-line 1))
      entrypoint)))

(defun sidekick--session-label (file)
  "Label FILE's session as \"TIME  [KIND] SUMMARY\" for the resume prompt.
Dispatcher sessions get tagged: sidekick spawns one on every
`sidekick--start', and they all carry the same bootstrap prompt as their
summary, so the tag is the only thing telling them apart from a
conversation worth resuming."
  (format "%s  %s%s"
          (format-time-string
           "%Y-%m-%d %H:%M"
           (file-attribute-modification-time (file-attributes file)))
          (if (equal (sidekick--session-entrypoint file)
                     sidekick--entrypoint-dispatcher)
              "[dispatcher] "
            "")
          (sidekick--session-summary file)))

(defun sidekick--project-sessions (root)
  "List of (LABEL . SESSION-ID) for ROOT's past claude sessions, newest first."
  (let ((dir (sidekick--claude-projects-dir root)))
    (when (file-directory-p dir)
      (let ((files (sort (directory-files dir t "\\.jsonl\\'")
                         (lambda (a b)
                           (time-less-p (file-attribute-modification-time
                                         (file-attributes b))
                                        (file-attribute-modification-time
                                         (file-attributes a)))))))
        (mapcar (lambda (f)
                  (cons (sidekick--session-label f) (file-name-base f)))
                files)))))

;;;###autoload
(defun sidekick-resume ()
  "Resume a previous claude session for the current project.
Lists this project's past claude sessions (newest first, labelled with
their time and summary) for selection, then spawns claude with
`--resume', replacing any live session under the same key.  Mirrors
claude code's /resume."
  (interactive)
  (let* ((root (sidekick--project-root))
         (sessions (sidekick--project-sessions root)))
    (if (not sessions)
        (message "sidekick: no previous claude sessions for %s"
                 (sidekick--project-name root))
      (let* ((choice (completing-read "Resume claude session: "
                                      (mapcar #'car sessions) nil t))
             (session-id (cdr (assoc choice sessions)))
             (existing (gethash root sidekick--sessions)))
        (when existing (sidekick--kill-session existing))
        (sidekick--start root existing session-id)
        (message "sidekick: resumed claude session %s for %s"
                 session-id (sidekick--project-name root))))))

(defun sidekick--session-by-root (root)
  "The session plist registered for project ROOT, or nil.
Used by `sidekick-render' to push a native session's status back onto its
plist without depending on the internals of `sidekick--sessions'."
  (gethash root sidekick--sessions))

(defun sidekick--kill-session (session)
  "Kill SESSION's claude buffer and terminal process without prompting."
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (when-let ((proc (get-buffer-process buffer)))
        (set-process-query-on-exit-flag proc nil))
      (kill-buffer buffer))))

(defun sidekick--claude-prompt (id)
  "The startup prompt for claude: the /emacs:monitor command for session ID.
Claude expands the two arguments into the command's `$1' (the sidekick
server URL) and `$2' (the session id).  This mirrors what the nvim plugin
sends (see `lua/sidekick/init.lua'), and makes the prompt live in exactly
one place: the emacs@sidekick plugin, which is therefore required."
  (format "/emacs:monitor %s %d" sidekick-server-url id))

(defun sidekick--mcp-config (id)
  "Write a temp MCP config file wiring session ID to the sidekick server.
Returns the file path, suitable for claude's `--mcp-config'."
  (make-temp-file
   "sidekick-mcp" nil ".json"
   (json-serialize
    `((mcpServers
       . ((sidekick
           . ((type . "http")
              (url . ,(format "%s/mcp/%d" sidekick-server-url id))))))))))

(defun sidekick--spawn-claude (root id &optional resume-id)
  "Start `claude' for project ROOT keyed by ID, without stealing focus.
Dispatches on `sidekick-use-terminal': a native `sidekick-conversation-mode'
render (default) or the legacy read-only `term' buffer. Both return the
session's `*claude:NAME*' buffer; ID keys its MCP endpoint and /listen
stream on the sidekick server.  With RESUME-ID, resumes that past claude
session instead of starting a fresh conversation."
  (if sidekick-use-terminal
      (sidekick--spawn-claude-terminal root id resume-id)
    (sidekick--spawn-claude-native root id resume-id)))

;;; Native session (headless stream-json) -------------------------------------

(defun sidekick--send-user-message (proc text)
  "Send TEXT to PROC as one stream-json user turn (an NDJSON line on stdin)."
  (process-send-string
   proc
   (concat (json-serialize `((type . "user")
                             (message . ((role . "user") (content . ,text)))))
           "\n")))

(defun sidekick--process-filter (proc chunk)
  "Parse newline-delimited JSON events from CHUNK and render them.
Partial trailing lines are buffered on PROC until their newline arrives."
  (let ((buffer (process-buffer proc)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((pending (concat (process-get proc 'sidekick-pending) chunk))
               (lines (split-string pending "\n")))
          ;; The final element is whatever came after the last newline: an
          ;; incomplete line to prepend to the next chunk.
          (process-put proc 'sidekick-pending (car (last lines)))
          (dolist (line (butlast lines))
            (setq line (string-trim line))
            (unless (string-empty-p line)
              (sidekick--handle-event-line line))))))))

(defun sidekick--handle-event-line (line)
  "Parse one JSON event LINE and hand it to the renderer."
  (let ((event (condition-case err
                   (json-parse-string line :object-type 'alist
                                      :array-type 'list :null-object nil)
                 (error (message "sidekick: unparseable event: %s"
                                 (error-message-string err))
                        nil))))
    (when event (sidekick-render-event event))))

(defun sidekick--process-sentinel (proc event)
  "Note in PROC's buffer when the claude process ends, and mark it idle."
  (unless (process-live-p proc)
    (let ((buffer (process-buffer proc)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (sidekick--set-status nil nil)
          (let ((inhibit-read-only t))
            (goto-char (point-max))
            (unless (bolp) (insert "\n"))
            (insert (propertize (format "— claude exited (%s)\n"
                                        (string-trim event))
                                'face 'sidekick-footer-face))))))))

(defun sidekick--spawn-claude-native (root id &optional resume-id)
  "Run headless claude for ROOT keyed by ID and render it natively.
Spawns `claude -p' with stream-json I/O over a pipe, routes its NDJSON
stdout through `sidekick--process-filter' into a `sidekick-conversation-mode'
buffer, and sends the startup prompt as the first user turn on stdin. The
buffer is created but not displayed."
  (let* ((name (sidekick--project-name root))
         (config (sidekick--mcp-config id))
         (default-directory root)
         (buffer (get-buffer-create (format "*claude:%s*" name))))
    (with-current-buffer buffer
      (sidekick-conversation-mode)
      (sidekick-render-reset)
      (setq sidekick--conv-root root))
    (let ((proc (make-process
                 :name (format "claude:%s" name)
                 :buffer buffer
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :command (append
                           (list "claude" "-p"
                                 "--input-format" "stream-json"
                                 "--output-format" "stream-json"
                                 "--verbose" "--include-partial-messages"
                                 "--permission-mode" sidekick-permission-mode
                                 "--mcp-config" config)
                           (when resume-id (list "--resume" resume-id))
                           sidekick-extra-args)
                 :filter #'sidekick--process-filter
                 :sentinel #'sidekick--process-sentinel)))
      ;; The startup (monitor) prompt is the first turn but is not echoed as a
      ;; user line -- only claude's reply to it renders.
      (sidekick--send-user-message proc (sidekick--claude-prompt id)))
    buffer))

;;; Terminal session (legacy TUI) ---------------------------------------------

(defun sidekick--spawn-claude-terminal (root id &optional resume-id)
  "Start the interactive `claude' TUI for ROOT in a read-only `term' buffer.
ID keys this session's MCP endpoint and /listen stream on the sidekick
server. The buffer is not selected, so the user's window layout and
focus are untouched.  With RESUME-ID, resumes that past claude session
via claude's `--resume'."
  (let* ((name (sidekick--project-name root))
         (config (sidekick--mcp-config id))
         (default-directory root)
         ;; make-term names the buffer `*NAME*', creating it and the process
         ;; without displaying either.
         (buffer (apply #'make-term (format "claude:%s" name) "claude" nil
                        (append (when resume-id (list "--resume" resume-id))
                                (list "--mcp-config" config "--"
                                      (sidekick--claude-prompt id))))))
    (with-current-buffer buffer
      (term-mode)
      ;; This session is driven over MCP, never typed into, so present its
      ;; buffer as a passive output view. `term-line-mode' keeps rendering
      ;; claude's frames (terminal emulation is independent of the input mode)
      ;; but routes keystrokes through Emacs instead of the pty; making the
      ;; buffer read-only then blocks user edits and input outright. Claude's
      ;; output still flows in because `term-emulate-terminal' inserts it with
      ;; `inhibit-read-only' bound. The TUI keeps drawing its own prompt box --
      ;; that is part of the terminal frame and cannot be stripped from a live
      ;; render -- but it is now inert.
      (term-line-mode)
      (setq buffer-read-only t)
      ;; Claude's TUI rings BEL for attention; a background buffer's bells
      ;; must not flash/beep the user's frame.
      (setq-local ring-bell-function #'ignore))
    buffer))

;;;###autoload
(defun sidekick-notify (&optional context)
  "Notify the current buffer's project session about the current buffer.
The buffer is routed to the claude session whose project contains it, so
the right session hears about it when several are running.

CONTEXT, when non-nil, is sent alongside the buffer name -- called
interactively it is the active region (see `sidekick--region-context'), so
selecting code before invoking points the session at that snippet and its
location, mirroring `sidekick-prompt'."
  (interactive (list (sidekick--region-context)))
  (let* ((root (sidekick--project-root))
         (session (gethash root sidekick--sessions)))
    (if (not session)
        (message "sidekick: no session for %s (M-x sidekick-setup)"
                 (sidekick--project-name root))
      (sidekick--rpc-request
       "notify"
       `((buf . ,(buffer-name))
         (file . ,(or (buffer-file-name) ""))
         (region . ,(or context ""))
         (pid . ,(plist-get session :id))))
      (message "Notification sent to Claude"))))

;;; Server-issued RPCs ---------------------------------------------------------

;; The Go server calls back into this session with
;;   emacsclient -s <socket> --eval '(sidekick--rpc "<base64 json>")'
;; and parses the printed string as base64-encoded JSON. Base64 in both
;; directions sidesteps elisp/shell string escaping entirely. Buffers are
;; identified by their (unique) buffer name; line ranges follow the nvim API
;; convention: 0-based inclusive start, 0-based exclusive end, end -1 meaning
;; "through the last line".

(defun sidekick--rpc (b64)
  "Handle one sidekick request B64 (base64 JSON); return base64 JSON."
  (base64-encode-string
   (encode-coding-string
    (json-serialize
     (condition-case err
         (sidekick--dispatch
          (json-parse-string
           (decode-coding-string (base64-decode-string b64) 'utf-8)
           :object-type 'alist :array-type 'list :null-object nil))
       (error `((error . ,(error-message-string err))))))
    'utf-8)
   t))

(defun sidekick--dispatch (req)
  (let-alist req
    (pcase .op
      ("list-buffers" `((buffers . ,(sidekick--buffers nil))))
      ("open-file-buffers" `((buffers . ,(sidekick--buffers t))))
      ("read-lines" `((lines . ,(sidekick--read-lines .buf .start .end))))
      ("set-lines" (sidekick--set-lines .buf .start .end .lines) '((ok . t)))
      ("open" `((id . ,(sidekick--open .path))))
      ("save" (with-current-buffer (sidekick--buffer .buf) (save-buffer)) '((ok . t)))
      ("jump" (sidekick--jump .buf .line .col) '((ok . t)))
      ("find-definition"
       `((locations . ,(sidekick--xref .buf .line .col .symbol
                                        #'xref-backend-definitions))))
      ("find-references"
       `((locations . ,(sidekick--xref .buf .line .col .symbol
                                        #'xref-backend-references))))
      ("diagnostics" `((diagnostics . ,(sidekick--diagnostics .buf))))
      ("ask" `((answer . ,(sidekick--ask .prompt .choices))))
      (_ (error "unknown op: %s" .op)))))

(defun sidekick--buffer (name)
  (or (get-buffer name) (error "no buffer named %s" name)))

(defun sidekick--buffers (file-only)
  "Session buffers as a vector of (id name) alists.
NAME is the backing file's absolute path, or \"\" for file-less buffers.
With FILE-ONLY, keep only file-backed buffers. Hidden buffers (name
starting with a space) are internal and always skipped."
  (vconcat
   (seq-keep (lambda (b)
               (let ((file (buffer-file-name b)))
                 (unless (or (string-prefix-p " " (buffer-name b))
                             (and file-only (null file)))
                   `((id . ,(buffer-name b)) (name . ,(or file ""))))))
             (buffer-list))))

(defun sidekick--line-beg (n)
  "Position of the beginning of 0-based line N; `point-max' past the end."
  (save-excursion
    (goto-char (point-min))
    (forward-line n)
    (point)))

(defun sidekick--read-lines (buf start end)
  "Lines [START, END) of BUF as a vector; END of -1 means end of buffer."
  (with-current-buffer (sidekick--buffer buf)
    (save-excursion
      (save-restriction
        (widen)
        (let* ((beg (sidekick--line-beg start))
               (fin (if (< end 0) (point-max) (sidekick--line-beg end)))
               (text (buffer-substring-no-properties beg fin)))
          (if (string-empty-p text)
              []
            (vconcat (split-string (string-remove-suffix "\n" text) "\n"))))))))

(defun sidekick--reveal-point (buf pos)
  "Move point in BUF to POS and reveal it in every window showing BUF.
Leaves point at POS so a later switch to BUF lands where I last edited, and
for windows already displaying BUF moves their point there, recenters, and
pulses the line -- so the user sees where I'm working (like the nvim side)."
  (with-current-buffer buf
    (when (<= (point-min) pos (point-max))
      (goto-char pos)
      (dolist (win (get-buffer-window-list buf nil t))
        (set-window-point win pos)
        (with-selected-window win
          (recenter)
          (pulse-momentary-highlight-one-line pos))))))

(defun sidekick--set-lines (buf start end lines)
  "Replace lines [START, END) of BUF with LINES; END of -1 means end of buffer.
Empty LINES deletes the range. The inserted block is newline-terminated,
matching nvim's implicit final newline on every line. Point is left at the
start of the edited region and any window showing BUF is moved there, so the
user sees where I'm working."
  (with-current-buffer (sidekick--buffer buf)
    (let (edit-pos)
      (save-restriction
        (widen)
        (let ((beg (sidekick--line-beg start))
              (fin (if (< end 0) (point-max) (sidekick--line-beg end))))
          (delete-region beg fin)
          (goto-char beg)
          (setq edit-pos beg)
          (when lines
            ;; Appending past a final line that lacks its trailing newline
            ;; lands mid-line; start the insertion on a fresh line.
            (unless (bolp) (insert "\n"))
            (insert (string-join lines "\n") "\n"))))
      (sidekick--reveal-point (current-buffer) edit-pos))))

(defun sidekick--open (path)
  "Load PATH as a buffer without displaying it; return its buffer name."
  (buffer-name
   (find-file-noselect
    (expand-file-name path (or sidekick-root default-directory)))))

(defun sidekick--jump (buf line col)
  "Show BUF in the selected window with point at LINE:COL (1-based).
Pushes the prior location onto the xref marker stack first, so
\\[xref-go-back] (M-,) returns there, then recenters and briefly pulses
the target line so the user's eye lands on it."
  (let ((buffer (sidekick--buffer buf))
        (win (selected-window)))
    ;; This runs with the server's internal buffer current, so record the
    ;; user-visible location: the buffer and point of the selected window.
    (xref-push-marker-stack
     (with-current-buffer (window-buffer win)
       (copy-marker (window-point win))))
    (switch-to-buffer buffer)
    (widen)
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column (max 0 (1- col)))
    (recenter)
    (pulse-momentary-highlight-one-line (point))))

;;; Ask the user ---------------------------------------------------------------

(defun sidekick--ask (prompt choices)
  "Ask the user PROMPT and let them pick one of CHOICES; return the pick.
Backs the server's `ask' op, so claude can put a multiple-choice question
to the user and receive the selection as the tool result. Blocks in the
minibuffer (a recursive edit) until an answer is chosen, which is what
keeps claude waiting on the originating tool call."
  (let ((completion-ignore-case t))
    (completing-read (format "%s " (or prompt "Claude asks:"))
                     choices nil t)))

;;; xref -----------------------------------------------------------------------

(defun sidekick--xref (buf line col symbol query)
  "Run xref QUERY for the identifier at BUF LINE:COL (1-based).
QUERY is `xref-backend-definitions' or `xref-backend-references'. SYMBOL,
when a non-empty string, overrides the identifier at point; position-based
backends (eglot/lsp-mode) ignore it and use point regardless. Returns a
vector of (file line summary) alists for the file-backed results."
  (with-current-buffer (sidekick--buffer buf)
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        (forward-line (1- line))
        (move-to-column (max 0 (1- col)))
        (let* ((backend (or (xref-find-backend)
                            (error "no xref backend in %s" buf)))
               (id (if (and (stringp symbol) (not (string-empty-p symbol)))
                       symbol
                     (or (xref-backend-identifier-at-point backend)
                         (error "no identifier at %s:%d:%d" buf line col)))))
          (sidekick--xrefs->vector (funcall query backend id)))))))

(defun sidekick--xrefs->vector (xrefs)
  "XREFS (a list of `xref-item') as a vector of (file line summary) alists.
Non-file locations (which have no path to open) are dropped."
  (vconcat
   (delq nil
         (mapcar (lambda (x)
                   (let* ((loc (xref-item-location x))
                          (file (xref-location-group loc))
                          (line (xref-location-line loc)))
                     (when (and (stringp file) line)
                       `((file . ,file)
                         (line . ,line)
                         (summary . ,(xref-item-summary x))))))
                 xrefs))))

;;; diagnostics ----------------------------------------------------------------

(defun sidekick--diagnostics (buf)
  "Diagnostics for BUF as a vector of (line column severity message) alists.
Reads from flycheck when its mode is on, otherwise flymake; errors when
neither is active so the caller knows no checker is running."
  (with-current-buffer (sidekick--buffer buf)
    (cond
     ((and (bound-and-true-p flycheck-mode) (fboundp 'flycheck-current-errors))
      (vconcat
       (mapcar (lambda (e)
                 `((line . ,(or (flycheck-error-line e) 0))
                   (column . ,(or (flycheck-error-column e) 0))
                   (severity . ,(symbol-name (flycheck-error-level e)))
                   (message . ,(or (flycheck-error-message e) ""))))
               (flycheck-current-errors))))
     ((and (bound-and-true-p flymake-mode) (fboundp 'flymake-diagnostics))
      (save-restriction
        (widen)
        (vconcat
         (mapcar (lambda (d)
                   (let ((beg (flymake-diagnostic-beg d)))
                     `((line . ,(line-number-at-pos beg t))
                       (column . ,(save-excursion (goto-char beg) (1+ (current-column))))
                       (severity . ,(sidekick--flymake-severity d))
                       (message . ,(or (flymake-diagnostic-text d) "")))))
                 (flymake-diagnostics)))))
     (t (error "no flycheck-mode or flymake-mode active in %s" buf)))))

(defun sidekick--flymake-severity (d)
  "Map flymake diagnostic D's type to \"error\", \"warning\", or \"note\"."
  (let ((type (flymake-diagnostic-type d)))
    (cond
     ((memq type '(:error error eglot-error)) "error")
     ((memq type '(:warning warning eglot-warning)) "warning")
     ((memq type '(:note note eglot-note)) "note")
     (t (format "%s" type)))))

;;; Mode-line status ----------------------------------------------------------

;; The spawned claude runs in a `*claude:NAME*' term buffer whose TUI is the
;; only in-Emacs signal of what it is doing. While a turn runs the TUI draws a
;; spinner line -- a cycling glyph followed by "... (<elapsed> - <n> tokens -
;; esc to interrupt)"; when idle that line is gone. We scrape the buffer tail
;; on a timer and expose a compact per-project indicator for the mode line.
;;
;; Note on context size: the terminal never renders context-window fullness
;; (only /context does), so it cannot be scraped. The number surfaced here is
;; the running turn's live token count -- the sole figure the TUI exposes.

(defvar sidekick-mode-line-update-interval 1.0
  "Seconds between refreshes of the sidekick mode-line indicator.")

(defconst sidekick--spinner-glyphs
  "✶✻✳✽✢✷✸✹✺⣾⣽⣻⢿⡿⣟⣯⣷⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  "Leading glyphs the claude TUI cycles through while a turn is running.
The idle footer starts with a different glyph and completed messages use
`●', so a tail line beginning with one of these means a turn is live.")

(defvar sidekick--mode-line-timer nil
  "Repeating timer refreshing each session's cached `:status'.")

(defun sidekick--session-status (session)
  "Compact working/idle status for SESSION, or nil when it has no live buffer.
Native sessions have their `:status' pushed from stream events by
`sidekick-render' (see `sidekick--set-status'), so it is simply read back;
terminal sessions are scraped from their TUI frame."
  (if (plist-get session :terminal)
      (sidekick--terminal-status session)
    (and (buffer-live-p (plist-get session :buffer))
         (plist-get session :status))))

(defun sidekick--terminal-status (session)
  "Compact status for a terminal SESSION's claude buffer, or nil.
Scans only the buffer tail -- the current TUI frame is always at the end --
for the spinner glyph (turn running), the turn's token count, and the
context-window fill the claude status line reports as \"ctx:NN%\"."
  (let ((buffer (plist-get session :buffer)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (save-excursion
          (save-restriction
            (widen)
            (let* ((end (point-max))
                   (beg (progn (goto-char end) (forward-line -12) (point)))
                   (tail (buffer-substring-no-properties beg end))
                   (working (string-match-p
                             (concat "^[ \t]*[" sidekick--spinner-glyphs "]")
                             tail))
                   (tokens (and (string-match
                                 "\\([0-9][0-9.,]*[kKmM]?\\) tokens" tail)
                                (match-string 1 tail)))
                   ;; The claude status line ends with "ctx:NN%" (percent of
                   ;; the context window still free); surface it verbatim.
                   (ctx (and (string-match "ctx:\\([0-9]+%\\)" tail)
                             (match-string 1 tail)))
                   (base (cond ((and working tokens) (concat "⟳ " tokens))
                               (working "⟳")
                               (t "◦"))))
              (if ctx (concat base " " ctx) base))))))))

(defun sidekick--mode-line-refresh ()
  "Recompute every session's `:status' and repaint mode lines on any change."
  (let (changed)
    (maphash (lambda (root session)
               (let ((new (sidekick--session-status session)))
                 (unless (equal new (plist-get session :status))
                   (setq changed t)
                   (puthash root (plist-put session :status new)
                            sidekick--sessions))))
             sidekick--sessions)
    (when changed (force-mode-line-update t))))

(defvar-local sidekick--buffer-root 'unset
  "Cached project root of this buffer, so the mode line avoids recomputing it
on every redisplay. `unset' means not yet computed.")

(defun sidekick--buffer-root ()
  "Project root for the current buffer, memoized in `sidekick--buffer-root'."
  (if (eq sidekick--buffer-root 'unset)
      (setq sidekick--buffer-root (ignore-errors (sidekick--project-root)))
    sidekick--buffer-root))

(defun sidekick--mode-line ()
  "Mode-line string for the current buffer's project claude session, or nil.
Reads the cached `:status' set by the timer -- cheap enough for redisplay."
  (when (> (hash-table-count sidekick--sessions) 0)
    (when-let* ((session (gethash (sidekick--buffer-root) sidekick--sessions))
                (status (plist-get session :status)))
      (concat " cc:" status))))

(defconst sidekick--mode-line-construct '(:eval (sidekick--mode-line))
  "The `global-mode-string' entry added by `sidekick-mode-line-mode'.")
(put 'sidekick--mode-line-construct 'risky-local-variable t)

;;;###autoload
(define-minor-mode sidekick-mode-line-mode
  "Global minor mode showing each project's claude working/idle state.
When on, every mode line gains a \" cc:\" indicator for the claude session
of that buffer's project: ⟳ (with the live turn token count) while a turn
runs, ◦ when idle, each followed by the context-window fill (\"NN%\", the
percent still free) when the claude status line reports it. A timer
refreshes it every
`sidekick-mode-line-update-interval' seconds. Enabled automatically by
`sidekick-setup'."
  :global t
  :lighter nil
  :group 'sidekick
  (if sidekick-mode-line-mode
      (progn
        (add-to-list 'global-mode-string sidekick--mode-line-construct t)
        (unless (timerp sidekick--mode-line-timer)
          (setq sidekick--mode-line-timer
                (run-with-timer 0 sidekick-mode-line-update-interval
                                #'sidekick--mode-line-refresh))))
    (setq global-mode-string
          (delete sidekick--mode-line-construct global-mode-string))
    (when (timerp sidekick--mode-line-timer)
      (cancel-timer sidekick--mode-line-timer)
      (setq sidekick--mode-line-timer nil))
    (force-mode-line-update t)))

;;; Echo-area progress report -------------------------------------------------

;; The mode-line indicator only helps a user looking at the mode line. This
;; timer surfaces the same status in the echo area on a slow cadence so a
;; running turn announces itself even to a user watching a source buffer. Only
;; running turns are reported -- an idle session stays silent -- so it is a
;; heartbeat "still working" line, not constant noise.

(defvar sidekick-report-interval 10.0
  "Seconds between echo-area progress reports of running claude turns.")

(defvar sidekick--report-timer nil
  "Repeating timer driving `sidekick--report'.")

(defun sidekick--report ()
  "Echo the state of every session whose claude turn is currently running.
Idle sessions are skipped, so the echo area stays quiet when nothing runs.
A running turn's `sidekick--session-status' begins with the working glyph."
  (maphash (lambda (root session)
             (let ((status (sidekick--session-status session)))
               (when (and status (string-prefix-p "⟳" status))
                 (message "sidekick[%s]: %s"
                          (sidekick--project-name root) status))))
           sidekick--sessions))

;;;###autoload
(define-minor-mode sidekick-report-mode
  "Global minor mode echoing running claude turns on a slow timer.
When on, every `sidekick-report-interval' seconds each project whose
claude turn is running has its state echoed (\"sidekick[NAME]: ⟳ ...\");
idle sessions are not reported. Enabled automatically by `sidekick-setup'."
  :global t
  :lighter nil
  :group 'sidekick
  (if sidekick-report-mode
      (unless (timerp sidekick--report-timer)
        (setq sidekick--report-timer
              (run-with-timer sidekick-report-interval sidekick-report-interval
                              #'sidekick--report)))
    (when (timerp sidekick--report-timer)
      (cancel-timer sidekick--report-timer)
      (setq sidekick--report-timer nil))))

;;; Prompting the session ------------------------------------------------------

(defun sidekick--region-context ()
  "Describe the active region as prompt context, or nil when none is active.
The result is \"FILE:BEG-END\" on its own line followed by the region text in
a fenced block, so claude gets both the location and the exact source I am
pointing at.  Meant to be called from an `interactive' spec, before entering
the minibuffer clears the mark."
  (when (use-region-p)
    (let* ((beg (region-beginning))
           (end (region-end))
           (where (or buffer-file-name (buffer-name)))
           (lbeg (line-number-at-pos beg))
           (lend (line-number-at-pos end)))
      (format "\n\n%s:%d-%d\n```\n%s\n```"
              where lbeg lend
              (buffer-substring-no-properties beg end)))))

;;;###autoload
(defun sidekick-prompt (text &optional context)
  "Send TEXT to the current project's claude session and submit it.
Types TEXT straight into claude's input area, so you can drive the
background session without switching to its `*claude:NAME*' buffer. Routed
to the session whose project contains the current buffer, like
`sidekick-notify'.

TEXT may be a slash command such as \"/btw\" or \"/mr-review\"; it is
forwarded verbatim. CONTEXT, when non-nil, is appended to TEXT -- called
interactively it is the active region (see `sidekick--region-context'), so
selecting code before invoking sends that snippet and its location along."
  (interactive (list (read-string "Sidekick prompt: ")
                     (sidekick--region-context)))
  (let* ((root (sidekick--project-root))
         (session (gethash root sidekick--sessions))
         (buffer (and session (plist-get session :buffer)))
         (text (concat text (or context ""))))
    (if (not (buffer-live-p buffer))
        (message "sidekick: no session for %s (M-x sidekick-setup)"
                 (sidekick--project-name root))
      (let ((proc (get-buffer-process buffer)))
        (unless (process-live-p proc)
          (error "sidekick: %s has no live claude process" (buffer-name buffer)))
        (if (plist-get session :terminal)
            ;; `term-send-string' writes straight to the pty, bypassing the
            ;; buffer's read-only `term-line-mode', so the TUI sees TEXT as
            ;; typed input; the trailing return submits it. Wrap multi-line
            ;; TEXT in bracketed paste so an embedded newline is inserted
            ;; rather than treated as a submit by the TUI's line editor.
            (let ((multiline (string-search "\n" text)))
              (when multiline (term-send-string proc "\e[200~"))
              (term-send-string proc text)
              (when multiline (term-send-string proc "\e[201~"))
              (term-send-string proc "\r"))
          ;; Native session: echo the prompt into the rendered buffer, then
          ;; hand it to claude as one stream-json user turn on stdin.
          (with-current-buffer buffer (sidekick-render-user-prompt text))
          (sidekick--send-user-message proc text))
        (message "sidekick: sent prompt to %s" (sidekick--project-name root))))))

;;;###autoload
(defun sidekick-show-buffer ()
  "Pop to the claude session buffer for the current buffer's project.
Shows the `*claude:NAME*' buffer the session otherwise keeps in the
background -- claude's rendered output, or the read-only terminal view --
in another window, routed like `sidekick-notify' and `sidekick-prompt'."
  (interactive)
  (let* ((root (sidekick--project-root))
         (session (gethash root sidekick--sessions))
         (buffer (and session (plist-get session :buffer))))
    (if (not (buffer-live-p buffer))
        (message "sidekick: no session for %s (M-x sidekick-setup)"
                 (sidekick--project-name root))
      (pop-to-buffer buffer))))

;;; Keybindings ----------------------------------------------------------------

;;;###autoload (autoload 'sidekick-command-map "sidekick" nil t 'keymap)
(defvar-keymap sidekick-command-map
  :doc "Prefix keymap gathering sidekick's user commands.
Bind it to a single prefix key and get the whole family at once, e.g.

    (keymap-set global-map \"C-c s\" sidekick-command-map)

then `C-c s p' runs `sidekick-prompt', `C-c s n' `sidekick-notify', etc."
  "b" #'sidekick-show-buffer
  "p" #'sidekick-prompt
  "n" #'sidekick-notify
  "s" #'sidekick-setup
  "r" #'sidekick-reset
  "R" #'sidekick-resume)

;; Make the prefix reachable as a command so `C-c s' echoes its bindings.
;;;###autoload (autoload 'sidekick-command-prefix "sidekick" nil t 'keymap)
(defalias 'sidekick-command-prefix sidekick-command-map)

(provide 'sidekick)

;;; sidekick.el ends here
