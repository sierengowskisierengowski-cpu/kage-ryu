# scx_kage — Kage-Ryu sched-ext scheduler build
#
# Requires: clang, bpftool, libbpf (libbpf.so + headers), llvm-strip.
# Generates vmlinux.h from the running kernel's BTF, so it always matches
# whatever kernel you build on.

CLANG   ?= clang
BPFTOOL ?= bpftool
CC      ?= cc

ARCH := $(shell uname -m | sed 's/x86_64/x86/;s/aarch64/arm64/')
BTF  := /sys/kernel/btf/vmlinux

DESTDIR ?=
PREFIX  ?= /usr/local
BINDIR   = $(DESTDIR)$(PREFIX)/bin

BPF_CFLAGS := -g -O2 -Wall -target bpf -D__TARGET_ARCH_$(ARCH) -I.
USR_CFLAGS := -g -O2 -Wall -I.
USR_LDLIBS := -lbpf -lelf -lz

.PHONY: all clean install
all: scx_kage

vmlinux.h:
	$(BPFTOOL) btf dump file $(BTF) format c > $@

scx_kage.bpf.o: scx_kage.bpf.c vmlinux.h
	$(CLANG) $(BPF_CFLAGS) -c $< -o $@
	llvm-strip -g $@

scx_kage.skel.h: scx_kage.bpf.o
	$(BPFTOOL) gen skeleton $< name scx_kage > $@

scx_kage: scx_kage.c scx_kage.skel.h
	$(CC) $(USR_CFLAGS) $< -o $@ $(USR_LDLIBS)

install: scx_kage
	install -Dm755 scx_kage      $(BINDIR)/scx_kage
	install -Dm755 scx_kage_ctl  $(BINDIR)/scx_kage_ctl

clean:
	rm -f scx_kage scx_kage.bpf.o scx_kage.skel.h vmlinux.h
