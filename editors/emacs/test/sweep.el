;;; sweep.el --- al-mode tests: indentation against alc fmt, and Eglot -*- lexical-binding: t; -*-
;; Run by run.sh: emacs -Q --batch -L .. -l sweep.el -- <repo root> <alc> <scratch dir>
(require 'al-mode)
(require 'eglot)
(require 'cl-lib)

(defconst al-test-root (nth 1 command-line-args-left))
(defconst al-test-alc (nth 2 command-line-args-left))
(defconst al-test-tmp (nth 3 command-line-args-left))
(setq command-line-args-left nil)

;; The one layout of alc fmt that `al-indent-line' does not reproduce: the patterns of a
;; match arm wrapped after a comma (two lines of src/debug.al).
(defconst al-test-allowed 2)

(defun al-test-indent ()
  "Re-indent every line of src/ and std/: `alc fmt' laid them out, so nothing may move."
  (let ((lines 0) (bad 0))
    (dolist (dir '("src" "std"))
      (dolist (f (directory-files (expand-file-name dir al-test-root) t "\\.al\\'"))
        (with-temp-buffer
          (insert-file-contents f)
          (al-mode)
          (while (not (eobp))
            (unless (looking-at-p "[ \t]*$")
              (let ((want (current-indentation)))
                (al-indent-line)
                (setq lines (1+ lines))
                (unless (= want (current-indentation))
                  (setq bad (1+ bad))
                  (message "%s:%d: indented to %d, alc fmt has %d"
                           f (line-number-at-pos) (current-indentation) want)
                  (indent-line-to want))))
            (forward-line 1)))))
    (message "indent: %d lines, %d differ from alc fmt (%d allowed)" lines bad al-test-allowed)
    (<= bad al-test-allowed)))

(defun al-test-lsp ()
  "Start `alc lsp' through Eglot: a diagnostic, hover, and `al-fmt-buffer'."
  (let ((file (expand-file-name "main.al" al-test-tmp))
        (al-alc-command al-test-alc)
        (eglot-sync-connect 10)
        (ok t))
    (with-temp-file file
      (insert "fn add(a: i64, b: i64) -> i64 {\nreturn a+b\n}\n\n"
              "fn main() {\n    print(add(1, 2), undefined_thing)\n}\n"))
    (find-file file)
    (condition-case err
        (call-interactively #'eglot)
      (error (message "lsp: %s" (error-message-string err))))
    (let ((srv (eglot-current-server)))
      (if (not srv)
          (progn (message "lsp: Eglot did not connect") (setq ok nil))
        (let ((n 0))
          (while (and (< n 50) (null (flymake-diagnostics)))
            (accept-process-output nil 0.1)
            (setq n (1+ n))))
        (unless (cl-some (lambda (d) (string-match-p "undefined_thing" (flymake-diagnostic-text d)))
                         (flymake-diagnostics))
          (message "lsp: no diagnostic for the unknown identifier")
          (setq ok nil))
        (goto-char (point-min))
        (search-forward "add(1")
        (backward-char 4)
        (let ((hover (format "%S" (jsonrpc-request srv :textDocument/hover
                                                   (eglot--TextDocumentPositionParams)))))
          (unless (string-match-p "fn add(a: i64, b: i64) -> i64" hover)
            (message "lsp: hover is %s" hover)
            (setq ok nil)))
        (eglot-shutdown srv)))
    (al-fmt-buffer)
    (unless (save-excursion (goto-char (point-min)) (search-forward "\n    return a + b\n" nil t))
      (message "fmt: al-fmt-buffer left %S" (buffer-string))
      (setq ok nil))
    (set-buffer-modified-p nil)
    (message "lsp and fmt: %s" (if ok "ok" "FAILED"))
    ok))

(let ((indent (al-test-indent))
      (lsp (al-test-lsp)))
  (kill-emacs (if (and indent lsp) 0 1)))
;;; sweep.el ends here
