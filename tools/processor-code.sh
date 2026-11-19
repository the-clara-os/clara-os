#!/bin/sh
# What lisp/native.lisp makes of a function for a processor, as that
# processor's instructions, read back by LLVM.
#
# usage: tools/processor-code.sh arm64|x86-64 '(lambda (n) (+ n 1))'
#
# The form is compiled by lisp/compiler.lisp under SBCL, the machine's
# instructions are listed, and then the code for the processor, which a
# kernel would be handed as it stands. Needs sbcl, and llvm-mc and
# llvm-objdump: Homebrew's llvm has both, and elsewhere they come from the
# PATH. The numbers that the code reaches the kernel by are the stand-in's
# (lisp/host/vm.lisp), which are the kernel's own.
set -e
cd "$(dirname "$0")/.."
machine="$1"
form="$2"
case "$machine" in
    arm64)  triple=arm64-apple-macos ;;
    x86-64) triple=x86_64-apple-macos ;;
    *) echo "usage: tools/processor-code.sh arm64|x86-64 '(lambda (n) (+ n 1))'" >&2; exit 2 ;;
esac
[ -n "$form" ] || { echo "tools/processor-code.sh: no form" >&2; exit 2; }
llvm=/opt/homebrew/opt/llvm/bin
[ -x "$llvm/llvm-mc" ] && PATH="$llvm:$PATH"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
FORM="$form" MACHINE="$machine" OUT="$work/code.s" sbcl --noinform --non-interactive \
    --eval '(handler-bind ((warning (function muffle-warning)))
              (dolist (file (quote ("lisp/host/clara.lisp" "lisp/compiler.lisp" "lisp/host/vm.lisp" "lisp/native.lisp"
                                    "lisp/arm64.lisp" "lisp/x86-64.lisp")))
                (load file)))' \
    --eval '(let* ((form (let ((*package* (find-package "COMMON-LISP-USER"))) (read-from-string (sb-ext:posix-getenv "FORM"))))
                   (machine (intern (string-upcase (sb-ext:posix-getenv "MACHINE")) "KEYWORD"))
                   (code (clara.compiler::generate
                          (clara.compiler::convert-function nil (cadr form) (cddr form) (clara.compiler::make-env)))))
              (clara.native:start)
              (setq clara.native::*machine* machine)
              (clara.compiler::list-code code)
              (let ((words (clara.native::assemble (clara.native::lower code) (get machine (quote clara.native::writer))
                                                   (get machine (quote clara.native::unit)))))
                (format t "~D bytes for the processor:~%" (* 4 (length words)))
                (with-open-file (out (sb-ext:posix-getenv "OUT") :direction :output)
                  (format out " .text~%")
                  (loop for word across words
                        do (format out " .byte ~D, ~D, ~D, ~D~%" (ldb (byte 8 0) word) (ldb (byte 8 8) word)
                                   (ldb (byte 8 16) word) (ldb (byte 8 24) word))))))' 2>&1 | grep -v '^;\|^$'
llvm-mc -triple="$triple" -filetype=obj "$work/code.s" -o "$work/code.o"
llvm-objdump -d --no-show-raw-insn "$work/code.o" | sed -n '/^ *0:/,$p'
