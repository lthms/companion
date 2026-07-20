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
;; appends to a `sidekick-conversation-mode' buffer: answer text inline,
;; extended thinking in a fold that is collapsed by default, tool calls as slim
;; header lines. Per-turn token/cost totals from the trailing `result' event
;; drive the session's mode-line status directly, so nothing is scraped.
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

;;; Turn / block handling ------------------------------------------------------

(defun sidekick-render-reset ()
  "Clear the current conversation buffer and its parser state."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (setq sidekick--cur-block nil
        sidekick--answer-beg nil
        sidekick--fold-header nil
        sidekick--fold-content nil))

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
      ("message_delta" (sidekick--set-status t (let-alist .usage .output_tokens)))
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
                              'sidekick-tool-face))
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
      ;; input_json_delta (tool arguments) is not rendered in v1.
      (_ nil))))

(defun sidekick--block-stop ()
  "Finish the current block: fontify a completed answer, or close a fold."
  (pcase sidekick--cur-block
    ('text
     (when (and sidekick--answer-beg (marker-position sidekick--answer-beg))
       (sidekick--fontify-markdown sidekick--answer-beg (point-max)))
     (setq sidekick--answer-beg nil))
    ('thinking (sidekick--fold-end)))
  (setq sidekick--cur-block nil))

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
  "Close the open fold, wrapping its content in a collapsed overlay."
  (when (and sidekick--fold-content sidekick--fold-header)
    (let ((ov (make-overlay sidekick--fold-content (point-max) nil t nil))
          (inhibit-read-only t))
      (overlay-put ov 'invisible 'sidekick-fold)
      (overlay-put ov 'sidekick-header (copy-marker sidekick--fold-header))
      (overlay-put ov 'evaporate t)
      ;; Tag the whole header line so `sidekick-toggle-fold' (and a click) can
      ;; find this overlay from anywhere on it.
      (put-text-property sidekick--fold-header sidekick--fold-content
                         'sidekick-fold-overlay ov)
      (put-text-property sidekick--fold-header sidekick--fold-content
                         'mouse-face 'highlight)
      (put-text-property sidekick--fold-header sidekick--fold-content
                         'keymap sidekick-fold-header-map)))
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
