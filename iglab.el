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

(defcustom iglab-project-paths nil
  "Specific GitLab project paths to sync in addition to `iglab-root-groups'."
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

(defvar-local iglab-dashboard--filters nil
  "Current dashboard filters as a plist.")

(defvar-local iglab-dashboard--sort-key 'updated
  "Current dashboard sort key.")

(defvar-local iglab-dashboard--sort-descending t
  "Non-nil means sort dashboard rows descending.")

(defcustom iglab-dashboard-columns
  '((state "State" 8 t)
    (iid "IID" 8 t)
    (title "Title" 44 t)
    (assignee "Assignee" 16 t)
    (labels "Labels" 40 t)
    (note "Note" 44 t)
    (updated "Updated" 22 t)
    (project "Project" 36 t))
  "Dashboard columns.
Each item is (KEY TITLE WIDTH VISIBLE). WIDTH is measured in display
columns and controls the usable text width for that column."
  :type '(repeat
          (list
           (symbol :tag "Key")
           (string :tag "Title")
           (integer :tag "Width")
           (boolean :tag "Visible")))
  :group 'iglab)

(defcustom iglab-dashboard-column-gap 2
  "Number of display columns between dashboard columns."
  :type 'integer
  :group 'iglab)

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
     (list (concat "IGLAB_ROOT_GROUPS=" (mapconcat #'identity iglab-root-groups ";"))))
   (when iglab-project-paths
     (list (concat "IGLAB_PROJECT_PATHS=" (mapconcat #'identity iglab-project-paths ";"))))))

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
    (define-key map (kbd "o") #'iglab-dashboard-sort)
    (define-key map (kbd "/") #'iglab-dashboard-filter-text)
    (define-key map (kbd "s") #'iglab-dashboard-filter-state)
    (define-key map (kbd "a") #'iglab-dashboard-filter-assignee)
    (define-key map (kbd "p") #'iglab-dashboard-filter-project)
    (define-key map (kbd "l") #'iglab-dashboard-filter-label)
    (define-key map (kbd "C") #'iglab-dashboard-clear-filters)
    (define-key map (kbd "L") #'iglab-dashboard-show-labels)
    (define-key map (kbd "T") #'iglab-dashboard-toggle-column)
    (define-key map (kbd "W") #'iglab-dashboard-set-column-width)
    (define-key map (kbd "b") #'iglab-dashboard-browse-issue)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `iglab-dashboard-mode'.")

(define-derived-mode iglab-dashboard-mode special-mode "iglab-dashboard"
  "Major mode for browsing cached GitLab issues."
  (setq-local truncate-lines t)
  (setq-local cursor-type 'box)
  (setq-local show-trailing-whitespace nil)
  (buffer-face-set 'fixed-pitch))

;;;###autoload
(defun iglab-dashboard ()
  "Open the iglab issue dashboard."
  (interactive)
  (let ((buffer (get-buffer-create "*iglab-dashboard*")))
    (with-current-buffer buffer
      (iglab-dashboard-mode)
      (setq iglab-dashboard-state-filter "opened")
      (setq iglab-dashboard--filters nil)
      (setq iglab-dashboard--sort-key 'updated)
      (setq iglab-dashboard--sort-descending t)
      (iglab-dashboard-refresh))
    (pop-to-buffer buffer)))

(defun iglab-dashboard-refresh ()
  "Refresh the dashboard from SQLite and Org note summaries."
  (interactive)
  (let* ((issues (iglab--json-call "query" "dashboard" "--state" iglab-dashboard-state-filter))
         (notes (iglab-dashboard--org-note-summaries))
         (by-id (make-hash-table :test 'equal))
         (visible-issues nil))
    (dolist (issue issues)
      (puthash (iglab-dashboard--issue-custom-id issue) issue by-id))
    (setq iglab-dashboard--issues-by-id by-id)
    (setq iglab-dashboard--note-summaries notes)
    (setq visible-issues (iglab-dashboard--sort-issues (iglab-dashboard--filter-issues issues)))
    (iglab-dashboard--render visible-issues)
    (message "iglab-dashboard: %s/%s issues%s"
             (length visible-issues)
             (length issues)
             (iglab-dashboard--status-suffix))))

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

(defun iglab-dashboard-sort (column)
  "Sort dashboard by COLUMN.
Selecting the current sort column toggles ascending/descending order."
  (interactive (list (iglab-dashboard--read-column "Sort by column: ")))
  (if (eq column iglab-dashboard--sort-key)
      (setq iglab-dashboard--sort-descending (not iglab-dashboard--sort-descending))
    (setq iglab-dashboard--sort-key column)
    (setq iglab-dashboard--sort-descending (memq column '(updated iid))))
  (iglab-dashboard-refresh))

(defun iglab-dashboard-filter-state (state)
  "Filter dashboard by issue STATE."
  (interactive
   (list (completing-read "State: " '("opened" "closed" "all") nil t nil nil iglab-dashboard-state-filter)))
  (setq iglab-dashboard-state-filter state)
  (iglab-dashboard-refresh))

(defun iglab-dashboard-filter-assignee (assignee)
  "Filter dashboard by ASSIGNEE substring."
  (interactive (list (read-string "Assignee contains (empty clears): " (plist-get iglab-dashboard--filters :assignee))))
  (iglab-dashboard--set-filter :assignee assignee)
  (iglab-dashboard-refresh))

(defun iglab-dashboard-filter-project (project)
  "Filter dashboard by PROJECT substring."
  (interactive (list (read-string "Project contains (empty clears): " (plist-get iglab-dashboard--filters :project))))
  (iglab-dashboard--set-filter :project project)
  (iglab-dashboard-refresh))

(defun iglab-dashboard-filter-label (label)
  "Filter dashboard by LABEL substring."
  (interactive (list (read-string "Label contains (empty clears): " (plist-get iglab-dashboard--filters :label))))
  (iglab-dashboard--set-filter :label label)
  (iglab-dashboard-refresh))

(defun iglab-dashboard-filter-text (text)
  "Filter dashboard by TEXT across title, note, project, assignee, and labels."
  (interactive (list (read-string "Search text (empty clears): " (plist-get iglab-dashboard--filters :text))))
  (iglab-dashboard--set-filter :text text)
  (iglab-dashboard-refresh))

(defun iglab-dashboard-clear-filters ()
  "Clear dashboard filters and restore the default opened-state view."
  (interactive)
  (setq iglab-dashboard-state-filter "opened")
  (setq iglab-dashboard--filters nil)
  (iglab-dashboard-refresh))

(defun iglab-dashboard-toggle-column (column)
  "Toggle dashboard COLUMN visibility."
  (interactive (list (iglab-dashboard--read-column "Toggle column: ")))
  (setq iglab-dashboard-columns
        (mapcar
         (lambda (spec)
           (if (eq (iglab-dashboard--column-key spec) column)
               (list (nth 0 spec) (nth 1 spec) (nth 2 spec) (not (nth 3 spec)))
             spec))
         iglab-dashboard-columns))
  (iglab-dashboard-refresh))

(defun iglab-dashboard-set-column-width (column width)
  "Set dashboard COLUMN WIDTH and refresh."
  (interactive
   (let* ((column (iglab-dashboard--read-column "Set width for column: "))
          (current (iglab-dashboard--column-width (iglab-dashboard--column-spec column))))
     (list column (read-number (format "Width for %s: " column) current))))
  (when (< width 4)
    (user-error "Column width must be at least 4"))
  (setq iglab-dashboard-columns
        (mapcar
         (lambda (spec)
           (if (eq (iglab-dashboard--column-key spec) column)
               (list (nth 0 spec) (nth 1 spec) width (nth 3 spec))
             spec))
         iglab-dashboard-columns))
  (iglab-dashboard-refresh))

(defun iglab-dashboard--render (issues)
  "Render ISSUES into the current dashboard buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (iglab-dashboard--insert-status-line (length issues))
    (iglab-dashboard--insert-header)
    (dolist (issue issues)
      (iglab-dashboard--insert-row issue))
    (goto-char (point-min))
    (forward-line 3)))

(defun iglab-dashboard--insert-status-line (count)
  "Insert dashboard status line for COUNT visible rows."
  (insert
   (propertize
    (format "Rows: %s  State: %s  Sort: %s %s%s"
            count
            iglab-dashboard-state-filter
            iglab-dashboard--sort-key
            (if iglab-dashboard--sort-descending "desc" "asc")
            (iglab-dashboard--status-suffix))
    'face
    'shadow)
   "\n"))

(defun iglab-dashboard--insert-header ()
  "Insert the dashboard header."
  (dolist (column (iglab-dashboard--visible-columns))
    (iglab-dashboard--insert-cell
     (iglab-dashboard--column-title (car column))
     (car column)
     nil
     'font-lock-keyword-face
     (cdr column)))
  (insert "\n")
  (insert (propertize (make-string (max 1 (iglab-dashboard--total-width)) ?-) 'face 'shadow) "\n"))

(defun iglab-dashboard--insert-row (issue)
  "Insert one dashboard row for ISSUE."
  (let* ((custom-id (iglab-dashboard--issue-custom-id issue))
         (note (gethash custom-id iglab-dashboard--note-summaries "")))
    (dolist (column (iglab-dashboard--visible-columns))
      (let ((key (car column)))
        (iglab-dashboard--insert-cell
         (iglab-dashboard--cell-value key issue note)
         key
         custom-id
         (iglab-dashboard--cell-face key)
         (cdr column))))
    (insert "\n")))

(defun iglab-dashboard--insert-cell (text column custom-id face layout)
  "Insert TEXT for COLUMN using LAYOUT and attach CUSTOM-ID to it."
  (let* ((start (point))
         (column-start (car layout))
         (column-width (cdr layout))
         (max-width (max 1 column-width))
         (display-text (truncate-string-to-width text max-width nil nil "...")))
    (unless (zerop column-start)
      (insert (propertize " " 'display (iglab-dashboard--align-space column-start))))
    (insert display-text)
    (when custom-id
      (add-text-properties start (point) `(iglab-dashboard-id ,custom-id mouse-face highlight)))
    (when face
      (add-text-properties start (point) `(face ,face)))))

(defun iglab-dashboard--align-space (column)
  "Return a display spec that aligns to dashboard COLUMN.
Use a pixel specification based on the current face width instead of a
bare column number.  Bare `:align-to' numbers use the frame's canonical
character width, which can disagree with the dashboard face on mixed
fonts and Windows font fallback."
  `(space . (:align-to (,column . width))))

(defun iglab-dashboard--cell-value (key issue note)
  "Return display value for KEY from ISSUE and NOTE."
  (pcase key
    ('state (iglab-dashboard--alist-get 'todo issue))
    ('iid (format "#%s" (iglab-dashboard--alist-get 'iid issue)))
    ('title (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'title issue)))
    ('assignee (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'assignee issue)))
    ('labels (iglab-dashboard--format-labels (alist-get 'labels issue)))
    ('note (iglab-dashboard--cell-text note))
    ('updated (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'updated_at issue)))
    ('project (iglab-dashboard--cell-text (iglab-dashboard--alist-get 'project issue)))
    (_ "")))

(defun iglab-dashboard--cell-face (key)
  "Return display face for column KEY."
  (pcase key
    ((or 'note 'project) 'shadow)
    (_ nil)))

(defun iglab-dashboard--filter-issues (issues)
  "Return ISSUES matching current dashboard filters."
  (seq-filter #'iglab-dashboard--issue-matches-filters-p issues))

(defun iglab-dashboard--issue-matches-filters-p (issue)
  "Return non-nil when ISSUE matches current dashboard filters."
  (let ((assignee (plist-get iglab-dashboard--filters :assignee))
        (project (plist-get iglab-dashboard--filters :project))
        (label (plist-get iglab-dashboard--filters :label))
        (text (plist-get iglab-dashboard--filters :text)))
    (and
     (iglab-dashboard--contains-p (iglab-dashboard--alist-get 'assignee issue) assignee)
     (iglab-dashboard--contains-p (iglab-dashboard--alist-get 'project issue) project)
     (iglab-dashboard--labels-contain-p (alist-get 'labels issue) label)
     (or (string-empty-p (or text ""))
         (iglab-dashboard--contains-p (iglab-dashboard--issue-search-text issue) text)))))

(defun iglab-dashboard--issue-search-text (issue)
  "Return searchable text for ISSUE."
  (let* ((custom-id (iglab-dashboard--issue-custom-id issue))
         (note (gethash custom-id iglab-dashboard--note-summaries "")))
    (string-join
     (list
      (iglab-dashboard--alist-get 'title issue)
      (iglab-dashboard--alist-get 'assignee issue)
      (iglab-dashboard--alist-get 'project issue)
      (iglab-dashboard--alist-get 'updated_at issue)
      note
      (string-join (or (alist-get 'labels issue) nil) " "))
     " ")))

(defun iglab-dashboard--contains-p (value needle)
  "Return non-nil when VALUE contains NEEDLE case-insensitively."
  (or (string-empty-p (or needle ""))
      (string-match-p (regexp-quote (downcase needle)) (downcase (format "%s" (or value ""))))))

(defun iglab-dashboard--labels-contain-p (labels needle)
  "Return non-nil when any label in LABELS contains NEEDLE."
  (or (string-empty-p (or needle ""))
      (seq-some (lambda (label) (iglab-dashboard--contains-p label needle)) labels)))

(defun iglab-dashboard--set-filter (key value)
  "Set dashboard filter KEY to VALUE, removing it when VALUE is empty."
  (setq iglab-dashboard--filters
        (if (string-empty-p (string-trim (or value "")))
            (plist-put iglab-dashboard--filters key nil)
          (plist-put iglab-dashboard--filters key (string-trim value)))))

(defun iglab-dashboard--sort-issues (issues)
  "Return ISSUES sorted by current dashboard sort settings."
  (let ((key iglab-dashboard--sort-key)
        (descending iglab-dashboard--sort-descending))
    (sort
     (copy-sequence issues)
     (lambda (left right)
       (let ((comparison (iglab-dashboard--compare-sort-values
                          (iglab-dashboard--sort-value key left)
                          (iglab-dashboard--sort-value key right))))
         (if descending
             (> comparison 0)
           (< comparison 0)))))))

(defun iglab-dashboard--sort-value (key issue)
  "Return sortable value for KEY from ISSUE."
  (let* ((custom-id (iglab-dashboard--issue-custom-id issue))
         (note (gethash custom-id iglab-dashboard--note-summaries "")))
    (pcase key
      ('state (iglab-dashboard--alist-get 'todo issue))
      ('iid (or (alist-get 'iid issue) 0))
      ('title (iglab-dashboard--alist-get 'title issue))
      ('assignee (iglab-dashboard--alist-get 'assignee issue))
      ('labels (string-join (or (alist-get 'labels issue) nil) " "))
      ('note note)
      ('updated (iglab-dashboard--alist-get 'updated_at issue))
      ('project (iglab-dashboard--alist-get 'project issue))
      (_ ""))))

(defun iglab-dashboard--compare-sort-values (left right)
  "Compare LEFT and RIGHT and return -1, 0, or 1."
  (cond
   ((and (numberp left) (numberp right))
    (cond ((< left right) -1) ((> left right) 1) (t 0)))
   (t
    (let ((left-text (downcase (format "%s" (or left ""))))
          (right-text (downcase (format "%s" (or right "")))))
      (cond ((string< left-text right-text) -1)
            ((string< right-text left-text) 1)
            (t 0))))))

(defun iglab-dashboard--status-suffix ()
  "Return status suffix describing active filters."
  (let (parts)
    (dolist (item '((:assignee . "assignee")
                    (:project . "project")
                    (:label . "label")
                    (:text . "text")))
      (when-let* ((value (plist-get iglab-dashboard--filters (car item))))
        (push (format "  %s=%s" (cdr item) value) parts)))
    (if parts
        (concat "  Filters:" (string-join (nreverse parts) ""))
      "")))

(defun iglab-dashboard--visible-columns ()
  "Return visible dashboard columns as (KEY . (START . WIDTH)).
The returned order is exactly the visible subset of
`iglab-dashboard-columns'."
  (let ((start 0)
        columns)
    (dolist (spec iglab-dashboard-columns)
      (when (iglab-dashboard--column-visible-p spec)
        (let ((key (iglab-dashboard--column-key spec))
              (width (iglab-dashboard--column-width spec)))
          (push (cons key (cons start width)) columns)
          (setq start (+ start width iglab-dashboard-column-gap)))))
    (nreverse columns)))

(defun iglab-dashboard--total-width ()
  "Return the total visible dashboard width."
  (cl-loop for spec in iglab-dashboard-columns
           when (iglab-dashboard--column-visible-p spec)
           sum (+ (iglab-dashboard--column-width spec) iglab-dashboard-column-gap)))

(defun iglab-dashboard--read-column (prompt)
  "Read a dashboard column key with PROMPT."
  (intern
   (completing-read
    prompt
    (mapcar (lambda (spec) (symbol-name (iglab-dashboard--column-key spec)))
            iglab-dashboard-columns)
    nil
    t)))

(defun iglab-dashboard--column-spec (key)
  "Return dashboard column spec for KEY."
  (or (seq-find (lambda (spec) (eq (iglab-dashboard--column-key spec) key))
                iglab-dashboard-columns)
      (user-error "Unknown dashboard column: %s" key)))

(defun iglab-dashboard--column-key (spec)
  "Return column key from SPEC."
  (nth 0 spec))

(defun iglab-dashboard--column-title (key)
  "Return dashboard column title for KEY."
  (nth 1 (iglab-dashboard--column-spec key)))

(defun iglab-dashboard--column-width (spec)
  "Return column width from SPEC."
  (max 4 (or (nth 2 spec) 4)))

(defun iglab-dashboard--column-visible-p (spec)
  "Return non-nil when dashboard column SPEC is visible."
  (nth 3 spec))

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
    (kbd "o") #'iglab-dashboard-sort
    (kbd "/") #'iglab-dashboard-filter-text
    (kbd "s") #'iglab-dashboard-filter-state
    (kbd "a") #'iglab-dashboard-filter-assignee
    (kbd "p") #'iglab-dashboard-filter-project
    (kbd "l") #'iglab-dashboard-filter-label
    (kbd "C") #'iglab-dashboard-clear-filters
    (kbd "L") #'iglab-dashboard-show-labels
    (kbd "T") #'iglab-dashboard-toggle-column
    (kbd "W") #'iglab-dashboard-set-column-width
    (kbd "b") #'iglab-dashboard-browse-issue
    (kbd "q") #'quit-window))

(provide 'iglab)

;;; iglab.el ends here
