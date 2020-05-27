;;; embark.el --- Conveniently act on minibuffer completions   -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Omar Antolín Camarena

;; Author: Omar Antolín Camarena <omar@matem.unam.mx>
;; Keywords: convenience
;; Version: 0.4
;; Homepage: https://github.com/oantolin/embark
;; Package-Requires: ((emacs "25.1"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; embark - Emacs Mini-Buffer Actions Rooted in Keymaps.

;; This package provides a pair of commands, `embark-act' and
;; `embark-exit-and-act', to execute actions on the top minibuffer
;; completion canidate: the one that would be chosen by
;; minibuffer-force-complete. Additionally `embark-act' can act on the
;; completion candidate at point in the completions buffer. You should
;; bind both of them in `minibuffer-local-completion-map' and also
;; bind `embark-act' in `completion-list-mode-map'.

;; The actions are arranged into keymaps separated by the type of
;; completion currently taking place.  By default `embark' recognizes
;; the following types of completion: file names, buffers and symbols.
;; The classification is configurable, see the variable
;; `embark-classifiers'.

;; For any given type there is a corresponding keymap as noted in
;; `embark-keymap-alist'.  For example, for the completion category
;; `file', by default the corresponding keymap is `embark-file-map'.
;; In this keymap you can bind normal commands you might want to use
;; on file names.  For example, by default `embark-file-map' binds
;; `delete-file' to "d", `rename-file' to "r" and `copy-file' to "c".

;; The default keymaps that come with `embark' all set
;; `embark-general-map' as their parent, so that the actions bound
;; there are available no matter what type of completion you are in
;; the middle of.  By default this includes bindings to save the
;; current candidate in the kill ring and to insert the current
;; candidate in the previously selected buffer (the buffer that was
;; current when you executed a command that opened up the minibuffer).

;; You can use any command that reads from the minibuffer as an action
;; and the target of the action will be inserted at the first
;; minibuffer prompt.  You don't even have to bind a command in one of
;; the keymaps listed in `embark-keymap-alist' to use it!  After
;; running `embark-act' all of your keybindings and even
;; `execute-extended-command' can be used to run a command.

;; By default, for most commands `embark' inserts the target of the
;; action into the next minibuffer prompt and "presses RET" for you,
;; accepting the target as is.  You can add commands for which you
;; want the chance to edit the target before acting upon it to the
;; list `embark-allow-edit-commands'.

;; If you want the default to be to allowing editing the target for
;; all commands, set `embark-allow-edit-default' to t and list
;; exceptions in `embark-skip-edit-commands'.

;; If you want to customize what happens after the target is inserted
;; at the minibuffer prompt of an action, you can use the global
;; `embark-setup-hook' or override it in the `embark-setup-overrides'
;; alist.  See the default value of `embark-setup-overrides' for an
;; example.

;; You can also write your own commands that do not read from the
;; minibuffer but act on the current target anyway: just use the
;; `embark-target' function (exactly once!: it "self-destructs") to
;; retrieve the current target.  See the definitions of
;; `embark-insert' or `embark-save' for examples.

;; If you wish to see a reminder of which actions are available, I
;; recommend installing which-key and using `which-key-mode' with the
;; `which-key-show-transient-maps' variable set to t.

;;; Code:

(eval-when-compile (require 'subr-x))
(require 'ffap)
(require 'thingatpt)

;;; user facing options

(defgroup embark nil
  "Emacs Mini-Buffer Actions Rooted in Keymaps"
  :group 'minibuffer)

(defcustom embark-keymap-alist
  '((general . embark-general-map)
    (file . embark-file-map)
    (buffer . embark-buffer-map)
    (command . embark-symbol-map)
    (symbol . embark-symbol-map)
    (package . embark-package-map))
  "Alist of action types and corresponding keymaps."
  :type '(alist :key-type symbol :value-type variable)
  :group 'embark)

(defcustom embark-classifiers
  '(embark-cached-type
    embark-category-type
    embark-package-type
    embark-symbol-completion-type
    embark-dired-type
    embark-ibuffer-type
    embark-ffap-type
    embark-symbol-at-point-type)
  "List of functions to classify the current completion session.
Each function should take no arguments and return a symbol
classifying the current minibuffer completion session, or nil to
indicate it could not determine the type of completion."
  :type 'hook
  :group 'embark)

(defcustom embark-target-finders
  '(embark-top-minibuffer-completion
    embark-button-label
    embark-completion-at-point
    ffap-file-at-point
    embark-symbol-at-point)
  "List of functions to pick the target for actions.
Each function should take no arguments and return either a target
string or nil (to indicate it found no target)."
  :type 'hook
  :group 'embark)

(defcustom embark-indicator (propertize "Act" 'face 'highlight)
  "Indicator to use when embarking upon an action.

If set to a string prepend it to the minibuffer prompt or to the
message in the echo area when outside of the minibuffer. When set
to a function it is called with no arguments to indicate the
pending action itself. For nil no indication is shown."
  :type '(choice function string nil)
  :group 'embark)

(defcustom embark-setup-hook nil
  "Hook to run after injecting target into minibuffer.
It can be overriden by the `embark-setup-overrides' alist."
  :type 'hook
  :group 'embark)

(defcustom embark-setup-overrides
  '((async-shell-command embark--shell-prep)
    (shell-command embark--shell-prep)
    (eval-expression embark--eval-prep))
  "Alist associating commands with post-injection setup hooks.
For commands appearing as keys in this alist, run the
corresponding value as a setup hook (instead of
`embark-setup-hook') after injecting the target into in the
minibuffer and before acting on it."
  :type '(alist :key-type function :value-type hook)
  :group 'embark)

(defcustom embark-allow-edit-default nil
  "Is the user allowed to edit the target before acting on it?
This variable sets the default policy, and can be overidden.
When this variable is nil, it is overridden by
`embark-allow-edit-commands'; when it is t, it is overidden by
`embark-skip-edit-commands'."
  :type 'boolean
  :group 'embark)

(defcustom embark-allow-edit-commands
  '(delete-file
    delete-directory
    kill-buffer
    shell-command
    async-shell-command
    embark-kill-buffer-and-window
    eval-expression)
  "Allowing editing of target prior to acting for these commands.
This list is used only when `embark-allow-edit-default' is nil."
  :type 'hook
  :group 'embark)

(defcustom embark-skip-edit-commands nil
  "Skip editing of target prior to acting for these commands.
This list is used only when `embark-allow-edit-default' is t."
  :type 'hook
  :group 'embark)

(defcustom embark-pre-action-hook nil
  "Hook run right before an action is embarked upon."
  :type 'hook
  :group 'embark)

(defcustom embark-candidate-collectors
  '(embark-minibuffer-candidates
    embark-completions-buffer-candidates
    embark-dired-candidates
    embark-ibuffer-candidates
    embark-embark-occur-candidates)
  "List of functions that collect all candidates in a given context.
These are used to fill an Embark Occur buffer."
  :type 'hook
  :group 'embark)

(defcustom embark-annotator-alist
  '((symbol . embark-first-line-of-docstring)
    (buffer . embark-file-and-major-mode)
    (file . embark-size-and-modification-time))
  "Alist associating completion types to annotation functions.
Each function should take a candidate for an action as a string
and return a string without newlines giving some extra
information about the candidate."
  :type '(alist :key-type symbol :value-type function)
  :group 'embark)

(defcustom embark-occur-initial-view-alist
  '((file . grid)
    (buffer . grid)
    (symbol . list)
    (t . list))
  "Initial views for Embark Occur buffers by type.
This is an alist associating completion types to either `list' or
`grid'.  Additionally you can associate t to a default initial
view for types not mentioned separately."
  :type '(choice (const :tag "List view" list)
                 (const :tag "Grid view" grid))
  :group 'embark)

(defcustom embark-exporters-alist
  '((buffer . embark-ibuffer)
    (file . embark-dired)
    (t . embark-occur))
  "Alist associating completion types to export functions.
Each function should take a list of strings which are candidates
for actions and make a buffer appropriate to manage them.  For
example, the default is to make a dired buffer for files, and an
ibuffer for buffers.

The key t is also allowed in the alist, and the corresponding
value indicates the default function to use for other types.  The
default is `embark-occur'."
  :type '(alist :key-type symbol :value-type function)
  :group 'embark)

;;; stashing information for actions in buffer local variables

(defvar embark--type nil
  "Cache for the completion type, meant to be set buffer-locally.
Always keep the non-local value equal to nil.")

(defvar embark--target-buffer nil
  "Cache for the previous buffer, meant to be set buffer-locally.
Always keep the non-local value equal to nil.")

(defvar embark--command nil
  "Command that started the completion session.")

(defun embark--record-command ()
  "Record the command that opened the minibuffer."
  (setq-local embark--command this-command))

(add-hook 'minibuffer-setup-hook #'embark--record-command)

(defun embark-cached-type ()
  "Return buffer local cached completion type if available."
  embark--type)

(defun embark--default-directory ()
  "Guess a reasonable default directory for the current candidates."
  (if (and (minibufferp) minibuffer-completing-file-name)
      (file-name-directory
       (expand-file-name
        (buffer-substring (minibuffer-prompt-end) (point))))
    default-directory))

(defun embark--target-buffer ()
  "Get target buffer for insert actions."
  (cond
   ((minibufferp) (window-buffer (minibuffer-selected-window)))
   ((derived-mode-p 'completion-list-mode)
    (if (minibufferp completion-reference-buffer)
        (with-current-buffer completion-reference-buffer
          (window-buffer (minibuffer-selected-window)))
      completion-reference-buffer))))

(defun embark--cache-info (&optional buffer)
  "Cache information needed for actions in variables local to BUFFER."
  (let ((type (embark-classify))
        (cmd embark--command)
        (dir (embark--default-directory))
        (target-buffer (embark--target-buffer)))
    (with-current-buffer (or buffer standard-output)
      (setq-local embark--command cmd)
      (setq-local embark--type type)
      (setq-local default-directory dir)
      (setq-local embark--target-buffer target-buffer))))

(add-hook 'completion-setup-hook #'embark--cache-info t)

;;; core functionality

(defvar embark--target nil "String the next action will operate on.")
(defvar embark--keymap nil "Keymap to activate for next action.")

(defvar embark--overlay nil
  "Overlay to communicate embarking on an action to the user.")

(defun embark--metadata ()
  "Return current minibuffer completion metadata."
  (completion-metadata (minibuffer-contents)
                       minibuffer-completion-table
                       minibuffer-completion-predicate))

(defun embark-category-type ()
  "Return minibuffer completion category per metadata."
  (completion-metadata-get (embark--metadata) 'category))

(defun embark-symbol-completion-type ()
  "Determine if currently completing symbols."
  (let ((mct minibuffer-completion-table))
    (when (or (eq mct 'help--symbol-completion-table)
              (vectorp mct)
              (and (consp mct) (symbolp (car mct)))
              (completion-metadata-get (embark--metadata) 'symbolsp)
              ;; before Emacs 27, M-x does not have command category
              (string-match-p "M-x" (or (minibuffer-prompt) "")))
      'symbol)))

(defun embark-package-type ()
  "Determine if currently completing package names."
  (when (string-suffix-p "package: " (or (minibuffer-prompt) ""))
    'package))

(defun embark-dired-type ()
  "Report that dired buffers yield files."
  (when (derived-mode-p 'dired-mode) 'file))

(defun embark-ibuffer-type ()
  "Report that ibuffer buffers yield buffer."
  (when (derived-mode-p 'ibuffer-mode) 'buffer))

(defun embark-ffap-type ()
  "If there is a file at point, report it."
  (when (ffap-file-at-point) 'file))

(defun embark-symbol-at-point-type ()
  "If there is a file at point, report it."
  (when (symbol-at-point) 'symbol))

(defun embark-classify ()
  "Classify current minibuffer completion session."
  (or (run-hook-with-args-until-success 'embark-classifiers)
      'general))

(defun embark-target ()
  "Return the target for the current action.
Save the result somewhere if you need it more than once: calling
this function again before the next action is initiating will
return nil."
  (prog1 embark--target
    (setq embark--target nil)))

(defun embark--inject ()
  "Inject embark target into minibuffer prompt."
  (when (or (not (string-match-p "M-x" (minibuffer-prompt)))
            (eq real-this-command 'embark-default-action)
            (eq real-this-command 'embark-action<embark-default-action>))
    (when-let ((target (embark-target)))
      (delete-minibuffer-contents)
      (insert target)
      (let ((embark-setup-hook
             (or (alist-get this-command embark-setup-overrides)
                 embark-setup-hook)))
        (run-hooks 'embark-setup-hook)
        (when (if embark-allow-edit-default
                  (memq this-command embark-skip-edit-commands)
                (not (memq this-command embark-allow-edit-commands)))
          (setq unread-command-events '(13)))))))

(defun embark--cleanup ()
  "Remove all hooks and modifications."
  (unless embark--target
    (remove-hook 'minibuffer-setup-hook #'embark--inject)
    (remove-hook 'post-command-hook #'embark--cleanup)
    (when embark--overlay
      (delete-overlay embark--overlay)
      (setq embark--overlay nil))))

(defun embark-top-minibuffer-completion ()
  "Return the top completion candidate in the minibuffer."
  (when (minibufferp)
    (let ((contents (minibuffer-contents)))
      (if (test-completion contents
                           minibuffer-completion-table
                           minibuffer-completion-predicate)
          contents
        (let ((completions (completion-all-sorted-completions)))
          (if (null completions)
              contents
            (concat
             (substring contents 0 (or (cdr (last completions)) 0))
             (car completions))))))))

(defun embark-button-label ()
  "Return the label of the button at point."
  (when-let* ((button (button-at (point)))
              (label (buffer-substring
                      (button-start button)
                      (buffer-end button))))
    (if (eq embark--type 'file)
        (abbreviate-file-name (expand-file-name label))
      label)))

(defun embark-completion-at-point (&optional relative)
  "Return the completion candidate at point in a completions buffer.
If the completions are file names and RELATIVE is non-nil, return
relative path."
  (when (eq major-mode 'completion-list-mode)
    (if (not (get-text-property (point) 'mouse-face))
        (user-error "No completion here")
      ;; this fairly delicate logic is taken from `choose-completion'
      (let (beg end)
        (cond
         ((and (not (eobp)) (get-text-property (point) 'mouse-face))
          (setq end (point) beg (1+ (point))))
         ((and (not (bobp))
               (get-text-property (1- (point)) 'mouse-face))
          (setq end (1- (point)) beg (point)))
         (t (user-error "No completion here")))
        (setq beg (previous-single-property-change beg 'mouse-face))
        (setq end (or (next-single-property-change end 'mouse-face)
                      (point-max)))
        (let ((raw (buffer-substring-no-properties beg end)))
          (if (and (eq embark--type 'file) (not relative))
              (abbreviate-file-name (expand-file-name raw))
            raw))))))

(defun embark-symbol-at-point ()
  "Return name of symbol at point."
  (when-let ((symbol (symbol-at-point)))
    (symbol-name symbol)))

(defun embark--keymap-for-type (type)
  "Return the keymap for the given completion type."
  (symbol-value (alist-get type embark-keymap-alist)))

(defun embark--setup ()
  "Setup for next action."
  (setq embark--keymap (embark--keymap-for-type (embark-classify)))
  (setq embark--target
        (run-hook-with-args-until-success 'embark-target-finders))
  (when (minibufferp)
    (setq-local embark--target-buffer
                (window-buffer (minibuffer-selected-window))))
  (add-hook 'minibuffer-setup-hook #'embark--inject)
  (add-hook 'post-command-hook #'embark--cleanup))

(defun embark--keep-alive-p ()
  "Is this command a prefix argument setter?
This is used to keep the transient keymap active."
  (memq this-command
        '(universal-argument
          universal-argument-more
          digit-argument
          negative-argument
          embark-keymap-help)))

(defun embark-keymap-help ()
  "Pop up help buffer for current embark keymap."
  (interactive)
  (help-setup-xref (list #'embark-keymap-help)
                   (called-interactively-p 'interactive))
  (with-output-to-temp-buffer (help-buffer)
    (princ
     (substitute-command-keys
      (format "\\{%s}" (alist-get (embark-classify) embark-keymap-alist))))))

(defun embark--show-indicator ()
  "Show pending action indicator accoring to `embark-indicator'."
  (cond ((stringp embark-indicator)
         (let ((mini (active-minibuffer-window)))
           (if (not mini)
               (message "%s on '%s'" embark-indicator embark--target)
             (setq embark--overlay
                   (make-overlay (point-min)
                                 (minibuffer-prompt-end)
                                 (window-buffer mini)))
             (overlay-put embark--overlay 'before-string
                          (concat embark-indicator " ")))))
        ((functionp embark-indicator)
         (funcall embark-indicator))))

(defmacro embark-after-exit (vars &rest body)
  "Run BODY after exiting all minibuffers.
Make sure the current values of VARS are still valid when running
BODY."
  (declare (indent defun))
  (let ((binds (cl-loop for var in vars collect
                        (list var (make-symbol (symbol-name var))))))
    `(progn
       (run-at-time 0 nil
                    (lambda ,(mapcar #'cadr binds)
                      (setq inhibit-message nil)
                      (let (,@binds)
                        ,@body))
                    ,@vars)
       (setq inhibit-message t)
       (top-level))))

(defun embark--bind-actions (exitp)
  "Set transient keymap with bindings for type-specific actions.
If EXITP is non-nil, exit all minibuffers too."
  (set-transient-map
   embark--keymap
   #'embark--keep-alive-p
   (lambda ()
     (setq embark--keymap nil)
     (run-hooks 'embark-pre-action-hook)
     (when (and exitp
                (not (memq this-command
                           '(embark-cancel embark-undefined))))
       (embark-after-exit
         (this-command prefix-arg embark--command embark--target-buffer)
         (command-execute this-command))))))

(defun embark-act (&optional exitp)
  "Embark upon a minibuffer action.
Bind this command to a key in `minibuffer-local-completion-map'.
If EXITP is non-nil (interactively, if called with a prefix
argument), exit all minibuffers too."
  (interactive "P")
  (embark--setup)
  (unless exitp
    (setq-local enable-recursive-minibuffers t))
  (embark--bind-actions exitp)
  (embark--show-indicator))

(defun embark-exit-and-act (&optional continuep)
  "Exit the minibuffer and embark upon an action.
If CONTINUEP is non-nil (interactively, if called with a prefix
argument), don't actually exit."
  (interactive "P")
  (embark-act (not continuep)))

(defun embark-keymap (binding-alist &optional parent-map)
  "Return keymap with bindings given by BINDING-ALIST.
If PARENT-MAP is non-nil, set it as the parent keymap."
  (let ((map (make-sparse-keymap)))
    (dolist (key-fn binding-alist)
      (pcase-let ((`(,key . ,fn) key-fn))
        (when (stringp key) (setq key (kbd key)))
        (define-key map key fn)))
    (when parent-map
      (set-keymap-parent map parent-map))
    map))

;;; embark occur

(defun embark-first-line-of-docstring (name)
  "Return the first line of the docstring of symbol called NAME.
To be used as an annotation function for symbols in `embark-occur'."
  (when-let* ((symbol (intern name))
              (docstring (if (functionp symbol)
                             (documentation symbol)
                           (documentation-property
                            symbol 'variable-documentation))))
    (car (split-string docstring "\n"))))

(defun embark-file-and-major-mode (name)
  "Return string with file and major mode of buffer called NAME."
  (when-let ((buffer (get-buffer name)))
    (format "%s%s (%s)"
            (if (buffer-modified-p buffer) "*" "")
            (if-let ((file-name (buffer-file-name buffer)))
                (abbreviate-file-name file-name)
              "")
            (buffer-local-value 'major-mode buffer))))

(defun embark-size-and-modification-time (file)
  "Return string with size and modification time of file."
  (let ((attributes (file-attributes file)))
    (format "%7s %s"
            (file-size-human-readable (file-attribute-size attributes))
            (format-time-string "%b %e %k:%M"
             (file-attribute-modification-time attributes)))))

(defun embark-minibuffer-candidates ()
  "Return all current completion candidates from the minibuffer."
  (when (minibufferp)
    (let* ((all (completion-all-completions
                 (minibuffer-contents)
                 minibuffer-completion-table
                 minibuffer-completion-predicate
                 (- (point) (minibuffer-prompt-end))))
           (last (last all)))
      (when last (setcdr last nil))
      all)))

(declare-function dired-get-filename "dired")

(defun embark-dired-candidates ()
  "Return all files shown in dired buffer."
  (when (derived-mode-p 'dired-mode)
    (save-excursion
      (goto-char (point-min))
      (let (files)
        (while (not (eobp))
          (when-let ((file (dired-get-filename t 'no-error-if-not-filep)))
            (push file files))
          (forward-line))
        (nreverse files)))))

(declare-function ibuffer-map-lines-nomodify "ibuffer")

(defun embark-ibuffer-candidates ()
  "Return names of buffers listed in ibuffer buffer."
  (when (derived-mode-p 'ibuffer-mode)
    (let (buffers)
      (ibuffer-map-lines-nomodify
       (lambda (buf _mk)
         (push (buffer-name buf) buffers)))
      (nreverse buffers))))

(defun embark-embark-occur-candidates ()
  "Return candidates in Embark Occur buffer.
This makes `embark-export' work in Embark Occur buffers."
  (when (derived-mode-p 'embark-occur-mode)
    embark-occur-candidates))

(defun embark-completions-buffer-candidates ()
  "Return all candidates in a completions buffer."
  (when (derived-mode-p 'completion-list-mode)
    (save-excursion
      (let (all)
        (next-completion 1)
        (while (not (eobp))
          (push (embark-completion-at-point 'relative-path) all)
          (next-completion 1))
        (nreverse all)))))

(defun embark--action-command (action)
  "Turn an action into a command that performs the action."
  (let ((name (intern (format "embark-action<%s>" action)))
        (fn (lambda ()
              (interactive)
              (setq this-command action)
              (embark--setup)
              (call-interactively action))))
    (fset name fn)
    (when (symbolp action)
      (put name 'function-documentation
           (documentation action)))
    name))

(defvar embark-occur-direct-action-minor-mode-map (make-sparse-keymap)
  "Keymap for direct bindings to embark actions.")

(define-minor-mode embark-occur-direct-action-minor-mode
  "Bind type-specific actions directly (without need for `embark-act')."
  :init-value nil
  :lighter " Act"
  :keymap embark-occur-direct-action-minor-mode-map
  (when embark-occur-direct-action-minor-mode
    ;; must mutate keymap, not make new one
    (let ((action-map (keymap-canonicalize
                       (embark--keymap-for-type embark--type))))
      (dolist (binding (cdr action-map))
        (setcdr binding (embark--action-command (cdr binding))))
      (setcdr embark-occur-direct-action-minor-mode-map
              (cdr action-map)))))

(define-button-type 'embark-occur-entry
  'face 'default
  'action 'embark-occur-select)

(defun embark-occur-select (_entry)
  "Run default action on ENTRY."
  (setq this-command embark--command)
  (embark--setup)
  (call-interactively this-command))

(defvar-local embark-occur-candidates nil
  "List of candidates in current occur buffer.")

(defvar-local embark-occur-view 'list
  "Type of view in occur buffer: `list' or `grid'.")

(define-derived-mode embark-occur-mode tabulated-list-mode "Embark Occur"
  "List of candidates to be acted on.
You should either bind `embark-act' in `embark-occur-mode-map' or
enable `embark-occur-direct-action-minor-mode' in
`embark-occur-mode-hook'.")

(setq embark-occur-mode-map
      (embark-keymap
       '(("a" . embark-act)
         ("A" . embark-occur-direct-action-minor-mode)
         ("M-q" . embark-occur-toggle-view)
         ("v" . embark-occur-toggle-view)
         ("e" . embark-export)
         ("s" . isearch-forward)
         ("n" . next-line)
         ("p" . previous-line)
         ("f" . forward-button)
         ("b" . backward-button)
         ("<right>" . forward-button)
         ("<left>" . backward-button))))

(defun embark-occur--max-width ()
  "Maximum width of any Embark Occur candidate."
  (cl-loop for cand in embark-occur-candidates
           maximize (length cand)))

(defun embark-occur--list-view ()
  "List view of candidates and annotations for Embark Occur buffer."
  (setq embark-occur-view 'list)
  (let ((annotator (alist-get embark--type embark-annotator-alist)))
    (setq tabulated-list-format
          (if annotator
              (let ((width (embark-occur--max-width)))
                `[("Candidate" ,width t) ("Annotation" 0 nil)])
            [("Candidate" 0 t)]))
    (setq tabulated-list-entries
          (mapcar (lambda (cand)
                    (if annotator
                        `(,cand [(,cand type embark-occur-entry)
                                 ,(or (funcall annotator cand) "")])
                      `(,cand [(,cand type embark-occur-entry)])))
                  embark-occur-candidates))))

(defun embark-occur--grid-view ()
  "Grid view of candidates for Embark Occur buffer."
  (setq embark-occur-view 'grid)
  (let* ((width (min (embark-occur--max-width) (floor (window-width) 2)))
         (columns (/ (window-width) width)))
    (setq tabulated-list-format
          (make-vector columns `("Candidate" ,width nil)))
    (setq tabulated-list-entries
          (cl-loop with cands = (copy-tree embark-occur-candidates)
                   while cands
                   collect
                   (list nil
                         (apply #'vector
                                (cl-loop repeat columns
                                         collect
                                         `(,(or (pop cands) "")
                                           type embark-occur-entry))))))))

(defun embark-occur-toggle-view ()
  "Toggle between list and grid views of Embark Occur buffer."
  (interactive)
  (if (eq embark-occur-view 'list)
      (embark-occur--grid-view)
    (embark-occur--list-view))
  (tabulated-list-print))

(defun embark-occur (&optional initial-view)
  "Create a buffer with current candidates for further action.
Optionally start in INITIAL-VIEW (either `list' or `grid')
instead of what `embark-occur-initial-view-alist' specifies.

Interactively, \\[universal-argument] requests grid view and a
numeric argument of 1 requests list view."
  (interactive
   (list (pcase current-prefix-arg
           ('(4) 'grid)
           (1 'list))))
  (ignore (embark-target)) ; allow use from embark-act
  (let ((candidates (if (consp initial-view)
                        ;; embark-export passed us the list of
                        ;; candidates, might as well use it
                        initial-view
                      (run-hook-with-args-until-success
                       'embark-candidate-collectors)))
        (buffer (generate-new-buffer "*Embark Occur*")))
    (when (consp initial-view) ; was really candidate list
      (setq initial-view nil))
    (with-current-buffer buffer
      (embark-occur-mode)
      (setq embark-occur-candidates candidates))
    (embark--cache-info buffer)
    (embark-after-exit ()
      (pop-to-buffer buffer)
      ;; wait so grid view knows the window width
      (let ((initial
             (or
              initial-view
              (alist-get embark--type embark-occur-initial-view-alist)
              (alist-get t embark-occur-initial-view-alist)
              'list)))
        (if (eq initial 'list)
            (embark-occur--list-view)
          (embark-occur--grid-view)))
      (tabulated-list-print))))

(defun embark-export ()
  "Create a type-specific buffer to manage current candidates.
The variable `embark-exporters-alist' controls how to make the
buffer for each type of completion."
  (interactive)
  (ignore (embark-target)) ; allow use from embark-act
  (let* ((candidates (run-hook-with-args-until-success
                      'embark-candidate-collectors))
         (type (embark-classify))
         (dir (embark--default-directory))
         (exporter (or (alist-get type embark-exporters-alist)
                       (alist-get t embark-exporters-alist))))
    (if (eq exporter 'embark-occur)
        ;; just run it now, so the necessary info is still there
        ;; at least we already have the candidates gathered.
        (funcall #'embark-occur candidates)
      (embark-after-exit ()
        (let ((default-directory dir))  ; dired needs this info
          (funcall exporter candidates))))))

(defun embark-ibuffer (buffers)
  "Create an ibuffer buffer listing BUFFERS."
  (ibuffer t "*Embark Ibuffer*"
           `((predicate . (member (buffer-name) ',buffers)))))

(declare-function dired-check-switches "dired")

(defun embark-dired (files)
  "Create a dired buffer listing FILES."
  (setq files (mapcar #'directory-file-name files))
  (when (dired-check-switches dired-listing-switches "A" "almost-all")
    (setq files (cl-remove-if-not
                 (lambda (path)
                   (let ((file (file-name-nondirectory path)))
                     (unless (or (string= file ".") (string= file ".."))
                       path)))
                 files)))
  (dired (cons default-directory files))
  (rename-buffer (format "*Embark Export Dired %s*" default-directory)))

;;; custom actions

(defun embark-default-action ()
  "Default action.
This is whatever command opened the minibuffer in the first place."
  (interactive)
  (setq this-command embark--command)   ; so the proper hooks apply
  (call-interactively embark--command))

(defun embark-insert ()
  "Insert embark target at point into the previously selected buffer."
  (interactive)
  (with-current-buffer embark--target-buffer
    (insert (substring-no-properties (embark-target)))))

(defun embark-save ()
  "Save embark target in the kill ring."
  (interactive)
  (kill-new (substring-no-properties (embark-target))))

(defun embark-cancel ()
  "Cancel current action."
  (interactive)
  (ignore (embark-target)))

(defun embark-undefined ()
  "Cancel action and show an error message."
  (interactive)
  (ignore (embark-target))
  (embark--cleanup) ; remove overlay immediately
  (minibuffer-message "Unknown embark action"))

(defun embark-eshell-in-directory ()
  "Run eshell in directory of embark target."
  (interactive)
  (let ((default-directory
          (file-name-directory
           (expand-file-name
            (embark-target)))))
    (eshell '(4))))

(defun embark-describe-symbol ()
  "Describe embark target as a symbol."
  (interactive)
  (describe-symbol (intern (embark-target))))

(defun embark-find-definition ()
  "Find definition of embark target."
  (interactive)
  (let ((symbol (intern (embark-target))))
    (cond
     ((fboundp symbol) (find-function symbol))
     ((boundp symbol) (find-variable symbol)))))

(defun embark-info-emacs-command ()
  "Go to the Info node in the Emacs manual for embark target."
  (interactive)
  (Info-goto-emacs-command-node (embark-target)))

(defun embark-info-lookup-symbol ()
  "Display the definition of embark target, from the relevant manual."
  (interactive)
  (info-lookup-symbol (intern (embark-target)) 'emacs-lisp-mode))

(defun embark-rename-buffer ()
  "Rename embark target buffer."
  (interactive)
  (with-current-buffer (embark-target)
    (call-interactively #'rename-buffer)))

(declare-function package-desc-p "package")
(declare-function package--from-builtin "package")
(declare-function package-desc-extras "package")
(defvar package--builtins)
(defvar package-alist)
(defvar package-archive-contents)

(defun embark-browse-package-url ()
  "Open homepage for embark target package with `browse-url'."
  (interactive)
  (if-let ((pkg (intern (embark-target)))
           (desc (or ; found this in `describe-package-1'
                  (if (package-desc-p pkg) pkg)
                  (car (alist-get pkg package-alist))
                  (if-let ((built-in (assq pkg package--builtins)))
                      (package--from-builtin built-in)
                    (car (alist-get pkg package-archive-contents)))))
           (url (alist-get :url (package-desc-extras desc))))
      (browse-url url)
    (message "No homepage found for `%s'" pkg)))

(defun embark-insert-relative-path ()
  "Insert relative path to embark target.
The insert path is relative to the previously selected buffer's
`default-directory'."
  (interactive)
  (with-current-buffer embark--target-buffer
    (insert (file-relative-name (embark-target)))))

(defun embark-save-relative-path ()
  "Save the relative path to embark target to kill ring.
The insert path is relative to the previously selected buffer's
`default-directory'."
  (interactive)
  (kill-new (file-relative-name (embark-target))))

(defun embark-shell-command-on-buffer (buffer command &optional replace)
  "Run shell COMMAND on contents of BUFFER.
Called with \\[universal-argument], replace contents of buffer
with command output. For replacement behaviour see
`shell-command-dont-erase-buffer' setting."
  (interactive
   (list
    (read-buffer "Buffer: " nil t)
    (read-shell-command "Shell command: ")
    current-prefix-arg))
  (with-current-buffer buffer
    (shell-command-on-region (point-min) (point-max)
                             command
                             (and replace (current-buffer)))))

(defun embark-open-externally (file)
  "Open file using system's default application."
  (interactive "fOpen: ")
  (if (and (eq system-type 'windows-nt)
           (fboundp 'w32-shell-execute))
      (w32-shell-execute "open" (expand-file-name file))
    (call-process (pcase system-type
                    ('darwin "open")
                    ('cygwin "cygstart")
                    (_ "xdg-open"))
                  nil 0 nil
                  (expand-file-name file))))

(defun embark-bury-buffer ()
  "Bury embark target buffer."
  (interactive)
  (if-let ((buf (embark-target))
           (win (get-buffer-window buf)))
      (with-selected-window win
        (bury-buffer))
    (bury-buffer)))

(defun embark-kill-buffer-and-window ()
  "Kill embark target buffer and delete its window."
  (interactive)
  (when-let ((win (get-buffer-window (embark-target))))
    (with-selected-window win
      (kill-buffer-and-window))))

;;; setup hooks for actions

(defun embark--shell-prep ()
  "Prepare target for use as argument for a shell command.
This quotes the spaces, inserts an extra space at the beginning
and leaves the point to the left of it."
  (let ((contents (minibuffer-contents)))
    (delete-minibuffer-contents)
    (insert " " (shell-quote-wildcard-pattern contents))
    (beginning-of-line)))

(defun embark--eval-prep ()
  "If target is: a variable, skip edit; a function, wrap in parens."
  (if (not (fboundp (intern (minibuffer-contents))))
      (setq unread-command-events '(13))
    (beginning-of-line)
    (insert "(")
    (end-of-line)
    (insert ")")
    (backward-char)))

;;; keymaps

(defvar embark-general-map
  (embark-keymap
   '(("i" . embark-insert)
     ("w" . embark-save)
     ("RET" . embark-default-action)
     ("C-g" . embark-cancel)
     ("C-h" . embark-keymap-help)
     ([remap self-insert-command] . embark-undefined)
     ("C-u" . universal-argument))
   universal-argument-map))

(defvar embark-file-map
  (embark-keymap
   '(("f" . find-file)
     ("o" . find-file-other-window)
     ("d" . delete-file)
     ("D" . delete-directory)
     ("r" . rename-file)
     ("c" . copy-file)
     ("!" . shell-command)
     ("&" . async-shell-command)
     ("=" . ediff-files)
     ("e" . embark-eshell-in-directory)
     ("+" . make-directory)
     ("I" . embark-insert-relative-path)
     ("W" . embark-save-relative-path)
     ("x" . embark-open-externally))
   embark-general-map))

(defvar embark-buffer-map
  (embark-keymap
   '(("k" . kill-buffer)
     ("b" . switch-to-buffer)
     ("o" . switch-to-buffer-other-window)
     ("z" . embark-bury-buffer)
     ("q" . embark-kill-buffer-and-window)
     ("r" . embark-rename-buffer)
     ("=" . ediff-buffers)
     ("|" . embark-shell-command-on-buffer))
   embark-general-map))

(defvar embark-symbol-map
  (embark-keymap
   '(("h" . embark-describe-symbol)
     ("c" . embark-info-emacs-command)
     ("s" . embark-info-lookup-symbol)
     ("d" . embark-find-definition)
     ("e" . eval-expression))
   embark-general-map))

(defvar embark-package-map
  (embark-keymap
   '(("h" . describe-package)
     ("i" . package-install)
     ("d" . package-delete)
     ("r" . package-reinstall)
     ("u" . embark-browse-package-url))
   embark-general-map))

(provide 'embark)
;;; embark.el ends here
