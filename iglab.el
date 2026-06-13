;;; iglab.el --- GitLab issue dashboard helpers -*- lexical-binding: t; -*-

;; This file is intentionally small: Python owns sync, SQLite, and rendering.

;;; Code:

(require 'browse-url)
(require 'cl-lib)
(require 'json)
(require 'org)
(require 'seq)
(require 'subr-x)

(defgroup iglab nil
  "Local GitLab issue dashboard backed by SQLite and Org."
  :group 'tools)

(defcustom iglab-python-command "python"
  "Python executable used to run the iglab CLI."
  :type 'string
  :group 'iglab)

(defcustom iglab-cli-module "iglab_cli"
  "Python module name for the iglab CLI."
  :type 'string
  :group 'iglab)

(defcustom iglab-config-file nil
  "Optional path to an iglab JSON config file."
  :type '(choice (const :tag "Unset" nil) file)
  :group 'iglab)

(defcustom iglab-database-file (expand-file-name "iglab/cache.sqlite" user-emacs-directory)
  "SQLite cache file used by iglab."
  :type 'file
  :group 'iglab)

(defcustom iglab-org-file (expand-file-name "iglab/gitlab-issues.org" user-emacs-directory)
  "Org file rendered from the local iglab SQLite cache."
  :type 'file
  :group 'iglab)

(defcustom iglab-gitlab-host nil
  "Base URL of the GitLab instance, for example https://gitlab.internal."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'iglab)

(defcustom iglab-gitlab-token nil
  "Private GitLab access token. Keep this in private local configuration."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'iglab)

(defcustom iglab-root-groups nil
  "Top-level GitLab groups to sync recursively."
  :type '(repeat string)
  :group 'iglab)

(defvar iglab--running-process nil
  "Current asynchronous iglab process, if any.")

(defvar-local iglab-dashboard--issues-by-id nil
  "Hash table of dashboard issue objects keyed by custom ID.")

(defvar-local iglab-dashboard--note-summaries nil
  "Hash table of Org note summaries keyed by custom ID.")

(defvar-local iglab-dashboard-state-filter "opened"
  "Current dashboard state filter.")

(defconst iglab-dashboard--columns
  '((state . 0)
    (iid . 8)
    (title . 16)
    (assignee . 60)
    (labels . 76)
    (note . 116)
    (updated . 160)
    (project . 182))
  "Dashboard column start positions.")

(defface iglab-dashboard-priority-label
  '((t :inherit font-lock-warning-face))
  "Face for priority labels."
  :group 'iglab)

(defface iglab-dashboard-status-label
  '((t :inherit font-lock-keyword-face))
  "Face for status labels."
  :group 'iglab)

(defface iglab-dashboard-type-label
  '((t :inherit font-lock-type-face))
  "Face for type labels."
  :group 'iglab)

(defface iglab-dashboard-muted-label
  '((t :inherit shadow))
  "Face for less important labels."
  :group 'iglab)

(defun iglab--base-command ()
  "Return the base Python CLI command as a list."
  (append
   (list iglab-python-command "-m" iglab-cli-module)
   (when iglab-config-file
     (list "--config" iglab-config-file))
   (list "--db" iglab-database-file)))

(defun iglab--call (&rest args)
  "Run iglab CLI with ARGS."
  (let ((command (append (iglab--base-command) args)))
    (let ((process-environment
           (append
            (iglab--environment)
            process-environment)))
      (with-current-buffer (get-buffer-create "*iglab*")
        (erase-buffer)
        (let ((exit-code (apply #'call-process (car command) nil t t (cdr command))))
          (unless (zerop exit-code)
            (display-buffer (current-buffer))
            (error "iglab command failed with exit code %s" exit-code))
          (buffer-string))))))

(defun iglab--json-call (&rest args)
  "Run iglab CLI with ARGS and parse its JSON output."
  (let ((json-array-type 'list)
        (json-object-type 'alist)
        (json-key-type 'symbol))
    (json-read-from-string (apply #'iglab--call args))))

(defun iglab--start-process (name args)
  "Start asynchronous iglab process NAME with ARGS."
  (when (process-live-p iglab--running-process)
    (error "An iglab process is already running"))
  (let* ((command (append (iglab--base-command) args))
         (buffer (get-buffer-create "*iglab*"))
         (process-environment
          (append
           (iglab--environment)
           process-environment)))
    (with-current-buffer buffer
      (erase-buffer)
      (insert "$ " (mapconcat #'identity command " ") "\n\n"))
    (setq iglab--running-process
          (make-process
           :name name
           :buffer buffer
           :command command
           :noquery t
           :filter #'iglab--process-filter
           :sentinel #'iglab--process-sentinel))
    (display-buffer buffer)
    (message "Started %s" name)
    iglab--running-process))

(defun iglab--process-filter (process output)
  "Append PROCESS OUTPUT and echo progress."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (goto-char (point-max))
      (insert output)))
  (dolist (line (split-string output "\n" t))
    (unless (string-empty-p (string-trim line))
      (message "iglab: %s" (string-trim line)))))

(defun iglab--process-sentinel (process event)
  "Report PROCESS completion EVENT."
  (when (memq (process-status process) '(exit signal))
    (let ((exit-code (process-exit-status process)))
      (setq iglab--running-process nil)
      (if (zerop exit-code)
          (message "iglab finished")
        (message "iglab failed with exit code %s: %s" exit-code (string-trim event))))))

(defun iglab--environment ()
  "Return environment variables passed to the Python CLI."
  (append
   (when iglab-gitlab-host
     (list (concat "IGLAB_GITLAB_HOST=" iglab-gitlab-host)))
   (when iglab-gitlab-token
     (list (concat "IGLAB_GITLAB_TOKEN=" iglab-gitlab-token)))
   (when iglab-root-groups
     (list (concat "IGLAB_ROOT_GROUPS=" (mapconcat #'identity iglab-root-groups ";"))))))

;;;###autoload
(defun iglab-init-db ()
  "Initialize the iglab SQLite cache."
  (interactive)
  (message "%s" (string-trim (iglab--call "init-db"))))

;;;###autoload
(defun iglab-sync (&optional scope)
  "Run iglab sync for SCOPE.
SCOPE defaults to active. This starts an asynchronous Python process and
streams progress to the *iglab* buffer."
  (interactive)
  (let ((resolved-scope (or scope "active")))
    (iglab--start-process "iglab-sync" (list "sync" resolved-scope))))

;;;###autoload
(defun iglab-cancel ()
  "Cancel the running asynchronous iglab process."
  (interactive)
  (if (process-live-p iglab--running-process)
      (progn
        (kill-process iglab--running-process)
        (setq iglab--running-process nil)
        (message "iglab process cancelled"))
    (message "No iglab process is running")))

;;;###autoload
(defun iglab-render-org ()
  "Render `iglab-org-file' from the local SQLite cache."
  (interactive)
  (message "%s" (string-trim (iglab--call "render-org" "--output" iglab-org-file)))
  (when-let* ((buffer (find-buffer-visiting iglab-org-file)))
    (with-current-buffer buffer
      (revert-buffer :ignore-auto :noconfirm))))

;;;###autoload
(defun iglab-open-org ()
  "Open the rendered iglab Org file."
  (interactive)
  (find-file iglab-org-file))

(defvar iglab-dashboard-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'iglab-dashboard-open-org-issue)
    (define-key map (kbd "g") #'iglab-dashboard-refresh)
    (define-key map (kbd "L") #'iglab-dashboard-show-labels)
    (define-key map (kbd "b") #'iglab-dashboard-browse-issue)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `iglab-dashboard-mode'.")

(define-derived-mode iglab-dashboard-mode special-mode "iglab-dashboard"
  "Major mode for browsing cached GitLab issues."
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box)
  (buffer-face-set 'fixed-pitch))

;;;###autoload
(defun iglab-dashboard ()
  "Open the iglab issue dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*iglab-dashboard*")))
    (with-current-buffer buffer
      (iglab-dashboard-mode)
      (setq iglab-dashboard-state-filter "opened")
      (iglab-dashboard-refresh))
    (pop-to-buffer buffer)))

(defun iglab-dashboard-refresh ()
  "Refresh the dashboard from SQLite and Org note summaries."
  (interactive)
  (let* ((issues (iglab--json-call "query" "dashboard" "--state" iglab-dashboard-state-filter))
         (notes (iglab-dashboard--org-note-summaries))
         (by-id (make-hash-table :test 'equal)))
    (dolist (issue issues)
      (puthash (iglab-dashboard--issue-custom-id issue) issue by-id))
    (setq iglab-dashboard--issues-by-id by-id)
    (setq iglab-dashboard--note-summaries notes)
    (iglab-dashboard--render issues)
    (message "iglab-dashboard: %s issues" (length issues))))

(defun iglab-dashboard-open-org-issue ()
  "Jump to the current issue in `iglab-org-file'."
  (interactive)
  (let* ((issue (iglab-dashboard--current-issue))
         (custom-id (iglab-dashboard--issue-custom-id issue)))
    (unless (file-readable-p iglab-org-file)
      (user-error "Org file is not readable; run M-x iglab-render-org"))
    (find-file iglab-org-file)
    (goto-char (point-min))
    (unless (search-forward (format ":CUSTOM_ID: %s" custom-id) nil t)
      (user-error "Issue not found in org file; run M-x iglab-render-org"))
    (org-back-to-heading t)
    (recenter)))

(defun iglab-dashboard-browse-issue ()
  "Open the current issue in a browser."
  (interactive)
  (let* ((issue (iglab-dashboard--current-issue))
         (url (iglab-dashboard--alist-get 'web_url issue)))
    (if (string-empty-p (or url ""))
        (user-error "Current issue has no GitLab URL")
      (browse-url url))))

(defun iglab-dashboard-show-labels ()
  "Show all labels for the current issue."
  (interactive)
  (let* ((issue (iglab-dashboard--current-issue))
         (labels (alist-get 'labels issue)))
    (message "%s" (if labels (string-join labels ", ") "No labels"))))

(defun iglab-dashboard--render (issues)
  "Render ISSUES into the current dashboard buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (iglab-dashboard--insert-header)
    (dolist (issue issues)
      (iglab-dashboard--insert-row issue))
    (goto-char (point-min))
    (forward-line 2)))

(defun iglab-dashboard--insert-header ()
  "Insert the dashboard header."
  (iglab-dashboard--insert-cell "State" 'state nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "IID" 'iid nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "Title" 'title nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "Assignee" 'assignee nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "Labels" 'labels nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "Note" 'note nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "Updated" 'updated nil 'font-lock-keyword-face)
  (iglab-dashboard--insert-cell "Project" 'project nil 'font-lock-keyword-face)
  (insert "\n")
  (insert (propertize (make-string 220 ?-) 'face 'shadow) "\n"))

(defun iglab-dashboard--insert-row (issue)
  "Insert one dashboard row for ISSUE."
  (let* ((custom-id (iglab-dashboard--issue-custom-id issue))
         (note (gethash custom-id iglab-dashboard--note-summaries "")))
    (iglab-dashboard--insert-cell (iglab-dashboard--alist-get 'todo issue) 'state custom-id nil)
    (iglab-dashboard--insert-cell (format "#%s" (iglab-dashboard--alist-get 'iid issue)) 'iid custom-id nil)
    (iglab-dashboard--insert-cell (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'title issue)) 'title custom-id nil)
    (iglab-dashboard--insert-cell (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'assignee issue)) 'assignee custom-id nil)
    (iglab-dashboard--insert-cell (iglab-dashboard--format-labels (alist-get 'labels issue)) 'labels custom-id nil)
    (iglab-dashboard--insert-cell (iglab-dashboard--cell-text note) 'note custom-id 'shadow)
    (iglab-dashboard--insert-cell (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'updated_at issue)) 'updated custom-id nil)
    (iglab-dashboard--insert-cell (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'project issue)) 'project custom-id 'shadow)
    (insert "\n")))

(defun iglab-dashboard--insert-cell (text column custom-id face)
  "Insert TEXT at COLUMN and attach CUSTOM-ID to it."
  (let* ((start (point))
         (next-column (iglab-dashboard--next-column column))
         (max-width (and next-column (- next-column (alist-get column iglab-dashboard--columns) 2)))
         (display-text (if max-width
                           (truncate-string-to-width text max-width nil nil "...")
                         text)))
    (when (< (current-column) (alist-get column iglab-dashboard--columns))
      (insert (propertize " " 'display `(space :align-to ,(alist-get column iglab-dashboard--columns)))))
    (insert display-text)
    (when custom-id
      (add-text-properties start (point) `(iglab-dashboard-id ,custom-id mouse-face highlight)))
    (when face
      (add-text-properties start (point) `(face ,face)))))

(defun iglab-dashboard--next-column (column)
  "Return the column after COLUMN, or nil for the final column."
  (cadr (member (alist-get column iglab-dashboard--columns)
                (mapcar #'cdr iglab-dashboard--columns))))

(defun iglab-dashboard--current-issue ()
  "Return the issue at point."
  (let* ((custom-id (or (get-text-property (point) 'iglab-dashboard-id)
                        (get-text-property (line-beginning-position) 'iglab-dashboard-id)
                        (save-excursion
                          (beginning-of-line)
                          (let ((end (line-end-position))
                                found)
                            (while (and (not found) (< (point) end))
                              (setq found (get-text-property (point) 'iglab-dashboard-id))
                              (forward-char 1))
                            found))))
         (issue (and custom-id (gethash custom-id iglab-dashboard--issues-by-id))))
    (unless issue
      (user-error "No issue on current line"))
    issue))

(defun iglab-dashboard--issue-custom-id (issue)
  "Return ISSUE custom ID."
  (iglab-dashboard--alist-get 'custom_id issue))

(defun iglab-dashboard--alist-get (key alist)
  "Return KEY from ALIST, or an empty string when missing."
  (or (alist-get key alist) ""))

(defun iglab-dashboard--cell-text (text)
  "Return TEXT normalized for one dashboard table cell."
  (string-trim (replace-regexp-in-string "[\r\n\t]+" " " (format "%s" (or text "")))))

(defun iglab-dashboard--format-labels (labels)
  "Return a compact propertized label string for LABELS."
  (let* ((labels (if (listp labels) labels nil))
         (sorted (sort (copy-sequence labels) #'iglab-dashboard--label-less-p))
         (visible (seq-take sorted 3))
         (remaining (- (length sorted) (length visible)))
         (parts (mapcar #'iglab-dashboard--propertize-label visible)))
    (when (> remaining 0)
      (setq parts (append parts (list (propertize (format "+%s" remaining) 'face 'iglab-dashboard-muted-label)))))
    (string-join parts " ")))

(defun iglab-dashboard--label-less-p (left right)
  "Return non-nil when label LEFT should sort before RIGHT."
  (< (iglab-dashboard--label-rank left) (iglab-dashboard--label-rank right)))

(defun iglab-dashboard--label-rank (label)
  "Return display rank for LABEL."
  (cond
   ((string-match-p "\\`\\(P[0-9]\\|priority::\\)" label) 0)
   ((string-match-p "\\`\\(status::\\|blocked\\|doing\\)" label) 1)
   ((string-match-p "\\`\\(type::\\|bug\\|feature\\)" label) 2)
   (t 3)))

(defun iglab-dashboard--propertize-label (label)
  "Return LABEL with a category face."
  (propertize
   label
   'face
   (pcase (iglab-dashboard--label-rank label)
     (0 'iglab-dashboard-priority-label)
     (1 'iglab-dashboard-status-label)
     (2 'iglab-dashboard-type-label)
     (_ 'iglab-dashboard-muted-label))))

(defun iglab-dashboard--org-note-summaries ()
  "Return a hash table of Org local note summaries keyed by custom ID."
  (let ((summaries (make-hash-table :test 'equal)))
    (when (file-readable-p iglab-org-file)
      (with-temp-buffer
        (insert-file-contents iglab-org-file)
        (goto-char (point-min))
        (while (re-search-forward "^\\*\\*\\*\\s-+" nil t)
          (let* ((heading-start (line-beginning-position))
                 (block-end (save-excursion
                              (if (re-search-forward "^\\*\\{1,3\\}\\s-+" nil t)
                                  (line-beginning-position)
                                (point-max))))
                 (custom-id nil)
                 (body-start nil))
            (save-excursion
              (goto-char heading-start)
              (when (re-search-forward "^:CUSTOM_ID:\\s-*\\(.+?\\)\\s-*$" block-end t)
                (setq custom-id (match-string 1))
                (when (re-search-forward "^:END:\\s-*$" block-end t)
                  (setq body-start (point)))))
            (when (and custom-id body-start)
              (let ((summary (iglab-dashboard--first-note-paragraph
                              (buffer-substring-no-properties body-start block-end))))
                (unless (string-empty-p summary)
                  (puthash custom-id summary summaries))))))))
    summaries))

(defun iglab-dashboard--first-note-paragraph (text)
  "Return the first non-empty paragraph summary from TEXT."
  (let ((lines (split-string text "\n"))
        (paragraph nil)
        (in-drawer nil)
        (done nil))
    (while (and lines (not done))
      (let ((line (string-trim (pop lines))))
        (cond
         (in-drawer
          (when (string= line ":END:")
            (setq in-drawer nil)))
         ((string-empty-p line)
          (when paragraph
            (setq done t)))
         ((string-match-p "\\`:[[:alnum:]_@#%]+:\\'" line)
          (if paragraph
              (setq done t)
            (setq in-drawer t)))
         ((string-match-p "\\`\\(SCHEDULED:\\|DEADLINE:\\|CLOSED:\\|CLOCK:\\)" line)
          nil)
         (t
          (push line paragraph)))))
    (iglab-dashboard--truncate (string-join (nreverse paragraph) " ") 120)))

(defun iglab-dashboard--truncate (text max-length)
  "Return TEXT truncated to MAX-LENGTH characters."
  (if (> (length text) max-length)
      (concat (substring text 0 (max 0 (- max-length 3))) "...")
    text))

(with-eval-after-load 'evil
  (evil-set-initial-state 'iglab-dashboard-mode 'normal)
  (evil-define-key 'normal iglab-dashboard-mode-map
    (kbd "RET") #'iglab-dashboard-open-org-issue
    (kbd "g") #'iglab-dashboard-refresh
    (kbd "L") #'iglab-dashboard-show-labels
    (kbd "b") #'iglab-dashboard-browse-issue
    (kbd "q") #'quit-window))

(provide 'iglab)

;;; iglab.el ends here
