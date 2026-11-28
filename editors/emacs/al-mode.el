;;; al-mode.el --- Major mode and LSP integration for AgentLang (AL) -*- lexical-binding: t; -*-

;; Author: AgentLang Contributors
;; Keywords: languages, al, agentlang, lsp
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Major mode for AgentLang (.al) source files with:
;; - Syntax highlighting (keywords, types, builtins, raw backtick strings,
;;   numbers, comments, and `// alc fmt: off|on` directives)
;; - Indentation matching `alc fmt` (4 spaces)
;; - Automatic `eglot` and `lsp-mode` registration for `alc lsp`
;; - `al-fmt-buffer` (`C-c C-f`) and optional format-on-save (`al-format-on-save`)
;; - `al-check` (`C-c C-c`), `al-test` (`C-c C-t`), `al-run` (`C-c C-r`),
;;   `al-build` (`C-c C-b`) with clickable `compilation-mode` error patterns
;; - `imenu` navigation for functions, structs, enums, constants, and tests

;;; Code:

(require 'compile)
(require 'prog-mode)

(defgroup al nil
  "Support for AgentLang (AL)."
  :group 'languages
  :prefix "al-")

(defcustom al-alc-command "alc"
  "Path or command name of the AgentLang compiler (`alc`)."
  :type 'string
  :group 'al)

(defcustom al-indent-offset 4
  "Number of spaces per indentation level in `al-mode' (matches `alc fmt')."
  :type 'integer
  :safe #'integerp
  :group 'al)

(defcustom al-format-on-save nil
  "When non-nil, run `al-fmt-buffer' automatically before saving `.al' files."
  :type 'boolean
  :safe #'booleanp
  :group 'al)

(defcustom al-enable-eglot t
  "When non-nil, register `alc lsp' automatically with `eglot-server-programs'."
  :type 'boolean
  :group 'al)

;; ---------- Syntax Table & Raw String Propertization ----------

(defvar al-mode-syntax-table
  (let ((st (make-syntax-table)))
    ;; Operators and punctuation
    (dolist (c '(?+ ?- ?* ?% ?& ?| ?^ ?! ?< ?> ?= ?~ ?: ?\; ?, ?. ??))
      (modify-syntax-entry c "." st))
    ;; Comments: // ... to end of line
    (modify-syntax-entry ?/ ". 12b" st)
    (modify-syntax-entry ?\n "> b" st)
    ;; Strings and character literals
    (modify-syntax-entry ?\" "\"" st)
    (modify-syntax-entry ?' "\"" st)
    (modify-syntax-entry ?\\ "\\" st)
    ;; Underscore is part of symbols/identifiers
    (modify-syntax-entry ?_ "_" st)
    ;; Paired delimiters
    (modify-syntax-entry ?\( "()" st)
    (modify-syntax-entry ?\) ")(" st)
    (modify-syntax-entry ?\[ "(]" st)
    (modify-syntax-entry ?\] ")[" st)
    (modify-syntax-entry ?\{ "(}" st)
    (modify-syntax-entry ?\} "){" st)
    st)
  "Syntax table for `al-mode'.")

(defconst al--syntax-propertize-function
  (syntax-propertize-rules
   ("`"
    (0 (prog1 (string-to-syntax "|")
         (let ((ppss (save-excursion (syntax-ppss (match-beginning 0)))))
           (unless (or (nth 3 ppss) (nth 4 ppss))
             ;; Mark backslashes inside the raw string as punctuation
             (let ((close (save-excursion (search-forward "`" (point-max) t))))
               (when close
                 (save-excursion
                   (goto-char (match-end 0))
                   (while (search-forward "\\" (1- close) t)
                     (put-text-property (1- (point)) (point)
                                        'syntax-table (string-to-syntax ".")))))))))))))

;; ---------- Font Lock ----------

(defconst al--keywords
  '("fn" "struct" "enum" "const" "priv" "use" "when"
    "if" "else" "match" "for" "in" "by" "while" "loop"
    "break" "continue" "return" "defer" "assert" "test"
    "extern" "inline" "noinline")
  "AL language keywords.")

(defconst al--primitive-types
  '("i8" "i16" "i32" "i64" "u8" "u16" "u32" "u64"
    "f32" "f64" "bool" "str" "never"
    "vec2" "vec3" "vec4" "quat" "mat4"
    "Opt" "Vec" "Map" "Region")
  "AL built-in and core generic types.")

(defconst al--constants
  '("true" "false" "nil" "Some" "None"
    "TARGET_OS" "TARGET_ARCH" "Linux" "Windows" "MacOS" "X86_64" "Arm64")
  "AL built-in constants and core enum variants.")

(defconst al--builtins
  '("print" "put" "putf" "eprint" "eput" "flush"
    "fmt" "fmtf" "fmti" "hex" "to_base"
    "len" "sizeof" "offsetof" "variant_count"
    "std140_size" "std430_size" "hlsl_cbuffer_size"
    "cast" "ptr" "mkslice" "memcopy" "memfill" "copy" "fill"
    "hash" "clone" "panic" "embed" "exit" "args" "env_get"
    "alloc" "new" "vec" "vec_of" "vec_fill" "map"
    "mark" "release" "region" "enter" "leave" "reset" "region_free" "mem_used"
    "sort" "sort_by" "min" "max" "abs" "floor" "ceil" "swap" "reverse"
    "sqrt" "fabs" "fmin" "fmax"
    "popcnt" "ctz" "clz" "bswap" "rotl" "rotr" "mulhi" "sat_add" "sat_sub"
    "syscall" "atomic_load" "atomic_store" "atomic_swap" "atomic_add"
    "atomic_sub" "atomic_and" "atomic_or" "atomic_xor" "atomic_cas" "atomic_fence")
  "AL compiler builtins and prelude functions.")

(defvar al-font-lock-keywords
  `(
    ;; Formatter directives: // alc fmt: off / on
    ("//[ \t]*alc fmt:[ \t]*\\(?:off\\|on\\)\\b.*" 0 font-lock-preprocessor-face t)
    ;; Declaration names
    ("\\_<fn\\_>[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1 font-lock-function-name-face)
    ("\\_<\\(?:struct\\|enum\\)\\_>[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1 font-lock-type-face)
    ("\\_<const\\_>[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1 font-lock-constant-face)
    ;; Module path in `use std.foo`
    ("\\_<use\\_>[ \t]+\\(std\\.[A-Za-z_][A-Za-z0-9_]*\\)" 1 font-lock-constant-face)
    ;; Keywords
    (,(regexp-opt al--keywords 'symbols) . font-lock-keyword-face)
    ;; Primitive and core types
    (,(regexp-opt al--primitive-types 'symbols) . font-lock-type-face)
    ;; Built-in constants
    (,(regexp-opt al--constants 'symbols) . font-lock-constant-face)
    ;; Built-in functions (followed by `(` or `[`)
    (,(concat "\\_<" (regexp-opt al--builtins t) "\\_>[ \t]*[(\\[]") 1 font-lock-builtin-face)
    ;; Loop labels `@name`
    ("@[A-Za-z_][A-Za-z0-9_]*" . font-lock-constant-face)
    ;; CamelCase type identifiers
    ("\\_<[A-Z][A-Za-z0-9_]*\\_>" . font-lock-type-face)
    ;; Function calls `foo(`
    ("\\_<\\([a-z_][A-Za-z0-9_]*\\)\\_>[ \t]*(" 1 font-lock-function-name-face)
    ;; Numeric literals (hex, binary, octal, decimal, float)
    ("\\_<0[xX][0-9A-Fa-f_]+\\_>" . font-lock-constant-face)
    ("\\_<0[bB][01_]+\\_>" . font-lock-constant-face)
    ("\\_<0[oO][0-7_]+\\_>" . font-lock-constant-face)
    ("\\_<[0-9][0-9_]*\\(?:\\.[0-9_]+\\)?\\(?:[eE][+-]?[0-9_]+\\)?\\_>" . font-lock-constant-face))
  "Font-lock rules for `al-mode'.")

;; ---------- Indentation ----------

(defun al--prev-code-line-ends-cont-p ()
  "Return non-nil if the previous code line ends with a continuation operator."
  (save-excursion
    (beginning-of-line)
    (let ((found nil))
      (while (and (not found) (not (bobp)))
        (forward-line -1)
        (let ((line (string-trim
                     (replace-regexp-in-string
                      "//.*$" ""
                      (buffer-substring-no-properties (line-beginning-position)
                                                      (line-end-position))))))
          (unless (string-empty-p line)
            (setq found
                  (string-match-p
                   "\\(?:[-+*/%^&|=]\\|<=\\|>=\\|<<\\|>>\\|->\\|=>\\)\\'"
                   line))
            (unless found
              (setq found 'no)))))
      (and found (not (eq found 'no))))))

(defun al--block-indent (open)
  "Return the indentation of the statement that holds the bracket at OPEN.
That is the line of OPEN itself, unless the line is the tail of a wrapped
signature or condition (`b: i64) -> T {', `    y > 0 {'): then it is the
line the wrapped construct starts on."
  (save-excursion
    (goto-char open)
    (let ((depth (car (syntax-ppss)))
          ppss)
      (back-to-indentation)
      (while (and (> (car (setq ppss (syntax-ppss))) depth) (nth 1 ppss))
        (goto-char (nth 1 ppss))
        (back-to-indentation))
      (if (al--prev-code-line-ends-cont-p)
          (max 0 (- (current-indentation) al-indent-offset))
        (current-indentation)))))

(defun al--trailing-comment-column (col)
  "Return COL if the comment block above ends a line of code at column COL.
The lines above may be more comment lines at COL; the first one that is
not must carry a trailing comment there."
  (save-excursion
    (let (result done)
      (while (and (not done) (zerop (forward-line -1)))
        (back-to-indentation)
        (unless (and (looking-at-p "//") (= (current-column) col))
          (setq done t)
          (end-of-line)
          (let ((ppss (syntax-ppss)))
            (when (nth 4 ppss)
              (goto-char (nth 8 ppss))
              (when (= (current-column) col)
                (setq result col))))))
      result)))

(defun al--calculate-indent ()
  "Return the column the current line should be indented to, or nil to keep it.
Like `alc fmt', a line inside brackets is one level deeper than the
statement that holds the innermost open bracket (so `f(T{' opens a single
level), a closing bracket lines up with that statement, and a line after
one that ends in a binary operator is one level deeper again."
  (save-excursion
    (back-to-indentation)
    (let* ((ppss (syntax-ppss))
           (open (nth 1 ppss))
           (open-indent (and open (al--block-indent open))))
      (cond
       ;; Inside a multiline raw string: leave the text alone
       ((nth 3 ppss) nil)
       ;; A comment that continues the trailing comment of the line above
       ((and (looking-at-p "//")
             (al--trailing-comment-column (current-column)))
        nil)
       ((looking-at-p "[])}]") (or open-indent 0))
       (t
        (let ((base (if open (+ open-indent al-indent-offset) 0)))
          (if (and (al--prev-code-line-ends-cont-p)
                   ;; no second level for `f(a +' / `    b)': the wrapped
                   ;; argument list is the continuation already
                   (or (null open)
                       (eq (char-after open) ?\{)
                       (save-excursion
                         (goto-char (1+ open))
                         (looking-at-p "[ \t]*\\(?://.*\\)?$"))))
              (+ base al-indent-offset)
            base)))))))

(defun al-indent-line ()
  "Indent current line according to AgentLang (`alc fmt') rules."
  (interactive)
  (let ((savep (> (current-column) (current-indentation)))
        (indent (al--calculate-indent)))
    (when indent
      (if savep
          (save-excursion (indent-line-to indent))
        (indent-line-to indent)))))

;; ---------- Imenu ----------

(defvar al-imenu-generic-expression
  '(("Functions" "^[ \t]*\\(?:priv[ \t]+\\)?\\(?:inline[ \t]+\\|noinline[ \t]+\\)?\\(?:extern[ \t]+[^ \t]+[ \t]+\\)?fn[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1)
    ("Structs"   "^[ \t]*\\(?:priv[ \t]+\\)?struct[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1)
    ("Enums"     "^[ \t]*\\(?:priv[ \t]+\\)?enum[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1)
    ("Constants" "^[ \t]*\\(?:priv[ \t]+\\)?const[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)" 1)
    ("Tests"     "^[ \t]*test[ \t]+\"\\([^\"]+\\)\"" 1))
  "Imenu patterns for `al-mode'.")

;; ---------- Compilation Error Pattern ----------

(defconst al-compilation-error-regexp
  '("^\\([^:\n]+\\.al\\):\\([0-9]+\\):\\([0-9]+\\): \\(?:\\(warning\\)\\|error\\):"
    1 2 3 (4))
  "Compilation error regex for `alc' diagnostics.")

(with-eval-after-load 'compile
  (add-to-list 'compilation-error-regexp-alist-alist (cons 'alc al-compilation-error-regexp))
  (add-to-list 'compilation-error-regexp-alist 'alc))

;; ---------- Formatting & Compiler Commands ----------

(defun al-fmt-buffer ()
  "Format the current buffer using `alc fmt -'."
  (interactive)
  (let* ((alc (or (executable-find al-alc-command) al-alc-command))
         (orig-buf (current-buffer))
         (out-buf (get-buffer-create " *alc-fmt-out*"))
         (err-buf (get-buffer-create " *alc-fmt-err*"))
         (err-file (make-temp-file "alc-fmt-err-")))
    (unwind-protect
        (progn
          (with-current-buffer out-buf (erase-buffer))
          (let ((exit-code
                 (call-process-region (point-min) (point-max)
                                      alc nil (list out-buf err-file) nil
                                      "fmt" "-")))
            (if (eq exit-code 0)
                (unless (zerop (compare-buffer-substrings orig-buf nil nil out-buf nil nil))
                  (if (fboundp 'replace-buffer-contents)
                      (replace-buffer-contents out-buf)
                    (let ((pt (point))
                          (ws (window-start)))
                      (erase-buffer)
                      (insert-buffer-substring out-buf)
                      (goto-char (min pt (point-max)))
                      (set-window-start nil (min ws (point-max))))))
              (with-current-buffer err-buf
                (erase-buffer)
                (insert-file-contents err-file)
                (message "alc fmt failed: %s" (string-trim (buffer-string)))))))
      (when (file-exists-p err-file)
        (delete-file err-file)))))

(defun al--before-save-hook ()
  "Format buffer before save when `al-format-on-save' is non-nil."
  (when al-format-on-save
    (al-fmt-buffer)))

(defun al--compile-file (subcmd &optional extra-args)
  "Run `alc SUBCMD EXTRA-ARGS <current-file>' in `compilation-mode'."
  (unless buffer-file-name
    (user-error "Buffer is not visiting a file"))
  (save-buffer)
  (let ((cmd (mapconcat #'shell-quote-argument
                        (append (list al-alc-command subcmd)
                                extra-args
                                (list buffer-file-name))
                        " ")))
    (compile cmd)))

(defun al-check ()
  "Run `alc check -W' on the current file."
  (interactive)
  (al--compile-file "check" '("-W")))

(defun al-test ()
  "Run `alc test' on the current file."
  (interactive)
  (al--compile-file "test"))

(defun al-run ()
  "Run `alc run' on the current file."
  (interactive)
  (al--compile-file "run"))

(defun al-build ()
  "Run `alc build' on the current file."
  (interactive)
  (al--compile-file "build"))

;; ---------- LSP Registration (Eglot & lsp-mode) ----------

(defvar eglot-server-programs)
(defvar lsp-language-id-configuration)
(declare-function lsp-register-client "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function lsp-activate-on "lsp-mode")

(defun al--eglot-contact (_interactive)
  "Return the command list for Eglot to start `alc lsp'."
  (list al-alc-command "lsp"))

(with-eval-after-load 'eglot
  (when al-enable-eglot
    (add-to-list 'eglot-server-programs
                 '(al-mode . al--eglot-contact))))

(with-eval-after-load 'lsp-mode
  (when (fboundp 'lsp-register-client)
    (add-to-list 'lsp-language-id-configuration '(al-mode . "al"))
    (lsp-register-client
     (make-lsp-client
      :new-connection (lsp-stdio-connection (lambda () (list al-alc-command "lsp")))
      :activation-fn (lsp-activate-on "al")
      :server-id 'alc-lsp))))

;; ---------- Keymap & Major Mode ----------

(defvar al-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-f") #'al-fmt-buffer)
    (define-key map (kbd "C-c C-c") #'al-check)
    (define-key map (kbd "C-c C-t") #'al-test)
    (define-key map (kbd "C-c C-r") #'al-run)
    (define-key map (kbd "C-c C-b") #'al-build)
    map)
  "Keymap for `al-mode'.")

;;;###autoload
(define-derived-mode al-mode prog-mode "AL"
  "Major mode for editing AgentLang (AL) source code."
  :syntax-table al-mode-syntax-table
  :group 'al
  (setq-local comment-start "// ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "//+\\s-*")
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width al-indent-offset)
  (setq-local indent-line-function #'al-indent-line)
  (setq-local syntax-propertize-function al--syntax-propertize-function)
  (setq-local font-lock-defaults '(al-font-lock-keywords))
  (setq-local imenu-generic-expression al-imenu-generic-expression)
  (setq-local electric-indent-chars (append '(?\{ ?\} ?\( ?\) ?\[ ?\] ?\n) electric-indent-chars))
  (add-hook 'before-save-hook #'al--before-save-hook nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.al\\'" . al-mode))

(provide 'al-mode)
;;; al-mode.el ends here
