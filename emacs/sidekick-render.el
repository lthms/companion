;;; sidekick-render.el --- Native rendering of a claude stream-json session -*- lexical-binding: t; -*-

;; Maintainer: Sylvain Ribstein <sylvain.ribstein@gmail.com>

;; This Source Code Form is subject to the terms of the Mozilla Public
;; License, v. 2.0. If a copy of the MPL was not distributed with this
;; file, You can obtain one at https://mozilla.org/MPL/2.0/.

;; Renders a headless `claude' session into an Emacs buffer instead of
;; emulating its terminal UI. The session is spawned (in sidekick.el) with
;;
;;   claude -p --input-format stream-json --output-format stream-json \
;;          --verbose --include-partial-messages ...
;;
;; so its stdout is a stream of NDJSON events and its stdin accepts NDJSON
;; user turns. `sidekick-render-event' consumes one parsed top-level event and
;; appends to a `sidekick-conversation-mode' buffer: answer text inline, tool
;; calls as slim header lines carrying a digest of their arguments, thinking as
;; a marker line with the turn's thinking-token count. Per-turn token/cost
;; totals from the trailing `result' event drive the session's mode-line status
;; directly, so nothing is scraped.
;;
;; The CLI redacts reasoning content: a thinking block streams only its
;; signature, and "thinking" is empty in the whole-message events and in the
;; on-disk transcript alike. So there is no thinking text to fold -- what a turn
;; is doing shows through the calls it makes, which is why tool arguments are
;; rendered. The fold machinery stays for blocks that do carry content.
;;
;; The content-block stream is sequential -- one block starts, streams its
;; deltas, and stops before the next begins -- so a single "current block"
;; state is enough; blocks never interleave.

;;; Code:

(require 'let-alist)
(require 'seq)

(defgroup sidekick-render nil
  "Native rendering of a claude stream-json session."
  :group 'sidekick
  :prefix "sidekick-")

(defface sidekick-prompt-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the user's prompt line separating turns.")

(defface sidekick-answer-face
  '((t :inherit default))
  "Face for Claude's answer text.")

(defface sidekick-thinking-face
  '((t :inherit shadow :slant italic))
  "Face for extended-thinking text (inside a fold).")

(defface sidekick-fold-header-face
  '((t :inherit font-lock-comment-face))
  "Face for the clickable header of a collapsible section.")

(defface sidekick-tool-face
  '((t :inherit font-lock-function-name-face))
  "Face for a tool-call header line.")

(defface sidekick-tool-arg-face
  '((t :inherit shadow))
  "Face for the argument digest trailing a tool-call header line.")

(defface sidekick-footer-face
  '((t :inherit shadow))
  "Face for the faint per-turn token/cost footer.")

;;; Buffer-local parser state --------------------------------------------------

(defvar-local sidekick--conv-root nil
  "Project root whose session this conversation buffer renders.
Lets the event handler update that session's mode-line status.")

(defvar-local sidekick--cur-block nil
  "Type of the content block currently streaming: `text', `thinking',
`tool_use', or nil between blocks.")

(defvar-local sidekick--answer-beg nil
  "Marker at the start of the current answer block, for markdown fontifying
once the block completes.")

(defvar-local sidekick--fold-header nil
  "Marker at the first char (the arrow) of the open fold's header line.")

(defvar-local sidekick--fold-content nil
  "Marker at the start of the open fold's hidden content.")

(defvar-local sidekick--thinking-eol nil
  "Marker at the end of a thinking line still awaiting its token count.")

(defvar-local sidekick--tool-args nil
  "Partial JSON of the streaming tool call's input, accumulated across deltas.")

(defvar-local sidekick--tool-eol nil
  "Marker at the end of the current tool call's header line, where its
argument digest is appended once the block stops.")

;;; Mode -----------------------------------------------------------------------

(defvar-keymap sidekick-conversation-mode-map
  :doc "Keymap for `sidekick-conversation-mode'."
  "TAB" #'sidekick-toggle-fold
  "<tab>" #'sidekick-toggle-fold
  "RET" #'sidekick-toggle-fold)

(defvar-keymap sidekick-fold-header-map
  :doc "Keymap active on a fold header line, via a `keymap' text property.
Scoped to the header text so mouse-1 elsewhere keeps its normal selection
behavior; on the header, a click (or TAB/RET) toggles the fold."
  "TAB" #'sidekick-toggle-fold
  "<tab>" #'sidekick-toggle-fold
  "RET" #'sidekick-toggle-fold
  "<mouse-1>" #'sidekick-toggle-fold
  "<mouse-2>" #'sidekick-toggle-fold)

(define-derived-mode sidekick-conversation-mode special-mode "Claude"
  "Major mode for a rendered, read-only claude conversation.
Extended-thinking sections fold; point on a fold header and \\[sidekick-toggle-fold]
\(or a click) toggles it."
  (setq-local truncate-lines nil)
  (setq-local word-wrap t)
  (visual-line-mode 1)
  ;; Overlays carrying `invisible' of `sidekick-fold' collapse when this spec
  ;; is active, which it is from buffer creation -- so folds start collapsed.
  (add-to-invisibility-spec 'sidekick-fold))

;;; Insertion ------------------------------------------------------------------

(defun sidekick--conv-insert (text &optional face)
  "Append TEXT (with FACE, if any) at end of buffer, following the tail.
Windows whose point sat at the old end are advanced to the new end so a
reader watching the conversation keeps seeing the latest output, while a
reader who scrolled up is left in place."
  (let* ((inhibit-read-only t)
         (old-max (point-max))
         (at-end (seq-filter (lambda (w) (= (window-point w) old-max))
                             (get-buffer-window-list (current-buffer) nil t))))
    (goto-char (point-max))
    (insert (if face (propertize text 'face face) text))
    (dolist (w at-end)
      (set-window-point w (point-max)))))

(defun sidekick--conv-insert-at (pos text &optional face)
  "Insert TEXT (with FACE, if any) at POS, leaving the tail and point alone.
For annotating a line already written -- a tool's arguments, a token count --
once the stream reveals what belongs on it."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char pos)
      (insert (if face (propertize text 'face face) text)))))

;;; Turn / block handling ------------------------------------------------------

(defun sidekick-render-reset ()
  "Clear the current conversation buffer and its parser state."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (setq sidekick--cur-block nil
        sidekick--answer-beg nil
        sidekick--fold-header nil
        sidekick--fold-content nil
        sidekick--thinking-eol nil
        sidekick--tool-args nil
        sidekick--tool-eol nil))

(defun sidekick-render-user-prompt (text)
  "Render TEXT as a user turn separating what follows from what came before."
  (unless (bobp) (sidekick--conv-insert "\n"))
  (sidekick--conv-insert (concat "› " text "\n") 'sidekick-prompt-face))

(defun sidekick-render-event (ev)
  "Render one parsed top-level stream-json event EV (an alist)."
  (let-alist ev
    (pcase .type
      ("stream_event" (sidekick--render-stream-event .event))
      ("result" (sidekick--render-result ev))
      ;; `assistant'/`user' carry the same content as whole messages; we render
      ;; from the partial `stream_event' deltas instead, so ignore them here.
      (_ nil))))

(defun sidekick--render-stream-event (event)
  "Dispatch a raw Claude API streaming EVENT (the `event' field of a
`stream_event')."
  (let-alist event
    (pcase .type
      ("content_block_start" (sidekick--block-start .content_block))
      ("content_block_delta" (sidekick--block-delta .delta))
      ("content_block_stop" (sidekick--block-stop))
      ("message_start" (sidekick--set-status t nil))
      ("message_delta"
       (let-alist .usage
         (sidekick--set-status t .output_tokens)
         (sidekick--note-thinking-tokens
          .output_tokens_details.thinking_tokens)))
      (_ nil))))

(defun sidekick--block-start (block)
  "Begin rendering content BLOCK (an alist with `type', and `name' for tools)."
  (let-alist block
    (pcase .type
      ("text"
       (setq sidekick--cur-block 'text)
       (unless (bolp) (sidekick--conv-insert "\n"))
       (setq sidekick--answer-beg (copy-marker (point-max))))
      ("thinking"
       (setq sidekick--cur-block 'thinking)
       (sidekick--fold-begin "thinking"))
      ("tool_use"
       (setq sidekick--cur-block 'tool_use)
       (unless (bolp) (sidekick--conv-insert "\n"))
       (sidekick--conv-insert (concat "→ " (or .name "tool") "\n")
                              'sidekick-tool-face)
       ;; The name is written straight away so the line shows up the moment the
       ;; call starts; the arguments stream in after it and get appended to the
       ;; same line by `sidekick--tool-render-args'.
       (setq sidekick--tool-args ""
             sidekick--tool-eol (copy-marker (1- (point-max)))))
      (_ (setq sidekick--cur-block nil)))))

(defun sidekick--block-delta (delta)
  "Append the incremental DELTA of the current block."
  (let-alist delta
    (pcase .type
      ("text_delta"
       (when (eq sidekick--cur-block 'text)
         (sidekick--conv-insert .text 'sidekick-answer-face)))
      ("thinking_delta"
       (when (eq sidekick--cur-block 'thinking)
         (sidekick--conv-insert .thinking 'sidekick-thinking-face)))
      ("input_json_delta"
       ;; Accumulated rather than rendered: the fragments are partial JSON, only
       ;; parseable once the block stops.
       (when (eq sidekick--cur-block 'tool_use)
         (setq sidekick--tool-args
               (concat sidekick--tool-args (or .partial_json "")))))
      (_ nil))))

(defun sidekick--block-stop ()
  "Finish the current block: fontify a completed answer, close a fold, or
digest a tool call's arguments onto its header line."
  (pcase sidekick--cur-block
    ('text
     (when (and sidekick--answer-beg (marker-position sidekick--answer-beg))
       (sidekick--fontify-markdown sidekick--answer-beg (point-max)))
     (setq sidekick--answer-beg nil))
    ('thinking (sidekick--fold-end))
    ('tool_use (sidekick--tool-render-args)))
  (setq sidekick--cur-block nil))

;;; Tool arguments -------------------------------------------------------------

;; Claude's reasoning is redacted from the stream (see `sidekick--fold-end'), so
;; what a turn is actually doing is only legible through the calls it makes --
;; which is why the header line carries an argument and not just the tool name.

(defconst sidekick--tool-arg-keys
  '(command file_path path pattern query url buffer prompt description)
  "Tool-input fields worth putting on a header line, most telling first.")

(defun sidekick--tool-render-args ()
  "Append a one-line digest of the finished tool call's input to its header."
  (when-let ((eol (and sidekick--tool-eol (marker-position sidekick--tool-eol)))
             (digest (sidekick--tool-digest sidekick--tool-args)))
    (sidekick--conv-insert-at eol (concat "  " digest) 'sidekick-tool-arg-face))
  (setq sidekick--tool-args nil
        sidekick--tool-eol nil))

(defun sidekick--tool-digest (json)
  "The most telling field of tool-input JSON, as one short line, or nil.
JSON may be incomplete if the block was cut off, in which case there is
nothing to show."
  (let* ((input (and (stringp json) (not (string-empty-p json))
                     (ignore-errors
                       (json-parse-string json :object-type 'alist
                                          :array-type 'list :null-object nil))))
         (stringy (lambda (v) (and (stringp v) (not (string-empty-p v)) v)))
         (val (and (consp input)
                   (or (seq-some (lambda (k) (funcall stringy (alist-get k input)))
                                 sidekick--tool-arg-keys)
                       ;; Unknown tool: show whatever string it did pass.
                       (seq-some (lambda (cell) (funcall stringy (cdr cell)))
                                 input)))))
    (when val
      (truncate-string-to-width
       (string-trim (replace-regexp-in-string "[ \t\n]+" " " val))
       72 nil nil t))))

(defun sidekick--note-thinking-tokens (n)
  "Append a count of N thinking tokens to the thinking line awaiting one.
That count is the only quantitative trace of a thinking phase the CLI leaves;
it arrives with `message_delta' when the message completes, so it lands just
after the line it annotates.  N covers the whole message, so with several
thinking blocks in one message only the last line is annotated."
  (when (and n (> n 0) sidekick--thinking-eol
             (marker-position sidekick--thinking-eol))
    (sidekick--conv-insert-at (marker-position sidekick--thinking-eol)
                              (format " · %s tokens" (sidekick--humanize n))
                              'sidekick-fold-header-face))
  (setq sidekick--thinking-eol nil))

(defun sidekick--render-result (ev)
  "Handle the trailing `result' EV: mark idle and append a token/cost footer."
  (let-alist ev
    (let* ((out (let-alist .usage .output_tokens))
           (cost .total_cost_usd))
      (sidekick--set-status nil out)
      (when (or out cost)
        (unless (bolp) (sidekick--conv-insert "\n"))
        (sidekick--conv-insert
         (concat (when out (format "  %s tokens" (sidekick--humanize out)))
                 (when cost (format "%s$%.4f"
                                    (if out " · " "  ") cost))
                 "\n")
         'sidekick-footer-face)))))

;;; Folds ----------------------------------------------------------------------

(defun sidekick--fold-begin (label)
  "Open a collapsible section titled LABEL; content inserted next is hidden."
  (unless (bolp) (sidekick--conv-insert "\n"))
  (setq sidekick--fold-header (copy-marker (point-max)))
  (sidekick--conv-insert (concat "▸ " label "\n") 'sidekick-fold-header-face)
  (setq sidekick--fold-content (copy-marker (point-max))))

(defun sidekick--fold-end ()
  "Close the open fold, wrapping its content in a collapsed overlay.
A fold that ended up empty gets no overlay: an empty overlay carrying
`evaporate' is deleted on the spot, which would leave a header tagged with a
dead overlay -- TAB on it then does nothing at all, not even complain.  Its
arrow is swapped for a flat marker instead, so the line reads as a note that
something happened rather than as something openable.  Claude's CLI redacts
extended thinking (only `signature_delta' arrives, never `thinking_delta'), so
in practice that is every thinking block."
  (when (and sidekick--fold-content sidekick--fold-header)
    (let ((inhibit-read-only t))
      (if (= sidekick--fold-content (point-max))
          (let ((beg (marker-position sidekick--fold-header)))
            (subst-char-in-region beg (1+ beg) ?▸ ?…)
            ;; Remember where the line ends so the turn's thinking-token count
            ;; can be appended to it once `message_delta' reports one.
            (setq sidekick--thinking-eol
                  (copy-marker (1- (marker-position sidekick--fold-content)))))
        (let ((ov (make-overlay sidekick--fold-content (point-max) nil t nil)))
          (overlay-put ov 'invisible 'sidekick-fold)
          (overlay-put ov 'sidekick-header (copy-marker sidekick--fold-header))
          (overlay-put ov 'evaporate t)
          ;; Tag the whole header line so `sidekick-toggle-fold' (and a click)
          ;; can find this overlay from anywhere on it.
          (put-text-property sidekick--fold-header sidekick--fold-content
                             'sidekick-fold-overlay ov)
          (put-text-property sidekick--fold-header sidekick--fold-content
                             'mouse-face 'highlight)
          (put-text-property sidekick--fold-header sidekick--fold-content
                             'keymap sidekick-fold-header-map)))))
  (setq sidekick--fold-header nil
        sidekick--fold-content nil))

(defun sidekick-toggle-fold (&optional event)
  "Toggle the fold whose header is at point (or under the mouse EVENT)."
  (interactive (list last-nonmenu-event))
  (when (and event (listp event))
    (goto-char (posn-point (event-end event))))
  (let ((ov (get-text-property (point) 'sidekick-fold-overlay)))
    (if (not ov)
        (message "sidekick: point is not on a fold header")
      (let ((hidden (overlay-get ov 'invisible))
            (hs (overlay-get ov 'sidekick-header))
            (inhibit-read-only t))
        (overlay-put ov 'invisible (and (not hidden) 'sidekick-fold))
        (when (and hs (marker-position hs))
          (save-excursion
            (goto-char hs)
            (when (looking-at "[▸▾]")
              (replace-match (if hidden "▾" "▸")))))))))

;;; Light markdown fontification ----------------------------------------------

(defconst sidekick--markdown-rules
  '(("^#\\{1,6\\} .*$" . font-lock-keyword-face)   ; headings
    ("`[^`\n]+`" . font-lock-constant-face)         ; inline code
    ("\\*\\*[^*\n]+\\*\\*" . bold))                 ; bold
  "Regexp -> face rules applied to a completed answer block.
Deliberately small: enough to lift structure out of the plain text without
reimplementing a markdown parser on a streaming buffer.")

(defun sidekick--fontify-markdown (beg end)
  "Overlay a few markdown cues (headings, inline code, bold) on [BEG, END)."
  (let ((inhibit-read-only t))
    (save-excursion
      (dolist (rule sidekick--markdown-rules)
        (goto-char beg)
        (while (re-search-forward (car rule) end t)
          (add-face-text-property (match-beginning 0) (match-end 0)
                                  (cdr rule)))))))

;;; Status bridge --------------------------------------------------------------

;; Native sessions never render a spinner, so status is pushed from events
;; rather than scraped: WORKING is non-nil during a turn, TOKENS is the running
;; output-token count. `sidekick--session-status' (in sidekick.el) returns the
;; `:status' set here for native sessions.

(declare-function sidekick--session-by-root "sidekick" (root))

(defun sidekick--set-status (working tokens)
  "Push a status string for this buffer's session: WORKING with TOKENS."
  (when sidekick--conv-root
    (when-let ((session (sidekick--session-by-root sidekick--conv-root)))
      (let ((status (cond ((and working tokens)
                           (concat "⟳ " (sidekick--humanize tokens)))
                          (working "⟳")
                          (t "◦"))))
        (unless (equal status (plist-get session :status))
          (plist-put session :status status)
          (force-mode-line-update t))))))

(defun sidekick--humanize (n)
  "Format token count N as a short string (e.g. 1234 -> \"1.2k\")."
  (cond ((null n) "0")
        ((>= n 1000000) (format "%.1fM" (/ n 1000000.0)))
        ((>= n 1000) (format "%.1fk" (/ n 1000.0)))
        (t (number-to-string n))))

(provide 'sidekick-render)

;;; sidekick-render.el ends here
