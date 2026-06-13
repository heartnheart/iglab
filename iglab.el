;;; iglab.el --- GitLab issue dashboard helpers -*- lexical-binding: t; -*-

;; This file is intentionally small: Python owns sync, SQLite, and rendering.

;;; Code:

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

(provide 'iglab)

;;; iglab.el ends here
